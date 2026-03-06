# chatpanel — wraps chatview + messageentry + optional mucparticipantlist sidebar.
#
# For MUC rooms (detected via jid query), a "Participants" checkbutton is
# added to the Chat menu. Toggling it shows/hides a participant list as
# a right pane in a horizontal panedwindow.
#
# Usage:
#   chatpanel $f.cp -client $client -jid $contactJid -menubar .menubar
#   pack $f.cp -expand yes -fill both

snit::widget chatpanel {
    hulltype ttk::frame

    option -client -readonly yes
    option -jid -readonly yes
    option -menubar -default ""

    variable cv
    variable ctrl
    variable entry
    variable searchbar
    variable datebar
    variable paned
    variable leftFrame
    variable isMuc
    variable roomJid ""
    variable showParticipants 0
    variable showJoinLeave 0
    variable mucCtrl ""
    variable mucList ""
    variable mucEventCtrl ""

    constructor args {
	$self configurelist $args

	set isMuc [expr {[jid query $options(-jid)] eq "join"}]
	if {$isMuc} {
	    set roomJid [jid bare $options(-jid)]
	}

	set paned [ttk::panedwindow $win.paned -orient horizontal]
	set leftFrame [ttk::frame $paned.left]

	set cv [chatview $leftFrame.cv \
	    -client $options(-client) -jid $options(-jid)]
	set ctrl [$cv controller]
	set entry [messageentry $leftFrame.entry \
	    -send-command [list $ctrl send] \
	    -request-voice-command [mymethod RequestVoice]]
	set searchbar [searchbar $leftFrame.search \
	    -search-command [mymethod OnSearch] \
	    -next-command   [list $ctrl search next] \
	    -prev-command   [list $ctrl search prev] \
	    -close-command  [mymethod HideSearch]]
	set datebar [datebar $leftFrame.datebar \
	    -goto-command  [mymethod OnGotoDate] \
	    -close-command [mymethod HideDatebar]]
	pack $cv -expand yes -fill both
	pack $entry -fill x

	$ctrl cell bind <SearchState> $self [mymethod OnSearchState]
	bind $win <Control-f> [mymethod ShowSearch]
	bind $win <Control-g> [mymethod ShowDatebar]

	$paned add $leftFrame -weight 1
	pack $paned -expand yes -fill both

	if {$options(-menubar) ne ""} {
	    $self InstallMenus
	}

	set showParticipants [::tacky setting get show_participants 0]
	set showJoinLeave [::tacky setting get show_join_leave 0]
	if {$isMuc && $showParticipants} {
	    $self ShowParticipants
	}

	if {$isMuc} {
	    $self CreateEventCtrl
	}
    }

    destructor {
	catch {$ctrl cell unbind <SearchState> $self}
	$self RemoveMenus
	$self DestroyParticipants
	$self DestroyEventCtrl
    }

    method InstallMenus {} {
	set mb $options(-menubar)
	menu $mb.chat -tearoff 0
	$mb.chat add command -label "Find..." -accelerator "Ctrl+F" \
	    -command [mymethod ShowSearch]
	$mb.chat add command -label "Go to date..." -accelerator "Ctrl+G" \
	    -command [mymethod ShowDatebar]
	if {$isMuc} {
	    $self RebuildMucMenu
	}
	$mb add cascade -label "Chat" -menu $mb.chat
    }

    method RebuildMucMenu {} {
	set mb $options(-menubar)
	$mb.chat delete 0 end

	# Always-visible items
	$mb.chat add checkbutton -label "Participants" \
	    -variable [myvar showParticipants] \
	    -command [mymethod ToggleParticipants]
	$mb.chat add checkbutton -label "Show Join/Leave" \
	    -variable [myvar showJoinLeave] \
	    -command [mymethod ToggleJoinLeave]
	$mb.chat add command -label "Room Topic..." \
	    -command [mymethod OpenRoomTopic]
	$mb.chat add separator
	$mb.chat add command -label "Invite User..." \
	    -command [mymethod InviteUser]
	$mb.chat add command -label "Change Nickname..." \
	    -command [mymethod ChangeNickname]

	# Permission-gated items
	set nick [$options(-client) muc myNick $roomJid]
	if {$nick ne ""} {
	    set occ [$options(-client) muc occupant $roomJid $nick]
	    if {$occ ne ""} {
		set role [dict get $occ role]
		set affil [dict get $occ affiliation]

		if {$affil eq "owner" || $affil eq "admin"} {
		    $mb.chat add separator
		    $mb.chat add command -label "Room Settings..." \
			-command [mymethod OpenRoomConfig]
		}
		if {$role eq "visitor"} {
		    $mb.chat add separator
		    $mb.chat add command -label "Request Voice" \
			-command [mymethod RequestVoice]
		}
		if {$affil eq "owner"} {
		    $mb.chat add separator
		    $mb.chat add command -label "Destroy Room..." \
			-command [mymethod DestroyRoom]
		}
	    }
	}

	# Always last
	$mb.chat add separator
	$mb.chat add command -label "Leave Room" \
	    -command [mymethod LeaveRoom]
	$mb.chat add command -label "Leave Room (Keep Bookmark)" \
	    -command [mymethod LeaveRoomKeepBookmark]
    }

    method RemoveMenus {} {
	set mb $options(-menubar)
	if {$mb eq "" || ![winfo exists $mb]} return
	set last [$mb index end]
	if {$last ne "none"} {
	    for {set i $last} {$i >= 0} {incr i -1} {
		if {[$mb type $i] eq "cascade" && [$mb entrycget $i -label] eq "Chat"} {
		    $mb delete $i
		    break
		}
	    }
	}
	if {[winfo exists $mb.chat]} {
	    destroy $mb.chat
	}
    }

    method ToggleParticipants {} {
	if {$showParticipants} {
	    $self ShowParticipants
	} else {
	    $self HideParticipants
	}
	::tacky setting set show_participants $showParticipants
    }

    method ToggleJoinLeave {} {
	if {$mucEventCtrl ne ""} {
	    $mucEventCtrl configure -show-join-leave $showJoinLeave
	}
	::tacky setting set show_join_leave $showJoinLeave
    }

    method ShowParticipants {} {
	if {$mucList ne ""} return
	set mucCtrl [mucparticipantctrl $win.mucctrl \
	    -client $options(-client) -jid $roomJid]
	set mucList [mucparticipantlist $paned.plist \
	    -controller $mucCtrl \
	    -client $options(-client) -jid $roomJid]
	$paned add $mucList -weight 0
    }

    method HideParticipants {} {
	$self DestroyParticipants
    }

    method DestroyParticipants {} {
	if {$mucList ne ""} {
	    catch {destroy $mucList}
	    set mucList ""
	}
	if {$mucCtrl ne ""} {
	    catch {$mucCtrl destroy}
	    set mucCtrl ""
	}
    }

    method ShowSearch {} {
	if {$searchbar in [pack slaves $leftFrame]} return
	$self HideDatebar
	pack $searchbar -fill x -before $cv
	$searchbar focus
    }

    method HideSearch {} {
	pack forget $searchbar
	$ctrl search clear
    }

    method ShowDatebar {} {
	if {$datebar in [pack slaves $leftFrame]} return
	$self HideSearch
	pack $datebar -fill x -before $cv
	$datebar focus
    }

    method HideDatebar {} {
	pack forget $datebar
    }

    method OnGotoDate {iso} {
	$ctrl search start -start $iso
	$self HideDatebar
    }

    method OnSearch {text local} {
	set args [list -fulltext $text]
	if {$local} { lappend args -local 1 }
	$ctrl search start {*}$args
    }

    method OnSearchState {stateDict} {
	if {$searchbar in [pack slaves $leftFrame]} {
	    $searchbar updateState $stateDict
	}
    }

    method CreateEventCtrl {} {
	set mucEventCtrl [muceventctrl $win.evtctrl \
	    -client $options(-client) -jid $roomJid \
	    -show-join-leave $showJoinLeave]
	$mucEventCtrl cell bind <SystemMessage> $self \
	    [mymethod OnSystemMessage]
	$mucEventCtrl cell bind <MyRoleChanged> $self \
	    [mymethod OnMyRoleChanged]
	# Bind MucRoomCreated to prompt for configuration
	$options(-client) muc cell bind <MucRoomCreated> $self \
	    [mymethod OnMucRoomCreated]
	# Set initial voice state from controller
	set r [$mucEventCtrl myRole]
	if {$r ne ""} {
	    if {$r eq "visitor"} {
		$entry setVoiceState visitor
	    } else {
		$entry setVoiceState normal
	    }
	}
    }

    method DestroyEventCtrl {} {
	catch {$options(-client) muc cell unbind <MucRoomCreated> $self}
	if {$mucEventCtrl ne ""} {
	    catch {$mucEventCtrl cell unbind <SystemMessage> $self}
	    catch {$mucEventCtrl cell unbind <MyRoleChanged> $self}
	    catch {$mucEventCtrl destroy}
	    set mucEventCtrl ""
	}
    }

    method OnSystemMessage {ev} {
	$cv system insert [dict get $ev text]
    }

    method OnMucRoomCreated {ev} {
	if {[dict get $ev room] ne $roomJid} return
	set answer [tk_messageBox -type yesno -icon question \
	    -title "New Room Created" \
	    -message "You created a new room. Configure it now?\n\nChoose No to accept default settings."]
	if {$answer eq "yes"} {
	    $self OpenRoomConfig
	} else {
	    $options(-client) muc createInstant $roomJid
	}
    }

    method OnMyRoleChanged {ev} {
	if {$options(-menubar) ne "" && [winfo exists $options(-menubar)]} {
	    $self RebuildMucMenu
	}
	if {[dict get $ev role] eq "visitor"} {
	    $entry setVoiceState visitor
	} else {
	    $entry setVoiceState normal
	}
    }

    method OpenRoomTopic {} {
	muctopicview show $options(-client) $roomJid
    }

    method OpenRoomConfig {} {
	mucroomconfig show $options(-client) $roomJid
    }

    method InviteUser {} {
	set jid [InputDialog .muc_invite_dlg \
	    -title "Invite User" -prompt "JID to invite:"]
	if {$jid eq ""} return
	set reason [InputDialog .muc_invite_reason_dlg \
	    -title "Invite User" -prompt "Reason (optional):"]
	set args [list $roomJid $jid]
	if {$reason ne ""} {
	    lappend args -reason $reason
	}
	$options(-client) muc invite {*}$args
    }

    method ChangeNickname {} {
	set myNick [$options(-client) muc myNick $roomJid]
	set newNick [InputDialog .muc_nick_dlg \
	    -title "Change Nickname" -prompt "New nickname:" \
	    -value $myNick]
	if {$newNick eq "" || $newNick eq $myNick} return
	$options(-client) bookmarks nick $roomJid $newNick
    }

    method RequestVoice {} {
	$options(-client) muc requestVoice $roomJid
    }

    method DestroyRoom {} {
	set answer [tk_messageBox -type yesno -icon warning \
	    -title "Destroy Room" \
	    -message "Are you sure you want to permanently destroy this room?\n\n$roomJid"]
	if {$answer ne "yes"} return
	$options(-client) muc destroyRoom $roomJid
    }

    method LeaveRoom {} {
	$options(-client) bookmarks leave $roomJid
    }

    method LeaveRoomKeepBookmark {} {
	$options(-client) muc leave $roomJid
    }
}
