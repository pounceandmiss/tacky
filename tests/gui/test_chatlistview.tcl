# Unit tests for chatlistview - the flat chat list over taco_chatlist
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

set acc user@test.example.com

# -- helpers --------------------------------------------------------------------

proc clv_setup {} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc user@test.example.com
    set ::_client [tacky client user@test.example.com]
    $::_client.conn configure -bound-jid user@test.example.com/res1
    $::_client.conn fire_ready 0
    $::_client.conn clear
}

proc clv_cleanup {} {
    destroy .clv
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
}

proc clv_roster {jid name args} {
    array set opts {groups {}}
    array set opts $args
    $::_client db eval {
        INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
        VALUES ($jid, $name, 'both', '', 0)
    }
    foreach g $opts(groups) {
        $::_client db eval {
            INSERT OR IGNORE INTO roster_item_group(roster_item_jid, group_name)
            VALUES ($jid, $g)
        }
    }
}

proc clv_bookmark {jid name} {
    $::_client db eval {
        INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
        VALUES ($jid, $name, 0, '', '')
    }
}

proc clv_chat {chat_jid {ts ""}} {
    if {$ts eq ""} { set ts [clock microseconds] }
    $::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid $chat_jid from_jid "$chat_jid/x" \
        body hi server_id "" own_id "" raw_xml "" server_status ""]]
}

proc clv_create {} {
    chatlistview .clv -acc user@test.example.com
    pack .clv -fill both -expand yes
    wait
}

# Row ids in the tree are the chat JIDs verbatim.
proc clv_rows {} {
    lsort [.clv.tree children {}]
}

# -- tests ----------------------------------------------------------------------

test clv-populates {one row per chat entry, keyed by chat JID} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_bookmark room@muc.example.com Room
    clv_chat stranger@example.com
} -body {
    clv_create
    clv_rows
} -cleanup { clv_cleanup } \
    -result {alice@example.com room@muc.example.com?join stranger@example.com}

test clv-empty {an empty backend renders no rows} -setup {
    clv_setup
} -body {
    clv_create
    clv_rows
} -cleanup { clv_cleanup } -result {}

test clv-recent-sort {default sort puts most-recently-active first} -setup {
    clv_setup
    set ts [clock microseconds]
    clv_roster alice@example.com Alice
    clv_roster bob@example.com Bob
    clv_chat alice@example.com $ts
    clv_chat bob@example.com [expr {$ts + 1000}]
} -body {
    clv_create
    .clv.tree children {}
} -cleanup { clv_cleanup } -result {bob@example.com alice@example.com}

test clv-item-inserts {a chatlist <Item> upsert adds a row live} -setup {
    clv_setup
} -body {
    clv_create
    clv_roster alice@example.com Alice
    $::_client emit chatlist <Item> -jid alice@example.com \
        -item {jid alice@example.com name Alice source roster \
            groupchat 0 autojoin 0 last_activity 0}
    wait
    clv_rows
} -cleanup { clv_cleanup } -result {alice@example.com}

test clv-remove-deletes {a chatlist <Remove> deletes the row} -setup {
    clv_setup
    clv_roster alice@example.com Alice
} -body {
    clv_create
    $::_client emit chatlist <Remove> -jid alice@example.com
    wait
    clv_rows
} -cleanup { clv_cleanup } -result {}

test clv-search-filters {the search box filters the held list client-side} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_roster bob@example.com Bob
} -body {
    clv_create
    focus -force .clv.header.search
    .clv.header.search insert 0 bob
    event generate .clv.header.search <KeyRelease> -keysym b
    wait
    clv_rows
} -cleanup { clv_cleanup } -result {bob@example.com}
