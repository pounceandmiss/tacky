snit::widgetadaptor accountnotebook {
    option -tacky -default ::tacky -readonly yes
    option -open-chat-command -default ""
    option -open-bookmark-command -default ""
    option -menubar -default "" -readonly yes

    variable tabs {}

    delegate method * to hull
    delegate option * to hull

    constructor args {
        installhull using ttk::notebook
        $self configurelist $args

        set tacky $options(-tacky)
        $tacky listen -tag $self account <Enabled>  [mymethod OnAccountEnabled]
        $tacky listen -tag $self account <Disabled> [mymethod OnAccountDisabled]
        $tacky listen -tag $self account <Removed>  [mymethod OnAccountRemoved]

        # Populate tabs for already-enabled accounts
        $tacky account list -enabled 1 -command [mymethod OnInitialAccounts]
    }

    destructor {
        catch {$options(-tacky) unlisten $self}
        foreach {jid child} $tabs {
            catch {destroy $child}
        }
    }

    method OnInitialAccounts {result} {
        foreach jid $result { $self AddTab $jid }
    }

    method OnAccountEnabled {ev} { $self AddTab [dict get $ev -acc] }
    method OnAccountDisabled {ev} { $self RemoveTab [dict get $ev -acc] }
    method OnAccountRemoved {ev} { $self RemoveTab [dict get $ev -acc] }

    method AddTab {jid} {
        if {[dict exists $tabs $jid]} return
        set safe [string map {@ _ . _} $jid]

        set panel [accountpanel $win.$safe \
            -account $jid \
            -tacky $options(-tacky) \
            -open-chat-command $options(-open-chat-command) \
            -open-bookmark-command $options(-open-bookmark-command) \
            -menubar $options(-menubar)]

        $hull add $panel -text $jid
        dict set tabs $jid $panel
    }

    method CurrentAccountJid {} {
        set sel [$hull select]
        if {$sel eq ""} { return "" }
        dict for {jid child} $tabs {
            if {$child eq $sel} { return $jid }
        }
        return ""
    }

    method RemoveTab {jid} {
        if {![dict exists $tabs $jid]} return
        set child [dict get $tabs $jid]
        destroy $child
        dict unset tabs $jid
    }
}
