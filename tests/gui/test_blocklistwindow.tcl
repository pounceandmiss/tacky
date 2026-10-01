# blocklistwindow: an account's XEP-0191 blocklist.
package require tcltest
namespace import ::tcltest::*

proc blw_up {} {
    mock_backend_up
    set ::blwPush 0
    blocklistwindow open user@test.example.com
    wait
}

proc blw_down {} {
    destroy .blocklist_[path_safe user@test.example.com]
    mock_backend_down
}

proc blw {} { return .blocklist_[path_safe user@test.example.com].bl }

# Have the server confirm urn:xmpp:blocking and answer the fetch with $jids.
proc blw_confirm {jids} {
    $::_client blocking OnReady
    set disco [lindex [$::_client.conn get_written] end]
    $::_client.conn feed [j iq -type result -id [xsearch $disco -get @id] \
        -from test.example.com {
            j query -ns http://jabber.org/protocol/disco#info {
                j feature -var urn:xmpp:blocking
            }
        }]
    wait
    set fetch [lindex [$::_client.conn get_written] end]
    $::_client.conn feed [j iq -type result -id [xsearch $fetch -get @id] {
        j blocklist -ns urn:xmpp:blocking {
            foreach j_ $jids { j item -jid $j_ }
        }
    }]
    wait
}

proc blw_written_items {tag} {
    set out {}
    foreach s [$::_client.conn get_written] {
        lappend out {*}[xsearch $s $tag -ns urn:xmpp:blocking item -gather @jid]
    }
    return $out
}

proc blw_state {button} {
    [blw].buttons.$button cget -state
}

test blw-unsupported-disables-actions {before the server confirms the feature nothing can be sent} \
    -setup {blw_up} -body {
    list [blw_state block] [blw_state unblock] [blw_state unblockall]
} -cleanup {blw_down} -result {disabled disabled disabled}

test blw-lists-the-blocklist {the fetched list shows sorted, and the actions come alive} \
    -setup {blw_up} -body {
    blw_confirm {zed@example.com alice@example.com}
    set tree [blw].tree
    list [$tree children {}] [blw_state block] [blw_state unblock] \
        [blw_state unblockall]
} -cleanup {blw_down} -result {{alice@example.com zed@example.com} normal disabled normal}

test blw-server-losing-feature-disables {a reconnect to a server without the feature empties the list and disables the actions} \
    -setup {blw_up} -body {
    blw_confirm {alice@example.com}
    $::_client bus publish <Disconnect>
    $::_client blocking OnReady
    set disco [lindex [$::_client.conn get_written] end]
    $::_client.conn feed [j iq -type result -id [xsearch $disco -get @id] \
        -from test.example.com {
            j query -ns http://jabber.org/protocol/disco#info
        }]
    wait
    list [[blw].tree children {}] [blw_state block] [blw_state unblockall]
} -cleanup {blw_down} -result {{} disabled disabled}

test blw-follows-pushes {a push from another resource updates the open window} \
    -setup {blw_up} -body {
    blw_confirm {}
    $::_client.conn feed [j iq -type set -id p1 -from user@test.example.com {
        j block -ns urn:xmpp:blocking { j item -jid spam.example }
    }]
    wait
    [blw].tree children {}
} -cleanup {blw_down} -result {spam.example}

test blw-unblock-sends-the-selection {Unblock sends one <unblock/> for the selected rows} \
    -setup {blw_up} -body {
    blw_confirm {alice@example.com bob@example.com carol@example.com}
    [blw].tree selection set {alice@example.com carol@example.com}
    wait
    $::_client.conn clear
    [blw] OnUnblock
    wait
    blw_written_items unblock
} -cleanup {blw_down} -result {alice@example.com carol@example.com}

test blw-block-sends-the-typed-jid {Block JID... sends what was typed, trimmed} \
    -setup {
    blw_up
    rename input_dialog _real_input_dialog
    proc input_dialog {w args} { return "  spam.example  " }
} -body {
    blw_confirm {}
    $::_client.conn clear
    [blw] OnBlock
    wait
    blw_written_items block
} -cleanup {
    rename input_dialog ""
    rename _real_input_dialog input_dialog
    blw_down
} -result {spam.example}

test blw-opens-from-accounts-menu {Accounts > the account > Blocked Contacts... opens that account's window} \
    -setup {
    mock_backend_up
    toplevel .blwtop
    menu .blwtop.mb
    set ::_blwMenu [accountsmenu %AUTO% -menubar .blwtop.mb]
    wait
} -body {
    # The mock account bypasses the account registry.
    $::_blwMenu OnSeedEnabled [list user@test.example.com]
    $::_blwMenu Rebuild
    set sub .blwtop.mb.accounts.mng_[path_safe user@test.example.com]
    $sub invoke [$sub index "Blocked Contacts..."]
    wait
    winfo exists [blw]
} -cleanup {
    $::_blwMenu destroy
    destroy .blwtop
    blw_down
} -result 1

test blw-open-twice-raises {a second open returns the same window} \
    -setup {blw_up} -body {
    expr {[blocklistwindow open user@test.example.com]
        eq ".blocklist_[path_safe user@test.example.com]"}
} -cleanup {blw_down} -result 1
