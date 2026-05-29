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
    variable showJidIn1to1 0
    variable omemoEnabled 1
    variable mucList ""
    variable findBar ""
    variable findMatches {}
    variable findIndex -1
    variable findQuery ""

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
        if {!$isMuc} {
            $self BuildOmemoToggle
        }

        bind $cv <<FindInChat>> [mymethod OpenFind]

        $paned add $leftFrame -weight 1
        pack $paned -expand yes -fill both

        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }

        if {$isMuc} {
            ::tacky observe -tag $win setting <Changed> -key show_participants \
                [mymethod OnShowParticipantsSetting]
            ::tacky listen -tag $win muc <RoomCreated> \
                -acc $options(-acc) [mymethod OnMucRoomCreated]
        } else {
            ::tacky observe -tag $win setting <Changed> -key show_jid_in_1to1 \
                [mymethod OnShowJidIn1to1Setting]
            ::tacky observe -tag $win omemo <Enabled> \
                -acc $options(-acc) -jid $options(-jid) \
                [mymethod OnOmemoEnabled]
        }
    }

    destructor {
        catch {::tacky unlisten $win}
        catch {$self RemoveMenus}
        catch {$self DestroyParticipants}
    }

    method OnShowParticipantsSetting {ev} {
        set val [dict get $ev -value]
        if {$val ne "" && $val} {
            set showParticipants 1
            $self ShowParticipants
        }
    }

    method OnShowJidIn1to1Setting {ev} {
        set val [dict get $ev -value]
        if {$val eq ""} { set val 0 }
        set showJidIn1to1 [expr {!!$val}]
    }

    method ToggleShowJidIn1to1 {} {
        ::tacky setting set -key show_jid_in_1to1 -value $showJidIn1to1
    }

    method BuildOmemoToggle {} {
        set slot [$entry accessory]
        ttk::checkbutton $slot.lock -style Toolbutton \
            -variable [myvar omemoEnabled] \
            -command [mymethod ToggleOmemo] \
            -image [list mate/24x24/status/stock_lock-open.png \
                selected mate/24x24/status/stock_lock.png]
        pack $slot.lock -fill both -expand 1
    }

    method OnOmemoEnabled {ev} {
        set omemoEnabled [dict get $ev -value]
    }

    method ToggleOmemo {} {
        ::tacky omemo setEnabled -acc $options(-acc) \
            -jid $options(-jid) -value $omemoEnabled
    }

    method OpenOmemoKeys {} {
        omemokeyswindow open $options(-acc) $options(-jid)
    }

    method Send {text} {
        ::tacky message send -acc $options(-acc) \
            -chat_jid $options(-jid) -body $text
    }

    method InstallMenus {} {
        set mb $options(-menubar)
        menu $mb.chat -tearoff 0
        $mb.chat add command -label "Jump to Date..." \
            -command [mymethod JumpToDate]
        $mb.chat add command -label "Find in Chat..." \
            -command [mymethod OpenFind] -accelerator "Ctrl+F"
        $mb.chat add command -label "Server Search..." \
            -command [mymethod OpenSearch]
        if {$isMuc} {
            $self RebuildMucMenu
        } else {
            $mb.chat add separator
            $mb.chat add checkbutton -label "Encrypt with OMEMO" \
                -variable [myvar omemoEnabled] \
                -command [mymethod ToggleOmemo]
            $mb.chat add command -label "OMEMO Keys..." \
                -command [mymethod OpenOmemoKeys]
            $mb.chat add separator
            $mb.chat add checkbutton -label "Show JID Instead of Name" \
                -variable [myvar showJidIn1to1] \
                -command [mymethod ToggleShowJidIn1to1]
            $mb.chat add command -label "Start Call" \
                -command [mymethod StartCall]
        }
        $mb add cascade -label "Chat" -menu $mb.chat
    }

    method RebuildMucMenu {} {
        set mb $options(-menubar)
        $mb.chat delete 0 end

        $mb.chat add command -label "Jump to Date..." \
            -command [mymethod JumpToDate]
        $mb.chat add command -label "Find in Chat..." \
            -command [mymethod OpenFind] -accelerator "Ctrl+F"
        $mb.chat add command -label "Server Search..." \
            -command [mymethod OpenSearch]
        $mb.chat add separator

        # Always-visible items
        $mb.chat add checkbutton -label "Participants" \
            -variable [myvar showParticipants] \
            -command [mymethod ToggleParticipants]
        $mb.chat add separator
        $mb.chat add command -label "Invite User..." \
            -command [mymethod InviteUser]
        $mb.chat add command -label "Change Nickname..." \
            -command [mymethod ChangeNickname]

        # Always last
        $mb.chat add separator
        $mb.chat add command -label "Leave Room" \
            -command [mymethod LeaveRoom]
        $mb.chat add command -label "Leave Room (Keep Bookmark)" \
            -command [mymethod LeaveRoomKeepBookmark]

        # Permission-gated items — fetched asynchronously and inserted
        ::tacky muc myNick -acc $options(-acc) -jid $roomJid \
            -command [mymethod OnMyNickForMenu]
    }

    method OnMyNickForMenu {nick} {
        if {$nick eq ""} return
        ::tacky muc occupant -acc $options(-acc) -jid $roomJid -nick $nick \
            -command [mymethod OnOccupantForMenu]
    }

    method OnOccupantForMenu {occ} {
        if {$occ eq ""} return
        set mb $options(-menubar)
        if {![winfo exists $mb.chat]} return

        set role [dict get $occ role]
        set affil [dict get $occ affiliation]

        # Insert permission-gated items before the trailing separator
        # Static menu: Jump to Date, Find in Chat, Server Search, sep, Participants, sep, Invite, Change Nick = indices 0-7
        set insertIdx 8
        if {$role eq "visitor"} {
            $mb.chat insert $insertIdx separator
            incr insertIdx
            $mb.chat insert $insertIdx command -label "Request Voice" \
                -command [mymethod RequestVoice]
            incr insertIdx
        }
        if {$affil eq "owner"} {
            $mb.chat insert $insertIdx separator
            incr insertIdx
            $mb.chat insert $insertIdx command -label "Destroy Room..." \
                -command [mymethod DestroyRoom]
        }
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

    method JumpToDate {} {
        set dateStr [InputDialog .jump_date_dlg \
            -title "Jump to Date" -prompt "Date (YYYY-MM-DD):"]
        if {$dateStr eq ""} return
        if {[catch {clock scan $dateStr -format "%Y-%m-%d"} secs]} {
            tk_messageBox -icon error -title "Invalid Date" \
                -message "Could not parse date: $dateStr\n\nExpected format: YYYY-MM-DD"
            return
        }
        $cv goto [expr {$secs * 1000000}] -source remote
    }

    method ToggleParticipants {} {
        if {$showParticipants} {
            $self ShowParticipants
        } else {
            $self DestroyParticipants
        }
        ::tacky setting set -key show_participants -value $showParticipants
    }

    method ShowParticipants {} {
        if {$mucList ne ""} return
        set mucList [mucparticipantlist $paned.plist \
            -acc $options(-acc) -jid $roomJid]
        $paned add $mucList -weight 0
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
        ::tacky muc myNick -acc $options(-acc) -jid $roomJid \
            -command [mymethod OnMyNickForChange]
    }

    method OnMyNickForChange {myNick} {
        set newNick [InputDialog .muc_nick_dlg \
            -title "Change Nickname" -prompt "New nickname:" \
            -value $myNick]
        if {$newNick eq "" || $newNick eq $myNick} return
        ::tacky bookmarks nick -acc $options(-acc) -jid $roomJid -nick $newNick
    }

    method RequestVoice {} {
        ::tacky muc requestVoice -acc $options(-acc) -jid $roomJid
    }

    method StartCall {} {
        ::tacky calls start -acc $options(-acc) \
            -to [jid bare $options(-jid)]
    }

    method DestroyRoom {} {
        set answer [tk_messageBox -type yesno -icon warning \
            -title "Destroy Room" \
            -message "Are you sure you want to permanently destroy this room?\n\n$roomJid"]
        if {$answer ne "yes"} return
        ::tacky muc destroyRoom -acc $options(-acc) -jid $roomJid
    }

    method LeaveRoom {} {
        ::tacky bookmarks remove -acc $options(-acc) -jid $roomJid
    }

    method LeaveRoomKeepBookmark {} {
        ::tacky bookmarks leave -acc $options(-acc) -jid $roomJid
    }

    method OpenFind {} {
        if {$findBar ne "" && [winfo exists $findBar]} {
            focus $findBar.entry
            return
        }
        set findBar [ttk::frame $leftFrame.findbar]
        ttk::label $findBar.lbl -text "Find:"
        ttk::entry $findBar.entry -width 30
        ttk::button $findBar.prev -text "Prev" -style Toolbutton \
            -command [mymethod FindPrev]
        ttk::button $findBar.next -text "Next" -style Toolbutton \
            -command [mymethod FindNext]
        ttk::label $findBar.status -text ""
        ttk::button $findBar.close -text "\u00D7" -style Toolbutton \
            -command [mymethod CloseFind]
        pack $findBar.lbl $findBar.entry $findBar.prev $findBar.next \
            $findBar.status -side left -padx 2
        pack $findBar.close -side right -padx 2
        pack $findBar -fill x -before $entry

        bind $findBar.entry <Return> [mymethod OnFindReturn]
        bind $findBar.entry <Shift-Return> [mymethod FindPrev]
        bind $findBar.entry <Escape> [mymethod CloseFind]

        set findMatches {}
        set findIndex -1
        set findQuery ""
        focus $findBar.entry
    }

    method CloseFind {} {
        if {$findBar ne "" && [winfo exists $findBar]} {
            destroy $findBar
        }
        set findBar ""
        set findMatches {}
        set findIndex -1
        set findQuery ""
        $cv highlight clear
    }

    method OnFindReturn {} {
        set query [$findBar.entry get]
        if {$query eq ""} return
        if {$query eq $findQuery && [llength $findMatches] > 0} {
            $self FindNext
        } else {
            set findQuery $query
            $self DoFind
        }
    }

    method DoFind {} {
        ::tacky message local_search -acc $options(-acc) \
            -chat $options(-jid) -query $findQuery \
            -command [mymethod OnFindResults]
    }

    method OnFindResults {timestamps} {
        set findMatches $timestamps
        if {[llength $findMatches] > 0} {
            set findIndex 0
            $self GotoFindMatch
        } else {
            set findIndex -1
        }
        $self UpdateFindStatus
    }

    method FindNext {} {
        if {[llength $findMatches] == 0} return
        set findIndex [expr {($findIndex + 1) % [llength $findMatches]}]
        $self GotoFindMatch
        $self UpdateFindStatus
    }

    method FindPrev {} {
        if {[llength $findMatches] == 0} return
        set findIndex [expr {
            ($findIndex - 1 + [llength $findMatches]) % [llength $findMatches]
        }]
        $self GotoFindMatch
        $self UpdateFindStatus
    }

    method GotoFindMatch {} {
        set ts [lindex $findMatches $findIndex]
        $cv goto $ts
    }

    method UpdateFindStatus {} {
        if {![winfo exists $findBar.status]} return
        if {[llength $findMatches] == 0} {
            $findBar.status configure -text "No matches"
        } else {
            $findBar.status configure -text \
                "[expr {$findIndex + 1}] of [llength $findMatches]"
        }
    }

    method OpenSearch {} {
        if {[winfo exists $win.search]} {
            wm deiconify $win.search
            raise $win.search
            return
        }
        searchwindow $win.search -acc $options(-acc) -jid $options(-jid) \
            -goto-command [mymethod OnSearchGoto]
    }

    method OnSearchGoto {timestamp} {
        $cv goto $timestamp -source remote
    }
}
