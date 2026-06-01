if 0 {
    profilesettings - form for editing profile name, avatar, and password.

    Usage:
        profilesettings open romeo@montague.lit
}

snit::widget profilesettings {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes

    variable statusAfter ""

    typemethod open {account} {
        set top .profile_[string map {@ _ . _} $account]
        if {[winfo exists $top]} {
            wm deiconify $top
            raise $top
            return
        }
        toplevel $top
        wm title $top "Profile"
        wm resizable $top 1 1
        pack [profilesettings $top.ps -acc $account] \
            -expand yes -fill both -padx 10 -pady 10
    }

    constructor args {
        $self configurelist $args

        if {$options(-acc) eq ""} {
            error "profilesettings requires -acc"
        }

        set acc $options(-acc)
        set t $options(-tacky)

        # --- Name row ---
        ttk::label $win.namelbl -text "Display Name"
        ttk::entry $win.nameentry -width 30
        ttk::button $win.namesave -text "Save" \
            -command [mymethod SaveName]

        grid $win.namelbl    -row 0 -column 0 -sticky nsew -padx 4 -pady 4
        grid $win.nameentry  -row 0 -column 1 -sticky nsew -padx 4 -pady 4
        grid $win.namesave   -row 0 -column 2 -sticky nsew -padx 4 -pady 4

        # --- Avatar row ---
        ttk::label $win.avatarlbl -text "Avatar"
        ttk::label $win.avatarimg -image {} -padding 2
        ttk::button $win.avatarchange -text "Change..." \
            -command [mymethod ChangeAvatar]
        ttk::button $win.avatarremove -text "Remove" \
            -command [mymethod RemoveAvatar]

        grid $win.avatarlbl     -row 1 -column 0 -sticky nsew -padx 4 -pady 4
        grid $win.avatarimg     -row 1 -column 1 -sticky nsew -padx 4 -pady 4
        grid $win.avatarchange  -row 2 -column 1 -sticky nsew -padx 4 -pady 4
        grid $win.avatarremove  -row 2 -column 2 -sticky nsew -padx 4 -pady 4

        # --- Password row ---
        ttk::label $win.passlbl -text "Password"
        showableentry $win.passentry -width 30
        ttk::button $win.passsave -text "Change Password" \
            -command [mymethod SavePassword]

        grid $win.passlbl    -row 3 -column 0 -sticky nsew -padx 4 -pady 4
        grid $win.passentry  -row 3 -column 1 -sticky nsew -padx 4 -pady 4
        grid $win.passsave   -row 3 -column 2 -sticky nsew -padx 4 -pady 4

        # --- Status label ---
        ttk::label $win.status -text ""
        grid $win.status -row 4 -column 0 -columnspan 3 -sticky nsew -padx 4 -pady 4

        # --- OMEMO own keys ---
        ttk::separator $win.omemosep -orient horizontal
        grid $win.omemosep -row 5 -column 0 -columnspan 3 -sticky ew -pady {8 4}
        ttk::label $win.omemolbl -text "My OMEMO keys" \
            -font {Helvetica 12 bold}
        grid $win.omemolbl -row 6 -column 0 -columnspan 3 -sticky w -padx 4
        omemokeyspanel $win.omemokeys -acc $acc -jid [jid bare $acc]
        grid $win.omemokeys -row 7 -column 0 -columnspan 3 -sticky nsew \
            -padx 4 -pady 4

        grid columnconfigure $win 1 -weight 1
        grid rowconfigure $win 7 -weight 1

        # Nick: load + stay live
        $t nick get -acc $acc -jid $acc \
            -tag $win -command [mymethod OnNick]
        $t listen -tag $win nick <Changed> -acc $acc -jid $acc \
            [mymethod OnNickChanged]

        # Avatar: load + stay live
        set img [avatarcache track \
            -acc $acc -jid $acc -tag $win.avatar \
            -command [mymethod OnAvatar]]
        $win.avatarimg configure -image $img
        $t listen -tag $win avatar <Progress> -acc $acc \
            [mymethod OnProgress]
    }

    destructor {
        if {$statusAfter ne ""} {
            after cancel $statusAfter
        }
        catch {$options(-tacky) unlisten $win}
        catch {$options(-tacky) avatar cancel -acc $options(-acc) -tag $win}
        catch {avatarcache untrack -tag $win.avatar}
    }

    # --- Data loading callbacks ---

    method OnNick {name} {
        $win.nameentry delete 0 end
        if {$name ne ""} {
            $win.nameentry insert 0 $name
        }
    }

    method OnNickChanged {ev} {
        $options(-tacky) nick get \
            -acc $options(-acc) -jid $options(-acc) \
            -tag $win -command [mymethod OnNick]
    }

    method OnAvatar {img} {
        $win.avatarimg configure -image $img
    }

    # --- Actions ---

    method SaveName {} {
        set name [$win.nameentry get]
        $options(-tacky) nick set \
            -acc $options(-acc) -nick $name \
            -tag $win -command [mymethod OnNameSaved]
    }

    method OnNameSaved {stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ ne "error"} {
            $self OnResult Name [list ok ""]
        } else {
            set errText [xsearch $stanza error text -get body]
            if {$errText eq ""} { set errText "Nick publish failed" }
            $self OnResult Name [list error $errText]
        }
    }

    method ChangeAvatar {} {
        set path [tk_getOpenFile -parent [winfo toplevel $win] -filetypes {
            {{Images} {.png .jpg .jpeg .gif}}
            {{All files} *}
        }]
        if {$path eq ""} return
        set fd [open $path rb]
        set data [read $fd]
        close $fd
        $options(-tacky) avatar publish \
            -acc $options(-acc) -data $data -type image/png \
            -tag $win -command [mymethod OnResult "Avatar"]
    }

    method RemoveAvatar {} {
        $options(-tacky) avatar disable \
            -acc $options(-acc) \
            -tag $win -command [mymethod OnResult "Avatar"]
    }

    method SavePassword {} {
        set pass [$win.passentry get]
        if {$pass eq ""} return
        $options(-tacky) account changePassword \
            -acc $options(-acc) -password $pass \
            -tag $win -command [mymethod OnResult "Password"]
    }

    # --- Feedback ---

    method OnProgress {ev} {
        if {$statusAfter ne ""} {
            after cancel $statusAfter
            set statusAfter ""
        }
        $win.status configure -text [dict get $ev -message] -foreground ""
    }

    method OnResult {what result} {
        lassign $result status msg
        if {$statusAfter ne ""} {
            after cancel $statusAfter
        }
        if {$status eq "ok"} {
            $win.status configure -text "$what saved." -foreground ""
        } else {
            $win.status configure -text "$what error: $msg" -foreground red
        }
        set statusAfter [after 3000 [mymethod ClearStatus]]
    }

    method ClearStatus {} {
        set statusAfter ""
        if {[winfo exists $win.status]} {
            $win.status configure -text ""
        }
    }
}
