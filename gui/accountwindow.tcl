if 0 {
    accountwindow - a toplevel showing one account.

    Owns its own menubar (File / Accounts / View), a paned layout with the
    account's chat list on the left (accountpanel) and an inline chat on the
    right, and the inline-vs-window chat routing. The Accounts menu switches
    the account shown here or opens another in its own window.

    Usage:
        accountwindow .acctwin_1 -account romeo@montague.lit -controller ::app
}

snit::widget accountwindow {
    hulltype toplevel

    option -account -readonly yes
    option -controller -readonly yes

    variable currentAccount ""
    variable shownAccount ""
    variable paned ""
    variable cpFrame ""
    variable panel ""
    variable accmenu ""
    variable inlineJid ""
    variable chatModeVar "inline"

    constructor args {
        $self configurelist $args

        if {$options(-account) eq ""} {
            error "accountwindow requires -account"
        }
        if {$options(-controller) eq ""} {
            error "accountwindow requires -controller"
        }
        set currentAccount $options(-account)

        # TODO: replace with ::tacky setting get once setting module exists
        set chatModeVar "inline"

        $self BuildMenubar
        $self BuildLayout

        wm protocol $win WM_DELETE_WINDOW [mymethod Close]
        bind $win <Control-q> [mymethod Quit]
        bind $win <Control-Q> [mymethod Quit]
        bind $win <Control-w> [mymethod Close]
        bind $win <Control-W> [mymethod Close]
        bind $win <Control-Shift-X> [mymethod OpenXmlConsole]
        bind $win <Control-f> [mymethod InlineOpenFind]
        bind $win <Control-F> [mymethod InlineOpenFind]

        ::tacky listen -tag $win account <Disabled> [mymethod OnAccountGone]
        ::tacky listen -tag $win account <Removed>  [mymethod OnAccountGone]
    }

    destructor {
        catch {::tacky unlisten $win}
        if {$accmenu ne ""} { catch {$accmenu destroy} }
    }

    # --- Construction ---

    method BuildMenubar {} {
        set mb $win.menubar
        menu $mb -tearoff 0

        menu $mb.file -tearoff 0
        $mb.file add command -label "XML Console..." \
            -command [mymethod OpenXmlConsole] -accelerator "Ctrl+Shift+X"
        $mb.file add command -label "MAM Info..." \
            -command [mymethod OpenMamInfo]
        $mb.file add separator
        $mb.file add command -label "Quit" \
            -command [mymethod Quit] -accelerator "Ctrl+Q"
        $mb add cascade -label "File" -menu $mb.file

        set accmenu [accountsmenu %AUTO% \
            -menubar $mb \
            -parent $win \
            -open-here-command [mymethod OpenHere] \
            -open-window-command [list $options(-controller) SpawnWindow] \
            -add-account-command [list $options(-controller) OpenAddAccount] \
            -join-room-command [mymethod OpenJoinRoom]]

        menu $mb.view -tearoff 0
        $mb.view add radiobutton -label "Open chats inline" \
            -variable [myvar chatModeVar] -value "inline" \
            -command [mymethod OnChatModeChanged]
        $mb.view add radiobutton -label "Open chats in window" \
            -variable [myvar chatModeVar] -value "window" \
            -command [mymethod OnChatModeChanged]
        $mb add cascade -label "View" -menu $mb.view

        $hull configure -menu $mb
    }

    method BuildLayout {} {
        set paned [ttk::panedwindow $win.paned -orient horizontal]
        set cpFrame [ttk::frame $paned.chatpanel]
        $self BuildPanel
        pack $paned -expand yes -fill both
        wm title $win "Tacky - $currentAccount"
    }

    method BuildPanel {} {
        set panel [accountpanel $paned.panel \
            -account $currentAccount \
            -open-chat-command [mymethod OpenChat] \
            -new-chat-command [mymethod OpenNewChat] \
            -menubar $win.menubar]
        # Request a width so the pane doesn't collapse before async content arrives.
        $panel configure -width 200
        $paned insert 0 $panel -weight 0
        set shownAccount $currentAccount
    }

    # --- Account switching ---

    method OpenHere {jid} {
        set existing [{*}$options(-controller) WindowForAccount $jid]
        if {$existing eq $win} return
        if {$existing ne ""} {
            {*}$options(-controller) RaiseWindow $existing
        } else {
            $self SwitchAccount $jid
        }
    }

    method SwitchAccount {jid} {
        if {$jid eq $shownAccount} return
        $self CloseInlineChat
        catch {destroy $panel}
        set currentAccount $jid
        $self BuildPanel
        wm title $win "Tacky - $currentAccount"
    }

    method OnAccountGone {ev} {
        if {[dict get $ev -acc] ne $currentAccount} return
        ::tacky account list -enabled 1 -tag $win -command [mymethod OnSurvivors]
    }

    method OnSurvivors {result} {
        set others [lsearch -all -inline -not -exact $result $currentAccount]
        if {[llength $others] > 0} {
            $self SwitchAccount [lindex $others 0]
        } else {
            $self Close
        }
    }

    # --- Lifecycle ---

    method Close {} {
        {*}$options(-controller) OnWindowClosed $win
    }

    method Quit {} {
        {*}$options(-controller) Quit
    }

    method CurrentAccount {} {
        return $currentAccount
    }

    # --- Chat routing ---

    method OpenChat {args} {
        array set opts $args
        if {$chatModeVar eq "inline"} {
            $self OpenChatInline -acc $opts(-acc) -jid $opts(-jid)
        } else {
            $self Openchatwindow -acc $opts(-acc) -jid $opts(-jid)
        }
    }

    method OpenChatInline {args} {
        array set opts $args
        if {$inlineJid eq $opts(-jid)} return

        foreach child [winfo children $cpFrame] {
            destroy $child
        }
        set inlineJid $opts(-jid)
        chatpanel $cpFrame.cp -acc $opts(-acc) -jid $opts(-jid) \
            -menubar $win.menubar
        pack $cpFrame.cp -expand yes -fill both

        if {$cpFrame ni [$paned panes]} {
            $paned add $cpFrame -weight 1
        }
    }

    method Openchatwindow {args} {
        array set opts $args
        set safe [string map {@ _ . _ / _ ? _} $opts(-jid)]
        chatwindow open .chatwin_$safe -acc $opts(-acc) -jid $opts(-jid)
    }

    method CloseInlineChat {} {
        if {$inlineJid eq ""} return
        foreach child [winfo children $cpFrame] {
            destroy $child
        }
        set inlineJid ""
        if {$cpFrame in [$paned panes]} {
            $paned forget $cpFrame
        }
    }

    method InlineOpenFind {} {
        if {$inlineJid ne "" && [winfo exists $cpFrame.cp]} {
            $cpFrame.cp OpenFind
        }
    }

    method OnChatModeChanged {} {
        # TODO: persist with ::tacky setting set once setting module exists
        if {$chatModeVar eq "window"} {
            $self CloseInlineChat
        }
    }

    # --- Menu actions ---

    method OpenJoinRoom {} {
        if {$currentAccount eq ""} return
        joinroomdialog show $currentAccount $win
    }
    method OpenNewChat {} {
        if {$currentAccount eq ""} return
        newchatdialog show $currentAccount $win [mymethod OpenChat]
    }

    method OpenXmlConsole {} {
        if {$currentAccount eq ""} return
        xmlconsole $currentAccount
    }

    method OpenMamInfo {} {
        if {$currentAccount eq ""} return
        if {$inlineJid ne ""} {
            maminfo open $currentAccount -target $inlineJid
        } else {
            maminfo open $currentAccount
        }
    }
}
