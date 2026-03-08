# chatpanel — wraps chatview + messageentry + optional mucparticipantlist sidebar.
#
# For MUC rooms (detected via jid query), a "Participants" checkbutton is
# added to the Chat menu. Toggling it shows/hides a participant list as
# a right pane in a horizontal panedwindow.
#
# Usage:
#   chatpanel $f.cp -acc $acc -jid $contactJid -menubar .menubar
#   pack $f.cp -expand yes -fill both

snit::widget chatpanel {
    hulltype ttk::frame

    option -acc -readonly yes
    option -jid -readonly yes
    option -menubar -default ""

    variable cv
    variable entry
    variable paned
    variable leftFrame
    variable isMuc
    variable roomJid ""
    variable showParticipants 0
    variable mucList ""

    constructor args {
	$self configurelist $args

	set isMuc [expr {[jid query $options(-jid)] eq "join"}]
	if {$isMuc} {
	    set roomJid [jid bare $options(-jid)]
	}

	set paned [ttk::panedwindow $win.paned -orient horizontal]
	set leftFrame [ttk::frame $paned.left]

	set cv [chatview $leftFrame.cv \
	    -acc $options(-acc) -jid $options(-jid)]
	set entry [messageentry $leftFrame.entry \
	    -send-command [mymethod Send] \
	    -request-voice-command [mymethod RequestVoice]]
	pack $cv -expand yes -fill both
	pack $entry -fill x

	$paned add $leftFrame -weight 1
	pack $paned -expand yes -fill both

	if {$options(-menubar) ne ""} {
	    $self InstallMenus
	}

	set showParticipants [$self SettingGet show_participants 0]
	if {$isMuc && $showParticipants} {
	    $self ShowParticipants
	}

	if {$isMuc} {
	    ::tacky listen -tag $win muc <RoomCreated> \
		-acc $options(-acc) [mymethod OnMucRoomCreated]
	}
    }

    destructor {
	::tacky unlisten $win
	$self RemoveMenus
	$self DestroyParticipants
    }

    method SettingGet {key default} {
	set result [::tacky setting get -key $key]
	set val [dict get $result -value]
	if {$val eq ""} { return $default }
	return $val
    }

    method Send {text} {
	if {$isMuc} {
	    ::tacky muc say -acc $options(-acc) -jid $roomJid -body $text
	}
	# TODO: 1:1 chat send
    }

    method InstallMenus {} {
	set mb $options(-menubar)
	menu $mb.chat -tearoff 0
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
	$mb.chat add separator
	$mb.chat add command -label "Invite User..." \
	    -command [mymethod InviteUser]
	$mb.chat add command -label "Change Nickname..." \
	    -command [mymethod ChangeNickname]

	# Permission-gated items
	set nick [::tacky muc myNick -acc $options(-acc) -jid $roomJid]
	if {$nick ne ""} {
	    set occ [::tacky muc occupant -acc $options(-acc) -jid $roomJid -nick $nick]
	    if {$occ ne ""} {
		set role [dict get $occ role]
		set affil [dict get $occ affiliation]

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
	::tacky setting set -key show_participants -value $showParticipants
    }

    method ShowParticipants {} {
	if {$mucList ne ""} return
	set mucList [mucparticipantlist $paned.plist \
	    -acc $options(-acc) -jid $roomJid]
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
    }

    method OnMucRoomCreated {ev} {
	if {[dict get $ev -jid] ne $roomJid} return
	set answer [tk_messageBox -type yesno -icon question \
	    -title "New Room Created" \
	    -message "You created a new room. Configure it now?\n\nChoose No to accept default settings."]
	if {$answer eq "yes"} {
	    # TODO: room config UI
	} else {
	    ::tacky muc createInstant -acc $options(-acc) -jid $roomJid
	}
    }

    method InviteUser {} {
	set jid [InputDialog .muc_invite_dlg \
	    -title "Invite User" -prompt "JID to invite:"]
	if {$jid eq ""} return
	set reason [InputDialog .muc_invite_reason_dlg \
	    -title "Invite User" -prompt "Reason (optional):"]
	set args [list -acc $options(-acc) -jid $roomJid -to $jid]
	if {$reason ne ""} {
	    lappend args -reason $reason
	}
	::tacky muc invite {*}$args
    }

    method ChangeNickname {} {
	set myNick [::tacky muc myNick -acc $options(-acc) -jid $roomJid]
	set newNick [InputDialog .muc_nick_dlg \
	    -title "Change Nickname" -prompt "New nickname:" \
	    -value $myNick]
	if {$newNick eq "" || $newNick eq $myNick} return
	::tacky bookmarks nick -acc $options(-acc) -jid $roomJid -nick $newNick
    }

    method RequestVoice {} {
	::tacky muc requestVoice -acc $options(-acc) -jid $roomJid
    }

    method DestroyRoom {} {
	set answer [tk_messageBox -type yesno -icon warning \
	    -title "Destroy Room" \
	    -message "Are you sure you want to permanently destroy this room?\n\n$roomJid"]
	if {$answer ne "yes"} return
	::tacky muc destroyRoom -acc $options(-acc) -jid $roomJid
    }

    method LeaveRoom {} {
	::tacky bookmarks leave -acc $options(-acc) -jid $roomJid
    }

    method LeaveRoomKeepBookmark {} {
	::tacky muc leave -acc $options(-acc) -jid $roomJid
    }
}
