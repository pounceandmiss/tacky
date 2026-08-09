package require snit
package require emojipicker

# chatview - the controller. Turns chatarea's thirst/cull signals into
# history requests against the Client API, and feeds the results back to
# chatarea as message dicts. See chatarea.tcl for the loading algorithm.
snit::widget chatview {
    hulltype ttk::frame

    # The area this drives. Held rather than adapted: an adaptor would
    # re-export every chatarea method through chatview.
    component area

    # Which avatar belongs to each author on screen.
    component avatars

    delegate method messages to area
    delegate method attachment to area
    delegate method textwidget to area
    delegate method {see *} to area using {%c see %m}
    delegate method {highlight *} to area using {%c highlight %m}
    delegate method system to area
    delegate method scrollbtn to area
    delegate method loading to area

    option -acc -readonly yes
    option -jid
    option -groupchat -default 0 -readonly yes
    option -menubar -default ""

    # True if AtTail is true AND the viewport is scrolled to the
    # visual bottom. Drives scroll-to-bottom button visibility (button
    # shown when !ViewAtTail).
    variable ViewAtTail

    # True if the displayed window contains the
    # conversation tail, regardless of viewport position. Gates live
    # message inserts (see OnMessage). Pegged to event transitions.
    #
    # Transition sites:
    #   constructor                   -> true    (empty window is vacuously at tail)
    #   OnInitialLoadDone             -> true    (newest page contains tail by definition)
    #   OnLoadDone(new)               -> true    (only when newest displayed == DB-tail)
    #   goto target!=end              -> false   (window may not reach the tail)
    #   OnCulled (new in directions)  -> false   (tail just dropped from the window)
    #   goto end                      -> false   (transient, until OnInitialLoadDone re-asserts)
    variable AtTail

    variable IsMuc

    # True between this chat's message <CatchupStarted> and its
    # <CatchupDone>. The archive may hold history the window doesn't across
    # that span, so AtTail is unverifiable and live inserts pause.
    variable CatchupBusy 0

    # True while a remote goto is in flight. Both flags feed UpdateLoading,
    # which owns the overlay strip.
    variable GotoBusy 0

    # Backend-pushed newest real-message timestamp for this chat (message
    # <Tail>). The at-tail check compares the newest displayed id against it;
    # tracking it by event instead of a per-scroll query keeps the check
    # correct under the async (threaded/process) transports.
    variable DbNewest ""

    # What the user can do to one message.
    component actions -public actions

    # What to call each author in this chat.
    component authors

    # The file transfers behind this chat's attachments.
    component transfers

    # Read markers: newest incoming id shown, and the last one we sent a
    # `displayed` for. See MaybeSendDisplayed.
    variable NewestIncoming ""
    variable LastDisplayedSent ""

    constructor args {
        $self configurelist $args
        install area using chatarea $win.ca \
            -thirst-command [mymethod OnThirsty] \
            -cull-command [mymethod OnCulled] \
            -scrollbtn-command [mymethod ScrollToBottom] \
            -loading-cancel-command [mymethod CancelGoto]
        pack $win.ca -expand yes -fill both
        set ViewAtTail 1
        # Empty display is vacuously at the tail; any live message
        # arriving before InitialLoad completes is the new tail.
        # InitialLoad / OnLoadDone(new) re-affirm; OnCulled(new) and
        # goto-non-end flip false.
        set AtTail 1
        set IsMuc $options(-groupchat)
        install authors using authornames ${selfns}::authors \
            -acc $options(-acc) -chat $options(-jid) -tag $win/authors \
            -show-jid-setting [expr {!$IsMuc}] \
            -changed-command [list $area author update]
        install avatars using avatarbinder ${selfns}::avatars \
            -acc $options(-acc) -tag $win \
            -repaint-command [list $area avatar set]
        install transfers using attachmentxfer ${selfns}::transfers \
            -acc $options(-acc) -chat $options(-jid) -tag $win/files \
            -parent $win -update-command [mymethod OnAttachmentUpdate]
        $area configure \
            -avatar-image-command [list $avatars image] \
            -avatar-release-command [list $avatars release] \
            -attachment-command $transfers
        ::tacky listen -tag $win message <New> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnMessage]
        ::tacky listen -tag $win message <Status> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnStatus]
        ::tacky listen -tag $win message <Confirmed> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnConfirmed]
        ::tacky listen -tag $win message <Reactions> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnReactions]
        ::tacky listen -tag $win message <Edited> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnEdited]
        ::tacky listen -tag $win message <Retracted> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnRetracted]
        ::tacky listen -tag $win message <CatchupStarted> \
            -acc $options(-acc) [mymethod OnCatchupStarted]
        ::tacky listen -tag $win message <CatchupDone> \
            -acc $options(-acc) [mymethod OnCatchupDone]
        ::tacky observe -tag $win message <Tail> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnTail]
        install actions using messageactions ${selfns}::actions \
            -acc $options(-acc) -chat $options(-jid) -tag $win/actions \
            -groupchat $IsMuc -widget $win \
            -message-command [list $area messages get] \
            -label-command [list $authors label]
        bind $area <<MessageRightClick>> [list $actions rightclick %d %X %Y]
        bind $area <<ReactToggle>> [list $actions toggle %d]
        bind $area <<ReplyJump>> [mymethod OnReplyJump %d]
        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }
        bind $win.ca.text <<Yview>> +[mymethod OnScroll]
        bind $win.ca.text <Configure> [mymethod OnFirstConfigure]
        # Refocusing marks the tail read (live arrivals go via OnMessage).
        # The toplevel outlives us, so guard on $win still existing.
        if {!$IsMuc} {
            bind [winfo toplevel $win] <FocusIn> +[list apply {{w} {
                if {[winfo exists $w]} { $w MaybeSendDisplayed }
            }} $win]
        }
    }

    method OnFirstConfigure {} {
        # Calling InitialLoad directly glitched out on some chats
        # (actually only one -#tcl%irc.libera.chat@irc.chinwag.im).
        # PixelsAbove would get a weird value of ~58000, I figure
        # because the widget didn't have real geometry yet, and
        # cleanup would kick in erasing everything. No idea why it
        # only happened with one chat.
        bind $win.ca.text <Configure> {}
        $self InitialLoad
    }

    method InitialLoad {} {
        if {[::tacky listening $win/new]} return
        ::tacky message history -acc $options(-acc) \
            -chat $options(-jid) -limit 50 \
            -tag $win/new -command [mymethod OnInitialLoadDone]
    }

    method OnInitialLoadDone {messages} {
        $self ProcessBatch $messages
        # Initial load fetches the newest page by definition; we are
        # at the tail even when the result is empty (empty conversation
        # is vacuously at tail).
        set AtTail 1
        $self UpdateViewAtTail
        $area see end
        $self MaybeSendDisplayed
    }

    destructor {
        foreach tag [list $win $win/goto $win/old $win/new] {
            catch {::tacky unlisten $tag}
            catch {::tacky message cancel -acc $options(-acc) -tag $tag}
        }
        catch {$self RemoveMenus}
    }

    # Cancel in-flight loads and leave the live tail before a non-tail jump.
    method ResetForGoto {} {
        set GotoBusy 0
        $self UpdateLoading
        foreach tag [list $win/goto $win/old $win/new] {
            ::tacky unlisten $tag
            ::tacky message cancel -acc $options(-acc) -tag $tag
        }
        set AtTail 0
    }

    method goto {target args} {
        set defaults [dict create -source local]
        set opts [dict merge $defaults $args]
        set source [dict get $opts -source]

        $self ResetForGoto

        if {$target eq "end"} {
            # Reset to "bottom of conversation" — same as initial open.
            # InitialLoad will flip AtTail back to true on completion.
            $area clear
            $self InitialLoad
            return
        }

        if {$source eq "remote"} {
            set GotoBusy 1
            $self UpdateLoading
        }
        ::tacky message goto -acc $options(-acc) \
            -chat $options(-jid) -date $target -source $source \
            -limit 50 -tag $win/goto \
            -command [mymethod OnGotoDone]
    }

    method OnGotoDone {result} {
        set GotoBusy 0
        $self UpdateLoading
        set messages [dict get $result messages]
        set anchor [dict get $result anchor]

        if {[llength $messages] == 0} return

        # If anchor is already visible, just scroll+highlight
        if {[$area messages has $anchor]} {
            $area see message $anchor
            return
        }

        # Clear and reload around the anchor
        $area clear
        $self ProcessBatch $messages
        $self UpdateViewAtTail
        if {$anchor ne "" && [$area messages has $anchor]} {
            $area see message $anchor
        }
    }

    method CancelGoto {} {
        ::tacky unlisten $win/goto
        ::tacky message cancel -acc $options(-acc) -tag $win/goto
        set GotoBusy 0
        $self UpdateLoading
    }

    # Both states share one strip; the user's own request outranks the
    # background sync.
    method UpdateLoading {} {
        if {$GotoBusy} {
            $area loading configure -text "Loading…" -cancellable 1
            $area loading show
        } elseif {$CatchupBusy} {
            $area loading configure -text "Syncing history…" -cancellable 0
            $area loading show
        } else {
            $area loading hide
        }
    }

    # Clicking a message's reply reference jumps to the replied-to message,
    # reusing the goto slice-and-highlight path (OnGotoDone).
    method OnReplyJump {data} {
        lassign $data replyId replyTo
        if {$replyId eq ""} return
        $self ResetForGoto
        ::tacky message gotoReply -acc $options(-acc) \
            -chat $options(-jid) -reply_id $replyId -reply_to $replyTo \
            -limit 50 -tag $win/goto \
            -command [mymethod OnGotoDone]
    }

    # Ours when it names this chat, or when it's the account-wide one and
    # we're a 1:1 - the account archive carries no groupchat, so a room
    # only ever hears about its own sync.
    method IsMyCatchup {ev} {
        set jid [expr {[dict exists $ev -jid] ? [dict get $ev -jid] : ""}]
        if {$jid eq $options(-jid)} { return 1 }
        return [expr {$jid eq "" && !$IsMuc}]
    }

    method OnCatchupStarted {ev} {
        if {![$self IsMyCatchup $ev]} return
        set CatchupBusy 1
        $self UpdateLoading
    }

    method OnCatchupDone {ev} {
        if {![$self IsMyCatchup $ev]} return
        set CatchupBusy 0
        $self UpdateLoading
        $self MaybeCatchupRepaint
    }

    # Catchup stores without emitting <New>, and live messages that landed
    # mid-sync were dropped, so reconcile against the pushed tail. Matching
    # timestamps mean nothing moved here, at no round trip.
    method MaybeCatchupRepaint {} {
        if {!$AtTail} return
        if {[::tacky listening $win/new]} return
        set newest [$area messages newest]
        if {$newest eq ""} {
            $self InitialLoad
            return
        }
        if {$newest eq $DbNewest} return
        ::tacky message history -acc $options(-acc) \
            -chat $options(-jid) -after $newest -limit 50 \
            -tag $win/new -command [mymethod OnCatchupLoadDone]
    }

    # A page stopping short of the tail means a hole sits in between.
    # Appending it would scroll the user into old history without going
    # live; leave them the scroll-to-bottom button.
    method OnCatchupLoadDone {messages} {
        if {[llength $messages] > 0
            && [dict get [lindex $messages end] timestamp] ne $DbNewest} {
            return
        }
        $self OnLoadDone new $messages
    }

    method OnThirsty {direction edgeId} {
        if {[::tacky listening $win/$direction]} return
        if {$direction eq "old"} {
            ::tacky message history -acc $options(-acc) \
                -chat $options(-jid) \
                -before $edgeId -limit 50 \
                -tag $win/$direction \
                -command [mymethod OnLoadDone $direction]
        } else {
            ::tacky message history -acc $options(-acc) \
                -chat $options(-jid) \
                -after $edgeId -limit 50 \
                -tag $win/$direction \
                -command [mymethod OnLoadDone $direction]
        }
    }

    method OnCulled {directions} {
        if {"new" in $directions} {
            # Tail is no longer displayed — pause live-message inserts
            # until the user rejoins the tail.
            set AtTail 0
        }
        foreach dir $directions {
            catch {::tacky unlisten $win/$dir}
            ::tacky message cancel -acc $options(-acc) -tag $win/$dir
        }
    }

    method OnLoadDone {direction messages} {
        set atEnd [$area atEnd]
        $self ProcessBatch $messages
        if {$direction eq "new"} {
            # If thirst caught up to the pushed tail, rejoin the live tail
            # so subsequent <New> events insert again. Comparing to DbNewest
            # is robust to changes in -limit.
            set newest [$area messages newest]
            if {$newest ne "" && $newest eq $DbNewest} {
                set AtTail 1
            }
        }
        $self UpdateViewAtTail
        if {$direction eq "new" && $atEnd} {
            $area see end
        }
        $self MaybeSendDisplayed
    }

    # Live-message flow.
    #
    # <New> arrives only after the backend persists the
    # message to the local store. So a live event we drop here is
    # durable in the DB and reachable by a subsequent `tacky message
    # history` query.
    #
    # The AtTail gate drops live events whenever the displayed window
    # doesn't contain the conversation tail. Inserting in that case
    # would create a temporal gap in the display and (worse) push the
    # "new" thirst cursor past the unfetched run, so the gap would
    # never fill. Dropping is safe: the user rejoins the tail by
    # either (a) clicking the scroll-to-bottom button, which calls
    # `goto end` → InitialLoad and reloads the newest page from the
    # DB, or (b) scrolling down naturally until thirst's `-after`
    # query catches up to DB-newest, at which point OnLoadDone flips
    # AtTail back to true and live inserts resume.
    #
    # A running catchup gates the same way: until it settles the archive
    # may hold history we don't, so inserting would splice the message
    # onto a stale tail. MaybeCatchupRepaint places it once it settles.
    method OnMessage {ev} {
        if {!$AtTail || $CatchupBusy} return
        set m [dict get $ev -message]
        $self KeepingTail {
            $self ProcessBatch [list $m]
            $self UpdateViewAtTail
        }
        $self MaybeSendDisplayed
    }

    # Send/receipt/upload status change: merge onto the checkmark row. Carries
    # any of server_status / remote_status / fail_reason.
    method OnStatus {ev} {
        set ts [dict get $ev -timestamp]
        if {![$area messages has $ts]} return
        set patch [dict create]
        foreach k {server_status remote_status fail_reason} {
            if {[dict exists $ev -$k]} { dict set patch $k [dict get $ev -$k] }
        }
        $area patchFields $ts $patch
    }

    # A pending send was acknowledged by the server. When the stamp held
    # (newtimestamp == timestamp) just update the checkmark in place; when the
    # server relocated the row, rekey the stored dict to the new timestamp and
    # redraw it at its new position.
    method OnConfirmed {ev} {
        set ts [dict get $ev -timestamp]
        if {![$area messages has $ts]} return
        set newTs [dict get $ev -newtimestamp]
        if {$newTs == $ts} {
            $area patchFields $ts \
                [dict create server_status [dict get $ev -server_status]]
            return
        }
        set storeDict [$area messages get $ts]
        dict set storeDict timestamp $newTs
        dict set storeDict server_status [dict get $ev -server_status]
        $self KeepingTail { $self Redraw $ts $storeDict }
    }

    method OnReactions {ev} {
        set ts [dict get $ev -timestamp]
        if {![$area messages has $ts]} return
        $area reactions update $ts [dict get $ev -reactions]
    }

    # Full-row redraw: the backend re-sends the whole store dict.
    method OnEdited {ev} {
        set msg [dict get $ev -message]
        set ts [dict get $msg timestamp]
        if {![$area messages has $ts]} return
        $self KeepingTail { $self Redraw $ts $msg }
    }

    # Retraction flips the shown entry to a tombstone. The event is lean
    # (just the timestamp), so reuse the retained store dict and set the
    # retracted flag; DrawMessage renders the tombstone from the header alone.
    method OnRetracted {ev} {
        set ts [dict get $ev -timestamp]
        if {![$area messages has $ts]} return
        set sd [$area messages get $ts]
        dict set sd retracted 1
        $self KeepingTail { $self Redraw $ts $sd }
    }

    # Run a redraw that may change the newest row's height, staying pinned to
    # the tail if we were riding it. Without this the view drifts as the row
    # grows, and the scroll-to-bottom button appears (and sticks) after an
    # edit, a confirm, or a thumbnail landing.
    method KeepingTail {script} {
        set atEnd [$area atEnd]
        uplevel 1 $script
        if {$atEnd} { $area see end }
    }

    method OnScroll {} {
        $self UpdateViewAtTail
    }

    method UpdateViewAtTail {} {
        set newest [$area messages newest]
        set hasNewest [expr {$newest ne "" && $newest eq $DbNewest}]
        set ViewAtTail [expr {$hasNewest && [$area atEnd]}]
        $self UpdateScrollBtn
    }

    # Backend-pushed newest-message timestamp. Recomputing here keeps the
    # tail state correct regardless of <Tail>/<New> arrival order.
    method OnTail {ev} {
        set DbNewest [dict get $ev -timestamp]
        $self UpdateViewAtTail
    }

    method UpdateScrollBtn {} {
        if {$ViewAtTail} {
            $area scrollbtn hide
        } else {
            $area scrollbtn show
        }
    }

    method ScrollToBottom {} {
        $self goto end
    }

    method EnrichMessage {storeDict} {
        enrich_store_message $storeDict [list $authors label]
    }

    # This chat is viewable and its toplevel holds the OS focus.
    method WindowFocused {} {
        if {![winfo viewable $win]} { return 0 }
        set f [focus -displayof $win]
        return [expr {$f ne "" && [winfo toplevel $f] eq [winfo toplevel $win]}]
    }

    # Mark the newest incoming message read once it's on screen.
    method MaybeSendDisplayed {} {
        if {$IsMuc || !$AtTail || $NewestIncoming eq ""} return
        if {$LastDisplayedSent ne "" && $NewestIncoming <= $LastDisplayedSent} return
        if {![$self WindowFocused]} return
        ::tacky message markDisplayed -acc $options(-acc) \
            -chat $options(-jid) -timestamp $NewestIncoming
        set LastDisplayedSent $NewestIncoming
    }

    method ProcessBatch {messages} {
        set enriched [lmap msg $messages {$self PrepareMessage $msg}]
        $area apply $enriched
        foreach emsg $enriched {
            $transfers fetch $emsg
        }
    }

    # Redraw a message already on screen from a fresh store dict. $key is the
    # row it currently occupies, which is not the new dict's key when the
    # server moved it.
    method Redraw {key msg} {
        set emsg [$self PrepareMessage $msg]
        $area replace $key $emsg
        $transfers fetch $emsg
    }

    # Turn a store dict into what chatarea draws: note it if it is the newest
    # incoming message, make sure its avatar is tracked, and stash the raw dict
    # as the row's payload for the redraws that start from it.
    method PrepareMessage {msg} {
        if {(![dict exists $msg is_outgoing] || ![dict get $msg is_outgoing])
                && (![dict exists $msg kind] || [dict get $msg kind] eq "message")} {
            set id [dict get $msg timestamp]
            if {$NewestIncoming eq "" || $id > $NewestIncoming} {
                set NewestIncoming $id
            }
        }
        set emsg [$self EnrichMessage $msg]
        set ajid [dict get $emsg avatar_jid]
        if {$ajid ne ""} {
            $avatars track $ajid
        }
        dict set emsg payload $msg
        return $emsg
    }

    # A thumbnail or progress row arriving after the message was drawn grows it
    # below the last line, so re-pin the tail if we were riding it - otherwise
    # the scroll-to-bottom button appears (and sticks).
    method OnAttachmentUpdate {key idx direction state loaded total thumb} {
        if {![$area messages has $key]} return
        set atEnd [$area atEnd]
        if {$state eq "done" && $thumb ne ""} {
            $area attachment image $key $idx $thumb
        }
        $area attachment state $key $idx $direction $state $loaded $total
        if {$atEnd} {
            # Packing the thumbnail into the embedded frame defers the frame's
            # geometry recalc to idle, so flush it before `see end` measures
            # the (now taller) last line; otherwise we land short and drift off.
            update idletasks
            $area see end
            $self UpdateViewAtTail
        }
    }

    method InstallMenus {} {
        set mb $options(-menubar)
        menu $mb.chat -tearoff 0
        $mb add cascade -label "Chat" -menu $mb.chat
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
}
