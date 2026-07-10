snit::widget newchatdialog {
    hulltype ttk::frame

    option -acc -readonly yes
    option -open-chat-command -default "" -readonly yes

    variable jid ""
    variable name ""
    variable addContact 1
    variable toplevelW

    typemethod show {accJid {parent ""} {openChatCmd ""}} {
        set dlg .newchatdialog
        if {[winfo exists $dlg]} {
            raise $dlg
            return
        }
        toplevel $dlg
        wm title $dlg "New Chat"
        wm resizable $dlg 1 0
        if {$parent ne "" && [winfo exists $parent]} {
            wm transient $dlg $parent
        }
        newchatdialog $dlg.content -acc $accJid -open-chat-command $openChatCmd
        pack $dlg.content -expand yes -fill both
    }

    constructor args {
        $self configurelist $args

        set toplevelW [winfo toplevel $win]

        ttk::label $win.l_jid -text "JID:"
        ttk::entry $win.e_jid -textvariable [myvar jid]
        grid $win.l_jid $win.e_jid -sticky ew -padx 4 -pady 4

        ttk::label $win.l_name -text "Name:"
        ttk::entry $win.e_name -textvariable [myvar name]
        grid $win.l_name $win.e_name -sticky ew -padx 4 -pady 4

        ttk::checkbutton $win.add -text "Add to my contacts" \
            -variable [myvar addContact]
        grid x $win.add -sticky w -padx 4 -pady 4

        ttk::frame $win.btns
        ttk::button $win.btns.start -text "Start" -command [mymethod DoStart]
        ttk::button $win.btns.cancel -text "Cancel" \
            -command [list destroy $toplevelW]
        pack $win.btns.start $win.btns.cancel -side left -padx 5
        grid x $win.btns -sticky e -padx 4 -pady 4

        grid columnconfigure $win 1 -weight 1

        bind $win.e_jid <Return> [mymethod DoStart]
        bind $win.e_name <Return> [mymethod DoStart]
        bind $toplevelW <Escape> [list destroy $toplevelW]

        focus $win.e_jid
    }

    method DoStart {} {
        set target [string trim $jid]
        if {$target eq "" || ![jid valid $target]} {
            tk_messageBox -icon warning -title "Invalid JID" \
                -parent $toplevelW \
                -message "Please enter a valid JID, e.g. someone@example.com"
            return
        }
        set target [jid bare [jid norm $target]]

        if {$addContact} {
            set addArgs [list -acc $options(-acc) -jid $target]
            set contactName [string trim $name]
            if {$contactName ne ""} {
                lappend addArgs -name $contactName
            }
            ::tacky roster add {*}$addArgs
        }

        if {$options(-open-chat-command) ne ""} {
            {*}$options(-open-chat-command) \
                -acc $options(-acc) -jid $target -groupchat 0
        }

        destroy $toplevelW
    }
}
