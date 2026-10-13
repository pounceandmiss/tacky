# accountscope - an account's windows close with it, or start over with it.
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

set as_acc user@test.example.com
set as_other user2@test.example.com

proc as_setup {} {
    backend_up [tacky_env -mock conn -avatarcache tk_avatarcache -extra-setup {
        tacky account add -acc user@test.example.com
        tacky account add -acc user2@test.example.com
        proc ::as_ctrl {args} {}
    }]
    accountscope listen
}

proc as_cleanup {} {
    catch {::tacky unlisten accountscope}
    foreach w [list .as_chat .as_other .callwindow .aw .profile_[path_safe $::as_acc]] {
        catch {destroy $w}
    }
    backend_down
    catch {rename ::as_ctrl ""}
}

# The account starting over, as the backend does it
proc as_restart {acc} {
    [[tacky client $acc] cget -taco] restartClient $acc "proxy changed"
    wait
}

test accountscope-gone-closes-its-windows {disable closes the account's chat and call windows, and no one else's} \
    -setup as_setup -cleanup as_cleanup -body {
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    chatwindow open .as_other -acc $::as_other -jid alice@example.com
    callwindow show -acc $::as_acc -sid s1 -peer bob@test.example.com
    wait
    tacky account disable -acc $::as_acc
    wait
    list [winfo exists .as_chat] [winfo exists .callwindow] [winfo exists .as_other]
} -result {0 0 1}

test accountscope-reset-reopens-chats {after a reset a chat window is built again on its chat, and the call window is gone} \
    -setup as_setup -cleanup as_cleanup -body {
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    callwindow show -acc $::as_acc -sid s1 -peer bob@test.example.com
    wait
    # Gone with the window it was put in
    ttk::frame .as_chat.marker
    as_restart $::as_acc
    list [winfo exists .as_chat] [winfo exists .as_chat.marker] \
        [.as_chat.cp cget -jid] [winfo exists .callwindow]
} -result {1 0 alice@example.com 0}

test accountscope-reset-rebuilds-account-window {the account window builds its panel and inline chat again} \
    -setup as_setup -cleanup as_cleanup -body {
    accountwindow .aw -account $::as_acc -controller as_ctrl
    wait
    .aw OpenChat -acc $::as_acc -jid alice@example.com
    wait
    ttk::frame .aw.paned.panel.marker
    ttk::frame .aw.paned.chatpanel.cp.marker
    as_restart $::as_acc
    list [winfo exists .aw] [winfo exists .aw.paned.panel] \
        [winfo exists .aw.paned.panel.marker] \
        [.aw.paned.chatpanel.cp cget -jid] \
        [winfo exists .aw.paned.chatpanel.cp.marker]
} -result {1 1 0 alice@example.com 0}

test accountscope-reset-leaves-other-accounts {a reset of one account leaves another's windows as they are} \
    -setup as_setup -cleanup as_cleanup -body {
    chatwindow open .as_other -acc $::as_other -jid alice@example.com
    wait
    ttk::frame .as_other.marker
    as_restart $::as_acc
    winfo exists .as_other.marker
} -result 1

test accountscope-reset-keeps-settings {a window over stored state, such as profile settings, stays through a reset} \
    -setup as_setup -cleanup as_cleanup -body {
    profilesettings open $::as_acc
    wait
    set top .profile_[path_safe $::as_acc]
    ttk::frame $top.marker
    as_restart $::as_acc
    winfo exists $top.marker
} -result 1

test accountscope-gone-closes-settings {profile settings close with the account} \
    -setup as_setup -cleanup as_cleanup -body {
    profilesettings open $::as_acc
    wait
    tacky account disable -acc $::as_acc
    wait
    winfo exists .profile_[path_safe $::as_acc]
} -result 0


# The profile bar's Reconnect is `account restart`, not disable then enable
test accountscope-restart-keeps-windows {restarting an account keeps its account window and chats} \
    -setup as_setup -cleanup as_cleanup -body {
    tacky account enable -acc $::as_acc
    accountwindow .aw -account $::as_acc -controller as_ctrl
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    wait
    tacky account restart -acc $::as_acc
    wait
    list [winfo exists .aw] [winfo exists .as_chat] \
        [tacky account get -acc $::as_acc -field enabled]
} -result {1 1 1}
