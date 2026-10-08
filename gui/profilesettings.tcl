if 0 {
    profilesettings - form for editing profile name, avatar, the password
    Tacky logs in with (with a way into changepassworddialog), and where the
    account connects.

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

    # The display name as last loaded or saved; the entry is only saved when
    # it differs.
    variable savedNick ""

    # Likewise for the stored login password.
    variable savedPass ""

    variable connRefused 0

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

        grid $win.avatar -row 0 -column 0 -rowspan 4 -sticky n \
            -padx {4 12} -pady 4

        # --- Account JID ---
        ttk::label $win.jid -text $acc -font {Helvetica 12 bold}
        grid $win.jid -row 0 -column 1 -columnspan 2 -sticky w -padx 4 -pady 4

        # --- Name row: saved on Return or focus-out, Escape reverts ---
        ttk::label $win.namelbl -text "Display Name"
        ttk::entry $win.nameentry -width 30
        bind $win.nameentry <Return> [mymethod SaveName]
        bind $win.nameentry <FocusOut> [mymethod SaveName]
        bind $win.nameentry <Escape> [mymethod RevertName]

        grid $win.namelbl    -row 1 -column 1 -sticky w -padx 4 -pady 4
        grid $win.nameentry  -row 1 -column 2 -sticky ew -padx 4 -pady 4

        # --- Login password: the stored one, saved like the name ---
        ttk::label $win.passlbl -text "Login Password"
        showableentry $win.passentry -width 30
        bind $win.passentry.entry <Return> [mymethod SavePass]
        bind $win.passentry.entry <FocusOut> [mymethod SavePass]
        bind $win.passentry.entry <Escape> [mymethod RevertPass]
        ttk::button $win.passchange -text "Change password on server\u2026" \
            -command [mymethod ChangePassword]

        grid $win.passlbl    -row 2 -column 1 -sticky nw -padx 4 -pady 4
        grid $win.passentry  -row 2 -column 2 -sticky ew -padx 4 -pady 4
        grid $win.passchange -row 3 -column 2 -sticky w -padx 4 -pady 4

        # --- Server connection: saved by its button ---
        ttk::label $win.connlbl -text "Server Connection"
        connectionfields $win.connection -collapsible 0
        ttk::button $win.connsave -text "Save connection settings" \
            -command [mymethod SaveConnection]
        grid $win.connlbl    -row 4 -column 1 -sticky nw -padx 4 -pady 4
        grid $win.connection -row 4 -column 2 -sticky ew -padx 4 -pady 4
        grid $win.connsave   -row 5 -column 2 -sticky w -padx 4 -pady 4

        # --- Status label ---
        ttk::label $win.status -text ""
        grid $win.status -row 6 -column 0 -columnspan 3 -sticky nsew -padx 4 -pady 4

        # --- OMEMO own keys ---
        ttk::separator $win.omemosep -orient horizontal
        grid $win.omemosep -row 7 -column 0 -columnspan 3 -sticky ew -pady {8 4}
        ttk::label $win.omemolbl -text "My OMEMO keys" \
            -font {Helvetica 12 bold}
        grid $win.omemolbl -row 8 -column 0 -columnspan 3 -sticky w -padx 4
        omemoownkeys $win.omemokeys -acc $acc
        grid $win.omemokeys -row 9 -column 0 -columnspan 3 -sticky nsew \
            -padx 4 -pady 4

        grid columnconfigure $win 2 -weight 1
        grid rowconfigure $win 9 -weight 1

        # Nick: load + stay live
        $t nick get -acc $acc -jid $acc \
            -tag $win -command [mymethod OnNick]
        $t listen -tag $win nick <Changed> -acc $acc -jid $acc \
            [mymethod OnNickChanged]

        $self LoadPass
        $self LoadConnection

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

    # A name arriving mid-edit leaves the edit alone.
    method OnNick {name} {
        set editing [expr {[$win.nameentry get] ne $savedNick}]
        set savedNick $name
        if {!$editing} { $self RevertName }
    }

    method OnNickChanged {ev} {
        $options(-tacky) nick get \
            -acc $options(-acc) -jid $options(-acc) \
            -tag $win -command [mymethod OnNick]
    }

    method LoadPass {} {
        $options(-tacky) account get -acc $options(-acc) -field password \
            -tag $win -command [mymethod OnPass]
    }

    method OnPass {pass} {
        set savedPass $pass
        $self RevertPass
    }

    method LoadConnection {} {
        $options(-tacky) account get -acc $options(-acc) \
            -tag $win -command [mymethod OnConnection]
    }

    method OnConnection {fields} {
        $win.connection load $fields
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
        if {$name eq $savedNick} return
        set savedNick $name
        $options(-tacky) nick set \
            -acc $options(-acc) -nick $name -tag $win \
            -command [mymethod OnNameSaved] \
            -onerror [mymethod OnNameError]
    }

    method RevertName {} {
        $win.nameentry delete 0 end
        $win.nameentry insert 0 $savedNick
    }

    method OnNameSaved {args} {
        $self OnResult Name [list ok ""]
    }

    method OnNameError {message} {
        $self OnResult Name [list error $message]
    }

    method SavePass {} {
        set pass [$win.passentry get]
        if {$pass eq $savedPass} return
        set savedPass $pass
        $options(-tacky) account set -acc $options(-acc) -password $pass \
            -tag $win -command [mymethod OnPassSaved] \
            -onerror [mymethod OnPassError]
    }

    method RevertPass {} {
        $win.passentry delete 0 end
        $win.passentry insert 0 $savedPass
    }

    # set replies only on error; the get queued behind it says when it's done
    method SaveConnection {} {
        set connRefused 0
        $options(-tacky) account set -acc $options(-acc) \
            {*}[$win.connection args] \
            -tag $win -onerror [mymethod OnConnectionError]
        $options(-tacky) account get -acc $options(-acc) \
            -tag $win -command [mymethod OnConnectionSaved]
    }

    method OnConnectionError {message} {
        set connRefused 1
        $self OnResult "Server connection" [list error $message]
    }

    method OnConnectionSaved {fields} {
        $win.connection load $fields
        if {!$connRefused} {
            $self OnResult "Server connection" [list ok ""]
        }
    }

    method OnPassSaved {args} {
        $self OnResult "Login password" [list ok ""]
    }

    method OnPassError {message} {
        $self OnResult "Login password" [list error $message]
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

    method ChangePassword {} {
        changepassworddialog open $options(-acc) -parent $win \
            -command [mymethod OnPasswordChanged]
    }

    method OnPasswordChanged {} {
        $self LoadPass
        $self Status "Password changed on server." ""
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
        if {$status eq "ok"} {
            $self Status "$what saved." ""
        } else {
            $self Status "$what error: $msg" red
        }
    }

    method Status {text color} {
        if {$statusAfter ne ""} {
            after cancel $statusAfter
        }
        $win.status configure -text $text -foreground $color
        set statusAfter [after 3000 [mymethod ClearStatus]]
    }

    method ClearStatus {} {
        set statusAfter ""
        if {[winfo exists $win.status]} {
            $win.status configure -text ""
        }
    }
}
