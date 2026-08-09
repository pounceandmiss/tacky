# Unit tests for accountwindow - the per-account toplevel.
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

# tacky + mock client + avatarcache + a stub controller. Pair with aw_cleanup.
proc aw_setup {} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc user@test.example.com
    tacky account add -acc user2@test.example.com
    proc ::aw_ctrl {args} {}
}

proc aw_cleanup {} {
    catch {destroy .aw}
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
    catch {rename ::aw_ctrl ""}
}

test accountwindow-builds-menubar-and-panel {constructs menubar, paned, and account panel} -setup {
    aw_setup
} -body {
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    list \
        menubar=[winfo exists .aw.menubar] \
        accounts=[winfo exists .aw.menubar.accounts] \
        paned=[winfo exists .aw.paned] \
        panel=[winfo exists .aw.paned.panel] \
        current=[.aw CurrentAccount]
} -cleanup {
    aw_cleanup
} -result {menubar=1 accounts=1 paned=1 panel=1 current=user@test.example.com}

test accountwindow-switch-rebuilds-panel {SwitchAccount swaps the displayed account and rebuilds the panel} -setup {
    aw_setup
} -body {
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    .aw SwitchAccount user2@test.example.com
    wait
    list current=[.aw CurrentAccount] panel=[winfo exists .aw.paned.panel]
} -cleanup {
    aw_cleanup
} -result {current=user2@test.example.com panel=1}

test accountwindow-inline-chat-packs-chatpanel {inline OpenChat adds a chatpanel into the right pane} -setup {
    aw_setup
} -body {
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    .aw OpenChat -acc user@test.example.com -jid alice@example.com
    wait
    winfo exists .aw.paned.chatpanel.cp
} -cleanup {
    aw_cleanup
} -result 1

# The autofetch settings are strings, not the booleans checkbutton coerces to,
# so the stored value has to reach the radiobutton variable verbatim.
test accountwindow-autofetch-menu-reflects-setting {a stored autofetch policy selects its radio entry} -setup {
    aw_setup
} -body {
    tacky setting set -key attachment_autofetch -value contacts
    tacky setting set -key attachment_autofetch_max -value 1048576
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    set policyVar [.aw.menubar.view.autofetch entrycget 0 -variable]
    set maxVar [.aw.menubar.view.autofetchmax entrycget 0 -variable]
    list policy=[set $policyVar] max=[set $maxVar] \
        entries=[.aw.menubar.view.autofetch index end]
} -cleanup {
    aw_cleanup
} -result {policy=contacts max=1048576 entries=2}

# MAM queries written by the account's connection, which is how a goto for a
# hit outside the cached page shows up.
proc aw_mam_queries {} {
    set client [tacky client user@test.example.com]
    llength [lsearch -all [$client conn get_written] *urn:xmpp:mam:2*]
}

test accountwindow-search-hit-opens-its-room-as-a-groupchat {the ?join suffix on a hit's chat is what makes it a room} -setup {
    aw_setup
} -body {
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    .aw OnSearchGoto {room@conf.example.com?join 300}
    wait
    list [.aw.paned.chatpanel.cp cget -jid] [.aw.paned.chatpanel.cp cget -groupchat]
} -cleanup {
    aw_cleanup
} -result {room@conf.example.com?join 1}

test accountwindow-search-hit-jumps-in-an-already-open-chat {a hit in the chat already showing still jumps to it} -setup {
    aw_setup
} -body {
    accountwindow .aw -account user@test.example.com -controller aw_ctrl
    wait
    .aw OpenChat -acc user@test.example.com -jid alice@example.com
    wait
    set before [aw_mam_queries]
    .aw OnSearchGoto {alice@example.com 300}
    wait
    expr {[aw_mam_queries] > $before}
} -cleanup {
    aw_cleanup
} -result 1
