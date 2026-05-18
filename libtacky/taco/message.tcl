# Durable message delivery
# ========================
#
# Message dict keys:
#   timestamp, chat_jid, from_jid, body, server_id, own_id,
#   raw_xml, server_status
#
# chat_jid assignment:
#   MUC groupchat:  room@muc?join   (appended by muc.say / OnGroupchatMessage)
#   MUC PM:         room@muc/nick   (set by OnPrivateMessage)
#   1:1 DM:         bare JID        (set by OnMessage from stanza @from)
#   MAM catchup:    derived from @from/@to vs own bare JID
#
# own_id:
#   own_id is only set for our outgoing messages (= timestamp = <message id>).
#   Incoming messages have own_id ""; MUC echo detected by nick match.
#   IsDuplicate matches by server_id or own_id (or content fallback).
#
# server_status lifecycle:
#   ""         incoming message (already delivered by definition)
#   "pending"  outgoing, stored locally, not yet confirmed by server
#   "received" server confirmed via MUC echo or SM ack
#
# === Outgoing: send ===
#
#   GUI/muc.say
#     → message.send -chat_jid $jid -body $text
#       1. ts = clock microseconds; own_id = ts
#       2. Derive type from chat_jid: ?join → groupchat, else → chat
#       3. Build stanza: <message to=$toJid type=$type id=$oid>
#       4. Store to DB: server_status=pending, server_id=""
#       5. Emit <Sent> → GUI displays immediately (optimistic)
#       6. $client write $stanza → to server
#          (if write throws, message is safe in DB for retry)
#
# === Confirmation path A: MUC echo ===
#
#   Server echoes <message> back with same @id
#     → muc.OnGroupchatMessage
#       → message.ingestLive
#         → ParseMessage: extracts server_id from <stanza-id>
#         → messagestore.store:
#           IsDuplicate finds pending row by own_id
#           UPDATE server_status='received', captures server_id
#           Returns confirmed list
#         → HandleConfirmation: emit <Patch> (GUI shows checkmark)
#         → No <Received> emitted (it's our own echo)
#
# === Confirmation path B: SM ack (1:1 and MUC) ===
#
#   Server sends <a h='N'/>
#     → sm: extracts acked stanzas from queue
#       → sm -ack-command
#         → conn.OnSmAck
#           → client.emit sm <Ack>
#             → client.emit intercepts, calls message.OnSmAck
#               → Extract @id from acked <message> stanzas
#               → messagestore.confirmByOwnIds:
#                 UPDATE server_status='received' WHERE pending
#               → Emit <Patch> per confirmed message
#
#   For MUC, both paths may fire — confirmation is idempotent
#   (second confirm finds no pending rows, does nothing).
#
# === Incoming ===
#
#   1:1: server stanza
#     → message.OnMessage
#       → message.ingestLive
#         → store: INSERT (server_status="")
#         → HandleInsertion: emit <Received> → GUI displays
#
#   MUC: server stanza
#     → muc.OnGroupchatMessage
#       → message.ingestLive (same path as above)
#
# === Sentinels ===
#
#   Sentinels mark "messages may exist here that we haven't fetched."
#   They're placed at moments of doubt:
#
#   - OnReady (reconnect): a `newer` sentinel after each chat's newest
#     pre-disconnect citizen, bracketing any history that arrived
#     while we were offline.
#   - OnFetch (MAM `complete=false`): a sentinel at the far edge of
#     the MAM response in the queried direction, signalling "more
#     server-side history exists past this point."
#
#   Sentinels are removed when their gap is proven empty:
#
#   - `store` overlap: a batch whose dups against pre-existing cache
#     prove the batch's bracket span has no gap — `store` sweeps any
#     sentinels in that span automatically.
#   - OnFetch sweep: after MAM stores a non-empty page, sweep any
#     sentinels strictly between the cursor and the batch's far edge
#     (RSM guarantees that range is server-contiguous).
#   - OnFetch RSM-complete: if the fetch was bounded by a sentinel on
#     the queried side and the server returns `complete=true`, the
#     bounding sentinel clears (direction proven exhausted).
#
# === Retry on reconnect ===
#
#   message.OnReady
#     → RetryPending: SELECT WHERE server_status='pending'
#       1:1 messages: resend immediately via RetrySend
#       MUC messages: stash in PendingRetry($roomJid)
#     → client.emit intercepts muc <Joined>
#       → message.OnMucJoined: flush PendingRetry for that room
#         → RetrySend: rebuild stanza with same own_id, $client write
#     → Echo/ack cycle confirms them normally
#
#   OnDisconnect clears PendingRetry (next OnReady re-queries DB).
#
# === GUI events ===
#
#   <Sent>      → OnMessage: insert message (is_outgoing=1, no checkmark)
#   <Received>  → OnMessage: insert message (is_outgoing=0)
#                  Dedup by timestamp/id — skips if already displayed
#   <Patch>     → OnPatch: patch displayed entry's fields (checkmark)
#
snit::type taco_message {
    option -client -readonly yes

    component messagestore -public messagestore

    variable client
    variable PendingRetry
    variable ActiveTags

    constructor {args} {
        $self configurelist $args
        set client $options(-client)
        install messagestore using taco_messagestore $self.messagestore \
            -db [$client cget -db]
        array set PendingRetry {}
        array set ActiveTags {}
        $client bus subscribe $self sm:<Ack>     [mymethod OnSmAck]
        $client bus subscribe $self muc:<Joined> [mymethod OnMucJoined]
        $client bus subscribe $self <Ready>      [mymethod OnReady]
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$messagestore destroy}
    }

    method OnReady {args} {
        $self PlaceReconnectSentinels
        $self DoCatchup
        $self RetryPending
    }

    # Bracket any history that arrived during the disconnect window:
    # a `newer` sentinel after each chat's newest citizen. Catchup may
    # then sweep these via store overlap; otherwise they remain and
    # bound future pagination.
    method PlaceReconnectSentinels {} {
        set chatJids {}
        $client db eval {
            SELECT DISTINCT chat_jid FROM chat_message
            WHERE kind='message' AND server_id IS NOT NULL
              AND server_id != ''
        } row {
            lappend chatJids $row(chat_jid)
        }
        foreach jid $chatJids {
            set newestTs [$client db onecolumn {
                SELECT MAX(timestamp) FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND server_id IS NOT NULL AND server_id != ''
            }]
            if {$newestTs ne ""} {
                $messagestore sentinel add $jid newer $newestTs
            }
        }
    }

    method DoCatchup {} {
        $client mam query -before {} -max 50 \
            -command [mymethod OnCatchup]
    }

    # Per-message walk: each catchup arrival fires <Received> (or
    # <Patch> for confirmations) individually so the GUI's AtTail
    # gate applies uniformly. Per-chat bracket tracking lets us
    # replicate the batch-level overlap sweep that single-call
    # `store` would do: if any one of this chat's catchup messages
    # dedups against pre-existing cache, the entire bracket span
    # is server-contiguous (RSM) and any sentinels in that span
    # are proven false positives.
    method OnCatchup {mamResult} {
        if {[dict exists $mamResult error]} {
            $client emit message <CatchupDone> -count 0
            return
        }

        set myBareJid [jid bare [$client cget -jid]]
        set totalCount 0
        # Per-chat: min/max input timestamps, oldest, and whether any
        # real overlap (dup against an existing citizen) was seen.
        set perChatMin     [dict create]
        set perChatMax     [dict create]
        set perChatOverlap [dict create]

        foreach resultNode [dict get $mamResult messages] {
            set fwdNode [lindex [xsearch $resultNode forwarded \
                                    -ns urn:xmpp:forward:0] 0]
            set msgNode [$client ensureTo [lindex [xsearch $fwdNode message] 0]]

            set fromBare [jid norm [jid bare [xsearch $msgNode -get @from]]]
            set toBare   [jid norm [jid bare [xsearch $msgNode -get @to]]]

            if {[string equal -nocase $fromBare $myBareJid]} {
                set chatJid $toBare
            } else {
                set chatJid $fromBare
            }

            set msg [$self ParseResultNode $resultNode $chatJid]
            if {[dict get $msg body] eq ""} continue

            set msgTs [dict get $msg timestamp]
            if {![dict exists $perChatMin $chatJid]
                || $msgTs < [dict get $perChatMin $chatJid]} {
                dict set perChatMin $chatJid $msgTs
            }
            if {![dict exists $perChatMax $chatJid]
                || $msgTs > [dict get $perChatMax $chatJid]} {
                dict set perChatMax $chatJid $msgTs
            }

            set result [$messagestore store [list $msg]]
            set confirmed [dict get $result confirmed]
            set inserted  [dict get $result inserted]

            if {[llength $confirmed] > 0} {
                $self HandleConfirmation $chatJid $confirmed
                # confirmed = pending->received echo; not an overlap proof
            } elseif {[llength $inserted] > 0} {
                set dbMsg [lindex [$messagestore get ids \
                    $chatJid $inserted] 0]
                $client emit message <Received> -jid $chatJid \
                    -message $dbMsg
                incr totalCount
            } else {
                # No insertion, no confirmation: IsDuplicate hit on a
                # citizen (real overlap).
                dict set perChatOverlap $chatJid 1
            }
        }

        # Per-chat sweep over the catchup span if any overlap occurred.
        dict for {jid _} $perChatOverlap {
            $messagestore sentinel removeBetween $jid \
                [dict get $perChatMin $jid] \
                [dict get $perChatMax $jid]
        }

        # Place older-edge sentinel for any chat in this catchup if the
        # global MAM query reports more older history. For chats with
        # an existing covering sentinel (PlaceReconnectSentinels), the
        # dedup invariant makes the add a no-op.
        if {![dict get $mamResult complete]} {
            dict for {jid minTs} $perChatMin {
                $messagestore sentinel add $jid older $minTs
            }
        }

        $client emit message <CatchupDone> -count $totalCount
    }

    method OnDisconnect {args} {
        array unset PendingRetry
    }

    # Called on message stanzas that haven't been intercepted by other
    # modules. These are supposed to be 1-1 messages.
    method OnMessage {stanza} {
        set fromBare [jid norm [jid bare [xsearch $stanza -get @from]]]
        set myBare [jid bare [$client cget -jid]]
        set isOwn [expr {$fromBare eq $myBare}]
        if {$isOwn} {
            set chatJid [jid norm [jid bare [xsearch $stanza -get @to]]]
        } else {
            set chatJid $fromBare
        }
        $self ingestLive $chatJid $stanza $isOwn
    }

    # Live-stanza entry point: parse, persist, dispatch to GUI.
    # Called from OnMessage (1:1 DMs) and from the MUC module
    # (groupchat with room@muc?join, PMs with room@muc/nick).
    # Two outcomes from messagestore:
    #   confirmed → echo of one of our own pending sends → HandleConfirmation
    #   inserted  → fresh incoming row                   → HandleInsertion
    method ingestLive {chatJid stanza {isOwn 0}} {
        set body [xsearch $stanza body -get body]
        if {$body eq ""} return
        set stamp [xsearch $stanza delay -ns urn:xmpp:delay -get @stamp]
        set ts [expr {$stamp ne "" ? [ParseTimestamp $stamp] : [clock microseconds]}]
        set serverId [xsearch $stanza stanza-id -ns urn:xmpp:sid:0 -get @id]
        set parseArgs [list -chat_jid $chatJid -timestamp $ts -server_id $serverId]
        if {$isOwn} {
            lappend parseArgs -own_id [xsearch $stanza -get @id]
        }
        set msg [$self ParseMessage $stanza {*}$parseArgs]
        set result [$messagestore store [list $msg]]
        set confirmed [dict get $result confirmed]
        if {[llength $confirmed] > 0} {
            $self HandleConfirmation $chatJid $confirmed
        } else {
            $self HandleInsertion $chatJid [dict get $result inserted]
        }
    }

    # Echo of a pending outgoing message: messagestore has already
    # flipped server_status pending → received and captured server_id.
    # Emit <Patch> so the GUI updates the checkmark; if the row's
    # timestamp moved (server stamp differs from our own_id), include
    # newtimestamp so the GUI can rekey the displayed row.
    method HandleConfirmation {chatJid confirmed} {
        foreach c $confirmed {
            set oldTs [dict get $c timestamp]
            set newTs [dict get $c newtimestamp]
            if {$oldTs != $newTs} {
                set patchMessages [list [dict create \
                    timestamp $oldTs newtimestamp $newTs \
                    server_status received]]
            } else {
                set patchMessages [list [dict create \
                    timestamp $oldTs server_status received]]
            }
            $client emit message <Patch> -jid $chatJid \
                -messages $patchMessages
        }
    }

    method HandleInsertion {chatJid inserted} {
        if {[llength $inserted] == 0} return
        set dbMsg [lindex [$messagestore get ids $chatJid $inserted] 0]
        $client emit message <Received> -jid $chatJid -message $dbMsg
    }

    # Durable message send — store before transmit, confirm on echo/ack.
    #
    # 1. Generate a unique ID, persist to DB with server_status='pending'.
    # 2. Emit <Sent> so the GUI can display immediately (optimistic).
    # 3. Write stanza to server (if this throws, message is safe in DB).
    #
    # Confirmation (pending → received) happens via two paths:
    #   MUC:  server echoes the message back with our id; the echo hits
    #         `ingestLive`, where `messagestore store` dedup finds
    #         the pending row and flips it to 'received'.
    #   1:1:  SM ack confirms the server received the stanza; `OnSmAck`
    #         calls `confirmByOwnIds` on the messagestore.
    # Both paths emit <Patch> so the GUI can show the checkmark.
    #
    # On reconnect, `RetryPending` resends any still-pending messages
    # with the same id, so the echo/ack cycle can complete.
    method send {args} {
        array set opts $args

        set ts [clock microseconds]
        set oid $ts

        if {[string match "*?join" $opts(-chat_jid)]} {
            set type groupchat
            regsub {\?join$} $opts(-chat_jid) {} toJid
            set nick [$client muc myNick -jid $toJid]
            set fromJid $toJid/$nick
            set fromRes ""
        } else {
            set toJid $opts(-chat_jid)
            set fromJid [jid bare [$client cget -jid]]
            set fromRes [jid resource [$client cget -jid]]
        }

        set stanza [j message -to $toJid -type $type -id $oid {
            j body #body $opts(-body)
        }]

        set msg [dict create \
            timestamp $ts \
            chat_jid $opts(-chat_jid) \
            from_jid $fromJid \
            from_resource $fromRes \
            body $opts(-body) \
            server_id "" \
            own_id $oid \
            raw_xml [jwrite $stanza] \
            server_status pending]

        set result [$messagestore store [list $msg]]
        set inserted [dict get $result inserted]
        set dbMsg [lindex [$messagestore get ids $opts(-chat_jid) $inserted] 0]

        $client emit message <Sent> \
            -jid $opts(-chat_jid) -message $dbMsg

        $client write $stanza
    }

    method OnSmAck {args} {
        set stanzas [dict get $args -stanzas]
        set ownIds {}
        foreach stanza $stanzas {
            if {[dict get $stanza tag] ne "message"} continue
            set oid [xsearch $stanza -get @id]
            if {$oid ne ""} {
                lappend ownIds $oid
            }
        }
        if {[llength $ownIds] == 0} return
        set confirmed [$messagestore confirmByOwnIds $ownIds]
        foreach c $confirmed {
            $client emit message <Patch> -jid [dict get $c chat_jid] \
                -messages [list [dict create \
                    timestamp [dict get $c timestamp] \
                    server_status received]]
        }
    }

    method RetryPending {} {
        set pending {}
        $client db eval {
            SELECT chat_jid, body, own_id FROM chat_message
            WHERE kind='message' AND server_status='pending'
            ORDER BY timestamp
        } row {
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id)]
        }
        # Group by MUC vs 1:1 — MUC messages must wait for room join
        foreach msg $pending {
            set chatJid [dict get $msg chat_jid]
            if {[string match "*?join" $chatJid]} {
                regsub {\?join$} $chatJid {} roomJid
                lappend PendingRetry($roomJid) $msg
            } else {
                $self RetrySend $msg
            }
        }
    }

    # Called via bus when a MUC room is joined — flush pending
    # retries for that room.
    method OnMucJoined {args} {
        set roomJid [dict get $args -jid]
        if {![info exists PendingRetry($roomJid)]} return
        set msgs $PendingRetry($roomJid)
        unset PendingRetry($roomJid)
        foreach msg $msgs {
            $self RetrySend $msg
        }
    }

    method RetrySend {msg} {
        set chatJid [dict get $msg chat_jid]
        set body [dict get $msg body]
        set oid [dict get $msg own_id]
        if {[string match "*?join" $chatJid]} {
            regsub {\?join$} $chatJid {} toJid
            set type groupchat
        } else {
            set toJid $chatJid
            set type chat
        }
        set stanza [j message -to $toJid -type $type -id $oid {
            j body #body $body
        }]
        $client write $stanza
    }

    # local_search -chat $jid -query "text" -command $cb
    # Synchronous LIKE search on local SQLite store.
    # Invokes callback with list of timestamps (newest first).
    method local_search {args} {
        array set opts $args
        set timestamps [$messagestore search $opts(-chat) $opts(-query)]
        {*}$opts(-command) $timestamps
    }

    # rawxml -chat $chatJid -timestamp $ts -command $cb
    tackymethod rawxml {args} {
        array set opts $args
        $client db onecolumn {
            SELECT raw_xml FROM chat_message
            WHERE chat_jid=$opts(-chat) AND timestamp=$opts(-timestamp)
        }
    }

    # history -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50?
    #         ?-tag $tag? -command $cb
    # Always async — calls -command with result list.
    # -tag: if given, the callback can be cancelled via `cancel -tag $tag`.
    #
    # Local-first: tries the local store before the server. messagestore
    # get methods truncate at sentinels and signal `bounded=1` when a
    # sentinel forced truncation and the limit wasn't satisfied; the
    # MAM fill kicks in to fetch what's on the far side of the gap.

    # Shared local-store query: dispatches to get before/after/latest.
    # Returns dict {messages bounded} (forwarded from messagestore.get).
    method GetLocal {chatJid before after limit} {
        if {$before ne ""} {
            return [$messagestore get before $chatJid $before $limit]
        } elseif {$after ne ""} {
            return [$messagestore get after $chatJid $after $limit]
        } else {
            return [$messagestore get latest $chatJid $limit]
        }
    }

    method history {args} {
        set defaults [dict create -before "" -after "" -limit 50 \
            -command "" -tag ""]
        set opts [dict merge $defaults $args]

        set chatJid [dict get $opts -chat]
        set limit   [dict get $opts -limit]
        set callback [dict get $opts -command]
        set before [dict get $opts -before]
        set after [dict get $opts -after]
        set tag [dict get $opts -tag]

        if {$tag ne ""} {
            set ActiveTags($tag) 1
        }

        set local [$self GetLocal $chatJid $before $after $limit]
        set localMessages [dict get $local messages]
        set bounded [dict get $local bounded]
        set hasCursor [expr {$before ne "" || $after ne ""}]

        # Return local immediately when it satisfies the request. Trigger
        # MAM only when there's a cursor to anchor the fill — initial
        # loads with bounded local data show what they have; the user
        # scrolls into the sentinel later to trigger fill.
        if {[llength $localMessages] >= $limit
            || ([llength $localMessages] > 0
                && (!$bounded || !$hasCursor))} {
            {*}$callback $localMessages
            return
        }

        # For -after queries with no sentinel ahead, skip MAM when
        # cursor is at or past the latest stored message — there's
        # nothing newer in the archive.
        if {$after ne "" && !$bounded} {
            set latestTs [$client db onecolumn {
                SELECT MAX(timestamp) FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
            }]
            if {$latestTs eq "" || $after >= $latestTs} {
                {*}$callback $localMessages
                return
            }
        }

        set mamArgs [list -max $limit]
        set cursorSid ""
        if {$before ne ""} {
            # Try server_id at cursor for RSM pagination; time-based fallback
            set cursorSid [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND timestamp=$before
                  AND server_id != ''
            }]
            if {$cursorSid ne ""} {
                lappend mamArgs -before $cursorSid
            } else {
                lappend mamArgs -end [FormatTimestampISO $before] -before {}
            }
        } elseif {$after ne ""} {
            set cursorSid [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND timestamp=$after
                  AND server_id != ''
            }]
            if {$cursorSid ne ""} {
                lappend mamArgs -after $cursorSid
            } else {
                lappend mamArgs -start [FormatTimestampISO $after]
            }
        } else {
            # Cursor-based: page backwards from earliest known citizen
            set cursorSid [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
                  AND server_id != ''
                ORDER BY timestamp ASC LIMIT 1
            }]
            if {$cursorSid ne ""} {
                lappend mamArgs -before $cursorSid
            }
        }

        # Direction is "older" for -before / initial, "newer" for -after.
        set direction [expr {$after ne "" ? "newer" : "older"}]

        lappend mamArgs -command [mymethod OnFetch $chatJid \
            $before $after $limit $callback $tag $direction $bounded]

        $client mam queryChat $chatJid {*}$mamArgs
    }

    method OnFetch {chatJid before after limit callback tag direction \
                    wasBounded mamResult} {
        if {[dict exists $mamResult error]} {
            if {$tag ne "" && ![info exists ActiveTags($tag)]} return
            set local [$self GetLocal $chatJid $before $after $limit]
            {*}$callback [dict get $local messages]
            return
        }

        # Parse result nodes into message dicts
        set messages {}
        foreach resultNode [dict get $mamResult messages] {
            lappend messages [$self ParseResultNode $resultNode $chatJid]
        }

        # Store the fetched batch (even if cancelled — data is still useful)
        if {[llength $messages] > 0} {
            $messagestore store $messages
        }
        # Sentinel ops apply for empty batches too — particularly the
        # complete=true bounding-sentinel removal, which signals the
        # server-side archive is exhausted in this direction.
        $self ApplyFetchSentinelOps $chatJid $messages \
            $direction $before $after $wasBounded \
            [dict get $mamResult complete]

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set local [$self GetLocal $chatJid $before $after $limit]
        {*}$callback [dict get $local messages]
    }

    # Sentinel ops after a non-empty MAM page lands:
    #   1. Sweep: any sentinels strictly between cursor and batch
    #      far-edge. RSM guarantees that range is contiguous, so any
    #      sentinel there was a false positive (the sentinel the user
    #      paginated past, or stale boundary sentinels).
    #   2. Place: if complete=false, drop a sentinel at the batch's
    #      far edge in the queried direction. The synthetic sentinel
    #      ts is one µs past the far-edge message (via BumpTs), so the
    #      sweep above doesn't touch it.
    #   3. Remove bounding sentinel on complete=true: if local was
    #      bounded by a sentinel on the queried side and the server
    #      confirms exhaustion, the bounding sentinel can clear.
    method ApplyFetchSentinelOps {chatJid messages direction \
                                  before after wasBounded complete} {
        # Cursor for sweep: the existing cursor message timestamp.
        # If no cursor (initial open), sweep span is open-ended on the
        # far side — no sweep applies.
        set cursorTs ""
        if {$direction eq "older"} {
            if {$before ne ""} { set cursorTs $before }
        } else {
            if {$after ne ""} { set cursorTs $after }
        }

        set hasBatch [expr {[llength $messages] > 0}]
        if {$hasBatch} {
            set tsList {}
            foreach m $messages {
                lappend tsList [dict get $m timestamp]
            }
            set oldestTs [tcl::mathfunc::min {*}$tsList]
            set newestTs [tcl::mathfunc::max {*}$tsList]
        }

        # 1. Sweep: only meaningful with a non-empty batch (RSM
        # contiguity guarantee applies to the returned range).
        if {$hasBatch && $cursorTs ne ""} {
            if {$direction eq "older"} {
                $messagestore sentinel removeBetween $chatJid \
                    $oldestTs $cursorTs
            } else {
                $messagestore sentinel removeBetween $chatJid \
                    $cursorTs $newestTs
            }
        }

        # 2. Place far-edge sentinel on complete=false (only if we got
        # a batch to anchor against; an empty batch with complete=false
        # is degenerate but doesn't tell us where to place).
        if {$hasBatch && !$complete} {
            if {$direction eq "older"} {
                $messagestore sentinel add $chatJid older $oldestTs
            } else {
                $messagestore sentinel add $chatJid newer $newestTs
            }
        }

        # 3. Remove bounding sentinel on complete=true. Applies even
        # when the batch was empty — the server has confirmed there's
        # nothing in this direction past the cursor, so the bounding
        # sentinel is proven false.
        if {$complete && $wasBounded && $cursorTs ne ""} {
            $messagestore sentinel remove $chatJid $direction $cursorTs
        }
    }

    method cancel {args} {
        set tag [dict get $args -tag]
        unset -nocomplain ActiveTags($tag)
    }

    # goto -chat $jid -date $ts -source local|remote -limit 50
    #      ?-tag $tag? -command $cb
    # Jump to a point in time. Returns {messages $list anchor $ts}.
    #   local:  get around from local store
    #   remote: MAM fetch from -start $date, store, then get around
    method goto {args} {
        set defaults [dict create -source local -limit 50 -tag ""]
        set opts [dict merge $defaults $args]

        set chatJid  [dict get $opts -chat]
        set date     [dict get $opts -date]
        set source   [dict get $opts -source]
        set limit    [dict get $opts -limit]
        set tag      [dict get $opts -tag]
        set callback [dict get $opts -command]

        if {$tag ne ""} {
            set ActiveTags($tag) 1
        }

        if {$source eq "local"} {
            set result [$messagestore get around $chatJid $date $limit]
            {*}$callback $result
            return
        }

        # remote: fetch from server first, then get around
        $client mam queryChat $chatJid \
            -start [FormatTimestampISO $date] -max $limit \
            -command [mymethod OnGoto $chatJid $date $limit $callback $tag]
    }

    method OnGoto {chatJid date limit callback tag mamResult} {
        if {[dict exists $mamResult error]} {
            # Fall back to local
            if {$tag ne "" && ![info exists ActiveTags($tag)]} return
            set result [$messagestore get around $chatJid $date $limit]
            {*}$callback $result
            return
        }

        set messages {}
        foreach resultNode [dict get $mamResult messages] {
            lappend messages [$self ParseResultNode $resultNode $chatJid]
        }

        if {[llength $messages] > 0} {
            $messagestore store $messages
        }

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set result [$messagestore get around $chatJid $date $limit]
        {*}$callback $result
    }

    # search -chat $jid -query "text" ?-before $serverId? ?-limit 20?
    #        ?-tag $tag? -command $cb
    #
    # Full text search via MAM. Always server-side.
    # Results are stored to the local cache and wrapped with sentinels
    # on each side — a hit is an isolated island whose surroundings we
    # know nothing about, so future pagination across it must fall
    # through to MAM. `sentinel add` is a no-op when the target gap is
    # already sentineled, so repeated searches don't accumulate.
    # Callback receives dict: messages, complete, last
    method search {args} {
        array set opts {-limit 20 -tag "" -field ""}
        array set opts $args

        set chatJid $opts(-chat)
        set callback $opts(-command)
        set tag $opts(-tag)

        if {$tag ne ""} {
            set ActiveTags($tag) 1
        }

        set mamArgs [list -fulltext $opts(-query) -max $opts(-limit)]
        if {$opts(-field) ne ""} {
            lappend mamArgs -field-var $opts(-field)
        }
        if {[info exists opts(-before)]} {
            lappend mamArgs -before $opts(-before)
        } else {
            lappend mamArgs -before {}
        }

        lappend mamArgs -command [mymethod OnSearch $chatJid $callback $tag]
        $client mam queryChat $chatJid {*}$mamArgs
    }

    method OnSearch {chatJid callback tag mamResult} {
        if {[dict exists $mamResult error]} {
            {*}$callback [dict create messages {} complete 0 last "" error 1]
            return
        }

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set messages {}
        foreach resultNode [dict get $mamResult messages] {
            set msg [$self ParseResultNode $resultNode $chatJid]
            if {[dict get $msg body] eq ""} continue
            set result [$messagestore store [list $msg]]
            set ins [dict get $result inserted]
            if {[llength $ins] > 0} {
                set storedTs [lindex $ins 0]
                $messagestore sentinel add $chatJid older $storedTs
                $messagestore sentinel add $chatJid newer $storedTs
                lappend messages [lindex [$messagestore get ids $chatJid $ins] 0]
            }
        }

        set complete [dict get $mamResult complete]
        set last [dict get $mamResult last]

        {*}$callback [dict create messages $messages complete $complete last $last]
    }

    method ParseResultNode {resultNode chatJid} {
        set serverId [xsearch $resultNode -get @id]
        set fwdNode [lindex [xsearch $resultNode forwarded -ns urn:xmpp:forward:0] 0]
        set stamp [xsearch $fwdNode delay -ns urn:xmpp:delay -get @stamp]
        set msgNode [lindex [xsearch $fwdNode message] 0]

        $self ParseMessage $msgNode \
            -chat_jid $chatJid \
            -timestamp [ParseTimestamp $stamp] \
            -server_id $serverId
    }

    # Shared parser: extract message dict from a <message> node.
    # Caller supplies -chat_jid, -timestamp, -server_id as overrides
    # (these come from different places for live vs MAM).
    method ParseMessage {msgNode args} {
        set chatJid [dict get $args -chat_jid]
        set rawFrom [xsearch $msgNode -get @from]
        set fromJid [NormalizeAuthorJid $chatJid $rawFrom]
        set fromRes [SplitFromResource $chatJid $rawFrom]
        dict create \
            timestamp  [dict get $args -timestamp] \
            chat_jid   $chatJid \
            from_jid   $fromJid \
            from_resource $fromRes \
            body       [xsearch $msgNode body -get body] \
            server_id  [dict get $args -server_id] \
            own_id     [expr {[dict exists $args -own_id] ? [dict get $args -own_id] : ""}] \
            raw_xml    [jwrite $msgNode] \
            server_status ""
    }
}

# Author identity within a chat: full `room/nick` for MUC chats (resource
# is the participant's stable nick), bare JID for 1:1 (resource is an
# ephemeral client tag with no identity meaning). chat_jid shapes:
# `room@muc?join` (groupchat) and `room@muc/nick` (PM) are MUC; anything
# else is 1:1.
proc NormalizeAuthorJid {chatJid fromJid} {
    if {[IsMucChatJid $chatJid]} {
        return $fromJid
    }
    return [jid bare $fromJid]
}

# Resource component for 1:1 senders (the ephemeral client tag — useful
# for debug / per-resource features). Empty for MUC, where the resource
# is the nick and lives in from_jid.
proc SplitFromResource {chatJid fromJid} {
    if {[IsMucChatJid $chatJid]} {
        return ""
    }
    return [jid resource $fromJid]
}

proc IsMucChatJid {chatJid} {
    expr {[string match {*\?join} $chatJid] || [string match */* $chatJid]}
}
