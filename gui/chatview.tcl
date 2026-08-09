package require snit
package require emojipicker

# chatview - the controller. Turns chatarea's thirst/cull signals into
# history requests against the Client API, and feeds the results back to
# chatarea as message dicts. See chatarea.tcl for the loading algorithm.
snit::widgetadaptor chatview {
    # set of jids tracked via avatarcache
    variable TrackedAvatars

    delegate method messages to hull
    delegate method attachment to hull
    delegate method {see *} to hull using {%c see %m}
    delegate method {highlight *} to hull using {%c highlight %m}
    delegate method system to hull

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

    # MUC only: our current role in the room, and the bare room JID. MyRole
    # is cached from muc <Presence> so CanModerate reads it synchronously
    # while building its popup menu.
    variable MyRole ""
    variable RoomBare ""

    # Names dict: from_jid → display name for messages in this chat.
    # Seeded from `tacky author get` at construction; kept in sync by
    # the author <Changed> listener.
    variable Names

    # 1:1 only: when true, render bare JIDs instead of resolved names.
    # Mirrors the global `show_jid_in_1to1` setting.
    variable ShowJid 0

    # Image downloads in flight: url -> list of "msgId,attIdx" awaiting their
    # thumbnail. A `file <Update>` for that url routes progress/result to each.
    variable DownloadPending

    # Read markers: newest incoming id shown, and the last one we sent a
    # `displayed` for. See MaybeSendDisplayed.
    variable NewestIncoming ""
    variable LastDisplayedSent ""

    constructor args {
        installhull using chatarea \
            -thirst-command [mymethod OnThirsty] \
            -cull-command [mymethod OnCulled] \
            -avatar-release-command [mymethod OnAvatarRelease] \
            -attachment-open-command [mymethod AttachOpen] \
            -attachment-save-command [mymethod AttachSave] \
            -attachment-openfolder-command [mymethod AttachOpenFolder] \
            -attachment-uncache-command [mymethod AttachUncache] \
            -attachment-load-command [mymethod AttachLoad] \
            -attachment-retry-command [mymethod AttachRetry] \
            -scrollbtn-command [mymethod ScrollToBottom] \
            -loading-cancel-command [mymethod CancelGoto]
        $self configurelist $args
        set ViewAtTail 1
        # Empty display is vacuously at the tail; any live message
        # arriving before InitialLoad completes is the new tail.
        # InitialLoad / OnLoadDone(new) re-affirm; OnCulled(new) and
        # goto-non-end flip false.
        set AtTail 1
        set IsMuc $options(-groupchat)
        set Names [dict create]
        set TrackedAvatars [list]
        set DownloadPending [dict create]
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
        ::tacky listen -tag $win file <Update> \
            -acc $options(-acc) [mymethod OnTransfer]
        ::tacky listen -tag $win author <Changed> \
            -acc $options(-acc) -chat $options(-jid) [mymethod OnAuthorChanged]
        ::tacky author get -acc $options(-acc) -chat $options(-jid) \
            -command [mymethod OnAuthorSeed]
        if {!$IsMuc} {
            ::tacky observe -tag $win setting <Changed> -key show_jid_in_1to1 \
                [mymethod OnShowJidSetting]
        } else {
            regsub {\?join$} $options(-jid) {} RoomBare
            set RoomBare [jid norm [jid bare $RoomBare]]
            ::tacky listen -tag $win muc <Presence> \
                -acc $options(-acc) -jid $RoomBare [mymethod RefreshMyRole]
            $self RefreshMyRole
        }
        bind $self <<MessageRightClick>> [mymethod OnMessageRightClick %d %X %Y]
        bind $self <<ReplyJump>> [mymethod OnReplyJump %d]
        bind $self <<ReactToggle>> [mymethod OnReactToggle %d]
        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }
        bind $win.text <<Yview>> +[mymethod OnScroll]
        bind $win.text <Configure> [mymethod OnFirstConfigure]
        # Refocusing marks the tail read (live arrivals go via OnMessage).
        # The toplevel outlives us, so guard on $win still existing.
        if {!$IsMuc} {
            bind [winfo toplevel $win] <FocusIn> +[list apply {{w} {
                if {[winfo exists $w]} { $w MaybeSendDisplayed }
            }} $win]
        }
    }

    # Initial snapshot of author names for this chat. Applies cached
    # names to any messages already rendered (history may have arrived
    # first if the seed callback is async).
    method OnAuthorSeed {names} {
        set Names $names
        dict for {fromJid name} $names {
            set label [expr {$ShowJid ? $fromJid : $name}]
            $hull author update $fromJid $label
        }
    }

    method OnAuthorChanged {ev} {
        set fromJid [dict get $ev -from]
        set name [dict get $ev -name]
        dict set Names $fromJid $name
        if {!$ShowJid} {
            $hull author update $fromJid $name
        }
    }

    # Live-toggle JID-vs-name rendering: repaints every existing author
    # label using $Names as the source of truth.
    method OnShowJidSetting {ev} {
        set val [dict get $ev -value]
        if {$val eq ""} { set val 0 }
        set val [expr {!!$val}]
        if {$val == $ShowJid} return
        set ShowJid $val
        dict for {fromJid name} $Names {
            set label [expr {$ShowJid ? $fromJid : $name}]
            $hull author update $fromJid $label
        }
    }

    method OnFirstConfigure {} {
        # Calling InitialLoad directly glitched out on some chats
        # (actually only one -#tcl%irc.libera.chat@irc.chinwag.im).
        # PixelsAbove would get a weird value of ~58000, I figure
        # because the widget didn't have real geometry yet, and
        # cleanup would kick in erasing everything. No idea why it
        # only happened with one chat.
        bind $win.text <Configure> {}
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
        $hull see end
        $self MaybeSendDisplayed
    }

    destructor {
        foreach tag [list $win $win/goto $win/old $win/new] {
            catch {::tacky unlisten $tag}
            catch {::tacky message cancel -acc $options(-acc) -tag $tag}
        }
        catch {$self RemoveMenus}
        catch {$self UntrackAllAvatars}
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
            $hull clear
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
        if {[$hull messages has $anchor]} {
            $hull see message $anchor
            return
        }

        # Clear and reload around the anchor
        $hull clear
        $self ProcessBatch $messages
        $self UpdateViewAtTail
        if {$anchor ne "" && [$hull messages has $anchor]} {
            $hull see message $anchor
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
            $hull loading configure -text "Loading…" -cancellable 1
            $hull loading show
        } elseif {$CatchupBusy} {
            $hull loading configure -text "Syncing history…" -cancellable 0
            $hull loading show
        } else {
            $hull loading hide
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
        set newest [$hull messages newest]
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
        set atEnd [$hull atEnd]
        $self ProcessBatch $messages
        if {$direction eq "new"} {
            # If thirst caught up to the pushed tail, rejoin the live tail
            # so subsequent <New> events insert again. Comparing to DbNewest
            # is robust to changes in -limit.
            set newest [$hull messages newest]
            if {$newest ne "" && $newest eq $DbNewest} {
                set AtTail 1
            }
        }
        $self UpdateViewAtTail
        if {$direction eq "new" && $atEnd} {
            $hull see end
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
        if {![$hull messages has $ts]} return
        set patch [dict create]
        foreach k {server_status remote_status fail_reason} {
            if {[dict exists $ev -$k]} { dict set patch $k [dict get $ev -$k] }
        }
        $hull patchFields $ts $patch
    }

    # A pending send was acknowledged by the server. When the stamp held
    # (newtimestamp == timestamp) just update the checkmark in place; when the
    # server relocated the row, rekey the stored dict to the new timestamp and
    # redraw it at its new position.
    method OnConfirmed {ev} {
        set ts [dict get $ev -timestamp]
        if {![$hull messages has $ts]} return
        set newTs [dict get $ev -newtimestamp]
        if {$newTs == $ts} {
            $hull patchFields $ts \
                [dict create server_status [dict get $ev -server_status]]
            return
        }
        set storeDict [$hull messages get $ts]
        dict set storeDict timestamp $newTs
        dict set storeDict server_status [dict get $ev -server_status]
        $self KeepingTail { $self Redraw $ts $storeDict }
    }

    method OnReactions {ev} {
        set ts [dict get $ev -timestamp]
        if {![$hull messages has $ts]} return
        $hull reactions update $ts [dict get $ev -reactions]
    }

    # Full-row redraw: the backend re-sends the whole store dict.
    method OnEdited {ev} {
        set msg [dict get $ev -message]
        set ts [dict get $msg timestamp]
        if {![$hull messages has $ts]} return
        $self KeepingTail { $self Redraw $ts $msg }
    }

    # Retraction flips the shown entry to a tombstone. The event is lean
    # (just the timestamp), so reuse the retained store dict and set the
    # retracted flag; DrawMessage renders the tombstone from the header alone.
    method OnRetracted {ev} {
        set ts [dict get $ev -timestamp]
        if {![$hull messages has $ts]} return
        set sd [$hull messages get $ts]
        dict set sd retracted 1
        $self KeepingTail { $self Redraw $ts $sd }
    }

    # Run a redraw that may change the newest row's height, staying pinned to
    # the tail if we were riding it. Without this the view drifts as the row
    # grows, and the scroll-to-bottom button appears (and sticks) after an
    # edit, a confirm, or a thumbnail landing.
    method KeepingTail {script} {
        set atEnd [$hull atEnd]
        uplevel 1 $script
        if {$atEnd} { $hull see end }
    }

    method OnScroll {} {
        $self UpdateViewAtTail
    }

    method UpdateViewAtTail {} {
        set newest [$hull messages newest]
        set hasNewest [expr {$newest ne "" && $newest eq $DbNewest}]
        set ViewAtTail [expr {$hasNewest && [$hull atEnd]}]
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
            $hull scrollbtn hide
        } else {
            $hull scrollbtn show
        }
    }

    method ScrollToBottom {} {
        $self goto end
    }

    method EnrichMessage {storeDict} {
        set names [expr {$ShowJid && !$IsMuc ? [dict create] : $Names}]
        enrich_store_message $storeDict $names
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
        $hull apply $enriched
        foreach emsg $enriched {
            $self FetchAttachments $emsg
        }
    }

    # Redraw a message already on screen from a fresh store dict. $key is the
    # row it currently occupies, which is not the new dict's key when the
    # server moved it.
    method Redraw {key msg} {
        set emsg [$self PrepareMessage $msg]
        $hull replace $key $emsg
        $self FetchAttachments $emsg
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
            $self TrackAvatar $ajid
        }
        dict set emsg payload $msg
        return $emsg
    }

    # Kick off the inline-thumbnail fetch for each image attachment. The file
    # module downloads (remote) or reads in place (local), derives the
    # thumbnail, and reports via `file <Update>` (-> OnTransfer).
    # -auto subjects the fetch to the autofetch policy and size cap. Our own
    # sends are exempt: from history they refetch the public URL that replaced
    # the local path on upload.
    method FetchAttachments {emsg} {
        if {![dict exists $emsg attachments]} return
        set id [dict get $emsg key]
        set idx 0
        set auto [expr {![dict get $emsg is_outgoing]}]
        foreach att [dict get $emsg attachments] {
            if {[dict get $att type] eq "image"} {
                $self StartDownload [dict get $att url] $id $idx \
                    -auto $auto -from [dict get $emsg from_jid]
            }
            incr idx
        }
    }

    # Click-to-reload after "Delete from cache" or a held-back autofetch: same
    # path as the initial fetch, minus the gating.
    method AttachLoad {url id idx} {
        $self StartDownload $url $id $idx
    }

    method StartDownload {url id idx args} {
        set key "$id,$idx"
        set cur [expr {[dict exists $DownloadPending $url]
            ? [dict get $DownloadPending $url] : {}}]
        if {$key ni $cur} {
            dict set DownloadPending $url [lappend cur $key]
        }
        ::tacky file download -acc $options(-acc) -url $url {*}$args
    }

    # Single transfer listener: upload events key on -id (== message id);
    # download events key on -url via DownloadPending.
    method OnTransfer {ev} {
        set dir   [dict get $ev -direction]
        set state [dict get $ev -state]
        set loaded [dict get $ev -loaded]
        set total  [dict get $ev -total]
        set thumb  [dict get $ev -thumbpath]
        set err    [dict get $ev -error]
        if {$dir eq "upload"} {
            $self ApplyTransfer [dict get $ev -id] 0 $dir $state $loaded $total \
                $thumb $err
            return
        }
        set url [dict get $ev -url]
        if {![dict exists $DownloadPending $url]} return
        foreach key [dict get $DownloadPending $url] {
            lassign [split $key ,] mid idx
            $self ApplyTransfer $mid $idx $dir $state $loaded $total $thumb $err
        }
        if {$state ne "active"} { dict unset DownloadPending $url }
    }

    method ApplyTransfer {id idx dir state loaded total thumb {err ""}} {
        if {![$hull messages has $id]} return
        # An image the policy held back isn't an error: with no state row the
        # attachment keeps its plain click-to-load caption.
        if {$state eq "failed" && [string match autofetch-* $err]} return
        # A thumbnail or progress row arriving after the message was drawn
        # grows it below the last line, pushing the viewport off the bottom.
        # Re-pin if we were riding the tail so the scroll-to-bottom button
        # doesn't spuriously appear (and stick).
        set atEnd [$hull atEnd]
        if {$state eq "done" && $thumb ne ""} {
            $hull attachment image $id $idx $thumb
        }
        $hull attachment state $id $idx $dir $state $loaded $total
        if {$atEnd} {
            # Packing the thumbnail into the embedded frame defers the frame's
            # geometry recalc to idle, so flush it before `see end` measures
            # the (now taller) last line; otherwise we land short and drift off.
            update idletasks
            $hull see end
            $self UpdateViewAtTail
        }
    }

    method AttachRetry {id} {
        $hull attachment state $id 0 upload active 0 0
        ::tacky message retryUpload -acc $options(-acc) \
            -chat $options(-jid) -timestamp $id
    }

    method AttachOpen {url} {
        if {[file exists $url]} { attachment_os_open $url; return }
        ::tacky file download -acc $options(-acc) -url $url \
            -command [mymethod OnAttachOpenReady]
    }

    method OnAttachOpenReady {path} {
        if {$path eq ""} {
            tk_messageBox -icon error -title "Download Failed" \
                -parent [winfo toplevel $win] \
                -message "Could not download the attachment."
            return
        }
        attachment_os_open $path
    }

    method AttachSave {url name} {
        set dest [tk_getSaveFile -initialfile $name -parent [winfo toplevel $win]]
        if {$dest eq ""} return
        if {[file exists $url]} {
            if {[catch {file copy -force -- $url $dest} err]} {
                tk_messageBox -icon error -title "Save Failed" \
                    -parent [winfo toplevel $win] -message $err
            }
            return
        }
        ::tacky file download -acc $options(-acc) -url $url \
            -command [mymethod OnAttachSaveReady $dest]
    }

    method OnAttachSaveReady {dest path} {
        if {$path eq ""} {
            tk_messageBox -icon error -title "Download Failed" \
                -parent [winfo toplevel $win] \
                -message "Could not download the attachment."
            return
        }
        if {[catch {file copy -force -- $path $dest} err]} {
            tk_messageBox -icon error -title "Save Failed" -message $err
        }
    }

    method AttachOpenFolder {url} {
        if {[file exists $url]} { showinfm::show $url; return }
        ::tacky file download -acc $options(-acc) -url $url \
            -command [mymethod OnAttachFolderReady]
    }

    method OnAttachFolderReady {path} {
        if {$path eq ""} {
            tk_messageBox -icon error -title "Download Failed" \
                -parent [winfo toplevel $win] \
                -message "Could not download the attachment."
            return
        }
        showinfm::show $path
    }

    method AttachUncache {url} {
        ::tacky file uncache -acc $options(-acc) -url $url
    }

    # Avatar lifecycle: TrackAvatar is called when a message is drawn.
    # It tracks via avatarcache which handles visibility, fetching, and
    # image lifecycle.  When all messages for a jid are culled by the
    # scroll cleanup, OnAvatarRelease fires and untracks from the cache.
    method TrackAvatar {jid} {
        if {$jid in $TrackedAvatars} return
        lappend TrackedAvatars $jid
        set img [avatarcache track \
            -acc $options(-acc) -jid $jid -tag $win/$jid \
            -command [mymethod OnAvatar $jid]]
        $hull avatar set $jid $img
    }

    method OnAvatar {jid img} {
        $hull avatar set $jid $img
    }

    method UntrackAllAvatars {} {
        foreach jid $TrackedAvatars {
            catch {avatarcache untrack -tag $win/$jid}
        }
        set TrackedAvatars [list]
    }

    method OnAvatarRelease {jid} {
        if {$jid ni $TrackedAvatars} return
        catch {avatarcache untrack -tag $win/$jid}
        set idx [lsearch -exact $TrackedAvatars $jid]
        set TrackedAvatars [lreplace $TrackedAvatars $idx $idx]
    }

    method OnMessageRightClick {id rootX rootY} {
        set m $win.__ctxmenu
        if {![winfo exists $m]} {
            menu $m -tearoff 0
        }
        $m delete 0 end
        set sd [$hull messages get $id]
        set isOutgoing [expr {[dict exists $sd is_outgoing]
            && [dict get $sd is_outgoing]}]
        set retracted [expr {[dict exists $sd retracted]
            && [dict get $sd retracted]}]

        $m add command -label "Reply" \
            -command [mymethod OnReplySelected $id]
        $m add command -label "Add Reaction" \
            -command [mymethod OnReactSelected $id $rootX $rootY]
        # Edit our own, non-retracted message (XEP-0308).
        if {$isOutgoing && !$retracted} {
            $m add command -label "Edit" \
                -command [mymethod OnEditSelected $id]
        }
        # Deletion: MUC is moderation (moderators only, XEP-0425); 1:1 is a
        # self-retraction of our own message (XEP-0424).
        if {!$retracted} {
            if {$IsMuc} {
                if {[$self CanModerate]} {
                    $m add command -label "Delete for everyone" \
                        -command [mymethod OnModerateSelected $id]
                }
            } elseif {$isOutgoing} {
                $m add command -label "Delete" \
                    -command [mymethod OnRetractSelected $id]
            }
        }
        $m add command -label "View XML" \
            -command [mymethod OnViewXml $id]
        $m add command -label "Find in Chat" \
            -command [list event generate $win <<FindInChat>>]
        tk_popup $m $rootX $rootY
    }

    # True iff we currently hold the moderator role in this room. Reads the
    # MyRole cache (a live `muc myRole` query only resolves inline in the
    # direct transport) so the popup menu can gate synchronously.
    method CanModerate {} {
        return [expr {$IsMuc && $MyRole eq "moderator"}]
    }

    # Refresh the cached role. Seeded at construction and re-run on each of
    # our own presence updates (role changes arrive as presence).
    method RefreshMyRole {args} {
        ::tacky muc myRole -acc $options(-acc) -jid $RoomBare \
            -tag $win -command [mymethod SetMyRole]
    }

    method SetMyRole {role} { set MyRole $role }

    method OnEditSelected {id} {
        set sd [$hull messages get $id]
        event generate $win <<EditMessage>> \
            -data [list $id [message_text $sd]]
    }

    method OnRetractSelected {id} {
        event generate $win <<RetractMessage>> -data $id
    }

    method OnModerateSelected {id} {
        event generate $win <<ModerateMessage>> -data $id
    }

    # Open an emoji picker at the click point; the chosen glyph toggles our
    # reaction on the message. Override-redirect + global grab so a click
    # anywhere else dismisses it (mirrors messageentry's emoji popup).
    method OnReactSelected {id rootX rootY} {
        # Unique name per open: a pending idle-destroy of a prior popup must
        # never land on a freshly reopened one at the same path.
        set pop $win.__reactpop[clock microseconds]
        toplevel $pop -borderwidth 1 -relief solid
        wm withdraw $pop
        wm overrideredirect $pop 1
        if {[tk windowingsystem] eq "x11"} {
            catch {wm attributes $pop -type popup_menu}
        }
        emojipicker $pop.p -command [mymethod OnReactPicked $id $pop]
        pack $pop.p -expand yes -fill both
        bind $pop <Escape> [list destroy $pop]
        bind $pop <ButtonPress> [mymethod OnReactGrabClick $pop %X %Y]
        wm transient $pop [winfo toplevel $win]
        wm geometry $pop +$rootX+$rootY
        wm deiconify $pop
        raise $pop
        if {[catch {ttk::globalGrab $pop}]} { catch {grab $pop} }
        $pop.p focusSearch
    }

    method OnReactPicked {id pop glyph} {
        # Hide immediately for instant feedback, but defer destroy: emojipicker's
        # Click still generates <<EmojiSelected>> on $pop.p after this -command
        # returns, so the window must outlive this callback.
        catch {ttk::releaseGrab $pop}
        catch {wm withdraw $pop}
        ::tacky message react -acc $options(-acc) -chat $options(-jid) \
            -timestamp $id -emoji $glyph
        after idle [list destroy $pop]
    }

    method OnReactGrabClick {pop X Y} {
        if {![winfo exists $pop]} return
        set x0 [winfo rootx $pop]
        set y0 [winfo rooty $pop]
        if {$X < $x0 || $X >= $x0 + [winfo width $pop]
         || $Y < $y0 || $Y >= $y0 + [winfo height $pop]} {
            catch {ttk::releaseGrab $pop}
            destroy $pop
        }
    }

    # Chip click: toggle our reaction (add if absent, retract if present).
    # The backend recomputes and sends the full set either way.
    method OnReactToggle {data} {
        lassign $data id emoji
        ::tacky message react -acc $options(-acc) -chat $options(-jid) \
            -timestamp $id -emoji $emoji
    }

    method OnReplySelected {id} {
        set sd [$hull messages get $id]
        set author [dict get [$self EnrichMessage $sd] display_name]
        set snippet [lindex [split [message_text $sd] \n] 0]
        if {[string length $snippet] > 80} {
            set snippet "[string range $snippet 0 79]…"
        }
        event generate $win <<ReplyTo>> -data [list $id $author $snippet]
    }

    method OnViewXml {id} {
        ::tacky message rawxml -acc $options(-acc) \
            -chat $options(-jid) -timestamp $id \
            -command {apply {{xml} {
                xmlstanza showxml $xml
            }}}
    }

    method OnReceipt {receiptDict} {
        $hull receipt update [dict get $receiptDict id] [dict get $receiptDict server_status]
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
