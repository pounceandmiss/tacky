# Unit tests for chatlistview - the flat chat list over taco_chatlist
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

set acc user@test.example.com

# -- helpers --------------------------------------------------------------------

proc clv_setup {} {
    mock_backend_up
}

proc clv_cleanup {} {
    destroy .clv
    mock_backend_down
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

# Row keys are the chat JIDs verbatim.
proc clv_rows {} {
    lsort [.clv.rows keys]
}

# What a row draws: its name, preview and unread count.
proc clv_row {jid} {
    set row [.clv.rows row $jid]
    list [dict get $row name] [dict get $row preview] [dict get $row unread]
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
    .clv.rows keys
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

test clv-row-previews-last-message {a row is the name, a preview of the newest message, and the unread count} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_roster bob@example.com Bob
    clv_chat alice@example.com
} -body {
    clv_create
    list [clv_row alice@example.com] [clv_row bob@example.com]
} -cleanup { clv_cleanup } -result {{Alice hi 1} {Bob {} 0}}

test clv-item-updates-preview {a chatlist <Item> carrying a new last_message repaints the preview} -setup {
    clv_setup
    clv_roster alice@example.com Alice
} -body {
    clv_create
    $::_client emit chatlist <Item> -jid alice@example.com \
        -item {jid alice@example.com name Alice source roster \
            groupchat 0 autojoin 0 last_activity 5 unread 0 \
            last_message {timestamp 5 from_jid alice@example.com \
                is_outgoing 1 retracted 0 \
                content {type text body "see you"}}}
    wait
    clv_row alice@example.com
} -cleanup { clv_cleanup } -result {Alice {You: see you} 0}

test clv-rename-starts-from-the-name {the rename dialog seeds the name, not the row text} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_chat alice@example.com
} -body {
    clv_create
    .clv.rows select alice@example.com
    set seed ""
    rename input_dialog _real_input_dialog
    proc input_dialog {w args} {
        set ::seed [dict get $args -value]
        return ""
    }
    .clv OnRenameContact
    set seed
} -cleanup {
    rename input_dialog ""
    rename _real_input_dialog input_dialog
    clv_cleanup
} -result Alice

# -- blocking -------------------------------------------------------------------

# Answer tk_messageBox with $answer, recording each -message in ::asked.
proc clv_stub_messagebox {answer} {
    set ::asked {}
    set ::answer $answer
    rename tk_messageBox _real_tk_messageBox
    proc tk_messageBox {args} {
        lappend ::asked [dict get $args -message]
        return $::answer
    }
}

proc clv_unstub_messagebox {} {
    rename tk_messageBox ""
    rename _real_tk_messageBox tk_messageBox
}

# The jids of every <$tag xmlns=urn:xmpp:blocking> item written so far.
proc clv_written_items {tag} {
    set out {}
    foreach s [$::_client.conn get_written] {
        lappend out {*}[xsearch $s $tag -ns urn:xmpp:blocking item -gather @jid]
    }
    return $out
}

proc clv_block_push {tag jid} {
    $::_client.conn feed [j iq -type set -id push[incr ::clvPush] \
        -from user@test.example.com [list j $tag -ns urn:xmpp:blocking \
            [list j item -jid $jid]]]
    wait
}

test clv-block-asks-then-sends {Block confirms first, then sends <block/> for the row} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_stub_messagebox yes
} -body {
    clv_create
    .clv.rows select alice@example.com
    .clv OnToggleBlock
    wait
    list [llength $::asked] [clv_written_items block]
} -cleanup {
    clv_unstub_messagebox
    clv_cleanup
} -result {1 alice@example.com}

test clv-block-declined-sends-nothing {saying no to the confirmation sends nothing} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_stub_messagebox no
} -body {
    clv_create
    .clv.rows select alice@example.com
    .clv OnToggleBlock
    wait
    clv_written_items block
} -cleanup {
    clv_unstub_messagebox
    clv_cleanup
} -result {}

test clv-blocked-row-styled-and-unblock-offered {a blocked contact's row is styled, and its menu offers Unblock without asking} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    clv_stub_messagebox yes
    rename tk_popup _real_tk_popup
    proc tk_popup {args} {}
} -body {
    clv_create
    clv_block_push block alice@example.com
    set tags [dict get [.clv.rows row alice@example.com] tags]
    .clv.rows select alice@example.com
    .clv OnContactMenu alice@example.com 0 0 1
    set m .clv.contactmenu
    set idx [$m index Unblock]
    set state [$m entrycget $idx -state]
    .clv OnToggleBlock
    wait
    list $tags $state [llength $::asked] [clv_written_items unblock]
} -cleanup {
    rename tk_popup ""
    rename _real_tk_popup tk_popup
    clv_unstub_messagebox
    clv_cleanup
} -result {blocked normal 0 alice@example.com}

test clv-block-disabled-without-server-support {the Block entry is greyed out when the server lacks the feature} -setup {
    clv_setup
    clv_roster alice@example.com Alice
    rename tk_popup _real_tk_popup
    proc tk_popup {args} {}
} -body {
    clv_create
    .clv OnContactMenu alice@example.com 0 0 0
    .clv.contactmenu entrycget [.clv.contactmenu index Block] -state
} -cleanup {
    rename tk_popup ""
    rename _real_tk_popup tk_popup
    clv_cleanup
} -result disabled
