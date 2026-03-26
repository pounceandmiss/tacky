package require control
package require snit

# Scroll-driven message loading algorithm
# ========================================
#
# The chat display is a virtualized window over the full message history.
# Only a slice of messages is kept in the text widget at any time. As the
# user scrolls, old messages are loaded on demand and distant ones are
# cleaned up to bound memory usage.
#
# Two cooperating types implement this:
#
#   chatarea  — the GUI layer (text widget). Knows about pixels, not history.
#   chatview  — the controller. Bridges chatarea's pixel-based needs to the
#               Client's history API.
#
# The pixel model
# ---------------
# chatarea tracks two values: PixelsAbove (content above the visible
# viewport) and PixelsBelow (content below it). These are measured on
# every scroll event and widget-view-sync, coalesced via [after idle].
#
# Three thresholds govern the behavior:
#
#   -load-threshold (default 500px)
#       When PixelsAbove or PixelsBelow drops below this, the chatarea is
#       "thirsty" for that direction and fires -thirst-command.
#
#   -clean-threshold (default 5000px)
#       When PixelsAbove or PixelsBelow exceeds this, messages at that
#       edge are deleted to free memory.
#
#   -clean-target (default 2500px)
#       During cleaning, messages are deleted until pixels drop to this
#       level (midpoint between load and clean thresholds).
#
# The cycle
# ---------
#  1. User scrolls (or widget syncs after insert).
#  2. <<Yview>> / <<WidgetViewSync>> fires → Cleanup is scheduled
#     [after idle] (coalesced: only one DoCleanup per idle cycle).
#  3. DoCleanup runs:
#     a. Measures PixelsAbove and PixelsBelow.
#     b. CLEAN phase — for each direction where pixels exceed
#        -clean-threshold, delete messages from that edge one by one
#        until pixels drop to -clean-target.
#     c. THIRST phase — for each direction where pixels are below
#        -load-threshold AND that direction was NOT just cleaned,
#        fire -thirst-command with {directions} and thirsty=yes.
#        (The "not just cleaned" guard prevents load→clean→load loops.)
#  4. chatview receives -thirst-command via OnThirst:
#     - If thirsty=yes and no load is already in flight for that
#       direction, starts an async history request (oldest/newest
#       message ID as the cursor).
#     - If thirsty=no, cancels any in-flight load for that direction.
#     - Duplicate calls while a load is in flight are ignored (the
#       LoadToken dict tracks what's active as a boolean).
#  5. History results arrive via OnLoadDone → ProcessBatch → apply:
#     a. The LoadToken for that direction is cleared.
#     b. Messages are inserted into chatarea via the prev-based rule
#        (see "Universal insertion rule" below).
#     c. [compensate] wraps the entire apply loop — it's a no-op for
#        below-viewport inserts, adjusts for above-viewport inserts.
#     d. The insert changes the text geometry, which triggers
#        <<WidgetViewSync>> → back to step 2.
#
# Universal insertion rule (chatarea apply)
# ------------------------------------------
# Every batch of messages passes through one generic loop:
#
#   for each message:
#     if already displayed → patch prev (hollow updates prev pointer)
#     if no body           → skip (hollow targeting non-displayed msg)
#     if some displayed message's prev == this id → insert before it
#     if this message's prev is displayed → insert after it
#     if widget empty → insert at end (bootstrap)
#     otherwise → skip (can't connect — silently discarded)
#
# This handles all directions, dedup, and staleness uniformly.
# A bidict (bidirectional map) tracks id→prev and prev→id for O(1)
# lookups in both directions.
#
# Staleness is handled by the rule itself: if the user scrolled away
# and the cursor message was cleaned, the batch can't connect to any
# displayed message and is silently discarded — no generation tokens
# or explicit guards needed.  Tag-based cancel (-tag $win/$dir) is
# an optional optimization to save backend work.
#
# Steady state
# ------------
# The user sees a smooth scroll. When they approach either edge of the
# loaded window, new messages appear seamlessly. When they scroll far
# from an edge, distant messages are pruned. The text widget never holds
# more than roughly -clean-threshold pixels of off-screen content in
# either direction.
#
# Live incoming messages
# ----------------------
# New messages arriving from the network bypass the thirst mechanism.
# chatview subscribes to <Received> events for its JID and feeds
# them through ProcessBatch → apply. The prev rule handles dedup
# (already-displayed → patch) and connectivity. After insert, the
# view scrolls to the end if the user was already at the bottom.
#
# Catchup and goto
# -----------------
# At connect, the backend runs a MAM catchup that silently syncs recent
# messages into the local DB (no per-message <Received> events).  When
# catchup completes it emits <CatchupDone>.  chatview listens for this
# and calls `goto end`, which clears the widget and runs InitialLoad to
# reload the newest messages from local store.
#
# `goto` supports three modes:
#   goto end             — clear and reload from the bottom (InitialLoad).
#   goto $ts             — local: getAround from local store, scroll to
#                          nearest.  If anchor is already visible, just scrolls.
#   goto $ts -source remote — MAM fetch from $ts, store, getAround, display.

snit::widgetadaptor chatview {
    # dict: old 0 / new 0 — prevents duplicate history requests (boolean)
    variable LoadToken

    # set of jids tracked via avatarcache
    variable TrackedAvatars

    delegate method messages to hull
    delegate method {see *} to hull using {%c see %m}
    delegate method {highlight *} to hull using {%c highlight %m}
    delegate method system to hull

    option -acc -readonly yes
    option -jid
    option -menubar -default ""

    variable WasAtEnd
    variable IsMuc
    variable ScrollBtnVisible

    constructor args {
        installhull using chatarea -thirst-command [mymethod OnThirst] \
            -avatar-release-command [mymethod OnAvatarRelease]
        $self configurelist $args
        set WasAtEnd 1
        set ScrollBtnVisible 0
        set IsMuc [expr {[jid query $options(-jid)] eq "join"}]
        set TrackedAvatars [list]
        set LoadToken [dict create old 0 new 0]
        ::tacky listen -tag $win message <Received> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnLiveMessage]
        ::tacky listen -tag $win message <Sent> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnLiveMessage]
        ::tacky listen -tag $win message <Patch> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnLivePatch]
        ::tacky listen -tag $win message <CatchupDone> \
            -acc $options(-acc) [mymethod OnCatchupDone]
        bind $self <<MessageRightClick>> [mymethod OnMessageRightClick %d %X %Y]
        if {$options(-menubar) ne ""} {
            $self InstallMenus
        }
        ttk::button $win.scrollbtn -image mate/22x22/actions/go-down \
            -style Toolbutton -command [mymethod ScrollToBottom]
        bind $win.scrollbtn <Button-4> [list event generate $win.text <Button-4>]
        bind $win.scrollbtn <Button-5> [list event generate $win.text <Button-5>]
        bind $win.scrollbtn <MouseWheel> [list event generate $win.text <MouseWheel> -delta %D]
        bind $win.text <<Yview>> +[mymethod OnScroll]
        bind $win.text <Configure> [mymethod OnFirstConfigure]
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
        if {[dict get $LoadToken new]} return
        dict set LoadToken new 1
        ::tacky message history -acc $options(-acc) \
            -chat $options(-jid) -limit 50 \
            -tag $win/new -command [mymethod OnInitialLoadDone]
    }

    method OnInitialLoadDone {messages} {
        dict set LoadToken new 0
        $self ProcessBatch $messages
        $self UpdateWasAtEnd
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
        $self HideLoading
        set defaults [dict create -source local]
        set opts [dict merge $defaults $args]
        set source [dict get $opts -source]

        foreach tag [list $win/goto $win/old $win/new] {
            ::tacky unlisten $tag
            ::tacky message cancel -acc $options(-acc) -tag $tag
        }

        if {$target eq "end"} {
            # Reset to "bottom of conversation" — same as initial open
            $hull clear
            set LoadToken [dict create old 0 new 0]
            $self InitialLoad
            return
        }

        if {$source eq "remote"} {
            $self ShowLoading
        }
        ::tacky message goto -acc $options(-acc) \
            -chat $options(-jid) -date $target -source $source \
            -limit 50 -tag $win/goto \
            -command [mymethod OnGotoDone]
    }

    method OnGotoDone {result} {
        $self HideLoading
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
        set LoadToken [dict create old 0 new 0]
        $self ProcessBatch $messages
        $self UpdateWasAtEnd
        if {$anchor ne "" && $anchor in [$hull messages ids]} {
            $hull see message $anchor
        }
    }

    method ShowLoading {} {
        set f $win.loading
        if {[winfo exists $f]} return
        ttk::frame $f
        ttk::label $f.lbl -text "Loading\u2026"
        ttk::button $f.cancel -text "Cancel" -style Toolbutton \
            -command [mymethod CancelGoto]
        pack $f.lbl $f.cancel -side left -padx 4
        place $f -in $win.text -relx 0.5 -y 8 -anchor n
    }

    method HideLoading {} {
        if {[winfo exists $win.loading]} {
            destroy $win.loading
        }
    }

    method CancelGoto {} {
        ::tacky unlisten $win/goto
        ::tacky message cancel -acc $options(-acc) -tag $win/goto
        $self HideLoading
    }

    method OnCatchupDone {ev} {
        if {$IsMuc} return
        $self goto end
    }

    method OnThirst {directions thirsty oldest newest} {
        if {$thirsty && $oldest eq "" && $newest eq ""} return
        foreach dir $directions {
            if {$thirsty} {
                if {[dict get $LoadToken $dir]} continue
                dict set LoadToken $dir 1
                set region [$hull messages regionForDirection $dir]
                if {$dir eq "old"} {
                    ::tacky message history -acc $options(-acc) \
                        -chat $options(-jid) \
                        -before $oldest -region $region -limit 50 \
                        -tag $win/$dir -command [mymethod OnLoadDone $dir]
                } else {
                    ::tacky message history -acc $options(-acc) \
                        -chat $options(-jid) \
                        -after $newest -region $region -limit 50 \
                        -tag $win/$dir -command [mymethod OnLoadDone $dir]
                }
            } else {
                dict set LoadToken $dir 0
                catch {::tacky unlisten $win/$dir}
                ::tacky message cancel -acc $options(-acc) -tag $win/$dir
            }
        }
    }

    method OnLoadDone {direction messages} {
        dict set LoadToken $direction 0
        if {$direction eq "old"} {
            set messages [lreverse $messages]
        }
        set atEnd [$hull atEnd]
        $self ProcessBatch $messages
        $self UpdateWasAtEnd
        if {$direction eq "new" && $atEnd} {
            $hull see end
        }
    }

    method OnLiveMessage {ev} {
        set messages [dict get $ev -messages]
        set atEnd [$hull atEnd]
        $self ProcessBatch $messages
        $self UpdateWasAtEnd
        if {$atEnd} { $hull see end }
    }

    method OnLivePatch {ev} {
        set messages [dict get $ev -messages]
        foreach msg $messages {
            set ts [dict get $msg timestamp]
            if {[dict exists $msg newtimestamp]} {
                # Timestamp change: grab stored dict, update, re-insert
                set newTs [dict get $msg newtimestamp]
                if {$ts in [$hull messages ids]} {
                    set storeDict [$hull messages get $ts]
                    $hull deleteById $ts
                    dict set storeDict timestamp $newTs
                    dict set storeDict server_status [dict get $msg server_status]
                    dict set storeDict prev [dict get $msg prev]
                    if {[dict exists $msg region]} {
                        dict set storeDict region [dict get $msg region]
                    }
                    $self ProcessBatch [list $storeDict]
                }
            } else {
                dict set msg id $ts
                $hull apply [list $msg]
            }
        }
    }

    method OnScroll {} {
        $self UpdateWasAtEnd
    }

    method UpdateWasAtEnd {} {
        set newest [$hull messages newest]
        set dbNewest [::tacky chats maxTimestamp \
            -acc $options(-acc) -chat $options(-jid)]
        set hasNewest [expr {$newest ne "" && $newest eq $dbNewest}]
        set WasAtEnd [expr {$hasNewest && [$hull atEnd]}]
        $self UpdateScrollBtn
    }

    method UpdateScrollBtn {} {
        if {!$WasAtEnd == $ScrollBtnVisible} return
        set ScrollBtnVisible [expr {!$WasAtEnd}]
        if {$ScrollBtnVisible} {
            place $win.scrollbtn -in $win.text \
                -relx 1.0 -rely 1.0 -anchor se -x -24 -y -8
            raise $win.scrollbtn
        } else {
            place forget $win.scrollbtn
        }
    }

    method ScrollToBottom {} {
        $self goto end
    }

    method EnrichMessage {storeDict} {
        enrich_store_message $storeDict $IsMuc
    }

    method ProcessBatch {messages} {
        set enriched {}
        foreach msg $messages {
            if {[dict exists $msg hollow]} {
                lappend enriched [dict create \
                    id [dict get $msg timestamp] \
                    prev [expr {[dict exists $msg prev] ? [dict get $msg prev] : ""}] \
                    hollow 1]
                continue
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
    # Insert messages using the universal prev-based rule.
    # Each message must have id, prev, and body (or just id+prev for hollow).
    $chatview apply $messageDictList
    $chatview message edit $id $messageDict
    $chatview message delete id $id
    $chatview message delete position $pos
}


image create photo image/mate/48x48/emblems/emblem-downloads.png -file /usr/share/icons/mate/22x22/emblems/emblem-downloads.png

image create photo mate/22x22/status/avatar-default.png -file /usr/share/icons/mate/22x22/status/avatar-default.png
image create photo mate/32x32/status/avatar-default.png -file /usr/share/icons/mate/32x32/status/avatar-default.png

image create photo mate/32x32/status/stock_lock.png -file /usr/share/icons/mate/32x32/status/stock_lock.png


snit::widget chatarea {
    hulltype ttk::frame
    component text
    component scrollbar
    
    # Might be useful for debugging: Global vars that will be set to
    # latest calculated numbers of pixels above and below the viewport
    option -pixelsabovevariable
    option -pixelsbelowvariable

    # These are minimum values; DoCleanup scales them up to
    # viewport-relative multiples (2x for load, 10x/5x for clean)
    # so fetching starts well before the user reaches the edge.

    # When the number of pixels in any direction exceeds
    # -clean-threshold, some messages will be erased
    option -clean-threshold -default 5000

    # When the number of pixels in any direction is less that
    # -load-threshold, some messages will be loaded
    option -load-threshold -default 500

    # When cleaning, delete messages until pixels drop to this level
    # (midpoint between load and clean thresholds)
    option -clean-target -default 2500

    # Callback invoked whenever there's less pixels above or below the
    # viewport than -load-threshold
    option -thirst-command -default control::no-op

    # Callback invoked when a culled/deleted message was the last one
    # displaying a given avatar JID. Called as: {*}$cmd $avatarJid
    option -avatar-release-command -default ""

    # Virtual events
    # <<MessageRightClick>> — fired on the chatarea frame when a message
    #   is right-clicked. -data is the message ID. Standard event fields
    #   %x, %y (widget-relative) and %X, %Y (screen coords) are set.
    #   Not fired if the click lands on empty space.

    # list of ids of all messages currently drawn on text
    # top to bottom, oldest to newest
    variable MessageIds

    # bidict: id → prev (forward), prev → id (reverse)
    variable Prevs

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
        set Prevs [bidict new]

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

    # Might-be pitfall about ordering:
    # While timestamp+prev is the ultimate source of truth, here we
    # just assume the backend also ordered the list correctly - which
    # the backend indeed currently does and it's covered by tests. If
    # the backend somehow sent messages out of order, we'd SILENTLY
    # DROP a message - just something to keep in mind. If there ever
    # arises a case where the backend could send the list out of order
    # - we'd have to rework this.
    method apply {messageDictList} {
        set inserted {}
        compensate $text {
            foreach msg $messageDictList {
                set id [dict get $msg id]
                set prev [expr {[dict exists $msg prev] ? [dict get $msg prev] : ""}]

                if {$id in $MessageIds} {
                    # Already displayed — patch fields
                    $self PatchMessage $id $msg
                    continue
                }

                if {[dict exists $msg hollow]} {
                    # Hollow targeting non-displayed msg — skip
                    continue
                }

                if {[bidict rexists $Prevs $id]} {
                    # Some displayed message claims this id as its prev
                    # → insert before that message
                    set target [bidict rget $Prevs $id]
                    $self InsertAt $target before $msg
                    lappend inserted $id
                } elseif {$prev ne "" && $prev in $MessageIds} {
                    # This message's prev is displayed → insert after it
                    $self InsertAt $prev after $msg
                    lappend inserted $id
                } elseif {[llength $MessageIds] == 0} {
                    # Bootstrap: empty widget
                    $self InsertAt "" end $msg
                    lappend inserted $id
                } else {
                    # can't connect — silently skip
                }
            }
        }

        return $inserted
    }

    method PatchMessage {id patchDict} {
        if {[dict exists $patchDict prev]} {
            set Prevs [bidict set $Prevs $id [dict get $patchDict prev]]
        }
        if {[dict exists $patchDict server_status]} {
            $self receipt update $id [dict get $patchDict server_status]
        }
    }

    method InsertAt {targetId position msg} {
        set id [dict get $msg id]
        set prev [expr {[dict exists $msg prev] ? [dict get $msg prev] : ""}]

        switch -- $position {
            before {
                set idx [lsearch -exact $MessageIds $targetId]
                set MessageIds [linsert $MessageIds $idx $id]
                $text mark set msgins item.$targetId.first
            }
            after {
                set idx [lsearch -exact $MessageIds $targetId]
                set MessageIds [linsert $MessageIds [expr {$idx + 1}] $id]
                $text mark set msgins item.$targetId.last
            }
            end {
                lappend MessageIds $id
                $text mark set msgins end
            }
        }

        set Prevs [bidict set $Prevs $id $prev]
        $self DrawMessage msgins $msg
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
        $text tag configure entity.overstrike -overstrike yes
        $text configure -font $font
        $text tag configure entity.bold -font "$font bold"
        $text tag configure entity.italic -font "$font italic"
        $text tag configure entity.monospace -font "Courier 13"
        $text tag configure entity.preformatted -font "Courier 13"
        $text tag configure entity.bold.italic -font "$font bold italic"
        $text tag configure entity.bold.monospace -font "Courier 13 bold"
        $text tag configure entity.italic.monospace -font "Courier 13 italic"
        $text tag configure entity.bold.italic.monospace -font "Courier 13 bold italic"
        $text tag configure entity.bold.overstrike -font "$font bold" -overstrike yes
        $text tag configure entity.italic.overstrike -font "$font italic" -overstrike yes
        $text tag configure entity.bold.italic.overstrike -font "$font bold italic" -overstrike yes
        $text tag configure entity.monospace.overstrike -font "Courier 13" -overstrike yes
        $text tag configure entity.bold.monospace.overstrike -font "Courier 13 bold" -overstrike yes
        $text tag configure entity.italic.monospace.overstrike -font "Courier 13 italic" -overstrike yes
        $text tag configure entity.bold.italic.monospace.overstrike -font "Courier 13 bold italic" -overstrike yes
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
        if {$vh > 0} {
            set loadTh      [expr {max($options(-load-threshold), $vh * 2)}]
            set cleanTh     [expr {max($options(-clean-threshold), $vh * 10)}]
            set cleanTarget [expr {max($options(-clean-target), $vh * 5)}]
        } else {
            set loadTh      $options(-load-threshold)
            set cleanTh     $options(-clean-threshold)
            set cleanTarget $options(-clean-target)
        }

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
            {*}$options(-thirst-command) $cleaned no \
                [lindex $MessageIds 0] [lindex $MessageIds end]
        }

        # Don't fire thirst for a direction we just cleaned —
        # that would cause a load→clean→load loop.
        set thirstDirections ""
        if {$PixelsAbove < $loadTh && "old" ni $cleaned} {
            lappend thirstDirections old
        }
        if {$PixelsBelow < $loadTh && "new" ni $cleaned} {
            lappend thirstDirections new
        }
        if {$thirstDirections ne "" } {
            {*}$options(-thirst-command) $thirstDirections yes \
                [lindex $MessageIds 0] [lindex $MessageIds end]
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

    # Find region for pagination: scan displayed messages for the
    # first (old) or last (new) non-outgoing region.
    method {messages regionForDirection} {dir} {
        if {$dir eq "old"} {
            foreach id $MessageIds {
                if {[dict exists $Messages $id]} {
                    set r [dict get [dict get $Messages $id] region]
                    if {$r != -1} { return $r }
                }
            }
        } else {
            foreach id [lreverse $MessageIds] {
                if {[dict exists $Messages $id]} {
                    set r [dict get [dict get $Messages $id] region]
                    if {$r != -1} { return $r }
                }
            }
        }
        return -1
    }

    method clear {} {
        $text del 0.0 end
        set MessageIds {}
        set HighlightedId ""
        set Prevs [bidict new]
        set Messages [dict create]
        if {$options(-avatar-release-command) ne ""} {
            set released {}
            dict for {mid ajid} $MessageAvatars {
                if {$ajid ni $released} {
                    lappend released $ajid
                    {*}$options(-avatar-release-command) $ajid
                }
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

    method ReceiptText {status} {
        switch -- $status {
            received { return "\u2713" }
            read     { return "\u2713\u2713" }
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
            $text ins msgins $message(display_name) [list $tag $tag.author author]
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
        set Prevs [bidict unset $Prevs $id]
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
        set Prevs [bidict unset $Prevs $id]
        if {[dict exists $Messages $id]} {
            dict unset Messages $id
        }
        $self CheckAvatarRelease $id
    }

    method CheckAvatarRelease {id} {
        if {$options(-avatar-release-command) eq ""} return
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
proc enrich_store_message {storeDict isMuc} {
    set fromJid [dict get $storeDict from_jid]
    set res [jid resource $fromJid]
    if {$res eq ""} {
        set res [jid bare $fromJid]
    }
    if {$isMuc} {
        set avatarJid $fromJid
    } else {
        set avatarJid [jid bare $fromJid]
    }
    set serverStatus [dict get $storeDict server_status]
    set isOutgoing [expr {$serverStatus ne ""}]
    set prev [expr {[dict exists $storeDict prev] ? [dict get $storeDict prev] : ""}]
    set region [expr {[dict exists $storeDict region] ? [dict get $storeDict region] : -1}]
    set d [dict create \
        id           [dict get $storeDict timestamp] \
        display_name $res \
        avatar_jid   $avatarJid \
        timestamp    [dict get $storeDict timestamp] \
        body         [dict get $storeDict body] \
        is_outgoing  $isOutgoing \
        server_status $serverStatus \
        prev         $prev \
        region       $region]
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
