if 0 {
    Usage:
        chatlistview .clv -acc juliet@capulet.li
}

snit::widget chatlistview {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -open-chat-command -default ""
    option -new-chat-command -default ""

    component rows
    component searchentry
    component contactmenu
    component bookmarkmenu
    component settingsmenu

    variable searchquery ""
    variable sortby "recent"
    variable showAvatars 1
    variable bookmarkMember 0
    variable trackedAvatars {}
    # jid -> chat entry (chatlist get shape), patched by <Item>/<Remove>
    variable model {}

    # Name style per backend room_state enum (taco_bookmarks RoomState).  Tags
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

        install rows using chatrows $win.rows \
            -activate-command [mymethod ActivateItem] \
            -menu-command [mymethod OnRowMenu]

        grid $win.header -row 0 -column 0 -sticky ew -padx 2 -pady 2
        grid $rows       -row 1 -column 0 -sticky nsew
        grid rowconfigure    $win 1 -weight 1
        grid columnconfigure $win 0 -weight 1

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
        settingmenu::checkbutton $settingsmenu "Show avatars" \
            -var [myvar showAvatars] -key show_avatars \
            -tag $win -tacky $options(-tacky) \
            -onchange [mymethod Render]
        $settingsmenu add separator
        $settingsmenu add command -label "Refresh" \
            -command [mymethod OnRefresh]

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

    # `chatlist get` answers with a flat list; key it on the way in.
    method OnData {data} {
        set model [dict create]
        foreach entry $data {
            dict set model [dict get $entry jid] $entry
        }
        $self Render
    }

    method OnItem {ev} {
        dict set model [dict get $ev -jid] [dict get $ev -item]
        $self Render
    }

    method OnRemove {ev} {
        dict unset model [dict get $ev -jid]
        $self Render
    }

    # -- rendering -------------------------------------------------------

    # Repaint the whole flat list: filter by the search box, sort, draw.
    # Row keys are the chat JID verbatim.
    method Render {} {
        set displayed {}
        set drawn {}
        foreach entry [$self VisibleEntries] {
            set jid [dict get $entry jid]
            lappend drawn [$self RowFor $entry]
            dict set displayed $jid 1
        }
        $rows set $drawn
        $self UntrackAvatars $displayed
    }

    method RowFor {entry} {
        set jid [dict get $entry jid]
        set name [dict get $entry name]
        if {$name eq ""} { set name $jid }
        set tags {}
        if {[dict exists $entry room_state]} {
            lappend tags muc_[dict get $entry room_state]
        }
        return [dict create key $jid name $name \
            preview [$self PreviewText $entry] \
            unread [dict getdef $entry unread 0] \
            mention [expr {[dict getdef $entry unread_mentions 0] > 0}] \
            time [dict getdef $entry last_activity 0] \
            image [$self TrackAvatar $jid] tags $tags]
    }

    method VisibleEntries {} {
        set out {}
        dict for {jid entry} $model {
            if {[$self MatchesQueryLocal $jid [dict get $entry name]]} {
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

    # The entry for a chat, or "" when we don't hold one.
    method ModelItem {jid} {
        return [dict getdef $model $jid {}]
    }

    method ConfigureMucTags {} {
        if {[lsearch -exact [font names] ChatlistMucItalic] < 0} {
            # Slanted from the row's name font, so it stays bold.
            font create ChatlistMucItalic {*}[font actual ChatrowsName]
            font configure ChatlistMucItalic -slant italic
        }
        foreach {state opts} $mucStateStyle {
            $rows tag configure muc_$state {*}$opts
        }
    }

    # -- interaction -----------------------------------------------------

    method OnOpenChat {} {
        set jid [$self SelectedLeafJid]
        if {$jid ne ""} { $self ActivateItem $jid }
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

    method OnRowMenu {jid X Y} {
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
                return "Join failed: [dict get $item room_reason]"
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

    # The selected chat JID, or "" if none.
    method SelectedLeafJid {} {
        return [$rows selected]
    }

    method OnRenameContact {} {
        set jid [$self SelectedLeafJid]
        if {$jid eq ""} return
        # The row text also carries the unread count and preview.
        set currentName [dict getdef [$self ModelItem $jid] name ""]

        set new [input_dialog .rename_dlg -parent $win \
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
        set currentName [dict getdef [$self ModelItem $jid] name ""]

        set new [input_dialog .bm_edit_dlg -parent $win \
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
        $rows image $jid $img
    }

    # -- rows ------------------------------------------------------------

    method PreviewText {item} {
        if {![dict exists $item last_message]} { return "" }
        return [message_preview [dict get $item last_message] \
            [dict getdef $item groupchat 0]]
    }

    method ActivateItem {jid} {
        # jid is an opaque chat identity; pass it back verbatim to open the chat.
        if {$options(-open-chat-command) ne ""} {
            set gc [dict getdef [$self ModelItem $jid] groupchat 0]
            {*}$options(-open-chat-command) \
                -acc $options(-acc) -jid $jid -groupchat $gc
        }
    }
}
