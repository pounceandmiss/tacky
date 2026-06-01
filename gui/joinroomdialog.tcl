# joinroomdialog - dialog for joining/discovering MUC rooms.
#
# Provides:
# - Room JID entry
# - Nick entry (pre-filled from bookmarks default nick)
# - Password entry (optional)
# - MUC service entry + "Discover" button
# - Room list treeview (populated by discoverRooms)
# - Join / Cancel buttons
#
# Usage:
#   joinroomdialog show $accountJid

snit::widget joinroomdialog {
    hulltype ttk::frame

    option -acc -readonly yes

    component roomlist
    component roomscroll

    variable roomjid ""
    variable nick ""
    variable password ""
    variable service ""
    variable toplevelW

    typemethod show {accJid {parent ""}} {
        set dlg .joinroomdialog
        if {[winfo exists $dlg]} {
            raise $dlg
            return
        }
        toplevel $dlg
        wm title $dlg "Join Room"
        wm minsize $dlg 400 350
        if {$parent ne "" && [winfo exists $parent]} {
            wm transient $dlg $parent
        }
        joinroomdialog $dlg.content -acc $accJid
        pack $dlg.content -expand yes -fill both
    }

    constructor args {
        $self configurelist $args

        set toplevelW [winfo toplevel $win]

        # Derive defaults
        set service "conference.[jid domain $options(-acc)]"
        ::tacky bookmarks defaultNick -acc $options(-acc) \
            -tag $self -command [mymethod OnDefaultNick]

        # Listen for join success/error
        ::tacky listen -tag $self \
            muc <Joined> -acc $options(-acc) [mymethod OnJoinOk]
        ::tacky listen -tag $self \
            muc <Error> -acc $options(-acc) [mymethod OnJoinError]

        # --- Room JID ---
        ttk::label $win.l_room -text "Room JID:"
        ttk::entry $win.e_room -textvariable [myvar roomjid]
        grid $win.l_room $win.e_room -sticky ew

        # --- Nick ---
        ttk::label $win.l_nick -text "Nickname:"
        ttk::entry $win.e_nick -textvariable [myvar nick]
        grid $win.l_nick $win.e_nick -sticky ew

        # --- Password ---
        ttk::label $win.l_pw -text "Password:"
        ttk::entry $win.e_pw -textvariable [myvar password] -show "*"
        grid $win.l_pw $win.e_pw -sticky ew

        # --- MUC Service + Discover ---
        ttk::label $win.l_svc -text "MUC Service:"
        ttk::frame $win.svc
        ttk::entry $win.svc.entry -textvariable [myvar service]
        ttk::button $win.svc.discover -text "Discover" \
            -command [mymethod Discover]
        pack $win.svc.entry -side left -expand yes -fill x
        pack $win.svc.discover -side left
        grid $win.l_svc $win.svc -sticky ew

        # --- Room list ---
        ttk::frame $win.rl
        install roomlist using sortabletreeview $win.rl.tv \
            -columns {jid name occupants} -show headings -height 8 \
            -selectmode browse \
            -sorttypes {occupants integer}
        $roomlist heading jid -text "JID"
        $roomlist heading name -text "Name"
        $roomlist heading occupants -text "Occupants"
        $roomlist column jid -width 200
        $roomlist column name -width 200
        $roomlist column occupants -width 70 -anchor center
        install roomscroll using ttk::scrollbar $win.rl.sb \
            -orient vertical -command [list $roomlist yview]
        $roomlist configure -yscrollcommand [list $roomscroll set]
        pack $roomscroll -side right -fill y
        pack $roomlist -side left -expand yes -fill both
        grid $win.rl - -sticky nsew

        bind $roomlist <<TreeviewSelect>> [mymethod OnRoomSelect]

        # --- Buttons ---
        ttk::frame $win.btns
        ttk::button $win.btns.join -text "Join" \
            -command [mymethod DoJoin]
        ttk::button $win.btns.cancel -text "Cancel" \
            -command [list destroy $toplevelW]
        pack $win.btns.join $win.btns.cancel -side left -padx 5
        grid $win.btns -

        # Grid weights
        grid columnconfigure $win 1 -weight 1
        grid rowconfigure $win 4 -weight 1

        # Keyboard bindings
        bind $win.e_room <Return> [mymethod DoJoin]
        bind $toplevelW <Escape> [list destroy $toplevelW]

        focus $win.e_room
    }

    destructor {
        catch {::tacky unlisten $self}
    }

    method Discover {} {
        foreach item [$roomlist children {}] {
            $roomlist delete $item
        }
        ::tacky muc discoverRooms \
            -acc $options(-acc) -jid $service \
            -tag $self -command [mymethod OnDiscoverResult]
    }

    method OnDiscoverResult {rooms} {
        if {![winfo exists $win]} return
        if {[lindex $rooms 0] eq "error"} {
            tk_messageBox -icon error -title "Discovery Failed" \
                -parent $toplevelW \
                -message "Could not discover rooms on $service"
            return
        }
        foreach room $rooms {
            set jid [dict get $room jid]
            set name [dict get $room name]
            set occupants [dict get $room occupants]
            $roomlist insert {} end -values [list $jid $name $occupants]
        }
    }

    method OnRoomSelect {} {
        set sel [$roomlist selection]
        if {$sel eq ""} return
        set roomjid [lindex [$roomlist item $sel -values] 0]
    }

    method OnDefaultNick {result} {
        if {$result ne ""} {
            set nick $result
        }
    }

    method DoJoin {} {
        if {$roomjid eq "" || $nick eq ""} {
            tk_messageBox -icon warning -title "Missing Info" \
                -parent $toplevelW \
                -message "Please enter a room JID and nickname."
            return
        }
        set bmArgs [list -acc $options(-acc) -jid $roomjid \
            -nick $nick -autojoin true]
        if {$password ne ""} {
            lappend bmArgs -password $password
        }
        ::tacky bookmarks item {*}$bmArgs
    }

    method OnJoinOk {ev} {
        if {[dict get $ev -jid] ne [string tolower $roomjid]} return
        after idle [list destroy $toplevelW]
    }

    method OnJoinError {ev} {
        if {[dict get $ev -jid] ne [string tolower $roomjid]} return
        set error ""
        if {[dict exists $ev -error]} {
            set error [dict get $ev -error]
        }
        tk_messageBox -icon error -title "Join Failed" \
            -parent $toplevelW \
            -message "Could not join $roomjid: $error"
    }
}
