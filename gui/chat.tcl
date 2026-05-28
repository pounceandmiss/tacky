package require control
package require snit

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

    constructor args {
        installhull using chatarea \
            -thirst-command [mymethod OnThirsty] \
            -cull-command [mymethod OnCulled] \
            -avatar-release-command [mymethod OnAvatarRelease] \
            -scrollbtn-command [mymethod ScrollToBottom] \
            -loading-cancel-command [mymethod CancelGoto]
        $self configurelist $args
        set ViewAtTail 1
        # Empty display is vacuously at the tail; any live message
        # arriving before InitialLoad completes is the new tail.
        # InitialLoad / OnLoadDone(new) re-affirm; OnCulled(new) and
        # goto-non-end flip false.
        set AtTail 1
        set IsMuc [expr {[jid query $options(-jid)] eq "join"}]
        set Names [dict create]
        set TrackedAvatars [list]
        ::tacky listen -tag $win message <Received> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnMessage]
        ::tacky listen -tag $win message <Sent> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnMessage]
        ::tacky listen -tag $win message <Patch> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnPatch]
        ::tacky listen -tag $win message <CatchupDone> \
            -acc $options(-acc) [mymethod OnCatchupDone]
        ::tacky listen -tag $win author <Changed> \
            -acc $options(-acc) -chat $options(-jid) [mymethod OnAuthorChanged]
        ::tacky author get -acc $options(-acc) -chat $options(-jid) \
            -command [mymethod OnAuthorSeed]
        if {!$IsMuc} {
            ::tacky observe -tag $win setting <Changed> -key show_jid_in_1to1 \
                [mymethod OnShowJidSetting]
        }
        bind $self <<MessageRightClick>> [mymethod OnMessageRightClick %d %X %Y]
        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }
        bind $win.text <<Yview>> +[mymethod OnScroll]
        bind $win.text <Configure> [mymethod OnFirstConfigure]
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
    }

    destructor {
        foreach tag [list $win $win/goto $win/old $win/new] {
            catch {::tacky unlisten $tag}
            catch {::tacky message cancel -acc $options(-acc) -tag $tag}
        }
        catch {$self RemoveMenus}
        catch {$self UntrackAllAvatars}
    }

    method goto {target args} {
        $hull loading hide
        set defaults [dict create -source local]
        set opts [dict merge $defaults $args]
        set source [dict get $opts -source]

        foreach tag [list $win/goto $win/old $win/new] {
            ::tacky unlisten $tag
            ::tacky message cancel -acc $options(-acc) -tag $tag
        }

        if {$target eq "end"} {
            # Reset to "bottom of conversation" — same as initial open.
            # InitialLoad will flip AtTail back to true on completion.
            $hull clear
            set AtTail 0
            $self InitialLoad
            return
        }

        # Goto-around displays a slice centered on an anchor that
        # isn't the tail; live messages should not append until the
        # user explicitly rejoins the tail.
        set AtTail 0

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

    # Catchup messages now flow through <Received> under the AtTail
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
            # so subsequent <Received> events insert again. Comparing
            # to maxTimestamp is robust to changes in -limit.
            set newest [$hull messages newest]
            set dbNewest [::tacky chats maxTimestamp \
                -acc $options(-acc) -chat $options(-jid)]
            if {$newest ne "" && $newest eq $dbNewest} {
                set AtTail 1
            }
        }
        $self UpdateViewAtTail
        if {$direction eq "new" && $atEnd} {
            $hull see end
        }
    }

    # Live-message flow.
    #
    # <Received> / <Sent> arrive only after the backend persists the
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
    }

    method OnPatch {ev} {
        foreach msg [dict get $ev -messages] {
            set ts [dict get $msg timestamp]
            if {$ts ni [$hull messages ids]} continue
            if {[dict exists $msg newtimestamp]} {
                # Timestamp move: grab stored dict, update, re-insert
                set newTs [dict get $msg newtimestamp]
                set storeDict [$hull messages get $ts]
                $hull deleteById $ts
                dict set storeDict timestamp $newTs
                dict set storeDict server_status [dict get $msg server_status]
                $self ProcessBatch [list $storeDict]
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
        set dbNewest [::tacky chats maxTimestamp \
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

    method ProcessBatch {messages} {
        set enriched {}
        foreach msg $messages {
            set emsg [$self EnrichMessage $msg]
            set ajid [dict get $emsg avatar_jid]
            if {$ajid ne ""} {
                $self TrackAvatar $ajid
            }
            $hull messages store [dict get $emsg id] $msg
            lappend enriched $emsg
        }
        $hull apply $enriched
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
        $m add command -label "View XML" \
            -command [mymethod OnViewXml $id]
        $m add command -label "Find in Chat" \
            -command [list event generate $win <<FindInChat>>]
        tk_popup $m $rootX $rootY
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
                # it. If none, append. (Linear scan — windows are small.)
                set idx 0
                foreach existing $MessageIds {
                    if {$existing > $id} break
                    incr idx
                }
                if {$idx == [llength $MessageIds]} {
                    lappend MessageIds $id
                    $text mark set msgins end
                } else {
                    set successor [lindex $MessageIds $idx]
                    set MessageIds [linsert $MessageIds $idx $id]
                    $text mark set msgins item.$successor.first
                }
                $self DrawMessage msgins $msg
                lappend inserted $id
            }
        }

        return $inserted
    }

    method patchFields {id patchDict} {
        if {[dict exists $patchDict server_status]} {
            $self receipt update $id [dict get $patchDict server_status]
        }
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
        # Message body - bigger indent
        $text tag configure body -lmargin1 40 -lmargin2 40
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
        $text tag configure timestamp -foreground #888888
        $text tag configure system -foreground gray50 -font "$font italic" \
            -justify center -lmargin1 20 -lmargin2 20 -rmargin 20
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

    method ReceiptText {status} {
        switch -- $status {
            received { return "\u2713" }
            read     { return "\u2713\u2713" }
            failed   { return "!" }
            default   { return "" }
        }
    }

    method {receipt update} {id status} {
        set tag item.$id.receipt
        set ranges [$text tag ranges $tag]
        if {[llength $ranges] == 0} return
        lassign $ranges start end
        set rt [$self ReceiptText $status]
        $text replace $start $end " $rt" [list item.$id $tag receipt]
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
            $text ins msgins \n $tag
            
            $text ins msgins $message(body) [list $tag body message $tag.body]
            if {$message(is_outgoing)} {
                set rt [$self ReceiptText $message(server_status)]
                $text ins msgins " $rt" [list $tag $tag.receipt receipt]
            }
            $text ins msgins \n $tag
            
            if {[info exists message(formatting)]} {
                foreach {type offset length} $message(formatting) {
                    $text tag add entity.$type \
                        "$tag.body.first + $offset chars" \
                        "$tag.body.first + $offset chars + $length chars"
                }
            }
        }
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
    set isOutgoing [expr {$serverStatus ne ""}]
    set d [dict create \
        id           [dict get $storeDict timestamp] \
        from_jid     $fromJid \
        display_name $displayName \
        avatar_jid   $fromJid \
        timestamp    [dict get $storeDict timestamp] \
        body         [dict get $storeDict body] \
        is_outgoing  $isOutgoing \
        server_status $serverStatus]
    if {[dict exists $storeDict formatting]} {
        dict set d formatting [dict get $storeDict formatting]
    }
    return $d
}

proc list_remove_once_inplace {varName val} {
    upvar 1 $varName lst
    set idx [lsearch -exact $lst $val]
    if {$idx == -1} { return 0 }
    set lst [lreplace $lst $idx $idx]
    return 1
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
