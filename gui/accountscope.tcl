# accountscope - forgetting an account's windows, in one place.
#
# A window belongs to the account its widgets carry in -acc (or -account), so
# nothing has to register: a new window is covered as soon as it has one.
#
#   accountscope listen
#       From the app: follow account <Removed>.
#   accountscope forget ACC
#       The account is gone: its windows close.
#
# A disabled account is not gone: its windows stay, to read from, and what
# its session had going ends through each module's own events (a call
# window closes on calls <Ended>).
#
# An account window is the exception: it follows the account itself
# (accountwindow's OnAccountGone).
snit::type accountscope {
    pragma -hastypeinfo no -hastypedestroy no -hasinstances no

    typemethod listen {} {
        ::tacky listen -tag accountscope account <Removed> \
            [list accountscope OnRemoved]
    }

    typemethod OnRemoved {ev} {
        accountscope forget [dict get $ev -acc]
    }

    typemethod forget {acc} {
        foreach top [accountscope Toplevels .] {
            if {![winfo exists $top]} continue
            if {[accountscope Of $top] ne $acc} continue
            if {[accountscope TypeOf $top] eq "::accountwindow"} continue
            destroy $top
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
}
