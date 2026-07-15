package require control
package require snit
package require emojipicker

# Scroll-driven message loading algorithm
# ========================================
#
# The text widget holds only a slice of the conversation, not the
# full history. As the user scrolls toward an edge, the next batch
# is loaded on demand; messages far from the viewport are culled to
# bound memory.
#
# Two layers implementing this:
#
#   chatarea  — the GUI layer built on top of Tk text. Measures pixels and emits
#               direction+edge message id signals when its loaded window runs thin
#               or fat. Knows nothing about history.
#   chatview  — the controller. Turns those signals into history requests
#               against the Client API, and feeds results back to chatarea
#               as message dicts.
#

snit::widgetadaptor chatview {
    # set of jids tracked via avatarcache
    variable TrackedAvatars

    delegate method messages to hull
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
        ::tacky listen -tag $win message <Patch> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnPatch]
        ::tacky listen -tag $win message <CatchupDone> \
            -acc $options(-acc) [mymethod OnCatchupDone]
        ::tacky listen -tag $win file <Update> \
            -acc $options(-acc) [mymethod OnTransfer]
        ::tacky listen -tag $win author <Changed> \
            -acc $options(-acc) -chat $options(-jid) [mymethod OnAuthorChanged]
        ::tacky author get -acc $options(-acc) -chat $options(-jid) \
            -command [mymethod OnAuthorSeed]
        if {!$IsMuc} {
            ::tacky observe -tag $win setting <Changed> -key show_jid_in_1to1 \
                [mymethod OnShowJidSetting]
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
        $hull loading hide
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
            $hull loading show
        }
        ::tacky message goto -acc $options(-acc) \
            -chat $options(-jid) -date $target -source $source \
            -limit 50 -tag $win/goto \
            -command [mymethod OnGotoDone]
    }

    method OnGotoDone {result} {
        $hull loading hide
        set messages [dict get $result messages]
        set anchor [dict get $result anchor]

        if {[llength $messages] == 0} return

        # If anchor is already visible, just scroll+highlight
        if {$anchor in [$hull messages ids]} {
            $hull see message $anchor
            return
        }

        # Clear and reload around the anchor
        $hull clear
        $self ProcessBatch $messages
        $self UpdateViewAtTail
        if {$anchor ne "" && $anchor in [$hull messages ids]} {
            $hull see message $anchor
        }
    }

    method CancelGoto {} {
        ::tacky unlisten $win/goto
        ::tacky message cancel -acc $options(-acc) -tag $win/goto
        $hull loading hide
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

    # Catchup messages now flow through <New> under the AtTail
    # gate; no reload needed. Kept as a stub for future UI-settling
    # work (spinners, badges).
    method OnCatchupDone {ev} {}

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
            # If thirst caught up to DB-newest, rejoin the live tail
            # so subsequent <New> events insert again. Comparing
            # to maxTimestamp is robust to changes in -limit.
            set newest [$hull messages newest]
            set dbNewest [::tacky message maxTimestamp \
                -acc $options(-acc) -chat $options(-jid)]
            if {$newest ne "" && $newest eq $dbNewest} {
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
    method OnMessage {ev} {
        if {!$AtTail} return
        set m [dict get $ev -message]
        set atEnd [$hull atEnd]
        $self ProcessBatch [list $m]
        $self UpdateViewAtTail
        if {$atEnd} { $hull see end }
        $self MaybeSendDisplayed
    }

    method OnPatch {ev} {
        foreach msg [dict get $ev -messages] {
            set ts [dict get $msg timestamp]
            if {$ts ni [$hull messages ids]} continue
            if {[dict exists $msg newtimestamp]} {
                # Timestamp move: grab stored dict, update, re-insert. Re-pin
                # the tail if we were at it, so a just-sent message whose
                # server stamp moves the row doesn't drift the view up (the
                # reinsert is otherwise top-anchored by compensate).
                set atEnd [$hull atEnd]
                set newTs [dict get $msg newtimestamp]
                set storeDict [$hull messages get $ts]
                $hull deleteById $ts
                dict set storeDict timestamp $newTs
                dict set storeDict server_status [dict get $msg server_status]
                $self ProcessBatch [list $storeDict]
                if {$atEnd} { $hull see end }
            } elseif {[dict exists $msg body]} {
                # Full-row patch (edit/retract): the backend re-sends the
                # whole enriched dict, so redraw the message in place. Re-pin
                # the tail if we were at it, so editing the newest message
                # keeps it visible instead of drifting below the fold as the
                # body grows (matches the live-insert path).
                set atEnd [$hull atEnd]
                $hull deleteById $ts
                $self ProcessBatch [list $msg]
                if {$atEnd} { $hull see end }
            } elseif {[dict exists $msg reactions]} {
                $hull reactions update $ts [dict get $msg reactions]
            } else {
                $hull patchFields $ts $msg
            }
        }
    }

    method OnScroll {} {
        $self UpdateViewAtTail
    }

    method UpdateViewAtTail {} {
        set newest [$hull messages newest]
        set dbNewest [::tacky message maxTimestamp \
            -acc $options(-acc) -chat $options(-jid)]
        set hasNewest [expr {$newest ne "" && $newest eq $dbNewest}]
        set ViewAtTail [expr {$hasNewest && [$hull atEnd]}]
        $self UpdateScrollBtn
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
        set enriched {}
        foreach msg $messages {
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
            $hull messages store [dict get $emsg id] $msg
            lappend enriched $emsg
        }
        $hull apply $enriched
        foreach emsg $enriched {
            $self FetchAttachments $emsg
        }
    }

    # Kick off the inline-thumbnail fetch for each image attachment. The file
    # module downloads (remote) or reads in place (local), derives the
    # thumbnail, and reports via `file <Update>` (-> OnTransfer).
    method FetchAttachments {emsg} {
        if {![dict exists $emsg attachments]} return
        set id [dict get $emsg id]
        set idx 0
        foreach att [dict get $emsg attachments] {
            if {[dict get $att type] eq "image"} {
                $self StartDownload [dict get $att url] $id $idx
            }
            incr idx
        }
    }

    # Click-to-reload after "Delete from cache": same path as the initial fetch.
    method AttachLoad {url id idx} {
        $self StartDownload $url $id $idx
    }

    method StartDownload {url id idx} {
        set key "$id,$idx"
        set cur [expr {[dict exists $DownloadPending $url]
            ? [dict get $DownloadPending $url] : {}}]
        if {$key ni $cur} {
            dict set DownloadPending $url [lappend cur $key]
        }
        ::tacky file download -acc $options(-acc) -url $url
    }

    # Single transfer listener: upload events key on -id (== message id);
    # download events key on -url via DownloadPending.
    method OnTransfer {ev} {
        set dir   [dict get $ev -direction]
        set state [dict get $ev -state]
        set loaded [dict get $ev -loaded]
        set total  [dict get $ev -total]
        set thumb  [dict get $ev -thumbpath]
        if {$dir eq "upload"} {
            $self ApplyTransfer [dict get $ev -id] 0 $dir $state $loaded $total $thumb
            return
        }
        set url [dict get $ev -url]
        if {![dict exists $DownloadPending $url]} return
        foreach key [dict get $DownloadPending $url] {
            lassign [split $key ,] mid idx
            $self ApplyTransfer $mid $idx $dir $state $loaded $total $thumb
        }
        if {$state ne "active"} { dict unset DownloadPending $url }
    }

    method ApplyTransfer {id idx dir state loaded total thumb} {
        if {$id ni [$hull messages ids]} return
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
        if {[file exists $url]} { attachment_os_open [file dirname $url]; return }
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
        attachment_os_open [file dirname $path]
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

    # True iff we currently hold the moderator role in this room.
    method CanModerate {} {
        if {!$IsMuc} { return 0 }
        regsub {\?join$} $options(-jid) {} roomBare
        set roomBare [jid bare $roomBare]
        return [expr {[::tacky muc myRole \
            -acc $options(-acc) -jid $roomBare] eq "moderator"}]
    }

    method OnEditSelected {id} {
        set sd [$hull messages get $id]
        event generate $win <<EditMessage>> \
            -data [list $id [dict get $sd body]]
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
        set snippet [lindex [split [dict get $sd body] \n] 0]
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


if 0 {
    # Insert messages at their timestamp-sorted position.
    # Each message must have id (== timestamp) and body (or id+patch
    # for a patch entry targeting an already-displayed message).
    $chatview apply $messageDictList
    $chatview message edit $id $messageDict
    $chatview message delete id $id
    $chatview message delete position $pos
}




# chatarea — the GUI layer that owns the text widget.
#
# Pixel model: chatarea tracks PixelsAbove (content above the visible
# viewport) and PixelsBelow (content below it). These are measured on
# every scroll event and widget-view-sync, coalesced via [after idle],
# and drive the load/cull decisions made by DoCleanup. Three thresholds
# govern that behavior — load, clean, and clean target — see the option
# block below.
snit::widget chatarea {
    hulltype ttk::frame
    component text
    component scrollbar
    component scrollbtn -public scrollbtn
    component loading   -public loading

    delegate option -scrollbtn-command      to scrollbtn as -command
    delegate option -loading-cancel-command to loading   as -cancel-command

    # For debugging: Global vars that will be set to the latest
    # calculated numbers of pixels above and below the viewport
    option -pixelsabovevariable
    option -pixelsbelowvariable

    # The three thresholds. Each is computed as
    # max(<name>-threshold, vh * <name>-factor) — the factor scales
    # with viewport height (primary tuning knob); the threshold is a
    # pixel floor that only matters on very small windows where
    # vh*factor would be too small.

    # When the buffer in any direction exceeds the clean threshold,
    # messages at that edge are deleted until the buffer drops to the
    # clean target.
    option -clean-factor    -default 10
    option -clean-threshold -default 5000

    # When the buffer in any direction drops below the load threshold,
    # chatarea fires -thirst-command for that direction.
    option -load-factor    -default 2
    option -load-threshold -default 500

    # Where cleaning stops — sits between load and clean for hysteresis,
    # so a clean pass leaves the buffer well clear of the load threshold.
    option -clean-target-factor    -default 5
    option -clean-target-threshold -default 2500

    # Fires when the buffer in $direction ("old"/"new") fell below the
    # load threshold. Called as: {*}$cmd $direction $edgeId — $edgeId
    # is the id of the oldest (for "old") or newest (for "new") displayed
    # message, i.e. the cursor the controller should fetch from. Fires
    # once per thirsty direction per DoCleanup pass. Not fired if the
    # display is empty (no edge to fetch from), nor for a direction that
    # was just culled in the same pass (avoids load→clean→load).
    option -thirst-command -default control::no-op

    # Fires after chatarea culled messages from one or both edges.
    # Called as: {*}$cmd $directions — $directions is a list containing
    # "old" and/or "new". The controller should invalidate any in-flight
    # loads for those directions; their cursors no longer connect to
    # displayed content. Fires once per DoCleanup pass that culled.
    option -cull-command -default control::no-op

    # Fires when the last message displaying a given avatar JID was just
    # removed. Called as: {*}$cmd $avatarJid. Lets the controller release
    # its avatar tracking for that JID.
    option -avatar-release-command -default control::no-op

    # Attachment actions, invoked from the rendered attachment widgets:
    #   open       {*}$cmd $url            download (cached) and open with the OS
    #   save       {*}$cmd $url $filename  download (cached) and copy to a path
    #   openfolder {*}$cmd $url            open the cached file's folder
    #   uncache    {*}$cmd $url            delete the cached copy from disk
    #   load       {*}$cmd $url $id $idx   (re)fetch an image thumbnail
    #   retry      {*}$cmd $id             retry a failed upload
    option -attachment-open-command -default control::no-op
    option -attachment-save-command -default control::no-op
    option -attachment-openfolder-command -default control::no-op
    option -attachment-uncache-command -default control::no-op
    option -attachment-load-command -default control::no-op
    option -attachment-retry-command -default control::no-op

    # Virtual events
    # <<MessageRightClick>> — fired on the chatarea frame when a message
    #   is right-clicked. -data is the message ID. Standard event fields
    #   %x, %y (widget-relative) and %X, %Y (screen coords) are set.
    #   Not fired if the click lands on empty space.

    # list of ids of all messages currently drawn on text
    # top to bottom, oldest to newest. Sorted by id (== timestamp).
    variable MessageIds

    # Whether a DoCleanup is already scheduled via after idle
    variable CleanupScheduled

    # dict: jid → Tk image name (current avatar for that JID)
    variable AvatarImages

    # dict: message_id → avatar_jid (tracks which avatar each message uses)
    variable MessageAvatars

    # dict of dicts: message_id → store dict (from backend)
    variable Messages

    # Viewport = what's currently visible on screen
    
    # How many pixels are above the viewport
    variable PixelsAbove
    # How many pixels are below the viewport
    variable PixelsBelow

    # ID of the currently highlighted message (search result), or ""
    variable HighlightedId
    
    constructor args {
        install text using chattext $win.text \
            -yscrollcommand [list $win.scrollbar set]
        install scrollbar using ttk::scrollbar $win.scrollbar\
            -command [list $win.text yview]
        install scrollbtn using chatscrollbtn $win.scrollbtn \
            -parent $win.text
        install loading using chatloading $win.loading \
            -parent $win.text

        $self configurelist $args
        
        grid $win.text $win.scrollbar -sticky nsew
        grid rowconfigure $win $win.text -weight 1
        grid columnconfigure $win $win.text -weight 1
        
        set MessageIds {}
        set CleanupScheduled 0
        set AvatarImages [dict create]
        set MessageAvatars [dict create]
        set Messages [dict create]
        set HighlightedId ""

        if {$options(-pixelsbelowvariable) ne ""} {
            upvar #0 $options(-pixelsbelowvariable) [myvar PixelsBelow]
        }
        if {$options(-pixelsabovevariable) ne ""} {
            upvar #0 $options(-pixelsabovevariable) [myvar PixelsAbove]
        }       

        # Configure text tags and fonts
        $self SetFont
        # Track scrolling to load more messages
        bind $win.text <<WidgetViewSync>> [mymethod OnWidgetViewSync %d]
        bind $win.text <<Yview>> [mymethod OnYview]
        bind $win.text <Button-3> [mymethod OnRightClick %x %y %X %Y]

    }

    destructor {
        after cancel [mymethod DoCleanup]
    }

    # Insert each message at its timestamp-sorted position. ID equals
    # the message's timestamp (unique, bumped on collision by backend),
    # so MessageIds stays sorted by id and a linear scan finds the
    # insertion point. Already-displayed entries get their fields
    # patched in place; staleness is handled outside this method (see
    # OnCulled for history requests, AtTail for live events).
    method apply {messageDictList} {
        set inserted {}
        compensate $text {
            foreach msg $messageDictList {
                set id [dict get $msg id]

                if {$id in $MessageIds} {
                    $self patchFields $id $msg
                    continue
                }

                # Find first displayed id greater than $id; insert before
                # it. If none, append. (Linear scan - windows are small.)
                set idx 0
                foreach existing $MessageIds {
                    if {$existing > $id} break
                    incr idx
                }
                if {$idx == [llength $MessageIds]} {
                    $text mark set msgins end
                } else {
                    set successor [lindex $MessageIds $idx]
                    $text mark set msgins item.$successor.first
                }
                # On a failed draw, roll back the partial content (tagged
                # item.$id) and leave a placeholder so the batch continues.
                if {[catch {$self DrawMessage msgins $msg} err]} {
                    catch {$text del item.$id.first item.$id.last}
                    catch {jlog error "DrawMessage failed for $id: $err" -obj chatarea}
                    $self DrawErrorPlaceholder msgins $id
                }
                set MessageIds [linsert $MessageIds $idx $id]
                lappend inserted $id
            }
        }

        return $inserted
    }

    method patchFields {id patchDict} {
        if {![dict exists $patchDict server_status]
                && ![dict exists $patchDict remote_status]} return
        # Merge onto the stored dict so a single-axis patch keeps the other
        # axis; a bare `apply` patch has none, so assume server-confirmed.
        if {[dict exists $Messages $id]} {
            set stored [dict get $Messages $id]
        } else {
            set stored [dict create server_status "" remote_status none]
        }
        foreach k {server_status remote_status} {
            if {[dict exists $patchDict $k]} {
                dict set stored $k [dict get $patchDict $k]
            }
        }
        if {[dict exists $Messages $id]} {
            dict set Messages $id $stored
        }
        set serverStatus [expr {[dict exists $stored server_status]
            ? [dict get $stored server_status] : ""}]
        set remoteStatus [expr {[dict exists $stored remote_status]
            ? [dict get $stored remote_status] : "none"}]
        $self receipt update $id $serverStatus $remoteStatus
    }

    method OnYview {} {
        $self Cleanup
    }

    method OnWidgetViewSync synced {
        if {!$synced} {
            return
        }
        $self Cleanup
    }

    method OnRightClick {x y X Y} {
        # Map widget-relative coords to text index, then find the item tag
        set tags [$text tag names @$x,$y]
        foreach tag $tags {
            if {[string match "item.*" $tag] && ![string match "item.*.*" $tag]} {
                set messageId [string range $tag 5 end]
                event generate $win <<MessageRightClick>> \
                    -data $messageId -x $x -y $y -rootx $X -rooty $Y
                return
            }
        }
    }

    method {see end} {} {
        # Force a synchronous layout first: an embedded attachment whose
        # thumbnail just grew the last line needs its new geometry resolved
        # before `see` can land on the true bottom (else we stop short and
        # the viewport drifts off the tail once the relayout settles).
        $text sync
        $text see end
    }

    method atEnd {} {
        set below [$text count -ypixels @0,[winfo height $text] end-1line]
        return [expr {$below < 10}]
    }

    method {see message} {id} {
        $self highlight message $id
        $text yview item.$id.first
    }

    method {highlight message} {id} {
        if {$HighlightedId ne ""} {
            $text tag configure item.$HighlightedId -background {}
        }
        $text tag configure item.$id -background yellow
        set HighlightedId $id
    }

    method {highlight clear} {} {
        if {$HighlightedId ne ""} {
            $text tag configure item.$HighlightedId -background {}
            set HighlightedId ""
        }
    }

    method {system insert} {msg} {
        $text ins end "$msg\n" system
        $text see end
    }

    method SetFont {{font {Helvetica 13}}} {
        # Message body - bigger indent, a little breathing room below/between lines
        $text tag configure body -lmargin1 40 -lmargin2 40 -spacing2 2 -spacing3 6
        # Author name - bold accent color, space above to separate messages
        $text tag configure author -font "$font bold" -foreground #2d6da3 \
            -spacing1 10
        # XEP-0461 reply preview: inset, lightly-filled block, clickable.
        $text tag configure replyref -lmargin1 52 -lmargin2 52 \
            -background #f0f3f6 -font "Helvetica 11"
        $text tag configure replyref.author -font "Helvetica 11 bold"
        $text tag configure replyref.body -foreground #666666
        # Formatting gimmicks
        $text tag configure entity.quote -foreground green -lmargin1 40 -lmargin2 55
        $text tag configure entity.preformatted -font "Courier 13"
        $text configure -font $font
        # Cross-product of bold/italic/monospace/overstrike entity tags.
        foreach bold {0 1} {
            foreach italic {0 1} {
                foreach mono {0 1} {
                    foreach over {0 1} {
                        if {!$bold && !$italic && !$mono && !$over} continue
                        set parts {}
                        set fontspec [expr {$mono ? {Courier 13} : $font}]
                        if {$bold}   { lappend parts bold;       append fontspec " bold" }
                        if {$italic} { lappend parts italic;     append fontspec " italic" }
                        if {$mono}   { lappend parts monospace }
                        set opts [list -font $fontspec]
                        if {$over}   { lappend parts overstrike; lappend opts -overstrike yes }
                        $text tag configure "entity.[join $parts .]" {*}$opts
                    }
                }
            }
        }
        $text tag configure receipt -foreground #888888
        $text tag configure receipt.read -foreground #2d6da3
        # XEP-0444 reaction chips
        $text tag configure reaction -lmargin1 40 -lmargin2 40 \
            -font "Helvetica 11" -spacing1 2 -spacing3 4
        $text tag configure timestamp -foreground #888888 -font "Helvetica 10"
        $text tag configure system -foreground gray50 -font "$font italic" \
            -justify center -lmargin1 20 -lmargin2 20 -rmargin 20
        $text tag configure drawerror -foreground #b04040 \
            -font "$font italic" -lmargin1 40 -lmargin2 40 -spacing3 6
        # XEP-0308 "(edited)" marker and XEP-0424/0425 retraction tombstone
        $text tag configure edited -foreground #888888
        $text tag configure tombstone -foreground gray50 -font "$font italic"
    }

    method GetPixelsAbove {} {
        set PixelsAbove [$text count -ypixels 0.0 @0,0]
    }
    
    method GetPixelsBelow {} {
        set PixelsBelow [$text count -ypixels @0,[winfo height $text] end-1line]
    }

    method Cleanup {} {
        if {$CleanupScheduled} {
            return
        }
        set CleanupScheduled 1
        after idle [mymethod DoCleanup]
    }

    method DoCleanup {} {
        if {![winfo exists $win]} return
        set CleanupScheduled 0

        $self GetPixelsBelow
        $self GetPixelsAbove

        # Scale thresholds to viewport height so fetching starts
        # well before the user reaches the edge of loaded content.
        set vh [winfo height $text]
	set loadTh      [expr {max($options(-load-threshold),         $vh * $options(-load-factor))}]
	set cleanTh     [expr {max($options(-clean-threshold),        $vh * $options(-clean-factor))}]
	set cleanTarget [expr {max($options(-clean-target-threshold), $vh * $options(-clean-target-factor))}]

        set cleaned {}

        if {$PixelsAbove > $cleanTh} {
            lappend cleaned old
            while {$PixelsAbove > $cleanTarget && [llength $MessageIds] > 0} {
                $self deleteByPos 0
                $self GetPixelsAbove
            }
        }

        if {$PixelsBelow > $cleanTh} {
            lappend cleaned new
            while {$PixelsBelow > $cleanTarget && [llength $MessageIds] > 0} {
                $self deleteByPos end
                $self GetPixelsBelow
            }
        }

        # Invalidate in-flight loads whose cursors may now be stale.
        if {[llength $cleaned] > 0} {
            {*}$options(-cull-command) $cleaned
        }

        # Need an edge id to fetch from; if the display ended up empty
        # there is nothing to be thirsty about. Initial load comes
        # through a different path (chatview::InitialLoad), so the
        # controller's dedupe guard would not catch this.
        if {[llength $MessageIds] == 0} return

        # Don't fire thirst for a direction we just cleaned —
        # that would cause a load→clean→load loop.
        if {$PixelsAbove < $loadTh && "old" ni $cleaned} {
            {*}$options(-thirst-command) old [lindex $MessageIds 0]
        }
        if {$PixelsBelow < $loadTh && "new" ni $cleaned} {
            {*}$options(-thirst-command) new [lindex $MessageIds end]
        }
    }
    
    method {messages oldest} {} {
        lindex $MessageIds 0
    }

    method {messages newest} {} {
        lindex $MessageIds end
    }

    method {messages ids} {} {
        set MessageIds
    }

    method {messages store} {id storeDict} {
        dict set Messages $id $storeDict
    }

    method {messages get} {id} {
        dict get $Messages $id
    }

    method clear {} {
        $text del 0.0 end
        set MessageIds {}
        set HighlightedId ""
        set Messages [dict create]
        set released {}
        dict for {mid ajid} $MessageAvatars {
            if {$ajid ni $released} {
                lappend released $ajid
                {*}$options(-avatar-release-command) $ajid
            }
        }
        set MessageAvatars [dict create]
    }
    
    method {avatar set} {jid image} {
        dict set AvatarImages $jid $image
        # Update all already-rendered avatars for this JID
        foreach {start end} [$text tag ranges from.$jid] {
            $text image configure $start -image $image
        }
    }

    # Repaint the author label for every visible message authored by
    # $fromJid. Tags are preserved so styling and per-item identity
    # survive the replace.
    method {author update} {fromJid newName} {
        foreach {start end} [$text tag ranges author.$fromJid] {
            set tags [$text tag names $start]
            $text replace $start $end $newName $tags
        }
    }

    # Outgoing receipt glyph: "!" failed, "" while pending, single check
    # once the server has it, double on delivered/read (read is coloured).
    method ReceiptText {serverStatus remoteStatus} {
        if {$serverStatus eq "failed"} { return "!" }
        if {$serverStatus ne ""} { return "" }
        switch -- $remoteStatus {
            read - delivered { return "\u2713\u2713" }
            default          { return "\u2713" }
        }
    }

    # Read gets an accent colour via receipt.read.
    method ReceiptTags {id serverStatus remoteStatus} {
        set tags [list item.$id item.$id.receipt receipt]
        if {$serverStatus eq "" && $remoteStatus eq "read"} {
            lappend tags receipt.read
        }
        return $tags
    }

    # Insert the receipt glyph at msgins.
    method DrawReceiptGlyph {id serverStatus remoteStatus} {
        set rt [$self ReceiptText $serverStatus $remoteStatus]
        $text ins msgins " $rt" [$self ReceiptTags $id $serverStatus $remoteStatus]
    }

    method {receipt update} {id serverStatus remoteStatus} {
        set tag item.$id.receipt
        set ranges [$text tag ranges $tag]
        if {[llength $ranges] == 0} return
        lassign $ranges start end
        set rt [$self ReceiptText $serverStatus $remoteStatus]
        $text replace $start $end " $rt" \
            [$self ReceiptTags $id $serverStatus $remoteStatus]
    }

    # Swap the chip row in place; body stays put, viewport doesn't jump.
    method {reactions update} {id reactions} {
        if {$id ni $MessageIds} return
        if {[dict exists $Messages $id]} {
            dict set Messages $id reactions $reactions
        }
        compensate $text {
            set ranges [$text tag ranges item.$id.reactions]
            if {[llength $ranges] > 0} {
                lassign $ranges start end
                $text del $start $end
            }
            if {[dict size $reactions] > 0} {
                $text mark set msgins item.$id.last
                $self DrawReactions $id $reactions
            }
        }
    }

    # Draws message, doesn't store info about it, doesn't adjust the
    # text accordingly. Internal use only!
    method DrawMessage {textIndex messageDict} {
        array set message $messageDict
        $text mark set msgins $textIndex

        # text tag that will be applied to the whole message
        set tag item.$message(id)

        # Hole marker: thick horizontal line indicating an archive gap
        if {[info exists message(hole_above)] && $message(hole_above)} {
            set hf [frame $text._hole_$message(id) -height 3 -background #aaaaaa]
            $text window create msgins -window $hf -stretch 1 -padx 10 -pady 8
            $text tag add $tag "msgins - 1 chars"
            $text ins msgins \n $tag
        }

        # A retracted (XEP-0424/0425) message renders as a tombstone: header
        # for context, then a placeholder in place of the (now gone) content.
        if {[info exists message(retracted)] && $message(retracted)} {
            $self DrawTombstone $messageDict $tag
            return
        }

        eval {
            # Pick the avatar: per-JID if tracked, else default
            set avatarJid ""
            if {[info exists message(avatar_jid)]} {
                set avatarJid $message(avatar_jid)
            }
            if {$avatarJid ne ""} {
                dict set MessageAvatars $message(id) $avatarJid
            }
            if {$avatarJid ne "" && [dict exists $AvatarImages $avatarJid]} {
                set avatarImg [dict get $AvatarImages $avatarJid]
            } else {
                set avatarImg mate/32x32/status/avatar-default.png
            }
            set imageId [$text image create msgins -image $avatarImg]
            $text tag add $tag $imageId
            $text tag add $tag.avatar $imageId
            if {$avatarJid ne ""} {
                $text tag add from.$avatarJid $imageId
            }
            set authorTags [list $tag $tag.author author]
            if {[info exists message(from_jid)] && $message(from_jid) ne ""} {
                lappend authorTags author.$message(from_jid)
            }
            $text ins msgins $message(display_name) $authorTags
            $text ins msgins "  [clock format [expr {$message(timestamp) / 1000000}] -format {%Y-%m-%d %H:%M}]" [list $tag timestamp]
            if {[info exists message(encryption)] && $message(encryption) eq "omemo"} {
                $text ins msgins " " [list $tag timestamp]
                set lockId [$text image create msgins -image mate/16x16/status/stock_lock.png]
                $text tag add $tag $lockId
            }
            $text ins msgins \n $tag

            $self DrawReplyPreview $messageDict $tag

            # The backend supplies `caption` (body with redundant attachment
            # URLs removed) for attachment messages; plain messages have none.
            set displayBody [expr {[info exists message(caption)]
                ? $message(caption) : $message(body)}]
            set hasAttachments [expr {[info exists message(attachments)]
                && [llength $message(attachments)] > 0}]
            set remoteStatus [expr {[info exists message(remote_status)]
                ? $message(remote_status) : "none"}]
            $text ins msgins $displayBody [list $tag body message $tag.body]
            if {[info exists message(edited)] && $message(edited)} {
                $text ins msgins "  (edited)" [list $tag edited]
            }
            # Plain message: receipt trails the body. Attachment: below.
            if {$message(is_outgoing) && !$hasAttachments} {
                $self DrawReceiptGlyph $message(id) \
                    $message(server_status) $remoteStatus
            }
            $text ins msgins \n $tag

            # Formatting offsets index into the body. An empty body draws no
            # $tag.body characters, so $tag.body.first would not resolve -
            # skip rather than let the index lookup throw and abort the draw.
            if {[info exists message(formatting)]
                && [llength [$text tag ranges $tag.body]] > 0} {
                foreach {type offset length} $message(formatting) {
                    $text tag add entity.$type \
                        "$tag.body.first + $offset chars" \
                        "$tag.body.first + $offset chars + $length chars"
                }
            }

            if {$hasAttachments} {
                set aidx 0
                foreach att $message(attachments) {
                    $self DrawAttachment $tag $message(id) $aidx $att \
                        $message(server_status)
                    incr aidx
                }
                if {$message(is_outgoing)} {
                    # Receipt right of the last attachment, before its newline.
                    set lastWin $text.att_$message(id)_[expr {$aidx - 1}]
                    $text mark set msgins "$lastWin + 1 chars"
                    $self DrawReceiptGlyph $message(id) \
                        $message(server_status) $remoteStatus
                }
            }

            if {[info exists message(reactions)]
                && [dict size $message(reactions)] > 0} {
                $text mark set msgins item.$message(id).last
                $self DrawReactions $message(id) $message(reactions)
            }
        }
    }

    # Chip row below a message; each chip is emoji + count, click toggles.
    method DrawReactions {id reactions} {
        set tag item.$id
        set rtag item.$id.reactions
        set i 0
        dict for {emoji info} $reactions {
            set count [llength [dict get $info reactors]]
            set bindTag react.$id.[incr i]
            $text ins msgins " $emoji $count " \
                [list $tag $rtag reaction $bindTag]
            $text tag bind $bindTag <Button-1> \
                [list event generate $win <<ReactToggle>> \
                    -data [list $id $emoji]]
            $text ins msgins "  " [list $tag $rtag reaction]
        }
        $text ins msgins \n [list $tag $rtag reaction]
    }

    # Placeholder for a message that failed to draw. Field-free so it can't
    # fail itself; carries item.$id so id lookup and successor inserts work.
    method DrawErrorPlaceholder {textIndex id} {
        $text mark set msgins $textIndex
        set tag item.$id
        if {![catch {
            $text image create msgins \
                -image mate/16x16/status/dialog-warning.png -padx 3
        } imageId]} {
            $text tag add $tag $imageId
        }
        $text ins msgins "This message could not be displayed" [list $tag drawerror]
        $text ins msgins \n $tag
    }

    # Tombstone for a retracted message: avatar/author/timestamp header (so it
    # keeps its slot and attribution) followed by a greyed placeholder. Whole
    # row carries item.$id so id lookup and successor inserts still work.
    method DrawTombstone {messageDict tag} {
        array set message $messageDict
        set avatarJid [expr {[info exists message(avatar_jid)]
            ? $message(avatar_jid) : ""}]
        if {$avatarJid ne "" && [dict exists $AvatarImages $avatarJid]} {
            set avatarImg [dict get $AvatarImages $avatarJid]
        } else {
            set avatarImg mate/32x32/status/avatar-default.png
        }
        set imageId [$text image create msgins -image $avatarImg]
        $text tag add $tag $imageId
        $text tag add $tag.avatar $imageId
        set authorTags [list $tag $tag.author author]
        if {[info exists message(from_jid)] && $message(from_jid) ne ""} {
            lappend authorTags author.$message(from_jid)
        }
        $text ins msgins $message(display_name) $authorTags
        $text ins msgins "  [clock format [expr {$message(timestamp) / 1000000}] -format {%Y-%m-%d %H:%M}]" [list $tag timestamp]
        $text ins msgins \n $tag
        $text ins msgins "This message was deleted" [list $tag body tombstone]
        $text ins msgins \n $tag
    }

    # Quoted reply preview, drawn at msgins above the body. No-op unless
    # the message carries a reply_id.
    method DrawReplyPreview {messageDict tag} {
        array set message $messageDict
        if {![info exists message(reply_id)] || $message(reply_id) eq ""} return
        set rtag $tag.replyref
        set ra [expr {[info exists message(reply_author)] ? $message(reply_author) : ""}]
        if {$ra eq ""} { set ra "a message" }
        set preview [expr {[info exists message(reply_body)] ? $message(reply_body) : ""}]
        if {$preview eq ""} { set preview "Original message" }
        set ricon [$text image create msgins \
            -image mate/16x16/actions/mail-reply-sender.png -padx 3]
        $text tag add $tag $ricon
        $text tag add $rtag $ricon
        $text tag add replyref $ricon
        $text ins msgins $ra      [list $tag $rtag replyref replyref.author]
        $text ins msgins \n       [list $tag $rtag replyref]
        $text ins msgins $preview [list $tag $rtag replyref replyref.body]
        $text ins msgins \n       [list $tag $rtag replyref]
        set rto [expr {[info exists message(reply_to)] ? $message(reply_to) : ""}]
        $text tag bind $rtag <Button-1> \
            [list event generate $win <<ReplyJump>> \
                 -data [list $message(reply_id) $rto]]
    }

    # Render one attachment as an embedded `attachment` widget under the body.
    # The widget owns its drawing and routes user actions to chatarea's
    # -attachment-*-command callbacks itself; chatarea only forwards
    # `attachment image`/`attachment state` to it by id+idx. `status` is the
    # message's server_status, which seeds the upload-state row (progress bar
    # while 'uploading', Retry when 'failed').
    method DrawAttachment {tag id idx att status} {
        set f $text.att_${id}_${idx}
        catch {destroy $f}
        attachment $f \
            -chatarea $self \
            -url [dict get $att url] -kind [dict get $att type] \
            -name [dict get $att name] -id $id -idx $idx \
            -scroll-target $text
        $text window create msgins -window $f -padx 40 -pady 2
        $text tag add $tag "msgins - 1 chars"
        $text ins msgins \n $tag
        switch -- $status {
            uploading { $self attachment state $id $idx upload active 0 0 }
            failed    { $self attachment state $id $idx upload failed 0 0 }
        }
    }

    # Forward a backend-produced thumbnail (already downscaled) to the widget.
    method {attachment image} {id idx path} {
        set f $text.att_${id}_${idx}
        if {![winfo exists $f]} return
        $f setImage $path
    }

    # Forward a transfer-progress update to the widget: a progress bar while
    # active, an error + Retry row on failure, removed on done.
    method {attachment state} {id idx direction state loaded total} {
        set f $text.att_${id}_${idx}
        if {![winfo exists $f]} return
        $f setState $direction $state $loaded $total
    }

    method deleteById {id} {
        list_remove_once_inplace MessageIds $id
        set tag item.$id
        # Delete contents under that tag
        $text del $tag.first $tag.last
        # Delete tag itself
        $text tag delete item.$id
        if {[dict exists $Messages $id]} {
            dict unset Messages $id
        }
        $self CheckAvatarRelease $id
    }

    method deleteByPos {idx} {
        set id [lindex $MessageIds $idx]
        set MessageIds [lreplace $MessageIds $idx $idx]
        $text del item.$id.first item.$id.last
        $text tag delete item.$id
        if {[dict exists $Messages $id]} {
            dict unset Messages $id
        }
        $self CheckAvatarRelease $id
    }

    method CheckAvatarRelease {id} {
        if {![dict exists $MessageAvatars $id]} return
        set ajid [dict get $MessageAvatars $id]
        dict unset MessageAvatars $id
        # Check if any other messages still reference this avatar
        if {[llength [$text tag ranges from.$ajid]] == 0} {
            {*}$options(-avatar-release-command) $ajid
        }
    }
}

# Shared enrichment: converts a store dict (from_jid, server_status,
# timestamp, body, etc.) into the display dict that chatarea expects.
# `names` maps from_jid → display name (from tacky author get); not in
# the dict means a late-arriving author the cache hasn't been told about
# yet, in which case we fall back to the resource of from_jid (the MUC
# nick) or the from_jid itself (1:1 bare JID after Phase 1 normalisation).
proc enrich_store_message {storeDict names} {
    set fromJid [dict get $storeDict from_jid]
    if {[dict exists $names $fromJid]} {
        set displayName [dict get $names $fromJid]
    } else {
        set displayName [jid resource $fromJid]
        if {$displayName eq ""} { set displayName $fromJid }
    }
    set serverStatus [dict get $storeDict server_status]
    set remoteStatus [expr {[dict exists $storeDict remote_status]
        ? [dict get $storeDict remote_status] : "none"}]
    # Direction comes from the backend (own_id-derived); the view doesn't
    # re-derive it. Older dicts without the flag fall back to "incoming".
    set isOutgoing [expr {[dict exists $storeDict is_outgoing]
        && [dict get $storeDict is_outgoing]}]
    set d [dict create \
        id           [dict get $storeDict timestamp] \
        from_jid     $fromJid \
        display_name $displayName \
        avatar_jid   $fromJid \
        timestamp    [dict get $storeDict timestamp] \
        body         [dict get $storeDict body] \
        is_outgoing  $isOutgoing \
        server_status $serverStatus \
        remote_status $remoteStatus \
        encryption   [expr {[dict exists $storeDict encryption] ? [dict get $storeDict encryption] : ""}] \
        fail_reason  [expr {[dict exists $storeDict fail_reason] ? [dict get $storeDict fail_reason] : ""}]]
    # XEP-0308/0424 state (backend booleans). A retracted message renders as
    # a tombstone; an edited one gets an "(edited)" marker.
    dict set d edited [expr {[dict exists $storeDict edited]
        && [dict get $storeDict edited]}]
    dict set d retracted [expr {[dict exists $storeDict retracted]
        && [dict get $storeDict retracted]}]
    if {[dict exists $storeDict formatting]} {
        dict set d formatting [dict get $storeDict formatting]
    }
    if {[dict exists $storeDict reply_id] && [dict get $storeDict reply_id] ne ""} {
        set rto [dict get $storeDict reply_to]
        dict set d reply_id [dict get $storeDict reply_id]
        dict set d reply_to $rto
        # reply_author_jid is normalized by the backend (nick for MUC, bare for
        # 1:1), matching how names is keyed; resolve its display name here.
        set raj [expr {[dict exists $storeDict reply_author_jid]
            ? [dict get $storeDict reply_author_jid] : $rto}]
        if {[dict exists $names $raj]} {
            set ra [dict get $names $raj]
        } else {
            set ra $raj
        }
        if {$ra eq ""} { set ra $rto }
        dict set d reply_author $ra
        if {[dict exists $storeDict reply_body]} {
            dict set d reply_body [dict get $storeDict reply_body]
        }
    }
    if {[dict exists $storeDict caption]} {
        dict set d caption [dict get $storeDict caption]
    }
    if {[dict exists $storeDict attachments]
        && [llength [dict get $storeDict attachments]] > 0} {
        dict set d attachments [dict get $storeDict attachments]
    }
    # XEP-0444 reactions: backend hands per-emoji {reactors mine}; the count
    # is derived from the reactor list at render time.
    if {[dict exists $storeDict reactions]
        && [dict size [dict get $storeDict reactions]] > 0} {
        dict set d reactions [dict get $storeDict reactions]
    }
    return $d
}

# Open a downloaded attachment with the platform's default handler.
proc attachment_os_open {path} {
    catch {
        if {$::tcl_platform(os) eq "Darwin"} {
            exec open $path &
        } elseif {$::tcl_platform(platform) eq "windows"} {
            exec cmd /c start "" $path &
        } else {
            exec xdg-open $path &
        }
    }
}

proc list_remove_once_inplace {varName val} {
    upvar 1 $varName lst
    set idx [lsearch -exact $lst $val]
    if {$idx == -1} { return 0 }
    set lst [lreplace $lst $idx $idx]
    return 1
}

# One rendered attachment, embedded in the chat text widget. Draws a caption
# (image) or an Open/Save chip (file), with the thumbnail and a transfer
# progress/Retry row added later via `setImage` / `setState`. The widget knows
# its own url/id/idx and routes every user action (open, save, click-to-load,
# retry, the right-click menu) straight to its host chatarea's
# -attachment-*-command callbacks; chatarea just creates it and forwards
# setImage/setState by message id+idx.
snit::widget attachment {
    hulltype ttk::frame

    option -chatarea -default ""      ;# host chatarea; source of action callbacks
    option -url  -default ""
    option -kind -default file        ;# image | file
    option -name -default ""
    option -id   -default ""          ;# message id, passed to load/retry callbacks
    option -idx  -default 0           ;# attachment index within the message
    option -scroll-target -default "" ;# text widget wheel events relay to

    constructor args {
        $self configurelist $args
        if {$options(-kind) eq "image"} {
            ttk::label $win.cap -text $options(-name) -foreground blue -cursor hand2
            bind $win.cap <Button-1> [mymethod Click]
            pack $win.cap -side top -anchor w
        } else {
            set chip [ttk::frame $win.chip]
            ttk::label  $chip.name -text $options(-name)
            ttk::button $chip.open -text "Open" -style Toolbutton \
                -command [mymethod Open]
            ttk::button $chip.save -text "Save" -style Toolbutton \
                -command [mymethod Save]
            pack $chip.name $chip.open $chip.save -side left -padx 2
            pack $chip -side top -anchor w
        }
        $self RelayScroll $win
        $self BindMenu $win
    }

    # Invoke one of the host chatarea's -attachment-<name>-command callbacks.
    method Cb {name args} {
        {*}[$options(-chatarea) cget -attachment-$name-command] {*}$args
    }

    # Image caption/thumbnail click: open the image when its thumbnail is shown,
    # else (re)load it (e.g. after "Delete from cache" cleared it).
    method Click {} {
        if {[$self hasImage]} {
            $self Open
        } else {
            $self Cb load $options(-url) $options(-id) $options(-idx)
        }
    }

    method Open {} { $self Cb open $options(-url) }
    method Save {} { $self Cb save $options(-url) $options(-name) }

    method hasImage {} { winfo exists $win.img }
    method dropImage {} { catch {destroy $win.img} }

    # Add the backend-produced thumbnail (already downscaled) above the caption.
    method setImage {path} {
        if {[winfo exists $win.img]} return
        if {[catch {image create photo -file $path} photo]} return
        ttk::label $win.img -image $photo -cursor hand2
        # Tk photos aren't auto-freed when their last referencing widget dies,
        # so tie this one's lifetime to the label so cull/clear/uncache release it.
        bind $win.img <Destroy> [list catch [list image delete $photo]]
        if {[winfo exists $win.cap]} {
            bind $win.img <Button-1> [mymethod Click]
            pack $win.img -side top -anchor w -before $win.cap
        } else {
            pack $win.img -side top -anchor w
        }
        $self RelayScroll $win.img
        $self BindMenu $win.img
    }

    # Transfer state row: a progress bar while active, an error + Retry on
    # failure, removed on done. upload/download use separate rows ($win.up /
    # $win.dl) so an uploading image keeps both its bar and its thumbnail.
    method setState {direction state loaded total} {
        set w $win.[expr {$direction eq "upload" ? "up" : "dl"}]
        switch -- $state {
            done   { catch {destroy $w} }
            failed { $self ShowFailed $w $direction }
            active { $self ShowActive $w $direction $loaded $total }
        }
    }

    method ShowActive {w direction loaded total} {
        if {![winfo exists $w.bar]} {
            catch {destroy $w}
            ttk::frame $w
            ttk::progressbar $w.bar -length 200
            ttk::label $w.lbl -foreground #888888
            pack $w.bar $w.lbl -side left -padx {0 6}
            pack $w -side top -anchor w -pady {2 0}
            $self RelayScroll $w
        }
        $w.lbl configure -text \
            [expr {$direction eq "upload" ? "Uploading..." : "Downloading..."}]
        if {$total > 0} {
            $w.bar configure -mode determinate \
                -value [expr {100.0 * $loaded / $total}]
        } else {
            $w.bar configure -mode indeterminate
            catch {$w.bar start}
        }
    }

    method ShowFailed {w direction} {
        catch {destroy $w}
        ttk::frame $w
        ttk::label $w.lbl -foreground #c0504d -text \
            [expr {$direction eq "upload" ? "Upload failed" : "Download failed"}]
        ttk::button $w.retry -text "Retry" -style Toolbutton \
            -command [mymethod Retry $direction]
        pack $w.lbl $w.retry -side left -padx {0 6}
        pack $w -side top -anchor w -pady {2 0}
        $self RelayScroll $w
    }

    # Upload retry re-runs the upload; download retry re-fetches the thumbnail
    # (same path as the click-to-load placeholder).
    method Retry {direction} {
        if {$direction eq "upload"} {
            $self Cb retry $options(-id)
        } else {
            $self Cb load $options(-url) $options(-id) $options(-idx)
        }
    }

    # Embedded windows in the text widget swallow wheel events; forward them
    # (and any later descendants') to the text so scrolling keeps working when
    # the pointer is over an attachment. Mirrors chatscrollbtn.
    method RelayScroll {w} {
        set t $options(-scroll-target)
        if {$t eq ""} return
        bind $w <Button-4>   [list event generate $t <Button-4>]
        bind $w <Button-5>   [list event generate $t <Button-5>]
        bind $w <MouseWheel> [list event generate $t <MouseWheel> -delta %D]
        foreach c [winfo children $w] { $self RelayScroll $c }
    }

    # Bind the right-click menu on $w and its descendants; the thumbnail arrives
    # after the chip/caption, so setImage runs this again for it.
    method BindMenu {w} {
        bind $w <Button-3> [mymethod Menu %X %Y]
        foreach c [winfo children $w] { $self BindMenu $c }
    }

    # The right-click menu is identical for every attachment; build it lazily,
    # once per widget, with its actions bound to this one.
    method Menu {X Y} { tk_popup [$self MenuWidget] $X $Y }

    method MenuWidget {} {
        set m $win.menu
        if {[winfo exists $m]} { return $m }
        menu $m -tearoff 0
        $m add command -label "Open"              -command [mymethod Open]
        $m add command -label "Open folder"       -command [mymethod OpenFolder]
        $m add command -label "Delete from cache" -command [mymethod Uncache]
        return $m
    }

    method OpenFolder {} { $self Cb openfolder $options(-url) }

    # Drop the cached copy on disk and the inline thumbnail; the message keeps
    # its caption/chip and re-fetches the next time the thumbnail is requested.
    method Uncache {} {
        $self dropImage
        $self Cb uncache $options(-url)
    }
}

# Scroll-to-bottom button overlay.
snit::widgetadaptor chatscrollbtn {
    option -parent -readonly yes
    delegate option -command to hull
    delegate method * to hull

    variable Visible 0

    constructor args {
        installhull using ttk::button \
            -image mate/22x22/actions/go-down -style Toolbutton
        $self configurelist $args

	# Wheel events on the button are forwarded to the text widget
	# so the user can keep scrolling if the cursor comes over it.
        bind $win <Button-4> \
            [list event generate $options(-parent) <Button-4>]
        bind $win <Button-5> \
            [list event generate $options(-parent) <Button-5>]
        bind $win <MouseWheel> \
            [list event generate $options(-parent) <MouseWheel> -delta %D]
    }

    method show {} {
        if {$Visible} return
        set Visible 1
        place $win -in $options(-parent) \
            -relx 1.0 -rely 1.0 -anchor se -x -24 -y -8
        raise $win
    }

    method hide {} {
        if {!$Visible} return
        set Visible 0
        place forget $win
    }
}

# "Loading…" overlay with a Cancel button
snit::widget chatloading {
    hulltype ttk::frame
    component cancel
    option -parent -readonly yes
    delegate option -cancel-command to cancel as -command

    constructor args {
        ttk::label $win.lbl -text "Loading…"
        install cancel using ttk::button $win.cancel \
            -text "Cancel" -style Toolbutton
        $self configurelist $args
        pack $win.lbl $win.cancel -side left -padx 4
    }

    method show {} {
        place $win -in $options(-parent) -relx 0.5 -y 8 -anchor n
    }

    method hide {} {
        place forget $win
    }
}
