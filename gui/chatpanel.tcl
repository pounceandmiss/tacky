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
    option -groupchat -default 0 -readonly yes
    option -menubar -default ""

    variable cv
    variable entry
    variable paned
    variable leftFrame
    variable isMuc
    variable roomJid ""
    variable showParticipants 0
    variable showJidIn1to1 0
    variable sendReceipts 1
    variable omemoEnabled 1
    variable mucList ""
    # name -> widget, for the banners packed above the composer.
    variable banners {}
    variable findMatches {}
    variable findIndex -1
    variable findQuery ""
    variable replyToTs ""
    variable editingTs ""
    variable dropBg -array {}

    constructor args {
        $self configurelist $args

        set isMuc $options(-groupchat)
        if {$isMuc} {
            set roomJid [jid bare $options(-jid)]
        }

        set paned [ttk::panedwindow $win.paned -orient horizontal]
        set leftFrame [ttk::frame $paned.left]

        set cv [chatview $leftFrame.cv \
            -acc $options(-acc) -jid $options(-jid) \
            -groupchat $options(-groupchat)]
        set entry [messageentry $leftFrame.entry \
            -send-command [mymethod Send] \
            -attach-command [mymethod Attach]]
        pack $cv -expand yes -fill both
        pack $entry -fill x
        if {!$isMuc} {
            $self BuildOmemoToggle
        }

        $self EnableFileDrop [$cv textwidget]
        $self EnableFileDrop $entry.text

        bind $cv <<FindInChat>> [mymethod OpenFind]
        bind $cv <<ReplyTo>> [mymethod StartReply %d]
        bind $cv <<EditMessage>> [mymethod StartEdit %d]
        bind $cv <<RetractMessage>> [mymethod ConfirmRetract %d]
        bind $cv <<ModerateMessage>> [mymethod ConfirmModerate %d]

        $paned add $leftFrame -weight 1
        pack $paned -expand yes -fill both

        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }

        if {$isMuc} {
            ::tacky listen -tag $win muc <RoomCreated> \
                -acc $options(-acc) [mymethod OnMucRoomCreated]
        } else {
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

    # --- Composer banners ---
    #
    # Reply, edit and find each pack a strip above the composer. The pane is
    # frozen while any is up, so a banner shrinks the chat view rather than
    # growing the window; it thaws once the last one goes.

    method HasBanner {name} {
        expr {[dict exists $banners $name]
            && [winfo exists [dict get $banners $name]]}
    }

    # The frame a banner's content lives in. "" when it isn't up.
    method BannerBody {name} {
        if {![$self HasBanner $name]} { return "" }
        return [[dict get $banners $name] body]
    }

    # Create the banner if absent, pack it, and return it. Options apply on
    # creation only - an already-open banner keeps the content it has.
    method ShowBanner {name args} {
        if {![$self HasBanner $name]} {
            dict set banners $name \
                [composerbanner $leftFrame.banner_$name {*}$args]
        }
        set w [dict get $banners $name]
        pack propagate $leftFrame 0
        pack $w -fill x -before $entry
        return $w
    }

    method HideBanner {name} {
        if {[dict exists $banners $name]} {
            catch {destroy [dict get $banners $name]}
            dict unset banners $name
        }
        if {[dict size $banners] == 0} {
            pack propagate $leftFrame 1
        }
    }

    method ApplyParticipants {} {
        if {$showParticipants} {
            $self ShowParticipants
        } else {
            $self DestroyParticipants
        }
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
        if {$editingTs ne ""} {
            ::tacky message edit -acc $options(-acc) -chat $options(-jid) \
                -timestamp $editingTs -body $text
            $self CancelEdit
            return
        }
        set sendArgs [list -acc $options(-acc) -chat $options(-jid) -body $text]
        if {$replyToTs ne ""} {
            lappend sendArgs -reply_to_ts $replyToTs
        }
        ::tacky message send {*}$sendArgs
        $self CancelReply
    }

    # Begin an XEP-0308 correction: banner + prefill the composer with the
    # current body. The next Send routes to `message edit` (see Send).
    method StartEdit {data} {
        lassign $data ts body
        $self CancelReply
        set editingTs $ts
        if {![$self HasBanner edit]} {
            set slot [[$self ShowBanner edit -close-command \
                [mymethod CancelEdit]] body]
            pack [ttk::label $slot.lbl -anchor w -text "Editing message"] \
                -fill x -expand yes
        }
        $entry set $body
        $entry focus
    }

    method CancelEdit {} {
        set editingTs ""
        $self HideBanner edit
    }

    method ConfirmRetract {id} {
        set ans [tk_messageBox -type yesno -icon question \
            -parent [winfo toplevel $win] -title "Delete message" \
            -message "Delete this message? This cannot be undone."]
        if {$ans ne "yes"} return
        ::tacky message retract -acc $options(-acc) \
            -chat $options(-jid) -timestamp $id
    }

    method ConfirmModerate {id} {
        set ans [tk_messageBox -type yesno -icon question \
            -parent [winfo toplevel $win] -title "Delete for everyone" \
            -message "Retract this message for everyone in the room?"]
        if {$ans ne "yes"} return
        ::tacky message moderate -acc $options(-acc) \
            -chat $options(-jid) -timestamp $id \
            -tag $win -onerror [mymethod ShowModerateError]
    }

    method ShowModerateError {message} {
        if {![winfo exists $win]} return
        tk_messageBox -icon error -title "Delete Failed" \
            -parent [winfo toplevel $win] -message $message
    }

    method StartReply {data} {
        lassign $data ts author snippet
        $self CancelEdit
        set replyToTs $ts
        set slot [[$self ShowBanner reply \
            -icon mate/16x16/actions/mail-reply-sender.png \
            -close-command [mymethod CancelReply]] body]
        if {![winfo exists $slot.lbl]} {
            pack [ttk::label $slot.lbl -anchor w] -fill x -expand yes
        }
        $slot.lbl configure -text "Replying to $author: $snippet"
        $entry focus
    }

    method CancelReply {} {
        set replyToTs ""
        $self HideBanner reply
    }

    method Attach {} {
        set path [tk_getOpenFile -title "Attach File" \
            -parent [winfo toplevel $win]]
        if {$path eq ""} return
        ::tacky message sendFile -acc $options(-acc) \
            -chat $options(-jid) -path $path
    }

    # Register $w as a drop target so files dragged onto it are sent to this
    # chat. No-op when tkdnd isn't loaded (e.g. under the test harness).
    method EnableFileDrop {w} {
        if {[catch {package require tkdnd}]} return
        tkdnd::drop_target register $w DND_Files
        bind $w <<DropEnter>> [mymethod DropEnter $w]
        bind $w <<DropLeave>> [mymethod DropLeave $w]
        bind $w <<Drop:DND_Files>> [mymethod DropFiles $w %D]
    }

    method DropEnter {w} {
        set dropBg($w) [$w cget -background]
        $w configure -background "#cfe0ff"
        return copy
    }

    method DropLeave {w} {
        if {[info exists dropBg($w)]} {
            $w configure -background $dropBg($w)
            unset dropBg($w)
        }
    }

    method DropFiles {w files} {
        $self DropLeave $w
        foreach path $files {
            if {![file isfile $path]} continue
            ::tacky message sendFile -acc $options(-acc) \
                -chat $options(-jid) -path $path
        }
        return copy
    }

    method InstallMenus {} {
        set mb $options(-menubar)
        menu $mb.chat -tearoff 0
        if {$isMuc} {
            $self RebuildMucMenu
        } else {
            $self AddChatMenuPrefix
            $mb.chat add separator
            $mb.chat add checkbutton -label "Encrypt with OMEMO" \
                -variable [myvar omemoEnabled] \
                -command [mymethod ToggleOmemo]
            $mb.chat add command -label "OMEMO Keys..." \
                -command [mymethod OpenOmemoKeys]
            $mb.chat add separator
            settingmenu::checkbutton $mb.chat "Show JID Instead of Name" \
                -var [myvar showJidIn1to1] -key show_jid_in_1to1 -tag $win
            settingmenu::checkbutton $mb.chat "Send Read Receipts" \
                -var [myvar sendReceipts] -key send_chat_markers -tag $win
            $mb.chat add command -label "Start Call" \
                -command [mymethod StartCall]
        }
        $mb add cascade -label "Chat" -menu $mb.chat
    }

    # The entries every chat has, in both layouts.
    method AddChatMenuPrefix {} {
        set mb $options(-menubar)
        $mb.chat add command -label "Jump to Date..." \
            -command [mymethod JumpToDate]
        $mb.chat add command -label "Find in Chat..." \
            -command [mymethod OpenFind] -accelerator "Ctrl+F"
        $mb.chat add command -label "Search Messages..." \
            -command [mymethod OpenSearch]
    }

    method RebuildMucMenu {} {
        set mb $options(-menubar)
        $mb.chat delete 0 end

        $self AddChatMenuPrefix
        $mb.chat add separator

        # Always-visible items
        settingmenu::checkbutton $mb.chat "Participants" \
            -var [myvar showParticipants] -key show_participants \
            -tag $win -onchange [mymethod ApplyParticipants]
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
            -tag $win -command [mymethod OnMyNickForMenu]
    }

    method OnMyNickForMenu {nick} {
        if {$nick eq ""} return
        ::tacky muc occupant -acc $options(-acc) -jid $roomJid -nick $nick \
            -tag $win -command [mymethod OnOccupantForMenu]
    }

    method OnOccupantForMenu {occ} {
        if {$occ eq ""} return
        set mb $options(-menubar)
        if {![winfo exists $mb.chat]} return

        set role [dict get $occ role]
        set affil [dict get $occ affiliation]

        # By label, not index: everything above shifts as the menu changes.
        # Lands on the separator that opens the trailing Leave Room block.
        set insertIdx [expr {[$mb.chat index "Leave Room"] - 1}]
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
                -parent [winfo toplevel $win] \
                -message "Could not parse date: $dateStr\n\nExpected format: YYYY-MM-DD"
            return
        }
        $cv goto [expr {$secs * 1000000}] -source remote
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
            -parent [winfo toplevel $win] \
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
            -tag $win -command [mymethod OnMyNickForChange]
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
            -parent [winfo toplevel $win] \
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
        set fresh [expr {![$self HasBanner find]}]
        set slot [[$self ShowBanner find \
            -close-command [mymethod CloseFind]] body]
        if {$fresh} {
            ttk::label $slot.lbl -text "Find:"
            ttk::entry $slot.entry -width 30
            ttk::button $slot.prev -text "Prev" -style Toolbutton \
                -command [mymethod FindPrev]
            ttk::button $slot.next -text "Next" -style Toolbutton \
                -command [mymethod FindNext]
            ttk::label $slot.status -text ""
            pack $slot.lbl $slot.entry $slot.prev $slot.next $slot.status \
                -side left -padx 2

            bind $slot.entry <Return> [mymethod OnFindReturn]
            bind $slot.entry <Shift-Return> [mymethod FindPrev]
            bind $slot.entry <Escape> [mymethod CloseFind]
            $self ResetFind
        }
        focus $slot.entry
    }

    method CloseFind {} {
        $self HideBanner find
        $self ResetFind
        $cv highlight clear
    }

    method ResetFind {} {
        set findMatches {}
        set findIndex -1
        set findQuery ""
    }

    method OnFindReturn {} {
        set query [[$self BannerBody find].entry get]
        if {$query eq ""} return
        if {$query eq $findQuery && [llength $findMatches] > 0} {
            $self FindNext
        } else {
            set findQuery $query
            $self DoFind
        }
    }

    method DoFind {} {
        ::tacky message search -acc $options(-acc) -source local -limit 500 \
            -chat $options(-jid) -query $findQuery \
            -tag $win -command [mymethod OnFindResults]
    }

    method OnFindResults {result} {
        set findMatches [lmap m [dict get $result messages] {dict get $m timestamp}]
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
        set status [$self BannerBody find].status
        if {![winfo exists $status]} return
        if {[llength $findMatches] == 0} {
            $status configure -text "No matches"
        } else {
            $status configure -text \
                "[expr {$findIndex + 1}] of [llength $findMatches]"
        }
    }

    method OpenSearch {} {
        if {[raise_existing $win.search]} return
        searchwindow $win.search -acc $options(-acc) -jid $options(-jid) \
            -goto-command [mymethod GotoMessage]
    }

    # Remote-sourced: a hit may be an isolated island in the local cache, so
    # the surrounding page has to come from the archive.
    method GotoMessage {timestamp} {
        $cv goto $timestamp -source remote
    }
}
