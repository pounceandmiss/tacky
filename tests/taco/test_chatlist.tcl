# Tests for taco_chatlist (one flat list of chat entries)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set chatlist_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# Helper: insert a roster item
proc roster_insert {jid args} {
    array set opts {name "" subscription none ask "" approved 0}
    array set opts $args
    c db eval {
        INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
        VALUES ($jid, $opts(name), $opts(subscription), $opts(ask), $opts(approved))
    }
    if {[info exists opts(groups)]} {
        foreach g $opts(groups) {
            c db eval {
                INSERT OR IGNORE INTO roster_item_group(roster_item_jid, group_name)
                VALUES ($jid, $g)
            }
        }
    }
}

# Helper: insert a bookmark
proc bookmark_insert {jid args} {
    array set opts {name "" autojoin 0 nick "" password ""}
    array set opts $args
    c db eval {
        INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
        VALUES ($jid, $opts(name), $opts(autojoin), $opts(nick), $opts(password))
    }
}

# Helper: insert a chat message (reuses pattern from test_chats.tcl)
proc chatlist_chat_insert {chat_jid args} {
    set defaults [dict create \
        timestamp [clock microseconds] \
        from_jid "$chat_jid/someone" \
        body "hello" \
        server_id "" \
        own_id "" \
        raw_xml "" \
        server_status ""]
    set msg [dict merge $defaults [dict create chat_jid $chat_jid] $args]
    c message messagestore store [list $msg]
}

# Helper: build a jid -> field dict from a flat get result
proc by_jid {entries {field ""}} {
    set out [dict create]
    foreach e $entries {
        if {$field eq ""} {
            dict set out [dict get $e jid] $e
        } else {
            dict set out [dict get $e jid] [dict get $e $field]
        }
    }
    return $out
}

test chatlist-empty {empty DB returns an empty list} \
    {*}$chatlist_common \
    -body {
        c chatlist get
    } -result {}

test chatlist-get-unions-sources {get unions roster, bookmarks, and free chats} \
    {*}$chatlist_common \
    -body {
        roster_insert contact@example.com name Contact
        bookmark_insert room@muc.example.com name Room
        chatlist_chat_insert stranger@example.com
        by_jid [c chatlist get] source
    } -result {contact@example.com roster room@muc.example.com?join bookmarks stranger@example.com free}

test chatlist-groupchat-flag {bookmark rooms carry ?join and groupchat=1; contacts do not} \
    {*}$chatlist_common \
    -body {
        roster_insert contact@example.com name Contact
        bookmark_insert room@muc.example.com name Room
        by_jid [c chatlist get] groupchat
    } -result {contact@example.com 0 room@muc.example.com?join 1}

test chatlist-last-activity {entries carry last_activity; unmessaged contacts are 0} \
    {*}$chatlist_common \
    -body {
        set ts [clock microseconds]
        chatlist_chat_insert active@example.com timestamp $ts
        roster_insert active@example.com name Active
        roster_insert quiet@example.com name Quiet
        set act [by_jid [c chatlist get] last_activity]
        list [expr {[dict get $act active@example.com] == $ts}] \
            [dict get $act quiet@example.com]
    } -result {1 0}

test chatlist-name-resolution {roster/bookmark names pass through; free chats have empty name} \
    {*}$chatlist_common \
    -body {
        roster_insert alice@example.com name "Alice R"
        bookmark_insert room@muc.example.com name "Room B"
        chatlist_chat_insert stranger@example.com
        by_jid [c chatlist get] name
    } -result {alice@example.com {Alice R} room@muc.example.com?join {Room B} stranger@example.com {}}

test chatlist-roster-groups {roster entries include the groups field} \
    {*}$chatlist_common \
    -body {
        roster_insert alice@example.com name Alice groups {Friends Work}
        dict get [lindex [c chatlist get] 0] groups
    } -result {Friends Work}

test chatlist-bookmark-fields {bookmark entries carry autojoin, nick, password, room_state} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name Room \
            autojoin 1 nick me password pw
        set bm [lindex [c chatlist get] 0]
        list [dict get $bm autojoin] [dict get $bm nick] \
            [dict get $bm password] [dict get $bm room_state]
    } -result {1 me pw idle}

test chatlist-changed-on-clear {wholesale source replacement emits <Changed>} \
    {*}$chatlist_common \
    -body {
        set got 0
        tacky listen chatlist <Changed> \
            {apply {{args} { incr ::got }}}
        c bus publish roster:<Changed> -action clear
        c bus publish bookmarks:<Changed> -action clear
        set got
    } -result {2}

test chatlist-item-roster-add {roster add funnels one <Item> with source roster} \
    {*}$chatlist_common \
    -body {
        roster_insert alice@example.com name "Alice R"
        set evs {}
        tacky listen chatlist <Item> \
            {apply {{ev} {
                set item [dict get $ev -item]
                lappend ::evs [dict get $ev -jid] [dict get $item source] \
                    [dict get $item name]
            }}}
        c bus publish roster:<Changed> -action add -jid alice@example.com
        set evs
    } -result {alice@example.com roster {Alice R}}

test chatlist-roster-remove-to-free {removing a contact with history re-emits as source=free} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert alice@example.com
        roster_insert alice@example.com name Alice
        c db eval {DELETE FROM roster_item WHERE jid='alice@example.com'}
        set evs {}
        tacky listen chatlist <Item> \
            {apply {{ev} { lappend ::evs item \
                [dict get [dict get $ev -item] source] }}}
        tacky listen chatlist <Remove> \
            {apply {{ev} { lappend ::evs remove }}}
        c bus publish roster:<Changed> -action remove -jid alice@example.com
        set evs
    } -result {item free}

test chatlist-roster-remove-gone {removing a contact with no history emits <Remove>} \
    {*}$chatlist_common \
    -body {
        roster_insert bob@example.com name Bob
        c db eval {DELETE FROM roster_item WHERE jid='bob@example.com'}
        set evs {}
        tacky listen chatlist <Item> \
            {apply {{ev} { lappend ::evs item }}}
        tacky listen chatlist <Remove> \
            {apply {{ev} { lappend ::evs remove [dict get $ev -jid] }}}
        c bus publish roster:<Changed> -action remove -jid bob@example.com
        set evs
    } -result {remove bob@example.com}

test chatlist-item-bookmark-add {bookmark add funnels one <Item> with ?join and source bookmarks} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name "Room B"
        set evs {}
        tacky listen chatlist <Item> \
            {apply {{ev} {
                set item [dict get $ev -item]
                lappend ::evs [dict get $ev -jid] \
                    [dict get $item jid] [dict get $item source]
            }}}
        c bus publish bookmarks:<Changed> -action add -jid room@muc.example.com
        set evs
    } -result {room@muc.example.com?join room@muc.example.com?join bookmarks}

test chatlist-remove-bookmark-gone {removing a bookmark with no history emits <Remove> for ?join} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name Room
        c db eval {DELETE FROM bookmark WHERE jid='room@muc.example.com'}
        set evs {}
        tacky listen chatlist <Remove> \
            {apply {{ev} { lappend ::evs [dict get $ev -jid] }}}
        c bus publish bookmarks:<Changed> -action remove -jid room@muc.example.com
        set evs
    } -result {room@muc.example.com?join}

test chatlist-chats-updated-item {chats:<Updated> emits <Item>, not <RecentTop>, with fresh activity} \
    {*}$chatlist_common \
    -body {
        set ts [clock microseconds]
        chatlist_chat_insert alice@example.com timestamp $ts
        set ev {}
        tacky listen chatlist <Item> \
            {apply {{e} { set ::ev $e }}}
        c bus publish chats:<Updated> -jid alice@example.com
        set item [dict get $ev -item]
        list [dict get $ev -jid] [dict get $item source] \
            [expr {[dict get $item last_activity] == $ts}]
    } -result {alice@example.com free 1}

test chatlist-roomstate-funnel {a room_state change funnels as a single <Item> carrying room_state} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name Room autojoin 1
        set states {}
        tacky listen chatlist <Item> \
            {apply {{ev} {
                if {[dict get $ev -jid] eq "room@muc.example.com?join"} {
                    lappend ::states [dict get [dict get $ev -item] room_state]
                }
            }}}
        c bus publish muc:<Error> -jid room@muc.example.com \
            -error registration-required -stanza {}
        lindex $states end
    } -result {error}
