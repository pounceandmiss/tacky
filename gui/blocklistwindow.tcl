if 0 {
    blocklistwindow - an account's XEP-0191 blocklist.

    Usage:
        blocklistwindow open romeo@montague.lit
}

# The Block/Unblock action shared by the chat list and chat panel. Blocking
# asks first.
proc blocking_toggle {win tacky acc jid blocked} {
    if {$blocked} {
        $tacky blocking unblock -acc $acc -jid $jid \
            -tag $win -onerror [list blocking_show_error $win "Unblock"]
        return
    }
    if {[tk_messageBox -type yesno -icon question \
            -parent [winfo toplevel $win] -title "Block $jid" \
            -message "Block $jid?" \
            -detail "You will no longer receive their messages,\
                presence or calls."] ne "yes"} return
    $tacky blocking block -acc $acc -jid $jid \
        -tag $win -onerror [list blocking_show_error $win "Block"]
}

proc blocking_show_error {win action message} {
    if {![winfo exists $win]} return
    tk_messageBox -icon error -title "$action Failed" \
        -parent [winfo toplevel $win] -message $message
}

snit::widget blocklistwindow {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes

    component tree

    variable supported 0
    variable status ""

    typemethod open {account} {
        set top .blocklist_[path_safe $account]
        if {[raise_existing $top]} { return $top }
        toplevel $top
        wm title $top "Blocked Contacts - $account"
        pack [blocklistwindow $top.bl -acc $account] \
            -expand yes -fill both -padx 10 -pady 10
        return $top
    }

    constructor args {
        $self configurelist $args
        if {$options(-acc) eq ""} {
            error "blocklistwindow requires -acc"
        }

        ttk::label $win.status -textvariable [myvar status] -foreground gray50
        install tree using ttk::treeview $win.tree -show {} \
            -columns jid -selectmode extended -height 12 \
            -yscrollcommand [list $win.sb set]
        $tree column jid -width 280
        ttk::scrollbar $win.sb -orient vertical -command [list $tree yview]

        ttk::frame $win.buttons
        ttk::button $win.buttons.block -text "Block JID..." \
            -command [mymethod OnBlock]
        ttk::button $win.buttons.unblock -text "Unblock" \
            -command [mymethod OnUnblock]
        ttk::button $win.buttons.unblockall -text "Unblock All" \
            -command [mymethod OnUnblockAll]
        pack $win.buttons.block $win.buttons.unblock $win.buttons.unblockall \
            -side left -padx {0 4}

        grid $win.status  -row 0 -column 0 -columnspan 2 -sticky w -pady {0 4}
        grid $tree        -row 1 -column 0 -sticky nsew
        grid $win.sb      -row 1 -column 1 -sticky ns
        grid $win.buttons -row 2 -column 0 -columnspan 2 -sticky w -pady {6 0}
        grid rowconfigure    $win 1 -weight 1
        grid columnconfigure $win 0 -weight 1

        bind $tree <<TreeviewSelect>> [mymethod UpdateButtons]

        set t $options(-tacky)
        set acc $options(-acc)
        $t listen -tag $win blocking <Changed> -acc $acc [mymethod OnChanged]
        $t listen -tag $win conn <State> -acc $acc [mymethod Refresh]
        $self Refresh
    }

    destructor {
        catch {$options(-tacky) unlisten $win}
    }

    method Refresh {args} {
        set t $options(-tacky)
        $t blocking supported -acc $options(-acc) -tag $win \
            -command [mymethod OnSupported]
        $t blocking list -acc $options(-acc) -tag $win \
            -command [mymethod Show]
    }

    method OnSupported {value} {
        set supported $value
        $self UpdateButtons
    }

    method OnChanged {ev} {
        $self Show [dict get $ev -list]
        $options(-tacky) blocking supported -acc $options(-acc) -tag $win \
            -command [mymethod OnSupported]
    }

    method Show {jids} {
        set keep [$tree selection]
        $tree delete [$tree children {}]
        foreach j [lsort $jids] {
            $tree insert {} end -id $j -values [list $j]
        }
        $tree selection set [lmap j $keep {
            if {![$tree exists $j]} continue
            set j
        }]
        $self UpdateButtons
    }

    method UpdateButtons {} {
        set n [llength [$tree children {}]]
        if {!$supported} {
            set status "Your server does not support blocking, or the\
                account is offline."
        } elseif {$n == 0} {
            set status "Nobody is blocked."
        } else {
            set status [expr {$n == 1 ? "1 blocked contact" : "$n blocked contacts"}]
        }
        set on [expr {$supported ? "normal" : "disabled"}]
        $win.buttons.block configure -state $on
        $win.buttons.unblock configure -state [expr {
            $supported && [llength [$tree selection]] ? "normal" : "disabled"}]
        $win.buttons.unblockall configure -state [expr {
            $supported && $n ? "normal" : "disabled"}]
    }

    method OnBlock {} {
        set jid [string trim [input_dialog .blocklist_add_dlg -parent $win \
            -title "Block JID" \
            -prompt "Address or domain to block:"]]
        if {$jid eq ""} return
        $options(-tacky) blocking block -acc $options(-acc) -jid $jid \
            -tag $win -onerror [list blocking_show_error $win "Block"]
    }

    method OnUnblock {} {
        set jids [$tree selection]
        if {![llength $jids]} return
        $options(-tacky) blocking unblock -acc $options(-acc) -jid $jids \
            -tag $win -onerror [list blocking_show_error $win "Unblock"]
    }

    method OnUnblockAll {} {
        if {[tk_messageBox -type yesno -icon question \
                -parent [winfo toplevel $win] \
                -message "Unblock everyone on this list?"] ne "yes"} return
        $options(-tacky) blocking unblockAll -acc $options(-acc) \
            -tag $win -onerror [list blocking_show_error $win "Unblock"]
    }
}
