if 0 {
    profilesettings - form for editing profile name, avatar, and password.

    Usage:
        profilesettings open romeo@montague.lit
}

snit::widget profilesettings {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes

    # Published avatars are cropped square and scaled to this edge (px).
    # The published PNG is the exact blob every subscriber downloads, so it
    # must stay under the server's stanza cap: a 128px photo PNG is ~30-70KB
    # base64, comfortable on typical servers.
    typevariable PublishEdge 128

    # Edge (px) of the avatar shown in this dialog.
    typevariable ShowEdge 96

    # Whether the account has an avatar; "Remove avatar" is disabled without one.
    variable hasAvatar 0

    variable statusAfter ""

    typemethod open {account} {
        set top .profile_[path_safe $account]
        if {[raise_existing $top]} return
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

        # --- Avatar: either click opens the Change/Remove menu ---
        ttk::frame $win.avatar
        ttk::label $win.avatar.img -image [avatarcache default] \
            -cursor hand2 -padding 0
        ttk::label $win.avatar.hint -text "Click to change" \
            -foreground gray50 -font TkSmallCaptionFont -cursor hand2
        pack $win.avatar.img -side top
        pack $win.avatar.hint -side top -pady {2 0}
        foreach w [list $win.avatar.img $win.avatar.hint] {
            bind $w <Button-1> [mymethod AvatarMenu %X %Y]
            bind $w <Button-3> [mymethod AvatarMenu %X %Y]
        }
        menu $win.avatarmenu -tearoff 0
        $win.avatarmenu add command -label "Change avatar\u2026" \
            -command [mymethod ChangeAvatar]
        $win.avatarmenu add command -label "Remove avatar" \
            -command [mymethod RemoveAvatar]

        grid $win.avatar -row 0 -column 0 -rowspan 3 -sticky n \
            -padx {4 12} -pady 4

        # --- Account JID ---
        ttk::label $win.jid -text $acc -font {Helvetica 12 bold}
        grid $win.jid -row 0 -column 1 -columnspan 3 -sticky w -padx 4 -pady 4

        # --- Name row ---
        ttk::label $win.namelbl -text "Display Name"
        ttk::entry $win.nameentry -width 30
        ttk::button $win.namesave -text "Save" \
            -command [mymethod SaveName]

        grid $win.namelbl    -row 1 -column 1 -sticky w -padx 4 -pady 4
        grid $win.nameentry  -row 1 -column 2 -sticky ew -padx 4 -pady 4
        grid $win.namesave   -row 1 -column 3 -sticky ew -padx 4 -pady 4

        # --- Password row ---
        ttk::label $win.passlbl -text "Password"
        showableentry $win.passentry -width 30
        ttk::button $win.passsave -text "Change Password" \
            -command [mymethod SavePassword]

        grid $win.passlbl    -row 2 -column 1 -sticky w -padx 4 -pady 4
        grid $win.passentry  -row 2 -column 2 -sticky ew -padx 4 -pady 4
        grid $win.passsave   -row 2 -column 3 -sticky ew -padx 4 -pady 4

        # --- Status label ---
        ttk::label $win.status -text ""
        grid $win.status -row 3 -column 0 -columnspan 4 -sticky nsew -padx 4 -pady 4

        # --- OMEMO own keys ---
        ttk::separator $win.omemosep -orient horizontal
        grid $win.omemosep -row 5 -column 0 -columnspan 4 -sticky ew -pady {8 4}
        ttk::label $win.omemolbl -text "My OMEMO keys" \
            -font {Helvetica 12 bold}
        grid $win.omemolbl -row 6 -column 0 -columnspan 4 -sticky w -padx 4
        omemoownkeys $win.omemokeys -acc $acc
        grid $win.omemokeys -row 7 -column 0 -columnspan 4 -sticky nsew \
            -padx 4 -pady 4

        grid columnconfigure $win 2 -weight 1
        grid rowconfigure $win 7 -weight 1

        # Nick: load + stay live
        $t nick get -acc $acc -jid $acc \
            -tag $win -command [mymethod OnNick]
        $t listen -tag $win nick <Changed> -acc $acc -jid $acc \
            [mymethod OnNickChanged]

        # Avatar: load + stay live
        set img [avatarcache track \
            -acc $acc -jid $acc -tag $win.avatar -size $ShowEdge \
            -command [mymethod OnAvatar]]
        $win.avatar.img configure -image $img
        $t avatar metadata -acc $acc -jid $acc \
            -tag $win -command [mymethod OnMeta]
        $t listen -tag $win avatar <Update> -acc $acc -jid $acc \
            [mymethod OnAvatarUpdate]
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
        $win.avatar.img configure -image $img
    }

    method OnMeta {meta} {
        set hasAvatar [expr {[dict exists $meta hash]
                             && [dict get $meta hash] ne ""}]
    }

    method OnAvatarUpdate {ev} {
        set hasAvatar [expr {[dict get $ev -hash] ne ""}]
    }

    method AvatarMenu {X Y} {
        $win.avatarmenu entryconfigure "Remove avatar" \
            -state [expr {$hasAvatar ? "normal" : "disabled"}]
        tk_popup $win.avatarmenu $X $Y
    }

    # --- Actions ---

    method SaveName {} {
        set name [$win.nameentry get]
        $options(-tacky) nick set \
            -acc $options(-acc) -nick $name -tag $win \
            -command [mymethod OnNameSaved] \
            -onerror [mymethod OnNameError]
    }

    method OnNameSaved {args} {
        $self OnResult Name [list ok ""]
    }

    method OnNameError {message} {
        $self OnResult Name [list error $message]
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

        # Prepare the image client-side: square it off at PublishEdge and
        # PNG-encode. The backend stores and sends these bytes verbatim.
        set out [square_photo $data $PublishEdge]
        if {$out eq ""} {
            $self OnResult Avatar [list error "Unsupported image format"]
            return
        }
        set png [::tkwuffs::encode_png_from_photo $out]
        image delete $out

        $options(-tacky) avatar publish \
            -acc $options(-acc) -data $png -type image/png \
            -width $PublishEdge -height $PublishEdge \
            -tag $win -command [mymethod OnAvatarSaved] \
            -onerror [mymethod OnAvatarError]
    }

    method RemoveAvatar {} {
        $options(-tacky) avatar disable \
            -acc $options(-acc) \
            -tag $win -command [mymethod OnAvatarSaved] \
            -onerror [mymethod OnAvatarError]
    }

    method OnAvatarSaved {args} {
        $self OnResult Avatar [list ok ""]
    }

    method OnAvatarError {message} {
        $self OnResult Avatar [list error $message]
    }

    method SavePassword {} {
        set pass [$win.passentry get]
        if {$pass eq ""} return
        $options(-tacky) account changePassword \
            -acc $options(-acc) -password $pass \
            -tag $win -command [mymethod OnPasswordSaved] \
            -onerror [mymethod OnPasswordError]
    }

    method OnPasswordSaved {args} {
        $self OnResult Password [list ok ""]
    }

    method OnPasswordError {message} {
        $self OnResult Password [list error $message]
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
