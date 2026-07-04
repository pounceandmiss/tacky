# taco_chatlist - one flat list of chat entries (roster + bookmarks + chats).
#
# The list is the union of roster contacts, bookmarked rooms, and any chat
# with message history. Each entry is keyed by its chat JID and carries a
# `source`:
#   roster     - a roster contact (bare JID)
#   bookmarks  - a bookmarked room (room@muc?join)
#   free       - has chat history but is in neither roster nor bookmarks
#
# Every jid is a chat JID, opened verbatim: bare = 1:1, room@muc?join = group
# chat, room@muc/nick = MUC PM. The ?join suffix is the tell for group vs 1:1.
#
# The module is the sole funnel: it consumes roster/bookmarks/chats/room-state
# signals and normalizes them into three protocol-agnostic events over the
# flat collection:
#   chatlist <Item>   -jid $jid -item $entry   upsert (add/rename/activity/state)
#   chatlist <Remove> -jid $jid                delete
#   chatlist <Changed>                         reset (refetch via `get`)
# Sorting, filtering, and any windowing are the frontend's job.

snit::type taco_chatlist {
    option -client -readonly yes

    variable client
    variable db

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]

        $client bus subscribe $self roster:<Changed> [mymethod OnRosterChanged]
        $client bus subscribe $self bookmarks:<Changed> [mymethod OnBookmarkChanged]
        $client bus subscribe $self bookmarks:<RoomState> [mymethod OnRoomState]
        $client bus subscribe $self chats:<Updated> [mymethod OnChatUpdated]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    # -- the whole list -------------------------------------------------

    tackymethod get {args} {
        set activity [$self ActivityMap]

        set entries {}
        set seen {}

        foreach item [$client roster get] {
            set bare [dict get $item jid]
            lappend entries \
                [$self MakeEntry $bare roster $item [$self MapTs $activity $bare]]
            dict set seen $bare 1
        }
        foreach item [$client bookmarks get] {
            set chatJid [dict get $item jid]?join
            lappend entries \
                [$self MakeEntry $chatJid bookmarks $item [$self MapTs $activity $chatJid]]
            dict set seen $chatJid 1
        }
        dict for {chatJid ts} $activity {
            if {[dict exists $seen $chatJid]} continue
            lappend entries [$self MakeEntry $chatJid free {} $ts]
        }
        return $entries
    }

    # -- single-entry resolution (event path) ---------------------------

    # The unified entry for one chat JID, or "" if it belongs to no source
    # and has no chat history.
    method EntryFor {chatJid} {
        set bare [regsub {\?join$} $chatJid {}]
        set isRoom [expr {$bare ne $chatJid}]
        if {$isRoom} {
            set bm [$self BookmarkEntry $bare]
            if {$bm ne ""} {
                return [$self MakeEntry $chatJid bookmarks $bm [$self Activity $chatJid]]
            }
        } else {
            set r [$self RosterEntry $bare]
            if {$r ne ""} {
                return [$self MakeEntry $chatJid roster $r [$self Activity $chatJid]]
            }
        }
        set ts [$self Activity $chatJid]
        if {$ts > 0} {
            return [$self MakeEntry $chatJid free {} $ts]
        }
        return ""
    }

    method MakeEntry {chatJid source base ts} {
        set entry $base
        dict set entry jid $chatJid
        dict set entry source $source
        dict set entry groupchat [expr {[string match {*\?join} $chatJid] ? 1 : 0}]
        dict set entry last_activity $ts
        if {![dict exists $entry name]} { dict set entry name "" }
        if {![dict exists $entry autojoin]} { dict set entry autojoin 0 }
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

    method ActivityMap {} {
        set activity {}
        $db eval {
            SELECT chat_jid, MAX(timestamp) AS ts FROM chat_message
            WHERE kind='message' GROUP BY chat_jid
        } row {
            dict set activity $row(chat_jid) $row(ts)
        }
        return $activity
    }

    method Activity {chatJid} {
        set ts [$db onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
        }]
        if {$ts eq ""} { return 0 }
        return $ts
    }

    method MapTs {activity key} {
        if {[dict exists $activity $key]} { return [dict get $activity $key] }
        return 0
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

    method OnChatUpdated {args} {
        array set opts {-jid ""}
        array set opts $args
        if {$opts(-jid) eq ""} return
        $self EmitEntry $opts(-jid)
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
