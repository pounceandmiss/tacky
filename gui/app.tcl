snit::type app_type {
    option -transient -default 0 -readonly yes
    option -backend -default direct -readonly yes
    option -debug-dir -default "" -readonly yes
    variable current ""

    variable notebook ""
    variable paned ""
    variable chatpanel ""
    variable inlineJid ""
    variable chatModeVar "inline"
    variable accmenu ""

    constructor args {
        $self configurelist $args
        switch $options(-backend) {
            process {
                tacky_init_process -transient $options(-transient)
            }
            thread {
                package require Thread
                tacky_init_threaded -transient $options(-transient)
            }
            default {
                tacky_init -transient $options(-transient)
            }
        }
        if {$options(-debug-dir) ne ""} {
            file mkdir $options(-debug-dir)
            jlog configure -logproc [list jlog_file_writer $options(-debug-dir)] \
                -defaultlevel debug
        }
        ::tacky listen -tag $self calls <Incoming> [mymethod OnIncomingCall]
        ::tacky listen -tag $self calls <Outgoing> [mymethod OnOutgoingCall]

        ::tacky account list  -enabled 1 -command [mymethod OnAccountList]
    }

    destructor {
        catch {::tacky unlisten $self}
        if {$current ne ""} {
            catch {destroy $current}
        }
        catch {::tacky destroy}
        foreach w [winfo children .] {
            catch {destroy $w}
        }
    }

    method OnAccountList {result} {
        if {[llength $result] > 0} {
            $self BuildMainUI
        } else {
            $self ShowSetup
        }
    }

    method TeardownUI {} {
        if {$current ne ""} {
            destroy $current
            set current ""
        }
        if {$accmenu ne ""} {
            $accmenu destroy
            set accmenu ""
        }
        . configure -menu {}
        if {[winfo exists .menubar]} {
            destroy .menubar
        }
        set notebook ""
        set paned ""
        set chatpanel ""
        set inlineJid ""
    }

    method ShowSetup {} {
        $self TeardownUI
        set current [initialsetup .setup \
            -onsuccess [mymethod OnSetupDone]]
        pack $current -expand yes -fill both
    }

    method OnSetupDone {jid} {
        ::tacky account enable -acc $jid
        $self TeardownUI
        $self BuildMainUI
    }

    method BuildMainUI {} {
        wm title . "Tacky"

        # TODO: replace with ::tacky setting get once setting module exists
        set chatModeVar "inline"

        # --- Menubar ---
        menu .menubar -tearoff 0

        # File menu
        menu .menubar.file -tearoff 0
        .menubar.file add command -label "XML Console..." \
            -command [mymethod OpenXmlConsole] -accelerator "Ctrl+Shift+X"
        .menubar.file add command -label "MAM Info..." \
            -command [mymethod OpenMamInfo]
        .menubar.file add separator
        .menubar.file add command -label "Quit" \
            -command [list destroy .] -accelerator "Ctrl+Q"
        .menubar add cascade -label "File" -menu .menubar.file

        # Accounts menu
        set accmenu [accountsmenu %AUTO% \
            -menubar .menubar \
            -add-account-command [mymethod OpenAddAccount] \
            -join-room-command [mymethod OpenJoinRoom]]

        # View menu
        menu .menubar.view -tearoff 0
        .menubar.view add radiobutton -label "Open chats inline" \
            -variable [myvar chatModeVar] -value "inline" \
            -command [mymethod OnChatModeChanged]
        .menubar.view add radiobutton -label "Open chats in window" \
            -variable [myvar chatModeVar] -value "window" \
            -command [mymethod OnChatModeChanged]
        .menubar add cascade -label "View" -menu .menubar.view

        . configure -menu .menubar

        # Global accelerators
        bind . <Control-q> [list destroy .]
        bind . <Control-Q> [list destroy .]
        bind . <Control-Shift-X> [mymethod OpenXmlConsole]
        bind . <Control-f> [mymethod InlineOpenFind]
        bind . <Control-F> [mymethod InlineOpenFind]

        # --- Paned layout ---
        set paned [ttk::panedwindow .paned -orient horizontal]
        set chatpanel [ttk::frame $paned.chatpanel]

        set notebook [accountnotebook $paned.notebook \
            -open-chat-command [mymethod OpenChat] \
            -open-bookmark-command [mymethod OpenBookmark] \
            -menubar .menubar]
        # Tabs load async in threaded mode — request a width so the
        # pane doesn't collapse before content arrives.
        $notebook configure -width 200
        $paned add $notebook -weight 0

        set current $paned
        pack $paned -expand yes -fill both
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

        # Destroy previous inline chat content
        foreach child [winfo children $chatpanel] {
            destroy $child
        }
        set inlineJid $opts(-jid)
        # Create chat widgets in the panel
        chatpanel $chatpanel.cp -acc $opts(-acc) -jid $opts(-jid) \
            -menubar .menubar
        pack $chatpanel.cp -expand yes -fill both

        # Add panel to paned if not already there
        if {$chatpanel ni [$paned panes]} {
            $paned add $chatpanel -weight 1
        }
    }

    method Openchatwindow {args} {
        array set opts $args
        set safe [string map {@ _ . _ / _ ? _} $opts(-jid)]
        chatwindow open .chatwin_$safe -acc $opts(-acc) -jid $opts(-jid)
    }

    method OpenBookmark {args} {
        array set opts $args
        $self OpenChat -acc $opts(-acc) -jid $opts(-jid)?join
    }

    method CloseInlineChat {} {
        if {$inlineJid eq ""} return
        foreach child [winfo children $chatpanel] {
            destroy $child
        }
        set inlineJid ""
        if {$chatpanel in [$paned panes]} {
            $paned forget $chatpanel
        }
    }

    method InlineOpenFind {} {
        if {$inlineJid ne "" && [winfo exists $chatpanel.cp]} {
            $chatpanel.cp OpenFind
        }
    }

    method OnChatModeChanged {} {
        # TODO: persist with ::tacky setting set once setting module exists
        if {$chatModeVar eq "window"} {
            $self CloseInlineChat
        }
    }

    # --- Menu actions ---

    method OpenAddAccount {} {
        if {[winfo exists .addaccount]} {
            raise .addaccount
            return
        }
        toplevel .addaccount
        wm title .addaccount "Add Account"
        initialsetup .addaccount.setup \
            -onsuccess [mymethod OnAddAccountDone]
        pack .addaccount.setup -expand yes -fill both
    }

    method OnAddAccountDone {jid} {
        ::tacky account enable -acc $jid
        destroy .addaccount
    }

    method OpenJoinRoom {} {
        set jid [$notebook CurrentAccountJid]
        if {$jid eq ""} return
        joinroomdialog show $jid
    }

    method OpenXmlConsole {} {
        set jid [$notebook CurrentAccountJid]
        if {$jid eq ""} return
        xmlconsole $jid
    }

    # --- Calls ---

    method OnIncomingCall {ev} {
        incomingcalldialog open \
            -acc [dict get $ev -acc] \
            -sid [dict get $ev -sid] \
            -from [dict get $ev -from]
    }

    method OnOutgoingCall {ev} {
        callwindow show \
            -acc [dict get $ev -acc] \
            -sid [dict get $ev -sid] \
            -peer [dict get $ev -to] \
            -direction outgoing
    }

    method OpenMamInfo {} {
        set jid [$notebook CurrentAccountJid]
        if {$jid eq ""} return
        if {$inlineJid ne ""} {
            maminfo open $jid -target $inlineJid
        } else {
            maminfo open $jid
        }
    }

}
