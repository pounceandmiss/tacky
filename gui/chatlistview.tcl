if 0 {
    Usage:
        chatlistview .clv -acc juliet@capulet.li
}

ttk::style configure Chatlistview.Treeview -rowheight 32

snit::widget chatlistview {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -open-chat-command -default ""
    option -new-chat-command -default ""

    component treeview
    component searchentry
    component contactmenu
    component bookmarkmenu
    component settingsmenu

    variable searchquery ""
    variable sortby "recent"
    variable prescolors 1
    variable showAvatars 1
    variable sendReceipts 1
    variable bookmarkMember 0
    variable trackedAvatars {}
    # Flat list of chat entries (chatlist get shape), patched by <Item>/<Remove>
    variable model {}

    # Row style per backend room_state enum (taco_bookmarks RoomState).  Tags
    # are named muc_<state>, so the state name IS the tag - no translation.
    #   joined = normal; idle = dimmed grey (not a member / unattempted);
    #   joining = grey italic (transient); disconnected = amber (a member
    #   room we're not in); error = red (explicit join error).
    typevariable mucStateStyle {
        joined       {-foreground ""           -font ""}
        idle         {-foreground gray60       -font ""}
        joining      {-foreground gray60       -font ChatlistMucItalic}
        disconnected {-foreground DarkOrange3  -font ""}
        error        {-foreground red3         -font ""}
    }

    constructor args {
        $self configurelist $args

        if {$options(-acc) eq ""} {
            error "chatlistview requires -acc"
        }

        ::tacky observe -tag $win setting <Changed> -key show_presence_colors \
            [mymethod OnPresenceColorsSetting]
        ::tacky observe -tag $win setting <Changed> -key show_avatars \
            [mymethod OnShowAvatarsSetting]
        ::tacky observe -tag $win setting <Changed> -key send_chat_markers \
            [mymethod OnSendReceiptsSetting]

        # Search entry + new-chat button
        ttk::frame $win.header
        install searchentry using ttk::entry $win.header.search \
            -textvariable [myvar searchquery]
        ttk::button $win.header.new \
            -image mate/16x16/actions/contact-new.png \
            -style Toolbutton -takefocus 0 \
            -command [mymethod OnNewChat]
        pack $win.header.new -side right -padx {2 0}
        pack $searchentry -side left -expand yes -fill x
        bind $searchentry <KeyRelease> [mymethod Render]

        # Treeview
        install treeview using ttk::treeview $win.tree \
            -show tree \
            -selectmode browse \
            -style Chatlistview.Treeview
        $treeview column #0 -stretch yes

        # Scrollbar
        ttk::scrollbar $win.scroll -orient vertical \
            -command [list $treeview yview]
        $treeview configure -yscrollcommand [list $win.scroll set]

        # Layout
        grid $win.header -row 0 -column 0 -columnspan 2 -sticky ew \
            -padx 2 -pady 2
        grid $treeview    -row 1 -column 0 -sticky nsew
        grid $win.scroll  -row 1 -column 1 -sticky ns
        grid rowconfigure    $win 1 -weight 1
        grid columnconfigure $win 0 -weight 1

        $self ConfigurePresenceTags
        $self ConfigureMucTags

        # --- Context menus ---

        # Contact item menu
        install contactmenu using menu $win.contactmenu -tearoff 0
        $contactmenu add command -label "" -state disabled
        $contactmenu add separator
        $contactmenu add command -label "Open Chat" \
            -command [mymethod OnOpenChat]
        $contactmenu add command -label "Start Call" \
            -command [mymethod OnStartCall]
        $contactmenu add separator
        $contactmenu add command -label "Rename..." \
            -command [mymethod OnRenameContact]
        $contactmenu add command -label "Remove" \
            -command [mymethod OnRemoveContact]
        $contactmenu add separator
        $contactmenu add command -label "Refresh avatar" \
            -command [mymethod OnRefreshAvatar]
        $contactmenu add command -label "Copy JID" \
            -command [mymethod OnCopyJid]

        # Bookmark item menu
        install bookmarkmenu using menu $win.bookmarkmenu -tearoff 0
        $bookmarkmenu add command -label "" -state disabled
        $bookmarkmenu add separator
        $bookmarkmenu add command -label "Open chat" \
            -command [mymethod OnOpenChat]
        $bookmarkmenu add checkbutton -label "Join" \
            -variable [myvar bookmarkMember] \
            -command [mymethod OnToggleMembership]
        $bookmarkmenu add command -label "Force join request" \
            -command [mymethod OnForceJoin]
        $bookmarkmenu add separator
        $bookmarkmenu add command -label "Edit..." \
            -command [mymethod OnEditBookmark]
        $bookmarkmenu add command -label "Remove Bookmark" \
            -command [mymethod OnRemoveBookmark]
        $bookmarkmenu add separator
        $bookmarkmenu add command -label "Refresh avatar" \
            -command [mymethod OnRefreshAvatar]
        $bookmarkmenu add command -label "Copy JID" \
            -command [mymethod OnCopyJid]

        # Settings menu (right-click on search entry)
        install settingsmenu using menu $win.settingsmenu -tearoff 0
        $settingsmenu add cascade -label "Sort by" \
            -menu $win.settingsmenu.sort
        menu $win.settingsmenu.sort -tearoff 0
        $win.settingsmenu.sort add radiobutton -label "Recent activity" \
            -variable [myvar sortby] -value "recent" \
            -command [mymethod Render]
        $win.settingsmenu.sort add radiobutton -label "Name" \
            -variable [myvar sortby] -value "name" \
            -command [mymethod Render]
        $settingsmenu add separator
        $settingsmenu add checkbutton -label "Show presence colors" \
            -variable [myvar prescolors] \
            -command [mymethod OnPresenceColorsChanged]
        $settingsmenu add checkbutton -label "Show avatars" \
            -variable [myvar showAvatars] \
            -command [mymethod OnShowAvatarsChanged]
        $settingsmenu add checkbutton -label "Send read receipts" \
            -variable [myvar sendReceipts] \
            -command [mymethod OnSendReceiptsChanged]
        $settingsmenu add separator
        $settingsmenu add command -label "Refresh" \
            -command [mymethod OnRefresh]

        # --- Bindings ---
        bind $treeview <Double-1> [mymethod OnDoubleClick %x %y]
        bind $treeview <Return>   [mymethod OnOpenChat]
        bind $treeview <Button-3> [mymethod OnRightClick %x %y %X %Y]
        bind $searchentry <Button-3> [mymethod OnSettingsRightClick %X %Y]

        # Listen for data changes: one collection, three verbs
        set t $options(-tacky)
        set acc $options(-acc)
        $t listen -tag $win chatlist <Changed> -acc $acc \
            [mymethod Rebuild]
        $t listen -tag $win chatlist <Item> -acc $acc \
            [mymethod OnItem]
        $t listen -tag $win chatlist <Remove> -acc $acc \
            [mymethod OnRemove]

        # Initial load
        $self Rebuild
    }

    destructor {
        catch {$options(-tacky) unlisten $win}
        $self UntrackAvatars {}
    }

    method UntrackAvatars {displayed} {
        dict for {jid _} $trackedAvatars {
            if {![dict exists $displayed $jid]} {
                catch {avatarcache untrack -tag $win/$jid}
                dict unset trackedAvatars $jid
            }
        }
    }

    # -- data ------------------------------------------------------------

    method Rebuild {args} {
        $options(-tacky) chatlist get -acc $options(-acc) \
            -tag $win -command [mymethod OnData]
    }

    method OnData {data} {
        set model $data
        $self Render
    }

    method OnItem {ev} {
        array set opts {-jid "" -item ""}
        array set opts $ev
        set model [$self ModelUpsert $opts(-jid) $opts(-item)]
        $self Render
    }

    method OnRemove {ev} {
        array set opts {-jid ""}
        array set opts $ev
        set model [$self ModelRemove $opts(-jid)]
        $self Render
    }

    # -- rendering -------------------------------------------------------

    # Repaint the whole flat list: filter by the search box, sort, insert.
    # Row ids are the chat JID verbatim.
    method Render {} {
        set sel [$treeview selection]
        $treeview delete [$treeview children {}]
        set displayed {}
        foreach entry [$self VisibleEntries] {
            set jid [dict get $entry jid]
            set tags {}
            if {[dict exists $entry room_state]} {
                set tags muc_[dict get $entry room_state]
            }
            $treeview insert {} end -id $jid \
                -text [$self DisplayText $entry] \
                -image [$self TrackAvatar $jid] -tags $tags
            dict set displayed $jid 1
        }
        $self UntrackAvatars $displayed
        if {[llength $sel] && [$treeview exists [lindex $sel 0]]} {
            $treeview selection set [lindex $sel 0]
        }
    }

    method VisibleEntries {} {
        set out {}
        foreach entry $model {
            if {[$self MatchesQueryLocal [dict get $entry jid] \
                    [dict get $entry name]]} {
                lappend out $entry
            }
        }
        return [lsort -command [mymethod CmpEntries] $out]
    }

    method MatchesQueryLocal {jid name} {
        if {$searchquery eq ""} { return 1 }
        set q [string tolower $searchquery]
        if {[string first $q [string tolower $jid]] >= 0} { return 1 }
        if {[string first $q [string tolower $name]] >= 0} { return 1 }
        return 0
    }

    # Recent activity (newest first) by default, name as tiebreak; name-only
    # when the user picks "Name".
    method CmpEntries {a b} {
        if {$sortby ne "name"} {
            set ta [dict get $a last_activity]
            set tb [dict get $b last_activity]
            # Newest first. Return the sign, not the raw microsecond
            # difference, which overflows lsort's integer compare.
            if {$ta > $tb} { return -1 }
            if {$ta < $tb} { return 1 }
        }
        string compare -nocase [$self SortName $a] [$self SortName $b]
    }

    method SortName {entry} {
        set n [dict get $entry name]
        if {$n eq ""} { set n [dict get $entry jid] }
        return $n
    }

    # -- model helpers ---------------------------------------------------

    method ModelItem {jid} {
        foreach item $model {
            if {[dict get $item jid] eq $jid} { return $item }
        }
        return {}
    }

    method ModelRemove {jid} {
        set items {}
        foreach item $model {
            if {[dict get $item jid] ne $jid} { lappend items $item }
        }
        return $items
    }

    method ModelUpsert {jid entry} {
        set items {}
        set replaced 0
        foreach item $model {
            if {[dict get $item jid] eq $jid} {
                lappend items $entry
                set replaced 1
            } else {
                lappend items $item
            }
        }
        if {!$replaced} { lappend items $entry }
        return $items
    }

    # -- presence / muc row styling -------------------------------------

    method ConfigurePresenceTags {} {
        if {$prescolors} {
            $treeview tag configure available -foreground green4
            $treeview tag configure away      -foreground goldenrod3
            $treeview tag configure xa        -foreground darkorange3
            $treeview tag configure dnd       -foreground red3
            $treeview tag configure offline   -foreground gray50
        } else {
            foreach tag {available away xa dnd offline} {
                $treeview tag configure $tag -foreground ""
            }
        }
    }

    method ConfigureMucTags {} {
        if {[lsearch -exact [font names] ChatlistMucItalic] < 0} {
            font create ChatlistMucItalic {*}[font actual TkDefaultFont]
            font configure ChatlistMucItalic -slant italic
        }
        foreach {state opts} $mucStateStyle {
            $treeview tag configure muc_$state {*}$opts
        }
    }

    method MucErrorText {condition} {
        switch -- $condition {
            not-authorized          { return "Password required or incorrect" }
            forbidden               { return "You are banned from this room" }
            registration-required   { return "Membership required to join" }
            conflict                { return "Nickname already in use" }
            service-unavailable     { return "Room is full" }
            item-not-found          { return "Room does not exist" }
            remote-server-not-found -
            remote-server-timeout   { return "Room server unreachable" }
            jid-malformed           { return "Invalid nickname" }
            gone                    { return "Room no longer exists" }
            default                 { return "Could not join room" }
        }
    }

    method OnPresenceColorsChanged {} {
        ::tacky setting set -key show_presence_colors -value $prescolors
        $self ConfigurePresenceTags
    }

    method OnPresenceColorsSetting {ev} {
        set val [dict get $ev -value]
        if {$val ne ""} {
            set prescolors $val
            $self ConfigurePresenceTags
        }
    }

    method OnShowAvatarsChanged {} {
        ::tacky setting set -key show_avatars -value $showAvatars
        $self Render
    }

    method OnSendReceiptsChanged {} {
        ::tacky setting set -key send_chat_markers -value $sendReceipts
    }

    method OnSendReceiptsSetting {ev} {
        set val [dict get $ev -value]
        if {$val ne ""} {
            set sendReceipts $val
        }
    }

    method OnShowAvatarsSetting {ev} {
        set val [dict get $ev -value]
        if {$val ne ""} {
            set showAvatars $val
            if {[winfo exists $treeview]} {
                $self Render
            }
        }
    }

    # -- interaction -----------------------------------------------------

    method OnDoubleClick {x y} {
        set item [$treeview identify item $x $y]
        if {[$self IsRow $item]} {
            $self ActivateItem $item
        }
    }

    method OnOpenChat {} {
        set item [$treeview selection]
        if {$item ne "" && [$self IsRow $item]} {
            $self ActivateItem $item
        }
    }

    method OnNewChat {} {
        if {$options(-new-chat-command) ne ""} {
            {*}$options(-new-chat-command)
        }
    }

    method OnStartCall {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        $options(-tacky) calls start -acc $options(-acc) \
            -to [jid bare $jid]
    }

    method OnRightClick {x y X Y} {
        set item [$treeview identify item $x $y]
        if {![$self IsRow $item]} return
        $treeview selection set $item
        set jid [$self ItemJid $item]

        # groupchat selects the menu: rooms get the bookmark menu, 1:1 and
        # free chats get the contact menu.
        if {[dict get [$self ModelItem $jid] groupchat]} {
            $options(-tacky) bookmarks autojoin \
                -acc $options(-acc) -jid $jid \
                -tag $win -command [mymethod OnAutojoinResult $X $Y]
        } else {
            $contactmenu entryconfigure 0 -label [string range $jid 0 39]
            tk_popup $contactmenu $X $Y
        }
    }

    method OnAutojoinResult {X Y value} {
        set bookmarkMember $value
        set jid [$self SelectedLeafJid]
        $bookmarkmenu entryconfigure 0 -label [string range $jid 0 39]
        $self UpdateBookmarkStatusLine $jid
        tk_popup $bookmarkmenu $X $Y
    }

    # User-facing copy for a room's state, shown as a disabled status line in
    # the bookmark menu.  Empty string = no line for this state.
    method BookmarkStatusLabel {jid} {
        set item [$self ModelItem $jid]
        set state idle
        if {$item ne "" && [dict exists $item room_state]} {
            set state [dict get $item room_state]
        }
        switch -- $state {
            error {
                set reason [dict get $item room_reason]
                return "Join failed: [$self MucErrorText $reason]"
            }
            joining      { return "Joining..." }
            disconnected { return "Not connected" }
            default      { return "" }
        }
    }

    # Show, update, or hide the status line at index 1, just under the jid
    # label (index 0).  Presence is read from the menu itself - index 1 is
    # either our inserted command or the original separator - so there is no
    # shadow flag to keep in sync.
    method UpdateBookmarkStatusLine {jid} {
        set label [$self BookmarkStatusLabel $jid]
        set present [expr {[$bookmarkmenu type 1] eq "command"}]
        if {$label ne ""} {
            if {$present} {
                $bookmarkmenu entryconfigure 1 -label $label
            } else {
                $bookmarkmenu insert 1 command -state disabled -label $label
            }
        } elseif {$present} {
            $bookmarkmenu delete 1
        }
    }

    method OnCopyJid {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        clipboard clear
        clipboard append $jid
    }

    method OnRefreshAvatar {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        $options(-tacky) avatar refresh -acc $options(-acc) -jid [jid bare $jid]
    }

    method OnSettingsRightClick {X Y} {
        tk_popup $settingsmenu $X $Y
    }

    method OnRefresh {} {
        $self Rebuild
        $options(-tacky) roster request -acc $options(-acc)
        $options(-tacky) bookmarks request -acc $options(-acc)
    }

    # Returns the JID of the selected leaf item, or "" if none.
    method SelectedLeafJid {} {
        set item [$treeview selection]
        if {$item eq "" || ![$self IsRow $item]} { return "" }
        return [$self ItemJid $item]
    }

    method OnRenameContact {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        set item [$treeview selection]
        set currentName [$treeview item $item -text]

        set new [InputDialog .rename_dlg \
            -title "Rename $jid" \
            -prompt "New name for $jid:" \
            -value $currentName]
        if {$new ne "" && $new ne $currentName} {
            $options(-tacky) roster item \
                -acc $options(-acc) -jid $jid -name $new
        }
    }

    method OnRemoveContact {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return

        if {[tk_messageBox -type yesno -icon question \
                -parent [winfo toplevel $win] \
                -message "Remove $jid from roster?"] eq "yes"} {
            $options(-tacky) roster remove \
                -acc $options(-acc) -jid $jid
        }
    }

    # The "Join" tick is the room's membership: ticking joins the room and
    # remembers it (autojoin=1); unticking leaves the room and forgets it.
    method OnToggleMembership {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        if {$bookmarkMember} {
            $options(-tacky) bookmarks item \
                -acc $options(-acc) -jid $jid -autojoin 1
        } else {
            $options(-tacky) bookmarks leave \
                -acc $options(-acc) -jid $jid
        }
    }

    # Re-send a join request without changing membership - for re-attempting
    # a room that was dropped (e.g. an IRC gateway disconnect).
    method OnForceJoin {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        $options(-tacky) bookmarks forceJoin \
            -acc $options(-acc) -jid $jid
    }

    method OnEditBookmark {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        set item [$treeview selection]
        set currentName [$treeview item $item -text]

        set new [InputDialog .bm_edit_dlg \
            -title "Edit $jid" \
            -prompt "Bookmark name for $jid:" \
            -value $currentName]
        if {$new ne "" && $new ne $currentName} {
            $options(-tacky) bookmarks item \
                -acc $options(-acc) -jid $jid -name $new
        }
    }

    method OnRemoveBookmark {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return

        if {[tk_messageBox -type yesno -icon question \
                -parent [winfo toplevel $win] \
                -message "Remove bookmark $jid?"] eq "yes"} {
            $options(-tacky) bookmarks remove \
                -acc $options(-acc) -jid $jid
        }
    }

    # -- avatars ---------------------------------------------------------

    method TrackAvatar {jid} {
        if {!$showAvatars} {
            return ""
        }
        if {[dict exists $trackedAvatars $jid]} {
            return [dict get $trackedAvatars $jid]
        }
        set img [avatarcache track \
            -acc $options(-acc) -jid $jid -tag $win/$jid \
            -command [mymethod OnAvatar $jid]]
        dict set trackedAvatars $jid $img
        return $img
    }

    method OnAvatar {jid img} {
        # Keep cache in sync - avatarcache deletes the old Tk image when
        # a real avatar arrives, so the handle in trackedAvatars would be
        # stale.
        dict set trackedAvatars $jid $img
        # Row ids are the chat JID verbatim.
        if {[$treeview exists $jid]} {
            $treeview item $jid -image $img
        }
    }

    # -- item id helpers -------------------------------------------------

    method DisplayText {item} {
        set name [dict get $item name]
        if {$name ne ""} { return $name }
        return [dict get $item jid]
    }

    method IsRow {item} {
        expr {$item ne "" && [$treeview exists $item]}
    }

    # Row ids are the chat JID verbatim.
    method ItemJid {item} {
        return $item
    }

    method ActivateItem {item} {
        # jid is an opaque chat identity; pass it back verbatim to open the chat.
        if {$options(-open-chat-command) ne ""} {
            {*}$options(-open-chat-command) \
                -acc $options(-acc) -jid [$self ItemJid $item]
        }
    }
}

# Simple text input dialog. Returns the entered string, or "" if cancelled.
#   InputDialog .dlg -title "Title" -prompt "Label:" -value "default"
proc InputDialog {w args} {
    array set opts {-title "Input" -prompt "Value:" -value ""}
    array set opts $args

    # Use per-dialog variables to avoid conflicts if re-entered
    set resultVar ::_inputdlg_result($w)
    set doneVar ::_inputdlg_done($w)

    catch {destroy $w}
    toplevel $w
    wm title $w $opts(-title)
    wm resizable $w 0 0
    wm protocol $w WM_DELETE_WINDOW [list set $doneVar 0]

    set $resultVar $opts(-value)
    set $doneVar ""

    ttk::label $w.l -text $opts(-prompt)
    ttk::entry $w.e -textvariable $resultVar -width 30
    ttk::frame $w.btns
    ttk::button $w.btns.ok -text OK -command [list set $doneVar 1]
    ttk::button $w.btns.cancel -text Cancel -command [list set $doneVar 0]

    pack $w.l -padx 10 -pady {10 0} -anchor w
    pack $w.e -padx 10 -pady 5 -fill x
    pack $w.btns -pady {0 10}
    pack $w.btns.ok $w.btns.cancel -side left -padx 5

    $w.e selection range 0 end
    focus $w.e
    bind $w.e <Return> [list set $doneVar 1]
    bind $w <Escape> [list set $doneVar 0]

    try {
        grab set $w
        vwait $doneVar
    } finally {
        catch {grab release $w}
    }
    set done [set $doneVar]
    set result [set $resultVar]
    destroy $w
    unset $resultVar $doneVar
    if {$done} { return $result }
    return ""
}
