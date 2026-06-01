if 0 {
    profilebar - compact identity bar showing avatar + display name.

    Sits above the contact list. Clicking fires -command.
    Right-clicking shows a context menu with connection status and actions.

    Usage:
        profilebar .bar -acc romeo@montague.lit
        .bar configure -command [list puts "clicked"]
}

snit::widget profilebar {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -command -default ""

    variable connstate disconnected
    variable errmsg ""

    constructor args {
        $self configurelist $args

        if {$options(-acc) eq ""} {
            error "profilebar requires -acc"
        }

        set acc $options(-acc)
        set t $options(-tacky)

        # Avatar label (32x32)
        ttk::label $win.avatar -image [avatarcache default] -padding 2
        set img [avatarcache track \
            -acc $acc -jid $acc -tag $win \
            -command [mymethod OnAvatar]]
        $win.avatar configure -image $img
        # Name label — default to JID username until we fetch the nick
        ttk::label $win.name -text [jid username $acc] -padding {4 2}
        # Connection status indicator
        ttk::label $win.status -text "\u25CF" -foreground gray50 -padding {4 2}

        pack $win.avatar -side left
        pack $win.name -side left -fill x -expand yes
        pack $win.status -side right

        # Click bindings on the whole bar
        foreach w [list $win $win.avatar $win.name $win.status] {
            bind $w <Button-1> [mymethod OnClick]
            bind $w <Button-3> [mymethod OnRightClick %X %Y]
        }

        # Connection state events
        $t listen -tag $win conn <State> -acc $acc [mymethod OnConnState]
        $t listen -tag $win conn <AuthError> -acc $acc [mymethod OnError]
        $t listen -tag $win conn <Disconnected> -acc $acc [mymethod OnError]

        # Fetch display name
        $t bookmarks defaultNick -acc $acc \
            -tag $win -command [mymethod OnDefaultNick]
    }

    destructor {
        catch {$options(-tacky) unlisten $win}
        catch {avatarcache untrack -tag $win}
    }

    # --- Event handlers ---

    method OnDefaultNick {name} {
        if {$name ne ""} {
            $win.name configure -text $name
        }
    }

    method OnAvatar {img} {
        $win.avatar configure -image $img
    }

    method OnConnState {ev} {
        set connstate [dict get $ev -state]
        switch -- $connstate {
            connected {
                set errmsg ""
                $win.status configure -text "\u25CF" -foreground green4
            }
            connecting - authenticating - binding {
                set errmsg ""
                $win.status configure -text "\u25CF" -foreground goldenrod3
            }
            waiting {
                $win.status configure -text "\u25CF" -foreground goldenrod3
            }
            disconnected {
                if {$errmsg eq ""} {
                    $win.status configure -text "\u25CF" -foreground gray50
                }
            }
        }
    }

    method OnError {ev} {
        set errmsg [dict get $ev -message]
        set connstate disconnected
        $win.status configure -text "\u25CF" -foreground red3
    }

    method OnClick {} {
        if {$options(-command) ne ""} {
            {*}$options(-command)
        }
    }

    method OnRightClick {X Y} {
        set m $win.__ctxmenu
        if {![winfo exists $m]} { menu $m -tearoff 0 }
        $m delete 0 end

        # Status line
        if {$errmsg ne ""} {
            $m add command -label $errmsg -state disabled
        } else {
            $m add command -label [string totitle $connstate] -state disabled
        }

        $m add separator

        # Connection actions
        set acc $options(-acc)
        set t $options(-tacky)
        if {$connstate eq "connected" || $connstate eq "connecting"
                || $connstate eq "authenticating" || $connstate eq "binding"} {
            $m add command -label "Disconnect" \
                -command [list $t account disable -acc $acc]
        } else {
            $m add command -label "Reconnect" -command [list apply {{t acc} {
                $t account disable -acc $acc
                $t account enable -acc $acc
            }} $t $acc]
        }

        $m add separator
        $m add command -label "Account settings..." \
            -command [mymethod OnClick]

        tk_popup $m $X $Y
    }
}
