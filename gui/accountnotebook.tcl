snit::widget accountnotebook {
    hulltype ttk::frame

    option -tacky -default ::tacky -readonly yes
    option -open-chat-command -default ""
    option -open-bookmark-command -default ""
    option -menubar -default "" -readonly yes

    delegate option -width to hull
    delegate option -height to hull

    variable tabs {}
    variable combo ""
    variable pages_w ""
    variable jidList {}

    constructor args {
        $self configurelist $args

        set combo [ttk::combobox $win.combo -state readonly]
        pack $combo -fill x
        bind $combo <<ComboboxSelected>> [mymethod OnSelect]

        set pages_w [pages $win.pages]
        pack $pages_w -fill both -expand yes

        set tacky $options(-tacky)
        $tacky listen -tag $self account <Enabled>  [mymethod OnAccountEnabled]
        $tacky listen -tag $self account <Disabled> [mymethod OnAccountDisabled]
        $tacky listen -tag $self account <Removed>  [mymethod OnAccountRemoved]

        $tacky account list -enabled 1 -tag $self -command [mymethod OnInitialAccounts]
    }

    destructor {
        catch {$options(-tacky) unlisten $self}
        foreach {jid child} $tabs {
            catch {destroy $child}
        }
    }

    method OnInitialAccounts {result} {
        foreach jid $result { $self AddTab $jid }
        # Re-raise selected panel so it sits on top of the grid stack
        set sel [$combo get]
        if {$sel ne ""} {
            $pages_w raise [dict get $tabs $sel]
        }
    }

    method OnAccountEnabled {ev} { $self AddTab [dict get $ev -acc] }
    method OnAccountDisabled {ev} { $self RemoveTab [dict get $ev -acc] }
    method OnAccountRemoved {ev} { $self RemoveTab [dict get $ev -acc] }

    method AddTab {jid} {
        if {[dict exists $tabs $jid]} return
        set safe [string map {@ _ . _} $jid]

        set panel [accountpanel $pages_w.$safe \
            -account $jid \
            -tacky $options(-tacky) \
            -open-chat-command $options(-open-chat-command) \
            -open-bookmark-command $options(-open-bookmark-command) \
            -menubar $options(-menubar)]

        $pages_w add $panel
        dict set tabs $jid $panel
        lappend jidList $jid
        $combo configure -values $jidList

        # Auto-select first account
        if {[llength $jidList] == 1} {
            $combo set $jid
            $pages_w raise $panel
        }
    }

    method CurrentAccountJid {} {
        return [$combo get]
    }

    method RemoveTab {jid} {
        if {![dict exists $tabs $jid]} return
        set child [dict get $tabs $jid]
        set wasSelected [expr {[$combo get] eq $jid}]

        destroy $child
        dict unset tabs $jid

        set idx [lsearch -exact $jidList $jid]
        if {$idx >= 0} {
            set jidList [lreplace $jidList $idx $idx]
        }
        $combo configure -values $jidList

        if {$wasSelected} {
            if {[llength $jidList] > 0} {
                set newJid [lindex $jidList 0]
                $combo set $newJid
                $pages_w raise [dict get $tabs $newJid]
            } else {
                $combo set ""
            }
        }
    }

    method OnSelect {} {
        set jid [$combo get]
        if {$jid ne "" && [dict exists $tabs $jid]} {
            $pages_w raise [dict get $tabs $jid]
        }
    }
}
