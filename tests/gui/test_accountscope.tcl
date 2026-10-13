# A removed account's windows close with it; a disabled one's stay, to read
# from, and say it is disabled.
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

set as_acc user@test.example.com
set as_other user2@test.example.com

# Both accounts added, neither enabled
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
    foreach w [list .as_chat .as_other .callwindow .aw .as_pb .as_top \
            .profile_[path_safe $::as_acc]] {
        catch {destroy $w}
    }
    catch {$::_asMenu destroy}
    backend_down
    catch {rename ::as_ctrl ""}
}

test accountscope-remove-closes-its-windows {remove closes the account's chat and call windows, and no one else's} \
    -setup as_setup -cleanup as_cleanup -body {
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    chatwindow open .as_other -acc $::as_other -jid alice@example.com
    callwindow show -acc $::as_acc -sid s1 -peer bob@test.example.com
    profilesettings open $::as_acc
    wait
    tacky account remove -acc $::as_acc
    wait
    list [winfo exists .as_chat] [winfo exists .callwindow] \
        [winfo exists .profile_[path_safe $::as_acc]] [winfo exists .as_other]
} -result {0 0 0 1}

test accountscope-disable-keeps-windows {disable keeps the account window, its chats and its settings} \
    -setup as_setup -cleanup as_cleanup -body {
    tacky account enable -acc $::as_acc
    accountwindow .aw -account $::as_acc -controller as_ctrl
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    profilesettings open $::as_acc
    wait
    ttk::frame .as_chat.marker
    tacky account disable -acc $::as_acc
    wait
    list [winfo exists .aw] [.aw CurrentAccount] [winfo exists .as_chat.marker] \
        [winfo exists .profile_[path_safe $::as_acc]]
} -result [list 1 $::as_acc 1 1]

test accountscope-remove-account-window-takes-a-disabled-survivor {the account window moves to another account, enabled or not} \
    -setup as_setup -cleanup as_cleanup -body {
    accountwindow .aw -account $::as_acc -controller as_ctrl
    wait
    tacky account remove -acc $::as_acc
    wait
    list [winfo exists .aw] [.aw CurrentAccount]
} -result [list 1 $::as_other]

test accountscope-disabled-chat-banner {a disabled account's chat says so, and the banner goes on enable} \
    -setup as_setup -cleanup as_cleanup -body {
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    wait
    set before [.as_chat.cp HasBanner disabled]
    set body [.as_chat.cp BannerBody disabled]
    $body.enable invoke
    wait
    list $before [.as_chat.cp HasBanner disabled] \
        [tacky account get -acc $::as_acc -field enabled]
} -result {1 0 1}

test accountscope-disable-shows-chat-banner {disabling an account puts the banner up in its open chat} \
    -setup as_setup -cleanup as_cleanup -body {
    tacky account enable -acc $::as_acc
    chatwindow open .as_chat -acc $::as_acc -jid alice@example.com
    wait
    set before [.as_chat.cp HasBanner disabled]
    tacky account disable -acc $::as_acc
    wait
    list $before [.as_chat.cp HasBanner disabled]
} -result {0 1}

test accountscope-profilebar-enable {the profile bar of a disabled account offers Enable, which enables it} \
    -setup as_setup -cleanup as_cleanup -body {
    profilebar .as_pb -acc $::as_acc
    wait
    .as_pb OnRightClick 0 0
    set m .as_pb.__ctxmenu
    $m unpost
    set labels {}
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command"} { lappend labels [$m entrycget $i -label] }
    }
    $m invoke [$m index Enable]
    wait
    list [lrange $labels 0 1] [tacky account get -acc $::as_acc -field enabled]
} -result {{Disabled Enable} 1}

test accountscope-menu-opens-disabled {the accounts menu opens a disabled account} \
    -setup as_setup -cleanup as_cleanup -body {
    toplevel .as_top
    menu .as_top.mb
    set ::_asOpened ""
    set ::_asMenu [accountsmenu %AUTO% -menubar .as_top.mb \
        -open-here-command {apply {{jid} { set ::_asOpened $jid }}}]
    wait
    # Built as the menu posts
    $::_asMenu Rebuild
    set sub .as_top.mb.accounts.mng_[path_safe $::as_acc]
    $sub invoke [$sub index "Open in This Window"]
    set ::_asOpened
} -result user@test.example.com

