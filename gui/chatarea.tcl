package require control
package require snit

# Scroll-driven message loading.
#
# The text widget holds only a slice of the conversation, not the full history.
# As the user scrolls toward an edge the next batch is loaded on demand, and
# messages far from the viewport are culled to bound memory. Two layers:
#
#   chatarea  the GUI layer built on Tk text. Measures pixels and emits
#             direction+edge signals when its loaded window runs thin or fat.
#             Knows nothing about history.
#   chatview  the controller (chatview.tcl). Turns those signals into history
#             requests against the Client API and feeds the results back here.
#
# chatarea measures the content above and below the viewport on every scroll
# event and widget-view-sync; slicepolicy turns those numbers into the load
# and cull decisions, and chatarea carries them out.
snit::widget chatarea {
    hulltype ttk::frame
    component text
    component scrollbar
    component scrollbtn -public scrollbtn
    component loading   -public loading
    component policy

    delegate option -scrollbtn-command      to scrollbtn as -command
    delegate option -loading-cancel-command to loading   as -cancel-command

    # The load/clean/clean-target thresholds; see slicepolicy.
    delegate option -clean-factor           to policy
    delegate option -clean-threshold        to policy
    delegate option -load-factor            to policy
    delegate option -load-threshold         to policy
    delegate option -clean-target-factor    to policy
    delegate option -clean-target-threshold to policy
    delegate option -thirst-command         to policy

    delegate option -cull-command           to policy

    # The avatar image to draw for a JID, as {*}$cmd $jid. Returning "" (which
    # the default does) draws the placeholder, so an area with no avatars wired
    # up still renders.
    option -avatar-image-command -default control::no-op

    # Fires when the last message displaying a given avatar JID was just
    # removed. Called as: {*}$cmd $avatarJid, so whatever supplies the images
    # can stop following that JID.
    option -avatar-release-command -default control::no-op

    # Where the rendered attachment widgets send what the user asked for. The
    # action leads, so a single object with these methods can be the whole
    # callback:
    #   {*}$cmd open       $url            download (cached) and open with the OS
    #   {*}$cmd save       $url $filename  download (cached) and copy to a path
    #   {*}$cmd openfolder $url            show the cached file in its folder
    #   {*}$cmd uncache    $url            delete the cached copy from disk
    #   {*}$cmd load       $url $key $idx  (re)fetch an image thumbnail
    #   {*}$cmd retry      $key            retry a failed upload
    #   {*}$cmd cancel     $direction $url $key   abort a transfer in flight
    option -attachment-command -default control::no-op

    # Virtual events. Both carry the caller's key in -data, never the slot,
    # and neither fires when the click lands on empty space.
    # <<MessageClick>> - a message was left-clicked. %x, %y are set.
    # <<MessageRightClick>> - a message was right-clicked. %x, %y
    #   (widget-relative) and %X, %Y (screen coords) are set.

    # Every message currently drawn, top to bottom (oldest to newest). rowlist
    # owns slot, key and sort; the fields chatarea attaches to each row are:
    #   server_status  \ merged in place by patchFields, so a single-axis
    #   remote_status  / patch keeps the other axis.
    #   avatar_jid     which avatar this row draws.
    #   payload        handed back verbatim by `messages get`.
    component rows

    # Slot of the currently highlighted message (search result), or ""
    variable HighlightedSlot

    constructor args {
        install text using chattext $win.text \
            -yscrollcommand [list $win.scrollbar set]
        install scrollbar using ttk::scrollbar $win.scrollbar\
            -command [list $win.text yview]
        install scrollbtn using chatscrollbtn $win.scrollbtn \
            -parent $win.text
        install loading using chatloading $win.loading \
            -parent $win.text
        install rows using rowlist ${selfns}::rows
        install policy using slicepolicy ${selfns}::policy \
            -measure-command [mymethod Measure] \
            -rowcount-command [list $rows size] \
            -drop-command [mymethod DropEdge] \
            -edgekey-command [mymethod EdgeKey]

        $self configurelist $args

        grid $win.text $win.scrollbar -sticky nsew
        grid rowconfigure $win $win.text -weight 1
        grid columnconfigure $win $win.text -weight 1

        set HighlightedSlot ""

        # Configure text tags and fonts
        $self SetFont
        # Track scrolling to load more messages
        bind $win.text <<WidgetViewSync>> [mymethod OnWidgetViewSync %d]
        bind $win.text <<Yview>> [mymethod OnYview]
        bind $win.text <Button-1> [mymethod OnClick %x %y]
        bind $win.text <Button-3> [mymethod OnRightClick %x %y %X %Y]

    }

    destructor {
        $policy cancel
    }

    # What slicepolicy asks us for: pixels of content outside the viewport,
    # the viewport's own height, which row sits at an edge, and its removal.
    method Measure {what} {
        if {![winfo exists $win]} { return 0 }
        switch -- $what {
            above  { return [$text count -ypixels 0.0 @0,0] }
            below  { return [$text count -ypixels @0,[winfo height $text] end-1line] }
            height { return [winfo height $text] }
        }
    }

    method DropEdge {direction} {
        $self deleteByPos [expr {$direction eq "old" ? 0 : "end"}]
    }

    method EdgeKey {direction} {
        set row [$rows at [expr {$direction eq "old" ? 0 : "end"}]]
        if {$row eq ""} { return "" }
        dict get $row key
    }

    # Insert each message at its sorted position, returning the keys that drew
    # a new row. Callers supply `key` (identity) and `sort` (position); an
    # already-displayed key gets its fields patched in place instead.
    # Staleness is handled outside this method (see OnCulled for history
    # requests, AtTail for live events).
    method apply {messageDictList} {
        set inserted {}
        compensate $text {
            foreach msg $messageDictList {
                if {[$self ApplyOne $msg]} {
                    lappend inserted [dict get $msg key]
                }
            }
        }
        return $inserted
    }

    # Redraw the row for $key from a fresh message dict. It keeps its place
    # unless the new `sort` moves it, and the dict may carry a different `key`:
    # a message the server relocated keeps its row, not its identity.
    method replace {key msg} {
        if {[$rows index $key] < 0} return
        set ajid [$rows field $key avatar_jid]
        compensate $text {
            $self Erase [$rows remove $key]
            $self ApplyOne $msg
        }
        # Deferred until the row is back: releasing between the erase and the
        # redraw would drop the avatar image the redraw is about to draw.
        $self CheckAvatarRelease $ajid
    }

    # Draw one message. A key already on screen has its fields patched in
    # place; anything else is inserted. Returns 1 when a new row was drawn.
    method ApplyOne {msg} {
        set key [dict get $msg key]
        set sort [dict get $msg sort]

        if {[$rows index $key] >= 0} {
            $self patchFields $key $msg
            return 0
        }

        # Draw in front of the first row sorting after this one, or at the end
        # when there is none.
        set successor [$rows successor $key $sort]
        if {$successor eq ""} {
            $text mark set msgins end
        } else {
            $text mark set msgins item.$successor.first
        }

        set slot [$rows insert $key $sort [dict create \
            server_status [dict getdef $msg server_status ""] \
            remote_status [dict getdef $msg remote_status none] \
            avatar_jid [dict getdef $msg avatar_jid ""] \
            payload [dict getdef $msg payload ""]]]

        # On a failed draw, roll back the partial content (tagged item.$slot)
        # and leave a placeholder so the batch continues.
        if {[catch {$self DrawMessage msgins $slot $msg} err]} {
            catch {$text del item.$slot.first item.$slot.last}
            catch {jlog error "DrawMessage failed for $key: $err" -obj chatarea}
            $self DrawErrorPlaceholder msgins $slot
        }
        return 1
    }

    method patchFields {key patchDict} {
        if {![dict exists $patchDict server_status]
                && ![dict exists $patchDict remote_status]} return
        if {[$rows index $key] < 0} return
        # Merge onto the row so a single-axis patch keeps the other axis.
        set patch [dict create]
        foreach k {server_status remote_status} {
            if {[dict exists $patchDict $k]} {
                dict set patch $k [dict get $patchDict $k]
            }
        }
        $rows merge $key $patch
        $self receipt update $key [$rows field $key server_status] \
            [$rows field $key remote_status]
    }

    method OnYview {} {
        $policy schedule
    }

    method OnWidgetViewSync synced {
        if {!$synced} {
            return
        }
        $policy schedule
    }

    # The key of the row under these widget-relative coords, or "".
    method KeyAt {x y} {
        foreach tag [$text tag names @$x,$y] {
            if {[string match "item.*" $tag] && ![string match "item.*.*" $tag]} {
                set key [$rows keyof [string range $tag 5 end]]
                if {$key ne ""} { return $key }
            }
        }
        return ""
    }

    method OnClick {x y} {
        set key [$self KeyAt $x $y]
        if {$key eq ""} return
        event generate $win <<MessageClick>> -data $key -x $x -y $y
    }

    method OnRightClick {x y X Y} {
        set key [$self KeyAt $x $y]
        if {$key eq ""} return
        event generate $win <<MessageRightClick>> \
            -data $key -x $x -y $y -rootx $X -rooty $Y
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

    method {see message} {key} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        $self highlight message $key
        $text yview item.$slot.first
    }

    method {highlight message} {key} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        $self highlight clear
        $text tag configure item.$slot -background yellow
        set HighlightedSlot $slot
    }

    # Mark every occurrence of $pattern within one row's body. Independent of
    # `highlight message`: that picks out a whole row, this picks out text
    # inside one. Cleared with the row, so a caller that re-runs a search
    # clears first.
    method {highlight matches} {key pattern} {
        set slot [$rows slot $key]
        if {$slot eq "" || $pattern eq ""} return
        if {[catch {$text index item.$slot.body.first} pos]} return
        set last item.$slot.body.last
        while 1 {
            set pos [$text search -nocase -count n -- $pattern $pos $last]
            if {$pos eq ""} break
            $text tag add search_match $pos "$pos + $n chars"
            set pos "$pos + $n chars"
        }
    }

    method {highlight clear} {} {
        if {$HighlightedSlot ne ""} {
            $text tag configure item.$HighlightedSlot -background {}
            set HighlightedSlot ""
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
        # Search hits inside a body; see `highlight matches`.
        $text tag configure search_match -background yellow -font "$font bold"
        $text tag configure timestamp -foreground #888888 -font "Helvetica 10"
        $text tag configure system -foreground gray50 -font "$font italic" \
            -justify center -lmargin1 20 -lmargin2 20 -rmargin 20
        $text tag configure drawerror -foreground #b04040 \
            -font "$font italic" -lmargin1 40 -lmargin2 40 -spacing3 6
        # XEP-0308 "(edited)" marker and XEP-0424/0425 retraction tombstone
        $text tag configure edited -foreground #888888
        $text tag configure tombstone -foreground gray50 -font "$font italic"
    }

    method {messages oldest} {} { $self EdgeKey old }
    method {messages newest} {} { $self EdgeKey new }

    # The text widget itself, for the things only it can do: searching its
    # content, tagging a range, accepting a file drop. Everything addressed by
    # message key goes through the methods above instead.
    method textwidget {} { return $text }

    method {messages keys} {} { $rows keys }
    method {messages has} {key} { expr {[$rows index $key] >= 0} }

    # Whatever the caller attached as `payload` when the row was applied.
    method {messages get} {key} { $rows field $key payload }

    # The text tag covering one row, or "" when it isn't drawn.
    method {messages tag} {key} {
        set slot [$rows slot $key]
        if {$slot eq ""} { return "" }
        return item.$slot
    }

    # Text indices spanning one row's body, as {first last}, or "" when the
    # row isn't drawn.
    method {messages body-range} {key} {
        set slot [$rows slot $key]
        if {$slot eq ""} { return "" }
        if {[catch {$text index item.$slot.body.first} first]} { return "" }
        return [list $first [$text index item.$slot.body.last]]
    }

    method clear {} {
        $text del 0.0 end
        set released {}
        foreach row [$rows clear] {
            set ajid [dict get $row avatar_jid]
            if {$ajid ne "" && $ajid ni $released} {
                lappend released $ajid
                {*}$options(-avatar-release-command) $ajid
            }
        }
        set HighlightedSlot ""
    }
    
    # Repaint every avatar already drawn for this JID.
    method {avatar set} {jid image} {
        foreach {start end} [$text tag ranges from.$jid] {
            $text image configure $start -image $image
        }
    }

    # What to draw for an author, falling back to the placeholder for one with
    # no avatar of its own (or none fetched yet).
    method AvatarImage {jid} {
        if {$jid ne ""} {
            set image [{*}$options(-avatar-image-command) $jid]
            if {$image ne ""} { return $image }
        }
        return mate/32x32/status/avatar-default.png
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
    method ReceiptTags {slot serverStatus remoteStatus} {
        set tags [list item.$slot item.$slot.receipt receipt]
        if {$serverStatus eq "" && $remoteStatus eq "read"} {
            lappend tags receipt.read
        }
        return $tags
    }

    # Insert the receipt glyph at msgins.
    method DrawReceiptGlyph {slot serverStatus remoteStatus} {
        set rt [$self ReceiptText $serverStatus $remoteStatus]
        $text ins msgins " $rt" [$self ReceiptTags $slot $serverStatus $remoteStatus]
    }

    method {receipt update} {key serverStatus remoteStatus} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        set ranges [$text tag ranges item.$slot.receipt]
        if {[llength $ranges] == 0} return
        lassign $ranges start end
        set rt [$self ReceiptText $serverStatus $remoteStatus]
        $text replace $start $end " $rt" \
            [$self ReceiptTags $slot $serverStatus $remoteStatus]
    }

    # Swap the chip row in place; body stays put, viewport doesn't jump.
    method {reactions update} {key reactions} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        set payload [$rows field $key payload]
        if {$payload ne ""} {
            dict set payload reactions $reactions
            $rows merge $key [dict create payload $payload]
        }
        compensate $text {
            set ranges [$text tag ranges item.$slot.reactions]
            if {[llength $ranges] > 0} {
                lassign $ranges start end
                $text del $start $end
            }
            if {[dict size $reactions] > 0} {
                $text mark set msgins item.$slot.last
                $self DrawReactions $slot $key $reactions
            }
        }
    }

    # Draws message, doesn't store info about it, doesn't adjust the
    # text accordingly. Internal use only!
    method DrawMessage {textIndex slot messageDict} {
        array set message $messageDict
        $text mark set msgins $textIndex

        # text tag that will be applied to the whole message
        set tag item.$slot

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
            set imageId [$text image create msgins \
                -image [$self AvatarImage $avatarJid]]
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
                $self DrawReceiptGlyph $slot \
                    $message(server_status) $remoteStatus
            }
            $text ins msgins \n $tag

            # Formatting offsets index into the body. An empty body draws no
            # $tag.body characters, so $tag.body.first would not resolve -
            # skip rather than let the index lookup throw and abort the draw.
            if {[info exists message(formatting)]
                && [llength [$text tag ranges $tag.body]] > 0} {
                # Font-affecting styles must combine into one tag per run (Tk
                # fonts don't merge across tags); block styles apply as-is.
                set fontSpans {}
                set applied {}
                foreach {type offset length} $message(formatting) {
                    if {$type in {bold italic monospace overstrike}} {
                        lappend fontSpans $type $offset $length
                    } else {
                        lappend applied $type $offset $length
                    }
                }
                foreach {type offset length} \
                        [concat $applied [entitytags::combine $fontSpans]] {
                    $text tag add entity.$type \
                        "$tag.body.first + $offset chars" \
                        "$tag.body.first + $offset chars + $length chars"
                }
            }

            if {$hasAttachments} {
                set aidx 0
                foreach att $message(attachments) {
                    $self DrawAttachment $tag $slot $message(key) $aidx $att \
                        $message(server_status)
                    incr aidx
                }
                if {$message(is_outgoing)} {
                    # Receipt right of the last attachment, before its newline.
                    set lastWin $text.att_${slot}_[expr {$aidx - 1}]
                    $text mark set msgins "$lastWin + 1 chars"
                    $self DrawReceiptGlyph $slot \
                        $message(server_status) $remoteStatus
                }
            }

            if {[info exists message(reactions)]
                && [dict size $message(reactions)] > 0} {
                $text mark set msgins item.$slot.last
                $self DrawReactions $slot $message(key) $message(reactions)
            }
        }
    }

    # Chip row below a message; each chip is emoji + count, click toggles.
    # Tags ride on the slot; the toggle event carries the caller's key.
    method DrawReactions {slot key reactions} {
        set tag item.$slot
        set rtag item.$slot.reactions
        set i 0
        dict for {emoji info} $reactions {
            set count [llength [dict get $info reactors]]
            set bindTag $tag.react.[incr i]
            $text ins msgins " $emoji $count " \
                [list $tag $rtag reaction $bindTag]
            $text tag bind $bindTag <Button-1> \
                [list event generate $win <<ReactToggle>> \
                    -data [list $key $emoji]]
            $text ins msgins "  " [list $tag $rtag reaction]
        }
        $text ins msgins \n [list $tag $rtag reaction]
    }

    # Placeholder for a message that failed to draw. Field-free so it can't
    # fail itself; carries item.$slot so lookup and successor inserts work.
    method DrawErrorPlaceholder {textIndex slot} {
        $text mark set msgins $textIndex
        set tag item.$slot
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
    # row carries item.$slot so lookup and successor inserts still work.
    method DrawTombstone {messageDict tag} {
        array set message $messageDict
        set avatarJid [expr {[info exists message(avatar_jid)]
            ? $message(avatar_jid) : ""}]
        set imageId [$text image create msgins \
            -image [$self AvatarImage $avatarJid]]
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
    # `attachment image`/`attachment state` to it by key+idx. `status` is the
    # message's server_status, which seeds the upload-state row (progress bar
    # while 'uploading', Retry when 'failed').
    # The frame is named off the slot: a Tk widget path can't hold the dots a
    # key may contain. The widget's own -id stays the key, since that is what
    # rides back out through the callbacks.
    method DrawAttachment {tag slot key idx att status} {
        set f $text.att_${slot}_${idx}
        catch {destroy $f}
        attachment $f \
            -command [mymethod AttachmentAction] \
            -url [dict get $att url] -kind [dict get $att type] \
            -name [dict get $att name] -id $key -idx $idx \
            -scroll-target $text
        $text window create msgins -window $f -padx 40 -pady 2
        $text tag add $tag "msgins - 1 chars"
        $text ins msgins \n $tag
        switch -- $status {
            uploading { $self attachment state $key $idx upload active 0 0 }
            failed    { $self attachment state $key $idx upload failed 0 0 }
        }
    }

    # Forwarded rather than handed over directly so that reconfiguring the
    # option reaches attachments that are already drawn.
    method AttachmentAction {args} {
        {*}$options(-attachment-command) {*}$args
    }

    # Widget path of one attachment frame, or "" when it isn't drawn.
    method {attachment path} {key idx} {
        set slot [$rows slot $key]
        if {$slot eq ""} { return "" }
        return $text.att_${slot}_${idx}
    }

    # Forward a backend-produced thumbnail (already downscaled) to the widget.
    method {attachment image} {key idx path} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        set f $text.att_${slot}_${idx}
        if {![winfo exists $f]} return
        $f setImage $path
    }

    # Forward a transfer-progress update to the widget: a progress bar while
    # active, an error + Retry row on failure, removed on done or cancelled.
    method {attachment state} {key idx direction state loaded total} {
        set slot [$rows slot $key]
        if {$slot eq ""} return
        set f $text.att_${slot}_${idx}
        if {![winfo exists $f]} return
        $f setState $direction $state $loaded $total
    }

    method deleteById {key} { $self Delete [$rows remove $key] }

    method deleteByPos {idx} { $self Delete [$rows removeat $idx] }

    method Delete {row} {
        if {$row eq ""} return
        $self Erase $row
        $self CheckAvatarRelease [dict get $row avatar_jid]
    }

    # Erase what a row drew. The row must already be out of the list, so that
    # nothing resolves its slot to text that is no longer there.
    method Erase {row} {
        set slot [dict get $row slot]
        $text del item.$slot.first item.$slot.last
        $text tag delete item.$slot
    }

    method CheckAvatarRelease {ajid} {
        if {$ajid eq ""} return
        # Release only once no drawn message still references this avatar.
        if {[llength [$text tag ranges from.$ajid]] == 0} {
            {*}$options(-avatar-release-command) $ajid
        }
    }
}
