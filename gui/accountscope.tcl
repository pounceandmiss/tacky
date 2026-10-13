# accountscope - forgetting an account's windows, in one place.
#
# A window belongs to the account its widgets carry in -acc (or -account), so
# nothing has to register: a new window is covered as soon as it has one.
#
#   accountscope listen
#       From the app: follow account <Removed>, <Disabled> and <Reset>.
#   accountscope forget ACC gone|reset
#       gone:  the account is removed or disabled; its windows close.
#       reset: the account started over (taco restartClient): its calls
#              and transfers are gone with the old client. Call windows
#              close, and chat windows reopen on their chat, so they read
#              it again. Windows over stored state (settings, keys,
#              search) stay as they are.
#
# An account window is the exception both ways: it follows the account itself
# (accountwindow's OnAccountGone and OnAccountReset).
snit::type accountscope {
    pragma -hastypeinfo no -hastypedestroy no -hasinstances no

    typemethod listen {} {
        ::tacky listen -tag accountscope account <Removed> \
            [list accountscope OnEvent gone]
        ::tacky listen -tag accountscope account <Disabled> \
            [list accountscope OnEvent gone]
        ::tacky listen -tag accountscope account <Reset> \
            [list accountscope OnEvent reset]
    }

    typemethod OnEvent {mode ev} {
        accountscope forget [dict get $ev -acc] $mode
    }

    # The windows a call lives in: a reset leaves nothing for them to show
    typevariable CALL_WINDOWS {::callwindow ::incomingcalldialog ::groupcallwindow}

    typemethod forget {acc mode} {
        foreach top [accountscope Toplevels .] {
            if {![winfo exists $top]} continue
            if {[accountscope Of $top] ne $acc} continue
            set type [accountscope TypeOf $top]
            if {$type eq "::accountwindow"} continue
            if {$mode eq "gone" || $type in $CALL_WINDOWS} {
                destroy $top
            } elseif {$type eq "::chatwindow"} {
                accountscope ReopenChat $top
            }
        }
    }

    # Every toplevel under $w, nested ones included, outermost first.
    typemethod Toplevels {w} {
        set out {}
        foreach child [winfo children $w] {
            if {[winfo toplevel $child] eq $child} { lappend out $child }
            lappend out {*}[accountscope Toplevels $child]
        }
        return $out
    }

    # The account $top's widgets are for, "" for none. A nested toplevel is
    # its own window, so the search stops at one.
    typemethod Of {top} {
        set queue [list $top]
        while {[llength $queue]} {
            set queue [lassign $queue w]
            foreach opt {-acc -account} {
                if {![catch {$w cget $opt} acc] && $acc ne ""} {
                    return $acc
                }
            }
            foreach child [winfo children $w] {
                if {[winfo toplevel $child] ne $child} { lappend queue $child }
            }
        }
        return ""
    }

    typemethod TypeOf {w} {
        if {[catch {$w info type} type]} { return "" }
        return $type
    }

    # The same chat in the same place, built anew.
    typemethod ReopenChat {top} {
        set opts [list -acc [$top cget -acc] -jid [$top cget -jid] \
            -groupchat [$top cget -groupchat]]
        set geometry [wm geometry $top]
        destroy $top
        chatwindow open $top {*}$opts
        wm geometry $top $geometry
    }
}
