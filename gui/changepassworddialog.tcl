if 0 {
    changepassworddialog - change an account's password on the server.

    Usage:
        changepassworddialog open romeo@montague.lit ?-parent $w? ?-command $cb?

    On success the server and the stored login password both hold the new
    one; the dialog closes and calls {*}$cb, unless -parent has gone by then.
    Errors stay in the dialog.
}

snit::widget changepassworddialog {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -command ""
    option -parent ""

    variable newpass ""
    variable busy 0

    typemethod open {account args} {
        array set opts {-parent "" -command ""}
        array set opts $args
        set top .chpass_[path_safe $account]
        if {[raise_existing $top]} return
        toplevel $top
        wm title $top "Change Password"
        wm resizable $top 0 0
        if {$opts(-parent) ne "" && [winfo exists $opts(-parent)]} {
            wm transient $top [winfo toplevel $opts(-parent)]
        }
        pack [changepassworddialog $top.d -acc $account \
                  -command $opts(-command) -parent $opts(-parent)] \
            -expand yes -fill both
        focus $top.d.new
    }

    constructor args {
        $self configurelist $args
        set acc $options(-acc)

        $hull configure -padding 10
        ttk::label $win.intro -justify left -wraplength 370 -text \
            "Changes the password for $acc on the server.\
             Tacky will log in with the new password from now on.\
             Other clients will need it too."
        ttk::label $win.newlbl -text "New password"
        showableentry $win.new -width 24 -textvariable [myvar newpass]
        ttk::label $win.msg -text "" -foreground red \
            -justify left -wraplength 370

        ttk::frame $win.btns
        ttk::button $win.btns.cancel -text "Cancel" \
            -command [list destroy [winfo toplevel $win]]
        ttk::button $win.btns.change -text "Change" -state disabled \
            -command [mymethod Change]
        pack $win.btns.change $win.btns.cancel -side right -padx {6 0}

        grid $win.intro -row 0 -column 0 -columnspan 2 -sticky w -pady {0 10}
        grid $win.newlbl -row 1 -column 0 -sticky nw -padx {0 8} -pady 2
        grid $win.new -row 1 -column 1 -sticky ew -pady 2
        grid $win.msg -row 2 -column 0 -columnspan 2 -sticky w -pady {6 0}
        grid $win.btns -row 3 -column 0 -columnspan 2 -sticky e -pady {10 0}
        grid columnconfigure $win 1 -weight 1

        bind $win.new.entry <Return> [mymethod Change]
        bind [winfo toplevel $win] <Escape> \
            [list destroy [winfo toplevel $win]]
        trace add variable [myvar newpass] write [mymethod Validate]
    }

    destructor {
        catch {$options(-tacky) unlisten $win}
    }

    method Validate {args} {
        if {$busy} return
        $win.msg configure -text ""
        $win.btns.change state [expr {$newpass ne "" ? "!disabled" : "disabled"}]
    }

    method Change {} {
        if {$busy || $newpass eq ""} return
        $self Busy 1
        $win.msg configure -text "Changing\u2026" -foreground ""
        $options(-tacky) account changePassword \
            -acc $options(-acc) -password $newpass \
            -tag $win -command [mymethod OnChanged] \
            -onerror [mymethod OnError]
    }

    method Busy {on} {
        set busy $on
        set st [expr {$on ? "disabled" : "!disabled"}]
        foreach w [list $win.new.entry $win.new.checkbutton $win.btns.change] {
            $w state $st
        }
    }

    method OnChanged {args} {
        set cmd $options(-command)
        set parent $options(-parent)
        destroy [winfo toplevel $win]
        # The window that asked may have closed meanwhile.
        if {$cmd ne "" && ($parent eq "" || [winfo exists $parent])} {
            {*}$cmd
        }
    }

    method OnError {message} {
        $self Busy 0
        $win.msg configure -text "Password not changed: $message" -foreground red
    }
}
