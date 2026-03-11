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
    option -open-bookmark-command -default ""
    option -menubar -default "" -readonly yes

    component treeview
    component searchentry
    component contactmenu
    component bookmarkmenu
    component rosterrootmenu
    component bookmarkrootmenu
    component settingsmenu

    variable searchquery ""
    variable sortby "name"
    variable grouping 0
    variable prescolors 1
    variable showAvatars 1
    variable bookmarkAutojoin 0
    variable trackedAvatars {}
    variable rosterItems {}
    variable bookmarkItems {}
    variable bookmarkJids {}
    variable recentJids {}

    constructor args {
	$self configurelist $args

	if {$options(-acc) eq ""} {
	    error "chatlistview requires -acc"
	}

	::tacky setting get -key show_presence_colors \
	    -command [mymethod OnPresenceColorsSetting]
	::tacky setting get -key show_avatars \
	    -command [mymethod OnShowAvatarsSetting]

	# Search entry
	install searchentry using ttk::entry $win.search \
	    -textvariable [myvar searchquery]
	bind $searchentry <KeyRelease> [mymethod RebuildAll]

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
	grid $searchentry -row 0 -column 0 -columnspan 2 -sticky ew \
	    -padx 2 -pady 2
	grid $treeview    -row 1 -column 0 -sticky nsew
	grid $win.scroll  -row 1 -column 1 -sticky ns
	grid rowconfigure    $win 1 -weight 1
	grid columnconfigure $win 0 -weight 1

	# Root items
	$treeview insert {} end -id RecentChats -text "Recent Chats" -open 1
	$treeview insert {} end -id Roster    -text "Contacts"   -open 1
	$treeview insert {} end -id Bookmarks -text "Bookmarks"  -open 1

	$self ConfigurePresenceTags

	# --- Context menus ---

	# Contact item menu
	install contactmenu using menu $win.contactmenu -tearoff 0
	$contactmenu add command -label "Open Chat" \
	    -command [mymethod OnOpenChat]
	$contactmenu add separator
	$contactmenu add command -label "Rename..." \
	    -command [mymethod OnRenameContact]
	$contactmenu add command -label "Remove" \
	    -command [mymethod OnRemoveContact]

	# Bookmark item menu
	install bookmarkmenu using menu $win.bookmarkmenu -tearoff 0
	$bookmarkmenu add command -label "Join Room" \
	    -command [mymethod OnOpenChat]
	$bookmarkmenu add command -label "Leave Room" \
	    -command [mymethod OnLeaveBookmark]
	$bookmarkmenu add separator
	$bookmarkmenu add checkbutton -label "Autojoin" \
	    -variable [myvar bookmarkAutojoin] \
	    -command [mymethod OnToggleAutojoin]
	$bookmarkmenu add command -label "Edit..." \
	    -command [mymethod OnEditBookmark]
	$bookmarkmenu add command -label "Remove Bookmark" \
	    -command [mymethod OnRemoveBookmark]

	# Roster root menu
	install rosterrootmenu using menu $win.rosterrootmenu -tearoff 0
	$rosterrootmenu add command -label "Expand all" \
	    -command [mymethod SetChildrenOpen 1]
	$rosterrootmenu add command -label "Collapse all" \
	    -command [mymethod SetChildrenOpen 0]
	$rosterrootmenu add separator
	$rosterrootmenu add command -label "Refresh" \
	    -command [mymethod OnRefresh]

	# Bookmarks root menu
	install bookmarkrootmenu using menu $win.bookmarkrootmenu -tearoff 0
	$bookmarkrootmenu add command -label "Refresh" \
	    -command [mymethod OnRefresh]

	# Settings menu (right-click on search entry)
	install settingsmenu using menu $win.settingsmenu -tearoff 0
	$settingsmenu add cascade -label "Sort by" \
	    -menu $win.settingsmenu.sort
	menu $win.settingsmenu.sort -tearoff 0
	$win.settingsmenu.sort add radiobutton -label "Name" \
	    -variable [myvar sortby] -value "name" \
	    -command [mymethod RebuildAll]
	$win.settingsmenu.sort add radiobutton -label "JID" \
	    -variable [myvar sortby] -value "jid" \
	    -command [mymethod RebuildAll]
	$settingsmenu add separator
	$settingsmenu add checkbutton -label "Group contacts" \
	    -variable [myvar grouping] \
	    -command [mymethod RebuildAll]
	$settingsmenu add checkbutton -label "Show presence colors" \
	    -variable [myvar prescolors] \
	    -command [mymethod OnPresenceColorsChanged]
	$settingsmenu add checkbutton -label "Show avatars" \
	    -variable [myvar showAvatars] \
	    -command [mymethod OnShowAvatarsChanged]

	# --- Bindings ---
	bind $treeview <Double-1> [mymethod OnDoubleClick %x %y]
	bind $treeview <Return>   [mymethod OnOpenChat]
	bind $treeview <Button-3> [mymethod OnRightClick %x %y %X %Y]
	bind $searchentry <Button-3> [mymethod OnSettingsRightClick %X %Y]

	# Listen for data changes
	set t $options(-tacky)
	set acc $options(-acc)
	$t listen -tag $win roster    <Changed> -acc $acc \
	    [mymethod RebuildAll]
	$t listen -tag $win bookmarks <Changed> -acc $acc \
	    [mymethod RebuildAll]
	$t listen -tag $win setting <Changed> -key show_presence_colors \
	    [mymethod OnPresenceColorsSetting]
	$t listen -tag $win setting <Changed> -key show_avatars \
	    [mymethod OnShowAvatarsSetting]
	$t listen -tag $win chats <Updated> -acc $acc \
	    [mymethod OnChatsUpdated]

	# Populate from cache
	$self RebuildRoster
	$self RebuildBookmarks

	# Load initial top chats
	$options(-tacky) chats latest -acc $options(-acc) \
	    -command [mymethod OnRecentChats]
    }

    destructor {
	catch {$options(-tacky) unlisten $win}
	$self UntrackAllAvatars
    }

    method UntrackAllAvatars {} {
	dict for {jid _img} $trackedAvatars {
	    catch {avatarcache untrack -tag $win/$jid}
	}
	set trackedAvatars {}
    }

    method RebuildRoster {} {
	# Remember which group nodes are open
	set openGroups {}
	foreach child [$treeview children Roster] {
	    if {[$treeview item $child -open]} {
		lappend openGroups $child
	    }
	}

	$options(-tacky) roster get -acc $options(-acc) \
	    -command [mymethod OnRosterData $openGroups]
    }

    method OnRosterData {openGroups items} {
	$treeview delete [$treeview children Roster]
	set items [$self FilterBySearch $items]
	set items [$self SortItems $items]
	set rosterItems $items

	if {$grouping} {
	    $self PopulateGrouped $items
	} else {
	    $self PopulateSection Roster $items
	}

	# Restore open state
	foreach gid $openGroups {
	    if {[$treeview exists $gid]} {
		$treeview item $gid -open 1
	    }
	}

	$self RebuildRecentChats
    }

    method RebuildBookmarks {} {
	$options(-tacky) bookmarks get -acc $options(-acc) \
	    -command [mymethod OnBookmarksData]
    }

    method OnBookmarksData {items} {
	$treeview delete [$treeview children Bookmarks]
	set items [$self FilterBySearch $items]
	set items [$self SortItems $items]
	set bookmarkItems $items
	set bookmarkJids {}
	foreach item $items {
	    dict set bookmarkJids [dict get $item -jid] 1
	}
	$self PopulateSection Bookmarks $items
	$self RebuildRecentChats
    }

    method PopulateSection {parent items} {
	foreach item $items {
	    set jid  [dict get $item -jid]
	    set text [$self DisplayText $item]
	    set img  [$self TrackAvatar $jid]
	    $treeview insert $parent end -id "$parent/$jid" -text $text \
		-image $img
	}
    }

    method PopulateGrouped {items} {
	foreach item $items {
	    set jid    [dict get $item -jid]
	    set text   [$self DisplayText $item]
	    set groups [dict get $item -groups]
	    set img [$self TrackAvatar $jid]

	    if {[llength $groups] == 0} {
		set groups [list "(ungrouped)"]
	    }

	    foreach group $groups {
		set gid "Roster/$group"
		if {![$treeview exists $gid]} {
		    $treeview insert Roster end \
			-id $gid -text $group -open 1
		}
		$treeview insert $gid end \
		    -id "$gid/$jid" -text $text \
		    -image $img
	    }
	}
    }

    method FilterBySearch {items} {
	if {$searchquery eq ""} {
	    return $items
	}
	set q [string tolower $searchquery]
	set result {}
	foreach item $items {
	    set jid  [string tolower [dict get $item -jid]]
	    set name [string tolower [dict get $item -name]]
	    if {[string first $q $jid] >= 0 ||
		[string first $q $name] >= 0} {
		lappend result $item
	    }
	}
	return $result
    }

    method SortItems {items} {
	if {$sortby eq "jid"} {
	    return [lsort -command [mymethod CmpJid] $items]
	}
	return [lsort -command [mymethod CmpName] $items]
    }

    method CmpName {a b} {
	set na [dict get $a -name]
	set nb [dict get $b -name]
	if {$na eq ""} { set na [dict get $a -jid] }
	if {$nb eq ""} { set nb [dict get $b -jid] }
	return [string compare -nocase $na $nb]
    }

    method CmpJid {a b} {
	return [string compare -nocase [dict get $a -jid] [dict get $b -jid]]
    }

    method RebuildAll {args} {
	$self UntrackAllAvatars
	$self RebuildRoster
	$self RebuildBookmarks
    }

    method RebuildRecentChats {} {
	$treeview delete [$treeview children RecentChats]

	# Merge roster + bookmark items into jid→item dict
	set merged [dict create]
	foreach item [concat $rosterItems $bookmarkItems] {
	    set jid [dict get $item -jid]
	    if {![dict exists $merged $jid]} {
		dict set merged $jid $item
	    }
	}

	# Populate in order, cap at 20
	set count 0
	foreach jid $recentJids {
	    if {[dict exists $merged $jid]} {
		set text [$self DisplayText [dict get $merged $jid]]
	    } else {
		set text $jid
	    }
	    set img [$self TrackAvatar $jid]
	    $treeview insert RecentChats end -id "RecentChats/$jid" \
		-text $text -image $img
	    if {[incr count] >= 20} break
	}
    }

    method OnChatsUpdated {ev} {
	set jid [dict get $ev -jid]
	# Move JID to front of the list
	set idx [lsearch -exact $recentJids $jid]
	if {$idx >= 0} {
	    set recentJids [lreplace $recentJids $idx $idx]
	}
	set recentJids [linsert $recentJids 0 $jid]
	$self RebuildRecentChats
    }

    method OnRecentChats {jids} {
	set recentJids $jids
	$self RebuildRecentChats
    }

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
	$self RebuildAll
    }

    method OnShowAvatarsSetting {ev} {
	set val [dict get $ev -value]
	if {$val ne ""} {
	    set showAvatars $val
	    if {[winfo exists $treeview]} {
		$self RebuildAll
	    }
	}
    }

    method OnDoubleClick {x y} {
	set item [$treeview identify item $x $y]
	if {$item ne "" && [$self IsLeaf $item]} {
	    $self ActivateItem $item
	}
    }

    method OnOpenChat {} {
	set item [$treeview selection]
	if {$item ne "" && [$self IsLeaf $item]} {
	    $self ActivateItem $item
	}
    }

    method OnRightClick {x y X Y} {
	set item [$treeview identify item $x $y]
	if {$item eq ""} return
	$treeview selection set $item

	if {$item eq "RecentChats"} {
	    return
	} elseif {$item eq "Roster"} {
	    tk_popup $rosterrootmenu $X $Y
	} elseif {$item eq "Bookmarks"} {
	    tk_popup $bookmarkrootmenu $X $Y
	} elseif {[$self IsLeaf $item]} {
	    set section [$self GetSection $item]
	    if {$section eq "RecentChats"} {
		set jid [$self ItemJid $item]
		set section [expr {[dict exists $bookmarkJids $jid] \
		    ? "Bookmarks" : "Roster"}]
	    }
	    if {$section eq "Bookmarks"} {
		set jid [$self ItemJid $item]
		$options(-tacky) bookmarks autojoin \
		    -acc $options(-acc) -jid $jid \
		    -command [mymethod OnAutojoinResult $X $Y]
	    } else {
		tk_popup $contactmenu $X $Y
	    }
	}
    }

    method OnAutojoinResult {X Y value} {
	set bookmarkAutojoin $value
	tk_popup $bookmarkmenu $X $Y
    }

    method OnSettingsRightClick {X Y} {
	tk_popup $settingsmenu $X $Y
    }

    method SetChildrenOpen {open} {
	foreach child [$treeview children Roster] {
	    $treeview item $child -open $open
	}
    }

    method OnRefresh {} {
	$self RebuildAll
	$options(-tacky) roster request -acc $options(-acc)
	$options(-tacky) bookmarks request -acc $options(-acc)
    }

    # Returns the JID of the selected leaf item, or "" if none.
    method SelectedLeafJid {} {
	set item [$treeview selection]
	if {$item eq "" || ![$self IsLeaf $item]} { return "" }
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
		-message "Remove $jid from roster?"] eq "yes"} {
	    $options(-tacky) roster remove \
		-acc $options(-acc) -jid $jid
	}
    }

    method OnLeaveBookmark {} {
	set jid [$self SelectedLeafJid]
	if {$jid eq ""} return
	$options(-tacky) bookmarks leave \
	    -acc $options(-acc) -jid $jid
    }

    method OnToggleAutojoin {} {
	set jid [$self SelectedLeafJid]
	if {$jid eq ""} return
	$options(-tacky) bookmarks item \
	    -acc $options(-acc) -jid $jid -autojoin $bookmarkAutojoin
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
		-message "Remove bookmark $jid?"] eq "yes"} {
	    $options(-tacky) bookmarks remove \
		-acc $options(-acc) -jid $jid
	}
    }

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
	# Keep cache in sync — avatarcache deletes the old Tk image when
	# a real avatar arrives, so the handle in trackedAvatars would be
	# stale.  RebuildRecentChats reuses cached handles without a full
	# UntrackAllAvatars cycle, so it needs the current image.
	dict set trackedAvatars $jid $img
	foreach item [$self FindItemsByJid $jid] {
	    $treeview item $item -image $img
	}
    }

    method FindItemsByJid {jid} {
	set result {}
	foreach root {RecentChats Roster Bookmarks} {
	    foreach child [$treeview children $root] {
		if {[string match "*/$jid" $child]} {
		    lappend result $child
		} else {
		    # Check grouped children
		    foreach grandchild [$treeview children $child] {
			if {[string match "*/$jid" $grandchild]} {
			    lappend result $grandchild
			}
		    }
		}
	    }
	}
	return $result
    }

    method DisplayText {item} {
	set name [dict get $item -name]
	if {$name ne ""} { return $name }
	return [dict get $item -jid]
    }

    method IsLeaf {item} {
	expr {[$treeview parent $item] ne {} && [$treeview children $item] eq {}}
    }

    # Section is always the first component of the item ID.
    method GetSection {item} {
	lindex [split $item /] 0
    }

    # JID is always the last slash-separated component of the item ID.
    method ItemJid {item} {
	set idx [string last / $item]
	string range $item $idx+1 end
    }

    method ActivateItem {item} {
	set section [$self GetSection $item]
	set jid [$self ItemJid $item]
	if {$section eq "RecentChats"} {
	    set section [expr {[dict exists $bookmarkJids $jid] \
		? "Bookmarks" : "Roster"}]
	}
	set opt [dict get {Roster -open-chat-command \
	    Bookmarks -open-bookmark-command} $section]
	if {$options($opt) ne ""} {
	    {*}$options($opt) -acc $options(-acc) -jid $jid
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
