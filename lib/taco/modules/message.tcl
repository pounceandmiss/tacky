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
        $client bus subscribe $self omemo:<SessionReady> \
            [mymethod OnOmemoSessionReady]
        # A peer's devicelist resolving (to devices or empty) also wakes
        # a blocked send: re-running encrypt either warms further, or
        # TERMINAL-fails on an empty list so the message stops hanging.
        $client bus subscribe $self omemo:<DevicelistResolved> \
            [mymethod OnOmemoSessionReady]
        # omemo's account-level prerequisites (store, own devicelist)
        # become ready after OnMessage's RetryPending has already run
        # this connection, so retry pending OMEMO sends once they land.
        $client bus subscribe $self omemo:<SelfReady> \
            [mymethod OnOmemoSelfReady]
        $client bus subscribe $self <Ready>      [mymethod OnReady]
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
        array set OmemoRetryBudget {}
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$messagestore destroy}
    }

    method OnReady {args} {
        # Network just came back. Transient disconnects shouldn't
        # exhaust the OMEMO retry budget — give each still-pending
        # message a fresh shot on the new connection.
        array unset OmemoRetryBudget
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

    # Maximum BuildOutgoingStanza attempts per message before marking
    # failed. Each <SessionReady> tick for the peer counts as one
    # attempt; warming usually settles within 1-2 ticks for live
    # peers, so 5 gives slack for slow bundle fetches without
    # looping forever on an undeliverable peer.
    variable OmemoRetryBudget
    typevariable OMEMO_RETRY_LIMIT 5

    # Compute (msgType, toJid, fromJid, fromRes) from a chat jid.
    # MUC chats use the `?join` suffix tacky uses internally for the
    # "self as room member" identity.
    method DeriveAddressing {chatJid} {
        if {[string match "*?join" $chatJid]} {
            set msgType groupchat
            regsub {\?join$} $chatJid {} toJid
            set nick [$client muc myNick -jid $toJid]
            return [list $msgType $toJid $toJid/$nick ""]
        }
        return [list chat $chatJid \
            [jid bare [$client cget -jid]] \
            [jid resource [$client cget -jid]]]
    }

    # Build the wire stanza for an outbound message. encMode is the
    # intended encryption ('omemo' or '' for plaintext); the caller
    # decides it (new sends from the per-chat toggle, retries from the
    # stamped `encryption` column). Throws TACO_OMEMO_NOT_READY
    # (transient — leave pending, retry on <SessionReady>) or
    # TACO_OMEMO_TERMINAL (don't retry) for OMEMO failures. Plaintext
    # path can't throw.
    #
    # OMEMO fail-closed: when encMode is 'omemo' we encrypt or throw;
    # never fall back to cleartext. See security invariant #2 in
    # lib/taco/modules/omemo.tcl.
    method BuildOutgoingStanza {chatJid body oid msgType toJid encMode} {
        if {$encMode ne "omemo"} {
            return [j message -to $toJid -type $msgType -id $oid {
                j body #body $body
            }]
        }
        set encNode [$client omemo encrypt $chatJid $body]
        return [j message -to $toJid -type $msgType -id $oid {
            j #as-is $encNode
            j encryption -ns urn:xmpp:eme:0 \
                -namespace eu.siacs.conversations.axolotl \
                -name OMEMO
            j body #body \
                "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
        }]
    }

    # The form stored in raw_xml: always the readable message, never
    # ciphertext. For OMEMO that's the real body + EME marker (symmetric
    # with the synthesised stanza we store for decrypted incoming
    # messages, and with the encryption stamp); for plaintext it's just
    # the body. The wire stanza (BuildOutgoingStanza) is separate.
    method StoredForm {body oid msgType toJid encMode} {
        if {$encMode ne "omemo"} {
            return [j message -to $toJid -type $msgType -id $oid {
                j body #body $body
            }]
        }
        return [j message -to $toJid -type $msgType -id $oid {
            j body #body $body
            j encryption -ns urn:xmpp:eme:0 \
                -namespace eu.siacs.conversations.axolotl \
                -name OMEMO
        }]
    }

    # Intended encryption for a fresh outbound message to $chatJid:
    # 'omemo' when it's a 1:1 chat with OMEMO enabled for that peer,
    # else '' (plaintext). The omemo module owns the per-chat toggle.
    method OutgoingEncMode {chatJid msgType} {
        if {$msgType eq "chat" && [$client omemo IsEnabled $chatJid]} {
            return omemo
        }
        return ""
    }

    # Durable message send — store before transmit, confirm on echo/ack.
    #
    # 1. Generate a unique ID, build the stanza (may need OMEMO).
    # 2. Persist to DB. server_status='pending' if we wrote to the wire
    #    or expect to retry; 'failed' if the build said TERMINAL.
    # 3. Emit <Sent> so the GUI can display immediately (optimistic).
    # 4. Write stanza to server if one exists.
    #
    # OMEMO cold-cache path: encrypt throws TACO_OMEMO_NOT_READY,
    # message persists pending without going on the wire, warming runs
    # in the background, OnOmemoSessionReady drives a retry. Reuses
    # the existing pending-row machinery rather than a separate
    # outbox/queue.
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

        # NB: do not use `type` as a local — snit injects its own
        # `type` (the snit type name like ::taco_message), and the
        # one-armed if below previously forgot to assign it in the
        # else branch, so the snit-injected value leaked into the
        # outgoing <message type=...> attribute. Use msgType.
        lassign [$self DeriveAddressing $opts(-chat_jid)] \
            msgType toJid fromJid fromRes

        set encMode [$self OutgoingEncMode $opts(-chat_jid) $msgType]
        set stanza ""
        set status "pending"
        set failReason ""
        try {
            set stanza [$self BuildOutgoingStanza \
                $opts(-chat_jid) $opts(-body) $oid $msgType $toJid $encMode]
        } trap TACO_OMEMO_NOT_READY {emsg} {
            # Stays pending; warming kicks via encrypt side effect.
            # Initial attempt counts toward the budget.
            jlog debug "send $opts(-chat_jid): OMEMO not ready ($emsg), parking pending oid=$oid"
            set OmemoRetryBudget($oid) [expr {$OMEMO_RETRY_LIMIT - 1}]
        } trap TACO_OMEMO_TERMINAL {emsg} {
            jlog debug "send $opts(-chat_jid): OMEMO terminal ($emsg), marking failed oid=$oid"
            set status "failed"
            set failReason "encrypt"
        }

        set msg [dict create \
            timestamp $ts \
            chat_jid $opts(-chat_jid) \
            from_jid $fromJid \
            from_resource $fromRes \
            body $opts(-body) \
            server_id "" \
            own_id $oid \
            raw_xml [expr {$stanza eq "" ? "" \
                : [jwrite [$self StoredForm $opts(-body) $oid $msgType $toJid $encMode]]}] \
            server_status $status \
            encryption $encMode \
            fail_reason $failReason]

        set result [$messagestore store [list $msg]]
        set inserted [dict get $result inserted]
        set dbMsg [lindex [$messagestore get ids $opts(-chat_jid) $inserted] 0]

        $client emit message <Sent> \
            -jid $opts(-chat_jid) -message $dbMsg

        if {$stanza ne ""} {
            $client write $stanza
        }
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
            SELECT chat_jid, body, own_id, encryption FROM chat_message
            WHERE kind='message' AND server_status='pending'
            ORDER BY timestamp
        } row {
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id) encryption $row(encryption)]
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

    # Called via bus when OMEMO makes progress for $peerJid — a session
    # got built (omemo:<SessionReady>) or the devicelist resolved
    # (omemo:<DevicelistResolved>). Retries OMEMO-intended pending
    # messages to $peerJid that never made it onto the wire (raw_xml==""
    # — encrypt threw NOT_READY, never written). The retry re-runs
    # encrypt: it succeeds, stays pending (still warming), or
    # TERMINAL-fails (peer's devicelist resolved empty). Pending-with-
    # stanza rows are already on the wire awaiting SM ack; retrying those
    # would duplicate sends each time another tick fires.
    method OnOmemoSessionReady {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set pending {}
        $client db eval {
            SELECT chat_jid, body, own_id, encryption FROM chat_message
            WHERE kind='message' AND chat_jid=$peerJid
              AND server_status='pending'
              AND encryption='omemo'
              AND (raw_xml IS NULL OR raw_xml = '')
            ORDER BY timestamp
        } row {
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id) encryption $row(encryption)]
        }
        jlog debug "omemo:<SessionReady> $peerJid: [llength $pending] pending omemo send(s) to retry"
        foreach msg $pending {
            $self RetrySend $msg
        }
    }

    # Called via bus when omemo's account-level state (store + own
    # devicelist) is ready. Unlike OnOmemoSessionReady this isn't tied
    # to one peer: retry every pending OMEMO send that never reached the
    # wire, since they were all blocked on the same account prerequisite.
    method OnOmemoSelfReady {args} {
        set pending {}
        $client db eval {
            SELECT chat_jid, body, own_id, encryption FROM chat_message
            WHERE kind='message' AND server_status='pending'
              AND encryption='omemo'
              AND (raw_xml IS NULL OR raw_xml = '')
            ORDER BY timestamp
        } row {
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id) encryption $row(encryption)]
        }
        jlog debug "omemo:<SelfReady>: [llength $pending] pending omemo send(s) to retry"
        foreach msg $pending {
            $self RetrySend $msg
        }
    }

    # Called via bus when a MUC room is joined - flush pending
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

    # Retry a still-pending message. Uses BuildOutgoingStanza so OMEMO
    # chats get re-encrypted against the current devicelist (the
    # devicelist may have changed since the original send; replaying
    # the stored raw_xml would either leak cleartext or send to a
    # stale recipient set). Honors the row's stamped `encryption` —
    # automatic retries never downgrade an OMEMO message to plaintext
    # even if the per-chat toggle was flipped off in the meantime.
    method RetrySend {msg} {
        set chatJid [dict get $msg chat_jid]
        set body    [dict get $msg body]
        set oid     [dict get $msg own_id]
        set encMode [expr {[dict exists $msg encryption] \
            ? [dict get $msg encryption] : ""}]
        lassign [$self DeriveAddressing $chatJid] msgType toJid _ _

        jlog debug "RetrySend $chatJid oid=$oid encMode=$encMode"
        try {
            set stanza [$self BuildOutgoingStanza \
                $chatJid $body $oid $msgType $toJid $encMode]
        } trap TACO_OMEMO_NOT_READY {} {
            # Bundle/devicelist warming still in flight. If we have
            # budget left, stay pending and wait for the next
            # <SessionReady> tick.
            if {![info exists OmemoRetryBudget($oid)]} {
                set OmemoRetryBudget($oid) $OMEMO_RETRY_LIMIT
            }
            incr OmemoRetryBudget($oid) -1
            jlog debug "RetrySend $chatJid oid=$oid: still NOT_READY, budget=$OmemoRetryBudget($oid)"
            if {$OmemoRetryBudget($oid) <= 0} {
                $self MarkOutgoingFailed $chatJid $oid encrypt
            }
            return
        } trap TACO_OMEMO_TERMINAL {} {
            jlog debug "RetrySend $chatJid oid=$oid: TERMINAL, marking failed"
            $self MarkOutgoingFailed $chatJid $oid encrypt
            return
        }

        unset -nocomplain OmemoRetryBudget($oid)
        jlog debug "RetrySend $chatJid oid=$oid: built stanza, writing to wire"
        # Stamp raw_xml with the readable form (not the ciphertext wire
        # stanza) so it stays non-empty - the sentinel that a later
        # <SessionReady> tick uses to skip re-sending an on-wire row.
        set xml [jwrite [$self StoredForm $body $oid $msgType $toJid $encMode]]
        $client db eval {
            UPDATE chat_message SET raw_xml=$xml
            WHERE chat_jid=$chatJid AND own_id=$oid
        }
        $client write $stanza
    }

    # resend -chat_jid X -timestamp T ?-plaintext 0|1?
    #
    # User-driven resend of a pending/failed outgoing message, keyed by
    # the GUI's stable (chat_jid, timestamp) id. Default honors the
    # row's stamped `encryption` — "try again, same way". `-plaintext 1`
    # rewrites the stamp to '' and is the ONLY path allowed to downgrade
    # an OMEMO message to cleartext, so a stuck encrypted message can be
    # sent in clear once the user learns the peer can't do OMEMO.
    #
    # Does NOT touch the chat toggle: downgrading one message leaves the
    # chat's default encryption for future messages unchanged. Fire-and-
    # forget; the outcome surfaces via <Patch> like any other send.
    method resend {args} {
        array set opts {-plaintext 0}
        array set opts $args
        set chatJid $opts(-chat_jid)
        set ts      $opts(-timestamp)

        set row [$client db eval {
            SELECT own_id, body, encryption FROM chat_message
            WHERE chat_jid=$chatJid AND timestamp=$ts AND kind='message'
        }]
        if {[llength $row] == 0} return
        lassign $row oid body enc

        if {$opts(-plaintext)} {
            set enc ""
            $client db eval {
                UPDATE chat_message SET encryption='', raw_xml=''
                WHERE chat_jid=$chatJid AND timestamp=$ts
            }
        }

        # Fresh attempt: reset budget, flip back to pending and clear the
        # prior failure so the GUI shows it in flight; MarkOutgoingFailed
        # re-stamps fail_reason if it fails again.
        unset -nocomplain OmemoRetryBudget($oid)
        $client db eval {
            UPDATE chat_message SET server_status='pending', fail_reason=''
            WHERE chat_jid=$chatJid AND timestamp=$ts
        }
        $client emit message <Patch> -jid $chatJid \
            -messages [list [dict create \
                timestamp $ts server_status pending fail_reason ""]]

        $self RetrySend [dict create \
            chat_jid $chatJid body $body own_id $oid encryption $enc]
    }

    # Flip a pending row to failed with a fail_reason category and notify
    # the GUI. `reason` is a category ('encrypt' = OMEMO couldn't produce
    # ciphertext); persisted on the row and carried in the <Patch> so the
    # GUI picks the right affordance (e.g. resend-as-plaintext).
    method MarkOutgoingFailed {chatJid oid reason} {
        $client db eval {
            UPDATE chat_message
            SET server_status='failed', fail_reason=$reason
            WHERE chat_jid=$chatJid AND own_id=$oid
              AND server_status='pending'
        }
        set ts [$client db onecolumn {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$chatJid AND own_id=$oid
        }]
        if {$ts eq ""} return
        unset -nocomplain OmemoRetryBudget($oid)
        $client emit message <Patch> -jid $chatJid \
            -messages [list [dict create \
                timestamp $ts server_status failed fail_reason $reason]]
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

        # If the archived message is OMEMO-encrypted, route it through
        # the same decrypt core that the live path uses. Returns a
        # synthesised plaintext stanza on success, the original
        # encrypted stanza on failure (which then parses to an empty
        # body and gets skipped by the caller's body-empty filter).
        set msgNode [$client omemo decryptForwarded $msgNode]

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
        # Encryption stamp from the EME marker (XEP-0380), which the decrypt
        # path (SynthesisePlain) leaves on decrypted messages; plaintext has
        # none. Drives the lock on peer messages.
        set emeNs [xsearch $msgNode encryption -ns urn:xmpp:eme:0 -get @namespace]
        set enc [expr {$emeNs eq "eu.siacs.conversations.axolotl" ? "omemo" : ""}]
        # own_id dedups messages we sent. The caller sets it on the live
        # carbon path; otherwise, for a stanza from our own bare JID (echo:
        # self-chat, carbon, MAM), derive it from @id - which equals the
        # own_id we stored on send, so messagestore confirms the row rather
        # than duplicating it.
        if {[dict exists $args -own_id]} {
            set ownId [dict get $args -own_id]
        } elseif {$rawFrom ne "" && [jid bare $rawFrom] eq [jid bare [$client cget -jid]]} {
            set ownId [xsearch $msgNode -get @id]
        } else {
            set ownId ""
        }
        dict create \
            timestamp  [dict get $args -timestamp] \
            chat_jid   $chatJid \
            from_jid   $fromJid \
            from_resource $fromRes \
            body       [xsearch $msgNode body -get body] \
            server_id  [dict get $args -server_id] \
            own_id     $ownId \
            raw_xml    [jwrite $msgNode] \
            server_status "" \
            encryption $enc
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
