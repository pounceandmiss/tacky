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
# The module is the sole funnel: it consumes roster/bookmarks/room-state,
# new-message, read-watermark and tail-message signals and normalizes them
# into three protocol-agnostic events over the flat collection:
#   chatlist <Item>   -jid $jid -item $entry   upsert (add/rename/activity/state)
#   chatlist <Remove> -jid $jid                delete
#   chatlist <Changed>                         reset (refetch via `get`)
# Sorting, filtering, and any windowing are the frontend's job.

snit::type taco_chatlist {
    option -client -readonly yes

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
        }
        return $entries
    }

    # -- single-entry resolution (event path) ---------------------------

    # The unified entry for one chat JID, or "" if it belongs to no source
    # and has no chat history.
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
        if {$tail ne ""} {
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
        if {$tail ne ""} {
            dict set entry last_message $tail
            dict set entry last_activity [dict get $tail timestamp]
        } else {
            dict set entry last_activity 0
        }
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
