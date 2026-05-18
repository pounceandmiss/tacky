# Tests for taco_chatlist (aggregated contact list)

set chatlist_common {
    -setup {
        tacky_type create tacky
        rename conn _real_conn
        rename mock_conn conn
        taco_client c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res
    }
    -cleanup {
        catch {c destroy}
        rename conn mock_conn
        rename _real_conn conn
        tacky destroy
    }
}

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

test chatlist-empty {empty DB returns empty sections} \
    {*}$chatlist_common \
    -body {
        c chatlist search
    } -result {recent {} roster {} bookmarks {}}

test chatlist-recent-order {recent section ordered by last message time} \
    {*}$chatlist_common \
    -body {
        set ts [clock microseconds]
        chatlist_chat_insert alice@example.com \
            timestamp $ts
        chatlist_chat_insert bob@example.com \
            timestamp [expr {$ts + 1}]
        chatlist_chat_insert carol@example.com \
            timestamp [expr {$ts + 2}]
        roster_insert alice@example.com name Alice
        roster_insert bob@example.com name Bob
        roster_insert carol@example.com name Carol
        set result [c chatlist search]
        set jids {}
        foreach item [dict get $result recent] {
            lappend jids [dict get $item jid]
        }
        set jids
    } -result {carol@example.com bob@example.com alice@example.com}

test chatlist-source-roster-only {source is roster when only in roster} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert alice@example.com
        roster_insert alice@example.com name Alice
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item source
    } -result {roster}

test chatlist-source-bookmark-only {source is bookmark when only in bookmarks} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert room@muc.example.com
        bookmark_insert room@muc.example.com name "My Room"
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item source
    } -result {bookmark}

test chatlist-source-both {source is both when in roster and bookmarks} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert alice@example.com
        roster_insert alice@example.com name Alice
        bookmark_insert alice@example.com name "Alice BM"
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item source
    } -result {both}

test chatlist-source-none {source is none when not in roster or bookmarks} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert stranger@example.com
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item source
    } -result {none}

test chatlist-name-resolution {roster name wins over bookmark name} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert alice@example.com
        roster_insert alice@example.com name "Alice R"
        bookmark_insert alice@example.com name "Alice B"
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item name
    } -result {Alice R}

test chatlist-search-filter {search filters by name and JID case-insensitively} \
    {*}$chatlist_common \
    -body {
        roster_insert alice@example.com name Alice
        roster_insert bob@example.com name Bob
        roster_insert carol@example.com name Carol
        set result [c chatlist search -query "ali"]
        set jids {}
        foreach item [dict get $result roster] {
            lappend jids [dict get $item jid]
        }
        set jids
    } -result {alice@example.com}

test chatlist-search-jid-match {search matches JID even when name differs} \
    {*}$chatlist_common \
    -body {
        roster_insert xyzzy@example.com name "John Smith"
        set result [c chatlist search -query "xyzzy"]
        llength [dict get $result roster]
    } -result {1}

test chatlist-roster-groups {roster items include groups field} \
    {*}$chatlist_common \
    -body {
        roster_insert alice@example.com name Alice groups {Friends Work}
        set result [c chatlist search]
        set item [lindex [dict get $result roster] 0]
        dict get $item groups
    } -result {Friends Work}

test chatlist-sort-by-name {roster and bookmarks sorted by name} \
    {*}$chatlist_common \
    -body {
        roster_insert carol@example.com name Carol
        roster_insert alice@example.com name Alice
        roster_insert bob@example.com name Bob
        set result [c chatlist search]
        set names {}
        foreach item [dict get $result roster] {
            lappend names [dict get $item name]
        }
        set names
    } -result {Alice Bob Carol}

test chatlist-sort-fallback-jid {items with no name sort by JID} \
    {*}$chatlist_common \
    -body {
        roster_insert carol@example.com name ""
        roster_insert alice@example.com name ""
        set result [c chatlist search]
        set jids {}
        foreach item [dict get $result roster] {
            lappend jids [dict get $item jid]
        }
        set jids
    } -result {alice@example.com carol@example.com}

test chatlist-recent-limit {recent section capped at 20} \
    {*}$chatlist_common \
    -body {
        set ts [clock microseconds]
        for {set i 0} {$i < 25} {incr i} {
            chatlist_chat_insert user${i}@example.com \
                timestamp [expr {$ts + $i}]
        }
        set result [c chatlist search]
        llength [dict get $result recent]
    } -result {20}

test chatlist-changed-event {chatlist <Changed> fires on roster change} \
    {*}$chatlist_common \
    -body {
        set got 0
        tacky listen chatlist <Changed> \
            {apply {{args} { set ::got 1 }}}
        # Simulate roster change via bus
        c bus publish roster:<Changed> -action add -jid alice@example.com
        set got
    } -result {1}

test chatlist-changed-on-bookmarks {chatlist <Changed> fires on bookmarks change} \
    {*}$chatlist_common \
    -body {
        set got 0
        tacky listen chatlist <Changed> \
            {apply {{args} { set ::got 1 }}}
        c bus publish bookmarks:<Changed> -action add -jid room@muc.example.com
        set got
    } -result {1}

test chatlist-changed-on-chats {chats:<Updated> emits <RecentTop> not <Changed>} \
    {*}$chatlist_common \
    -body {
        # Initialize RecentJids state
        c chatlist search
        set gotTop 0
        set gotChanged 0
        tacky listen chatlist <RecentTop> \
            {apply {{args} { set ::gotTop 1 }}}
        tacky listen chatlist <Changed> \
            {apply {{args} { set ::gotChanged 1 }}}
        chatlist_chat_insert alice@example.com
        c bus publish chats:<Updated> -jid alice@example.com
        list $gotTop $gotChanged
    } -result {1 0}

test chatlist-bookmark-autojoin {recent items from bookmarks include autojoin} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert room@muc.example.com
        bookmark_insert room@muc.example.com name "My Room" autojoin 1
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item autojoin
    } -result {1}

test chatlist-bookmarks-roster-name {bookmarks section uses roster name when available} \
    {*}$chatlist_common \
    -body {
        roster_insert room@muc.example.com name "Roster Name"
        bookmark_insert room@muc.example.com name "Bookmark Name"
        set result [c chatlist search]
        set item [lindex [dict get $result bookmarks] 0]
        dict get $item name
    } -result {Roster Name}

test chatlist-recent-top-metadata {<RecentTop> carries correct name and source} \
    {*}$chatlist_common \
    -body {
        c chatlist search ;# init RecentJids
        roster_insert alice@example.com name "Alice"
        bookmark_insert alice@example.com name "Alice BM" autojoin 1
        set ev {}
        tacky listen chatlist <RecentTop> \
            {apply {{ev} { set ::ev $ev }}}
        chatlist_chat_insert alice@example.com
        c bus publish chats:<Updated> -jid alice@example.com
        list [dict get $ev -jid] [dict get $ev -name] \
            [dict get $ev -source] [dict get $ev -autojoin]
    } -result {alice@example.com Alice both 1}

test chatlist-recent-drop {<RecentDrop> fires when JID falls off top-20} \
    {*}$chatlist_common \
    -body {
        set ts [clock microseconds]
        # Insert 20 chats so RecentJids is full
        for {set i 0} {$i < 20} {incr i} {
            chatlist_chat_insert user${i}@example.com \
                timestamp [expr {$ts + $i}]
        }
        c chatlist search ;# init RecentJids

        set dropped {}
        tacky listen chatlist <RecentDrop> \
            {apply {{ev} {
                lappend ::dropped [dict get $ev -jid]
            }}}
        # Insert a 21st chat — user0 (oldest) should drop
        chatlist_chat_insert new@example.com \
            timestamp [expr {$ts + 100}]
        c bus publish chats:<Updated> -jid new@example.com
        set dropped
    } -result {user0@example.com}

test chatlist-roster-change-still-emits-changed {roster/bookmark changes emit <Changed>} \
    {*}$chatlist_common \
    -body {
        set got 0
        tacky listen chatlist <Changed> \
            {apply {{args} { set ::got 1 }}}
        c bus publish roster:<Changed> -action add -jid alice@example.com
        set got
    } -result {1}

test chatlist-muc-status-default {bookmark items have muc-status "" by default} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name "Room"
        set result [c chatlist search]
        set item [lindex [dict get $result bookmarks] 0]
        dict get $item muc-status
    } -result {}

test chatlist-muc-status-joined {muc-status is joined after muc:<Joined>} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name "Room"
        c bus publish muc:<Joined> -jid room@muc.example.com -nick me
        set result [c chatlist search]
        set item [lindex [dict get $result bookmarks] 0]
        dict get $item muc-status
    } -result {joined}

test chatlist-muc-status-error {muc-status is error after muc:<Error>} \
    {*}$chatlist_common \
    -body {
        bookmark_insert room@muc.example.com name "Room"
        c bus publish muc:<Error> -jid room@muc.example.com -error not-authorized -stanza {}
        set result [c chatlist search]
        set item [lindex [dict get $result bookmarks] 0]
        dict get $item muc-status
    } -result {error}

test chatlist-muc-status-event {chatlist <MucStatus> fires with correct args} \
    {*}$chatlist_common \
    -body {
        set ev {}
        tacky listen chatlist <MucStatus> \
            {apply {{ev} { set ::ev $ev }}}
        c bus publish muc:<Error> -jid room@muc.example.com -error not-authorized -stanza {}
        list [dict get $ev -jid] [dict get $ev -muc-status]
    } -result {room@muc.example.com error}

test chatlist-muc-status-recent {recent bookmark items include muc-status} \
    {*}$chatlist_common \
    -body {
        chatlist_chat_insert room@muc.example.com
        bookmark_insert room@muc.example.com name "Room"
        c bus publish muc:<Error> -jid room@muc.example.com -error not-authorized -stanza {}
        set result [c chatlist search]
        set item [lindex [dict get $result recent] 0]
        dict get $item muc-status
    } -result {error}
