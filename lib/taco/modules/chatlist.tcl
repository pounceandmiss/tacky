# taco_chatlist - one flat list of chat entries (roster + bookmarks + chats).
#
# The list is the union of roster contacts, bookmarked rooms, and any chat
# with message history. Each entry is keyed by its chat JID and carries a
# `source`:
#   roster     - a roster contact (bare JID)
#   bookmarks  - a bookmarked room (room@muc?join)
#   free       - has chat history but is in neither roster nor bookmarks
#
# `invited` marks an unjoined room with a pending invite (usually why it is
# listed at all).
#
# Every jid is a chat JID, opened verbatim: bare = 1:1, room@muc?join = group
# chat, room@muc/nick = MUC PM. The ?join suffix is the tell for group vs 1:1.
#
# Each entry also carries `unread`: how many of the other side's messages
# sit past our own read watermark (see message markOwnRead), and
# `unread_mentions`: how many of those named us. A chat with history carries
# its newest message as `last_message` (a `history` dict), and `last_activity`
# is that message's timestamp. Rendering a preview from it is the frontend's job.
#
# Pinned chats (`pin`, `setPinned`) are local to this device. They and the
# chat with our own bare JID (`is_self`) are listed even with no history.
# Each entry carries an opaque `order`: the list reads by `order` descending,
# ties broken by jid, and pins sit above any activity.
#
# The module is the sole funnel: it consumes roster/bookmarks/room-state,
# new-message, read-watermark, tail-message, blocking and notify-policy
# signals and normalizes them
# into three protocol-agnostic events over the flat collection:
#   chatlist <Item>   -jid $jid -item $entry   upsert (add/rename/activity/state)
#   chatlist <Remove> -jid $jid                delete
#   chatlist <Changed>                         reset (refetch via `get`)
# Sorting by `order`, filtering, and any windowing are the frontend's job.

snit::type taco_chatlist {
    option -client -readonly yes

    # Pinned chats' order starts here, above any microsecond timestamp
    # (2^52 us is the year 2112; a later one is held below it). Every order
    # stays under 2^53, so a JSON reader using doubles keeps it exact.
    typevariable PinBase [expr {1 << 52}]

    variable client
    variable db

    # chat_jid -> newest message timestamp, so backfill emits nothing
    variable MaxTimestamps {}
    # chat_jid -> 1, flushed on idle: one <Item> per chat per batch
    variable PendingTails {}
    variable TailToken ""

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]

        $client bus subscribe $self roster:<Changed> [mymethod OnRosterChanged]
        $client bus subscribe $self bookmarks:<Changed> [mymethod OnBookmarkChanged]
        $client bus subscribe $self bookmarks:<RoomState> [mymethod OnRoomState]
        $client bus subscribe $self message:<OwnRead> [mymethod OnOwnRead]
        # The trigger below covers a new tail; these cover changes to the
        # existing one.
        $client bus subscribe $self message:<Edited> [mymethod OnTailChanged]
        $client bus subscribe $self message:<Retracted> [mymethod OnTailChanged]
        $client bus subscribe $self message:<Status> [mymethod OnTailChanged]
        $client bus subscribe $self message:<Confirmed> [mymethod OnTailConfirmed]
        $client bus subscribe $self blocking:<Changed> [mymethod OnBlockingChanged]
        $client bus subscribe $self notify:<Settings> [mymethod OnNotifySettings]

        # A hole sits just past the newest message; it is not one.
        $db eval {
            SELECT chat_jid, MAX(timestamp) AS max_ts
            FROM chat_message
            WHERE kind='message'
            GROUP BY chat_jid
        } row {
            dict set MaxTimestamps $row(chat_jid) $row(max_ts)
        }

        # Older databases carry this trigger under the chats module's name.
        $db function _chatlist_on_message [mymethod OnMessage]
        $db eval {
            DROP TRIGGER IF EXISTS trg_chats_on_message;
            CREATE TRIGGER IF NOT EXISTS trg_chatlist_on_message
            AFTER INSERT ON chat_message
            WHEN NEW.kind='message'
            BEGIN
                SELECT _chatlist_on_message(NEW.chat_jid, NEW.timestamp);
            END;
        }
    }

    # The last blocking:<Changed> list, to diff the next one against.
    variable Blocked {}

    destructor {
        catch {$client bus unsubscribe $self}
        catch {after cancel $TailToken}
    }

    # -- the whole list -------------------------------------------------

    tackymethod get {args} {
        set tails [$client message messagestore lastMessages]
        set tallies [$client message messagestore unreadTallies]

        set entries {}
        set seen {}

        foreach item [$client roster get] {
            set bare [dict get $item jid]
            lappend entries [$self MakeEntry $bare roster $item \
                [$self Lookup $tails $bare] [$self Tally $tallies $bare]]
            dict set seen $bare 1
        }
        foreach item [$client bookmarks get] {
            set chatJid [dict get $item jid]?join
            lappend entries [$self MakeEntry $chatJid bookmarks $item \
                [$self Lookup $tails $chatJid] [$self Tally $tallies $chatJid]]
            dict set seen $chatJid 1
        }
        dict for {chatJid tail} $tails {
            if {[dict exists $seen $chatJid]} continue
            lappend entries [$self MakeEntry $chatJid free {} $tail \
                [$self Tally $tallies $chatJid]]
            dict set seen $chatJid 1
        }
        # Listed with no source and no history: pinned chats, and ours.
        set bare [$self SelfJid]
        foreach chatJid [concat [$self PinnedJids] [list $bare]] {
            if {$chatJid eq "" || [dict exists $seen $chatJid]} continue
            lappend entries [$self MakeEntry $chatJid free {} "" \
                [$self Tally $tallies $chatJid]]
            dict set seen $chatJid 1
        }
        return $entries
    }

    # -- pins -----------------------------------------------------------

    # pin -jid J -pinned 0|1: a new pin goes on top of the others.
    tackymethod -noreturn pin {args} {
        set chatJid [dict get $args -jid]
        set want [expr {[dict get $args -pinned] ? 1 : 0}]
        if {$want == ([$self PinOrd $chatJid] > 0)} return
        if {$want} {
            $db eval {
                INSERT INTO chat_pin(chat_jid, ord)
                VALUES($chatJid, (SELECT COALESCE(MAX(ord), 0) + 1 FROM chat_pin))
            }
        } else {
            $db eval {DELETE FROM chat_pin WHERE chat_jid=$chatJid}
        }
        $self EmitEntry $chatJid
    }

    # setPinned -jids {top ... bottom}: the whole pinned list, in order.
    # A pinned chat left out is unpinned.
    tackymethod -noreturn setPinned {args} {
        set jids [dict get $args -jids]
        if {[llength [lsort -unique $jids]] != [llength $jids]} {
            return -code error -errorcode TACO_CHATLIST_DUPLICATE \
                "setPinned: a chat is listed twice"
        }
        set old [dict create]
        $db eval {SELECT chat_jid, ord FROM chat_pin} {
            dict set old $chat_jid $ord
        }
        set new [dict create]
        set ord [llength $jids]
        foreach chatJid $jids {
            dict set new $chatJid $ord
            incr ord -1
        }
        $db transaction {
            $db eval {DELETE FROM chat_pin}
            dict for {chatJid ord} $new {
                $db eval {INSERT INTO chat_pin(chat_jid, ord) VALUES($chatJid, $ord)}
            }
        }
        foreach chatJid [lsort -unique [concat [dict keys $old] [dict keys $new]]] {
            if {[$self Lookup $old $chatJid] ne [$self Lookup $new $chatJid]} {
                $self EmitEntry $chatJid
            }
        }
    }

    # The pinned chats, top first.
    method PinnedJids {} {
        $db eval {SELECT chat_jid FROM chat_pin ORDER BY ord DESC}
    }

    # A chat's pin rank, higher on top; 0 when it is not pinned.
    method PinOrd {chatJid} {
        set ord [$db onecolumn {SELECT ord FROM chat_pin WHERE chat_jid=$chatJid}]
        if {$ord eq ""} { return 0 }
        return $ord
    }

    # Our own bare JID; "" before we have one.
    method SelfJid {} {
        set jid [$client cget -jid]
        if {$jid eq ""} { return "" }
        return [jid norm [jid bare $jid]]
    }

    # -- single-entry resolution (event path) ---------------------------

    # The unified entry for one chat JID, or "" if it belongs to no source,
    # has no chat history, is not pinned, and is not our own.
    method EntryFor {chatJid} {
        set bare [regsub {\?join$} $chatJid {}]
        set isRoom [expr {$bare ne $chatJid}]
        set tally [$client message messagestore unreadTally $chatJid]
        set tail [$client message messagestore lastMessage $chatJid]
        if {$isRoom} {
            set bm [$self BookmarkEntry $bare]
            if {$bm ne ""} {
                return [$self MakeEntry $chatJid bookmarks $bm $tail $tally]
            }
        } else {
            set r [$self RosterEntry $bare]
            if {$r ne ""} {
                return [$self MakeEntry $chatJid roster $r $tail $tally]
            }
        }
        if {$tail ne "" || [$self PinOrd $chatJid] > 0
            || $chatJid eq [$self SelfJid]} {
            return [$self MakeEntry $chatJid free {} $tail $tally]
        }
        return ""
    }

    # tail is the chat's newest message dict, or "" for a chat with no history.
    method MakeEntry {chatJid source base tail tally} {
        set unread [dict get $tally unread]
        set mentions [dict get $tally mentions]
        set policy [$client message messagestore notifyPolicy $chatJid]
        set entry $base
        dict set entry jid $chatJid
        dict set entry source $source
        dict set entry groupchat [expr {[string match {*\?join} $chatJid] ? 1 : 0}]
        dict set entry is_self [expr {$chatJid eq [$self SelfJid]}]
        if {$tail ne ""} {
            dict set entry last_message $tail
            dict set entry last_activity [dict get $tail timestamp]
        } else {
            dict set entry last_activity 0
        }
        set pin [$self PinOrd $chatJid]
        dict set entry pinned [expr {$pin > 0}]
        dict set entry order [expr {$pin > 0 ? $PinBase + $pin
            : min([dict get $entry last_activity], $PinBase - 1)}]
        dict set entry unread $unread
        dict set entry unread_mentions $mentions
        dict set entry muted [dict get $policy muted]
        dict set entry mentions [dict get $policy mentions]
        if {![dict exists $entry name]} { dict set entry name "" }
        if {![dict exists $entry autojoin]} { dict set entry autojoin 0 }
        dict set entry blocked [expr {$chatJid in [$client blocking list]}]
        dict set entry invited [expr {[dict get $entry groupchat]
            && ![dict get $entry autojoin]
            && [$client message messagestore pendingInvite $chatJid]}]
        return $entry
    }

    # -- source lookups -------------------------------------------------

    method RosterEntry {bare} {
        foreach item [$client roster get] {
            if {[dict get $item jid] eq $bare} { return $item }
        }
        return ""
    }

    method BookmarkEntry {bare} {
        foreach item [$client bookmarks get] {
            if {[dict get $item jid] eq $bare} { return $item }
        }
        return ""
    }

    # A per-chat map's value for one chat, "" when it has no entry.
    method Lookup {map key} {
        if {[dict exists $map $key]} { return [dict get $map $key] }
        return ""
    }

    method Tally {tallies chatJid} {
        if {[dict exists $tallies $chatJid]} {
            return [dict get $tallies $chatJid]
        }
        return {unread 0 mentions 0}
    }

    # -- event funnel ---------------------------------------------------

    method OnRosterChanged {args} {
        array set opts {-action "" -jid ""}
        array set opts $args
        if {$opts(-action) eq "clear" || $opts(-jid) eq ""} {
            $client emit chatlist <Changed>
            return
        }
        $self EmitEntry $opts(-jid)
    }

    method OnBookmarkChanged {args} {
        array set opts {-action "" -jid ""}
        array set opts $args
        if {$opts(-action) eq "clear" || $opts(-jid) eq ""} {
            $client emit chatlist <Changed>
            return
        }
        $self EmitEntry $opts(-jid)?join
    }

    method OnRoomState {args} {
        array set opts {-jid ""}
        array set opts $args
        if {$opts(-jid) eq ""} return
        $self EmitEntry $opts(-jid)?join
    }

    # After a chat's history is dropped, any later message counts as new.
    method forget {chatJid} {
        dict unset MaxTimestamps $chatJid
    }

    method OnMessage {chatJid timestamp} {
        if {[dict exists $MaxTimestamps $chatJid] &&
            $timestamp <= [dict get $MaxTimestamps $chatJid]} {
            return ""
        }
        dict set MaxTimestamps $chatJid $timestamp
        dict set PendingTails $chatJid 1
        after cancel $TailToken
        set TailToken [after idle [mymethod FlushTails]]
        return ""
    }

    method FlushTails {} {
        set TailToken ""
        set pending $PendingTails
        set PendingTails [dict create]
        dict for {chatJid _} $pending {
            $self EmitEntry $chatJid
        }
    }

    method OnOwnRead {args} {
        array set opts {-jid ""}
        array set opts $args
        if {$opts(-jid) eq ""} return
        $self EmitEntry $opts(-jid)
    }

    # Only a change to the tail row is a chat-list change.
    method OnTailChanged {args} {
        array set opts {-jid "" -timestamp "" -message ""}
        array set opts $args
        if {$opts(-timestamp) eq "" && $opts(-message) ne ""} {
            set opts(-timestamp) [dict get $opts(-message) timestamp]
        }
        $self EmitIfTail $opts(-jid) $opts(-timestamp)
    }

    # A confirmation may relocate the row: test where it landed.
    method OnTailConfirmed {args} {
        array set opts {-jid "" -newtimestamp ""}
        array set opts $args
        $self EmitIfTail $opts(-jid) $opts(-newtimestamp)
    }

    # Re-emit the existing entries whose blocked flag flipped.
    method OnBlockingChanged {args} {
        array set opts {-list ""}
        array set opts $args
        set flipped {}
        foreach j $opts(-list) { if {$j ni $Blocked} { lappend flipped $j } }
        foreach j $Blocked { if {$j ni $opts(-list)} { lappend flipped $j } }
        set Blocked $opts(-list)
        foreach j $flipped {
            if {[$self EntryFor $j] ne ""} { $self EmitEntry $j }
        }
    }

    # The entry carries the chat's notify policy as `muted` / `mentions`.
    method OnNotifySettings {args} {
        array set opts {-jid ""}
        array set opts $args
        if {$opts(-jid) eq ""} return
        if {[$self EntryFor $opts(-jid)] ne ""} { $self EmitEntry $opts(-jid) }
    }

    method EmitIfTail {chatJid ts} {
        if {$chatJid eq "" || $ts eq ""} return
        if {$ts != [$client message maxTimestamp -chat $chatJid]} return
        $self EmitEntry $chatJid
    }

    method EmitEntry {chatJid} {
        set entry [$self EntryFor $chatJid]
        if {$entry eq ""} {
            $client emit chatlist <Remove> -jid $chatJid
        } else {
            $client emit chatlist <Item> -jid $chatJid -item $entry
        }
    }
}
