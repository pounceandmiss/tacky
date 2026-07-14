# Overview: see messagestore.tcl for the sparse-cache complexities.

# Message dict keys: timestamp, chat_jid, from_jid, from_resource, body,
#   server_id, own_id, origin_id, reply_id, reply_to, raw_xml (debug),
#   server_status, encryption, fail_reason, attachments, on_wire.

# chat_jid: MUC groupchat - room@muc?join; MUC PM - room@muc/nick;
#   1:1 - bare JID.

# server_status answers one question - "does the server have this exact
# message?" - and nothing else (direction is is_outgoing, from own_id):
#   ""          the server has it: incoming, MAM, carbon, or a confirmed
#               send - all the same situation
#   "pending"   ours, sent, not yet confirmed on the server
#   "uploading" ours, attachment HTTP PUT in flight (XEP-0363)
#   "failed"    ours, didn't reach the server (retryable)
#
# Incoming stanzas: live (OnMessage/ingestLive) and archived
# (ParseResultNode) stanzas share one ingestion core, Classify:
#   1. Dedup on the envelope ids (server stanza-id / @id), before
#      anything else:
#      1.1 an outgoing message may be confirmed - and its timestamp
#          relocated to the incoming stamp (MAM archive delay or MUC
#          ack live arrival time)
#      1.2 a match against an existing non-outgoing -> discard as duplicate
#      1.3 no id match -> new, carry on
#   2. Decrypt OMEMO
#   3. Classify the contents: a real body is stored and surfaced
#      (<New>); a control stanza (receipt, chat marker, chat state)
#      or other bodyless payload is currently discarded.
# === GUI events ===
#
#   <New>      insert a newly-persisted message; direction (outgoing vs
#              incoming) and checkmark derive from the message dict
#              (is_outgoing / server_status), not the event name
#   <Patch>    patch a displayed entry (checkmark / rekey)
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
        # An 'uploading' row from a previous run was never sent (PUT isn't
        # resumable); reconcile it to 'failed' so the user can retry.
        $messagestore failStaleUploads
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
        $self PlaceReconnectHoles
        $self DoCatchup
        $self RetryPending
    }

    # Bracket any history that arrived during the disconnect window:
    # a `newer` hole after each chat's newest citizen. Catchup may
    # then sweep these via store overlap; otherwise they remain and
    # bound future pagination.
    method PlaceReconnectHoles {} {
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
                $messagestore hole add $jid newer $newestTs
            }
        }
    }

    method DoCatchup {} {
        $client mam query -before {} -max 50 \
            -command [mymethod OnCatchup]
    }

    # Per-message walk: each catchup arrival fires <New> (or
    # <Patch> for confirmations) individually so the GUI's AtTail
    # gate applies uniformly. Per-chat bracket tracking lets us
    # replicate the batch-level overlap sweep that single-call
    # `store` would do: if any one of this chat's catchup messages
    # dedups against pre-existing cache, the entire bracket span
    # is server-contiguous (RSM) and any holes in that span
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

            set r [$self ParseResultNode $resultNode $chatJid]
            set verdict [dict get $r verdict]
            # A reaction updates a stored message's display; it isn't a
            # citizen and doesn't bound a hole (like drop).
            if {$verdict eq "reaction"} {
                $self ApplyReactionVerdict $chatJid $r
                continue
            }
            # drop = displayless new stanza; doesn't bound a hole (as before).
            if {$verdict eq "drop"} continue

            set msgTs [dict get $r timestamp]
            if {![dict exists $perChatMin $chatJid]
                || $msgTs < [dict get $perChatMin $chatJid]} {
                dict set perChatMin $chatJid $msgTs
            }
            if {![dict exists $perChatMax $chatJid]
                || $msgTs > [dict get $perChatMax $chatJid]} {
                dict set perChatMax $chatJid $msgTs
            }

            switch $verdict {
                confirmed {
                    # pending->"" echo; not an overlap proof
                    $self HandleConfirmation $chatJid \
                        [list [dict get $r reconciled]]
                }
                duplicate {
                    dict set perChatOverlap $chatJid 1
                }
                new {
                    set result [$messagestore store [list [dict get $r msg]]]
                    set inserted [dict get $result inserted]
                    if {[llength $inserted] > 0} {
                        set dbMsg [lindex [$messagestore get ids \
                            $chatJid $inserted] 0]
                        $client emit message <New> -jid $chatJid \
                            -message $dbMsg
                        incr totalCount
                    } else {
                        # store's own dedup caught an id-less content match.
                        dict set perChatOverlap $chatJid 1
                    }
                }
            }
        }

        # Per-chat sweep over the catchup span if any overlap occurred.
        dict for {jid _} $perChatOverlap {
            $messagestore hole removeBetween $jid \
                [dict get $perChatMin $jid] \
                [dict get $perChatMax $jid]
        }

        # Place older-edge hole for any chat in this catchup if the
        # global MAM query reports more older history. For chats with
        # an existing covering hole (PlaceReconnectHoles), the
        # dedup invariant makes the add a no-op.
        if {![dict get $mamResult complete]} {
            dict for {jid minTs} $perChatMin {
                $messagestore hole add $jid older $minTs
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
        if {!$isOwn && [$self HandleMarker $chatJid $stanza]} return
        $self ingestLive $chatJid $stanza $isOwn
        if {!$isOwn} {
            $self AutoReceipt $chatJid $stanza
        }
    }

    # send_chat_markers setting; unset means on. Gates all outgoing markers.
    method MarkersEnabled {} {
        if {[catch {[$client cget -taco] setting get -key send_chat_markers} v]} {
            return 1
        }
        return [expr {$v ne "0"}]
    }

    # Send a bodyless receipt/marker stanza referencing $refId. Not stored
    # (ClassifyMessage drops bodyless control stanzas).
    method SendMarker {toJid element ns refId} {
        $client write [j message -to $toJid -type chat -id [clock microseconds] {
            j $element -ns $ns -id $refId
        }]
    }

    # Reply with a `received` marker if a live 1:1 message asked for one
    # (XEP-0184 <request> / XEP-0333 <markable>). Read is GUI-driven.
    method AutoReceipt {chatJid stanza} {
        if {![$self MarkersEnabled]} return
        set refId [xsearch $stanza -get @id]
        if {$refId eq ""} return
        if {[llength [xsearch $stanza request -ns urn:xmpp:receipts]] > 0} {
            $self SendMarker $chatJid received urn:xmpp:receipts $refId
        }
        if {[llength [xsearch $stanza markable -ns urn:xmpp:chat-markers:0]] > 0} {
            $self SendMarker $chatJid received urn:xmpp:chat-markers:0 $refId
        }
    }

    # A bodyless XEP-0184 receipt / XEP-0333 chat marker from the peer
    # advances the referenced outgoing message's remote_status
    # (delivered/read) and emits a <Patch>. Returns 1 if the stanza was a
    # marker (consumed here), else 0 so OnMessage falls through to
    # ingestLive. A 'displayed' outranks a co-present 'received'.
    method HandleMarker {chatJid stanza} {
        set targetId [xsearch $stanza displayed \
            -ns urn:xmpp:chat-markers:0 -get @id]
        if {$targetId ne ""} {
            set tier read
        } else {
            set tier ""
            foreach ns {urn:xmpp:receipts urn:xmpp:chat-markers:0} {
                set targetId [xsearch $stanza received -ns $ns -get @id]
                if {$targetId ne ""} {
                    set tier delivered
                    break
                }
            }
        }
        if {$tier eq ""} { return 0 }
        set changed [$messagestore markRemoteStatus $chatJid $targetId $tier]
        if {$changed ne ""} {
            $client emit message <Patch> -jid $chatJid \
                -messages [list [dict create \
                    timestamp [dict get $changed timestamp] \
                    remote_status [dict get $changed remote_status]]]
        }
        return 1
    }

    # Live-stanza entry point. Called from OnMessage (1:1 DMs) and from the
    # MUC module (groupchat with room@muc?join, PMs with room@muc/nick).
    # Builds the {serverId ownId originId} triple off the stanza (live
    # messages carry their own stanza-id; an own echo's @id is passed
    # explicitly via isOwn) then funnels into the shared Classify core.
    method ingestLive {chatJid stanza {isOwn 0}} {
        set stamp [xsearch $stanza delay -ns urn:xmpp:delay -get @stamp]
        set ts [expr {$stamp ne "" ? [ParseTimestamp $stamp] : [clock microseconds]}]
        set idArgs {}
        if {$isOwn} {
            set idArgs [list -own_id [xsearch $stanza -get @id]]
        }
        set ids [$self ExtractEnvelopeIds $stanza $chatJid {*}$idArgs]
        $self DispatchLive $chatJid [$self Classify $chatJid $stanza $ts $ids]
    }

    # Act on one live message's verdict (from Classify):
    #   confirmed → echo of one of our own pending sends → <Patch>
    #   new       → store, then surface. store may still confirm it by the
    #               content fallback (id-less re-delivery of a pending send)
    #               or drop it as a real overlap with an existing citizen.
    #   duplicate → already a citizen; nothing to show.
    #   drop      → displayless (control type / keytransport); nothing.
    method DispatchLive {chatJid verdict} {
        switch [dict get $verdict verdict] {
            reaction {
                $self ApplyReactionVerdict $chatJid $verdict
            }
            confirmed {
                $self HandleConfirmation $chatJid \
                    [list [dict get $verdict reconciled]]
            }
            new {
                set result [$messagestore store [list [dict get $verdict msg]]]
                set confirmed [dict get $result confirmed]
                if {[llength $confirmed] > 0} {
                    $self HandleConfirmation $chatJid $confirmed
                } else {
                    $self HandleInsertion $chatJid [dict get $result inserted]
                }
            }
        }
    }

    # Echo of a pending outgoing message: messagestore has already
    # flipped server_status pending → '' (server has it) and captured
    # server_id. Emit <Patch> so the GUI updates the checkmark; if the
    # row's timestamp moved (server stamp differs from our own_id), include
    # newtimestamp so the GUI can rekey the displayed row.
    method HandleConfirmation {chatJid confirmed} {
        foreach c $confirmed {
            set oldTs [dict get $c timestamp]
            set newTs [dict get $c newtimestamp]
            if {$oldTs != $newTs} {
                set patchMessages [list [dict create \
                    timestamp $oldTs newtimestamp $newTs \
                    server_status ""]]
            } else {
                set patchMessages [list [dict create \
                    timestamp $oldTs server_status ""]]
            }
            $client emit message <Patch> -jid $chatJid \
                -messages $patchMessages
        }
    }

    method HandleInsertion {chatJid inserted} {
        if {[llength $inserted] == 0} return
        set dbMsg [lindex [$messagestore get ids $chatJid $inserted] 0]
        $client emit message <New> -jid $chatJid -message $dbMsg
    }

    # Maximum BuildMessageStanza attempts per message before marking
    # failed. Each <SessionReady> tick for the peer counts as one
    # attempt; warming usually settles within 1-2 ticks for live
    # peers, so 5 gives slack for slow bundle fetches without
    # looping forever on an undeliverable peer.
    variable OmemoRetryBudget
    typevariable OMEMO_RETRY_LIMIT 5

    # Per-call cap on demote-and-retry steps; demotion makes progress durable
    # across calls, so the cap only bounds one history call's blast radius.
    typevariable MaxCursorRetries 5

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

    # Build a <message> for an outbound message, in one of two forms:
    #   wire      what goes on the network. OMEMO body is the <encrypted>
    #             payload + EME marker + a warning body; the <fallback> is
    #             dropped (its offsets index the cleartext body, which isn't
    #             on the wire). Encrypting can throw TACO_OMEMO_NOT_READY
    #             (transient - leave pending, retry on <SessionReady>) or
    #             TACO_OMEMO_TERMINAL (don't retry).
    #   readable  the cleartext record stored in raw_xml (debug). OMEMO keeps
    #             the real body + EME marker and the fallback; never encrypts,
    #             never throws.
    # Plaintext is identical in both modes.
    #
    #   chatJid  destination chat (peer to OMEMO-encrypt for; wire only)
    #   body     readable text; for a reply, includes the `> quoted` prefix
    #   oid      origin id (= row's own_id); matches the echo/ack back
    #   msgType  'chat' or 'groupchat'
    #   toJid    address the stanza is sent to
    #   encMode  'omemo' or '' for plaintext (caller decides)
    #   replyId  XEP-0461 reply target id, or '' when not a reply
    #   replyTo  author of the replied-to message
    #   fbEnd    length of the quote prefix in $body (XEP-0428 fallback span)
    #
    # OMEMO fail-closed: the wire form encrypts or throws, never cleartext.
    # See security invariant #2 in lib/taco/modules/omemo.tcl.
    method BuildMessageStanza {mode chatJid body oid msgType toJid encMode \
            {replyId ""} {replyTo ""} {fbEnd 0}} {
        set omemo   [expr {$encMode eq "omemo"}]
        set encWire [expr {$omemo && $mode eq "wire"}]
        return [j message -to $toJid -type $msgType -id $oid {
            if {$omemo} {
                if {$encWire} {
                    j #as-is [$client omemo encrypt $chatJid $body]
                }
                j encryption -ns urn:xmpp:eme:0 \
                    -namespace eu.siacs.conversations.axolotl \
                    -name OMEMO
            }
            if {$encWire} {
                j body #body \
                    "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            } else {
                j body #body $body
            }
            if {$replyId ne ""} {
                j reply -ns urn:xmpp:reply:0 -to $replyTo -id $replyId
                if {$fbEnd > 0 && !$encWire} {
                    j fallback -ns urn:xmpp:fallback:0 -for urn:xmpp:reply:0 {
                        j body -start 0 -end $fbEnd
                    }
                }
            }
            # Ask 1:1 peers for delivery/read markers (XEP-0184/0333).
            if {$msgType eq "chat"} {
                j request -ns urn:xmpp:receipts
                j markable -ns urn:xmpp:chat-markers:0
            }
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
    # 3. Emit <New> so the GUI can display immediately (optimistic).
    # 4. Write stanza to server if one exists.
    #
    # OMEMO cold-cache path: encrypt throws TACO_OMEMO_NOT_READY,
    # message persists pending without going on the wire, warming runs
    # in the background, OnOmemoSessionReady drives a retry. Reuses
    # the existing pending-row machinery rather than a separate
    # outbox/queue.
    #
    # Confirmation (pending → "", server has it) happens via two paths:
    #   MUC:  server echoes the message back with our id; the echo hits
    #         `ingestLive`, where `reconcile` finds the pending row and
    #         flips it to ''.
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

        lassign [$self DeriveAddressing $opts(-chat)] \
            msgType toJid fromJid fromRes

        set replyId ""
        set replyTo ""
        set wireBody $opts(-body)
        set fbEnd 0
        if {[info exists opts(-reply_to_ts)] && $opts(-reply_to_ts) ne ""} {
            lassign [$self BuildReplyTarget $opts(-chat) $opts(-reply_to_ts)] \
                replyId replyTo quoteBody
            if {$replyId ne ""} {
                lassign [reply::quote $quoteBody] quote fbEnd
                set wireBody $quote$opts(-body)
            }
        }

        set encMode [$self OutgoingEncMode $opts(-chat) $msgType]
        set stanza ""
        set status "pending"
        set failReason ""
        try {
            set stanza [$self BuildMessageStanza wire \
                $opts(-chat) $wireBody $oid $msgType $toJid $encMode \
                $replyId $replyTo $fbEnd]
        } trap TACO_OMEMO_NOT_READY {emsg} {
            # Stays pending; warming kicks via encrypt side effect.
            # Initial attempt counts toward the budget.
            jlog debug "send $opts(-chat): OMEMO not ready ($emsg), parking pending oid=$oid"
            set OmemoRetryBudget($oid) [expr {$OMEMO_RETRY_LIMIT - 1}]
        } trap TACO_OMEMO_TERMINAL {emsg} {
            jlog debug "send $opts(-chat): OMEMO terminal ($emsg), marking failed oid=$oid"
            set status "failed"
            set failReason "encrypt"
        }

        set msg [dict create \
            timestamp $ts \
            chat_jid $opts(-chat) \
            from_jid $fromJid \
            from_resource $fromRes \
            body $opts(-body) \
            server_id "" \
            own_id $oid \
            origin_id $oid \
            reply_id $replyId \
            reply_to $replyTo \
            raw_xml [expr {$stanza eq "" ? "" \
                : [jwrite [$self BuildMessageStanza readable $opts(-chat) \
                    $wireBody $oid $msgType $toJid $encMode \
                    $replyId $replyTo $fbEnd]]}] \
            server_status $status \
            encryption $encMode \
            fail_reason $failReason \
            on_wire [expr {$stanza ne ""}]]

        set result [$messagestore store [list $msg]]
        set inserted [dict get $result inserted]
        set dbMsg [lindex [$messagestore get ids $opts(-chat) $inserted] 0]

        $client emit message <New> \
            -jid $opts(-chat) -message $dbMsg

        if {$stanza ne ""} {
            $client write $stanza
        }
    }

    # Look up the replied-to row and resolve its reply id (reply::pick_id).
    # Returns {replyId author fullBody}; the body feeds the wire quote.
    method BuildReplyTarget {chatJid ts} {
        set found 0
        $client db eval {
            SELECT server_id, origin_id, own_id, from_jid, body
            FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND timestamp=$ts
            LIMIT 1
        } row { set found 1 }
        if {!$found} { return [list "" "" ""] }
        set replyId [reply::pick_id [IsMucChatJid $chatJid] \
            $row(server_id) $row(origin_id) $row(own_id)]
        return [list $replyId $row(from_jid) $row(body)]
    }

    # Attachment send (XEP-0363 + XEP-0066), optimistic + progress:
    #   1. store now as 'uploading' (attachment url = local path) and emit
    #      <New> so it shows immediately;
    #   2. hand the file to the file module, which PUTs it and reports bytes
    #      via `file <Update>` (keyed by the message id);
    #   3. on success promote to 'pending' with the public URL + OOB stanza and
    #      transmit (echo/ack then confirms);
    #   4. on failure mark 'failed' (the file module's <Update> shows it).
    method sendFile {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set path $opts(-path)
        set oid [clock microseconds]
        lassign [$self DeriveAddressing $chatJid] msgType toJid fromJid fromRes
        set encMode [$self OutgoingEncMode $chatJid $msgType]
        set msg [dict create \
            timestamp $oid chat_jid $chatJid \
            from_jid $fromJid from_resource $fromRes \
            body "" server_id "" own_id $oid raw_xml "" \
            encryption $encMode \
            attachments [OutgoingAttachment $path $path] \
            server_status uploading]
        set inserted [dict get [$messagestore store [list $msg]] inserted]
        set ts [lindex $inserted 0]
        set dbMsg [lindex [$messagestore get ids $chatJid $inserted] 0]
        $client emit message <New> -jid $chatJid -message $dbMsg
        $self StartUpload $chatJid $oid $ts $path $encMode
    }

    # The transfer id is the message id (== own_id == timestamp), so the GUI,
    # which keys an outgoing attachment by its message id, correlates upload
    # progress without a handshake. Progress/terminal state reach the GUI via
    # the file module's `file <Update>` event; OnUploaded is the internal
    # completion that turns the GET URL into the actual outgoing stanza.
    method StartUpload {chatJid oid ts path encMode} {
        $client file upload -id $ts -path $path \
            -encrypt [expr {$encMode eq "omemo"}] \
            -command [mymethod OnUploaded $chatJid $oid $ts $path $encMode]
    }

    method OnUploaded {chatJid oid ts path encMode url} {
        if {$url eq ""} {
            $messagestore markUploadFailed $chatJid $oid
            return
        }
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        # OMEMO: the aesgcm:// fragment carries the media key, so the URL must
        # ride inside the OMEMO body, never a cleartext OOB. RetrySend encrypts
        # it and parks the row pending if the session isn't ready yet.
        if {$encMode eq "omemo"} {
            $messagestore markUploaded $chatJid $oid $url \
                [jwrite [$self BuildMessageStanza readable $chatJid $url $oid \
                    $msgType $toJid omemo]] \
                [OutgoingAttachment $url $path] omemo
            $self RetrySend [dict create chat_jid $chatJid body $url \
                own_id $oid encryption omemo reply_id "" reply_to ""]
            return
        }
        set stanza [j message -to $toJid -type $msgType -id $oid {
            j body #body $url
            j x -ns jabber:x:oob { j url #body $url }
        }]
        $messagestore markUploaded $chatJid $oid $url [jwrite $stanza] \
            [OutgoingAttachment $url $path] ""
        $client write $stanza
    }

    # Re-attempt a failed upload using the local file recorded on the row. A
    # missing source surfaces as a `file <Update>` failed (file upload checks
    # readability), so no separate guard is needed here.
    method retryUpload {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set ts $opts(-timestamp)
        set row [lindex [$messagestore get ids $chatJid [list $ts]] 0]
        if {$row eq "" || [llength [dict get $row attachments]] == 0} return
        set path [dict get [lindex [dict get $row attachments] 0] url]
        set oid [dict get $row own_id]
        set encMode [expr {[dict exists $row encryption] \
            ? [dict get $row encryption] : ""}]
        $messagestore markUploading $chatJid $oid
        $self StartUpload $chatJid $oid $ts $path $encMode
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
                    server_status ""]]
        }
    }

    # Pending sends as RetrySend-shaped dicts, by scope:
    #   all          every pending row (reconnect retry)
    #   parked-omemo pending OMEMO still off the wire (on_wire=0)
    #   peer-omemo   parked-omemo narrowed to $peerJid
    # on_wire=1 rows are in flight awaiting an SM ack; re-sending would
    # duplicate, so the omemo scopes exclude them.
    method PendingSends {scope {peerJid ""}} {
        set sql {SELECT chat_jid, body, own_id, encryption, reply_id, reply_to
                 FROM chat_message
                 WHERE kind='message' AND server_status='pending'}
        switch $scope {
            all {}
            parked-omemo { append sql { AND encryption='omemo' AND on_wire=0} }
            peer-omemo   { append sql \
                { AND chat_jid=$peerJid AND encryption='omemo' AND on_wire=0} }
        }
        append sql { ORDER BY timestamp}
        set pending {}
        $client db eval $sql row {
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id) encryption $row(encryption) \
                reply_id $row(reply_id) reply_to $row(reply_to)]
        }
        return $pending
    }

    method RetryPending {} {
        # Group by MUC vs 1:1 — MUC messages must wait for room join
        foreach msg [$self PendingSends all] {
            set chatJid [dict get $msg chat_jid]
            if {[string match "*?join" $chatJid]} {
                regsub {\?join$} $chatJid {} roomJid
                lappend PendingRetry($roomJid) $msg
            } else {
                $self RetrySend $msg
            }
        }
    }

    # Bus callback for omemo:<SessionReady>/<DevicelistResolved> on
    # $peerJid. Retries pending OMEMO sends to $peerJid still parked off
    # the wire: re-running encrypt either succeeds, stays pending (still
    # warming), or TERMINAL-fails (empty devicelist).
    method OnOmemoSessionReady {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set pending [$self PendingSends peer-omemo $peerJid]
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
        set pending [$self PendingSends parked-omemo]
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

    # Retry a still-pending message. Uses BuildMessageStanza so OMEMO
    # chats get re-encrypted against the current devicelist (the
    # devicelist may have changed since the original send; replaying a
    # stored stanza would either leak cleartext or send to a
    # stale recipient set). Honors the row's stamped `encryption` —
    # automatic retries never downgrade an OMEMO message to plaintext
    # even if the per-chat toggle was flipped off in the meantime.
    method RetrySend {msg} {
        set chatJid [dict get $msg chat_jid]
        set body    [dict get $msg body]
        set oid     [dict get $msg own_id]
        # double check encryption desire
        set dbEnc [$client db onecolumn {
            SELECT encryption FROM chat_message
            WHERE chat_jid=$chatJid AND own_id=$oid AND kind='message'
        }]
        set dictEnc [expr {[dict exists $msg encryption] \
            ? [dict get $msg encryption] : ""}]
        set encMode [expr {($dbEnc eq "omemo" || $dictEnc eq "omemo") \
            ? "omemo" : ""}]
        # Preserve the reply linkage across retries. The textual quote
        # fallback isn't reconstructed (the stored body is the clean,
        # unquoted text), so fbEnd stays 0 - 0461-aware peers still see
        # the <reply> reference.
        set replyId [expr {[dict exists $msg reply_id] \
            ? [dict get $msg reply_id] : ""}]
        set replyTo [expr {[dict exists $msg reply_to] \
            ? [dict get $msg reply_to] : ""}]
        lassign [$self DeriveAddressing $chatJid] msgType toJid _ _

        jlog debug "RetrySend $chatJid oid=$oid encMode=$encMode"
        try {
            set stanza [$self BuildMessageStanza wire \
                $chatJid $body $oid $msgType $toJid $encMode \
                $replyId $replyTo]
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
        # on_wire stops a later <SessionReady> tick re-sending this row;
        # raw_xml is refreshed only as a debug record (readable form, not
        # the wire ciphertext).
        set xml [jwrite [$self BuildMessageStanza readable \
            $chatJid $body $oid $msgType $toJid $encMode \
            $replyId $replyTo]]
        $client db eval {
            UPDATE chat_message SET on_wire=1, raw_xml=$xml
            WHERE chat_jid=$chatJid AND own_id=$oid
        }
        $client write $stanza
    }

    # resend -chat X -timestamp T ?-plaintext 0|1?
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
        set chatJid $opts(-chat)
        set ts      $opts(-timestamp)

        set row [$client db eval {
            SELECT own_id, body, encryption, reply_id, reply_to
            FROM chat_message
            WHERE chat_jid=$chatJid AND timestamp=$ts AND kind='message'
        }]
        if {[llength $row] == 0} return
        lassign $row oid body enc replyId replyTo

        if {$opts(-plaintext)} {
            set enc ""
            $client db eval {
                UPDATE chat_message SET encryption=''
                WHERE chat_jid=$chatJid AND timestamp=$ts
            }
        }

        # Fresh attempt: reset budget, flip back to pending, clear on_wire
        # (RetrySend re-stamps it on write; a still-parked OMEMO retry must
        # stay eligible for <SessionReady>) and clear the prior failure so
        # the GUI shows it in flight; MarkOutgoingFailed re-stamps
        # fail_reason if it fails again.
        unset -nocomplain OmemoRetryBudget($oid)
        $client db eval {
            UPDATE chat_message
            SET server_status='pending', fail_reason='', on_wire=0
            WHERE chat_jid=$chatJid AND timestamp=$ts
        }
        $client emit message <Patch> -jid $chatJid \
            -messages [list [dict create \
                timestamp $ts server_status pending fail_reason ""]]

        $self RetrySend [dict create \
            chat_jid $chatJid body $body own_id $oid encryption $enc \
            reply_id $replyId reply_to $replyTo]
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

    # maxTimestamp -chat $chatJid -command $cb — newest real message
    # timestamp for the chat, used by the chat view's at-tail check.
    # A fresh query, not the chats-module MaxTimestamps cache: that cache
    # counts hole rows and misses the timestamp UPDATE on MUC-echo
    # confirmation, so it can't answer this authoritatively.
    tackymethod maxTimestamp {args} {
        array set opts $args
        set ts [$client db onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$opts(-chat) AND kind='message'
        }]
        return [expr {$ts eq "" ? "" : $ts}]
    }

    # markDisplayed -chat $chatJid -timestamp $ts
    # Send a `displayed` marker for a read message. No-op for MUC, when
    # disabled, or when the row has no origin id to reference.
    tackymethod markDisplayed {args} {
        array set opts $args
        if {![$self MarkersEnabled]} return
        if {[string match "*?join" $opts(-chat)]} return
        set originId [$client db onecolumn {
            SELECT origin_id FROM chat_message
            WHERE chat_jid=$opts(-chat) AND timestamp=$opts(-timestamp)
        }]
        if {$originId eq ""} return
        $self SendMarker $opts(-chat) displayed urn:xmpp:chat-markers:0 $originId
    }

    # react -chat $chatJid -timestamp $targetTs -emoji $emoji
    # Toggle one emoji in our XEP-0444 reaction set for a message. The set
    # is recomputed and sent whole (the protocol sends the complete set, not
    # a delta); toggling off the last emoji sends an empty <reactions/>.
    tackymethod react {args} {
        array set opts $args
        set targetTs $opts(-timestamp)
        set targetId [$self ReactionTargetId $opts(-chat) $targetTs]
        if {$targetId eq ""} return
        set ownId [$self OwnReactionSenderId $opts(-chat)]
        set current [$messagestore ownReactions $opts(-chat) $targetId $ownId]
        set idx [lsearch -exact $current $opts(-emoji)]
        if {$idx >= 0} {
            set current [lreplace $current $idx $idx]
        } else {
            lappend current $opts(-emoji)
        }
        $self SetReactions $opts(-chat) $targetTs $current
    }

    # reactClear -chat $chatJid -timestamp $targetTs — drop all our reactions.
    tackymethod reactClear {args} {
        array set opts $args
        $self SetReactions $opts(-chat) $opts(-timestamp) {}
    }

    # Persist our full reaction set for a message (optimistic, is_own=1),
    # patch the local view, and put the set on the wire. In a MUC the room
    # reflects it back, re-applying idempotently to the same own-keyed row.
    method SetReactions {chatJid targetTs emojis} {
        set targetId [$self ReactionTargetId $chatJid $targetTs]
        if {$targetId eq ""} return
        set ownId [$self OwnReactionSenderId $chatJid]
        set ownLabel [$self OwnReactionLabel $chatJid]
        $messagestore applyReaction $chatJid $targetId $ownId $ownLabel 1 \
            $emojis [clock microseconds]
        $self EmitReactionPatch $chatJid $targetTs
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        $self SendReactions $toJid $msgType $targetId $emojis
    }

    # Wire id a reaction references, by the target message's stored ids:
    # MUC stanza-id, else 1:1 origin/own (reply::pick_id). "" if unresolved.
    method ReactionTargetId {chatJid targetTs} {
        set found 0
        $client db eval {
            SELECT server_id, origin_id, own_id FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND timestamp=$targetTs
            LIMIT 1
        } row { set found 1 }
        if {!$found} { return "" }
        return [reply::pick_id [IsMucChatJid $chatJid] \
            $row(server_id) $row(origin_id) $row(own_id)]
    }

    # Our stable reactor key for a chat: own occupant-id in a MUC (nick
    # fallback when the room has no XEP-0421), bare jid in 1:1. Must agree
    # with resolveSender's own sender_id so the optimistic local row and the
    # reflected echo land on the same key.
    method OwnReactionSenderId {chatJid} {
        if {[IsMucChatJid $chatJid]} {
            regsub {\?join$} $chatJid {} roomJid
            set roomJid [jid bare $roomJid]
            set myOcc [$client muc myOccupantId -jid $roomJid]
            if {$myOcc ne ""} { return $myOcc }
            return [$client muc myNick -jid $roomJid]
        }
        return [jid bare [$client cget -jid]]
    }

    # Display label for our own reaction row: our nick in a MUC, bare jid in
    # 1:1. Separate from the sender key, which is the opaque occupant-id.
    method OwnReactionLabel {chatJid} {
        if {[IsMucChatJid $chatJid]} {
            regsub {\?join$} $chatJid {} roomJid
            return [$client muc myNick -jid [jid bare $roomJid]]
        }
        return [jid bare [$client cget -jid]]
    }

    # Send our current reaction set for $targetId. An empty set sends an
    # empty <reactions/> (retract all). <store/> asks the server to archive
    # it so the set reconstructs from MAM.
    method SendReactions {toJid msgType targetId emojis} {
        $client write [j message -to $toJid -type $msgType \
                -id [clock microseconds] {
            j reactions -ns urn:xmpp:reactions:0 -id $targetId {
                foreach e $emojis { j reaction #body $e }
            }
            j store -ns urn:xmpp:hints
        }]
    }

    # history -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50?
    #         ?-tag $tag? -command $cb
    # Always async — calls -command with result list.
    # -tag: if given, the callback can be cancelled via `cancel -tag $tag`.
    #
    # Local-first: tries the local store before the server. messagestore
    # get methods truncate at holes and signal `bounded=1` when a
    # hole forced truncation and the limit wasn't satisfied; the
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
        # MAM only when there's a cursor to anchor the fill - initial
        # loads with some local data show what they have; the user
        # scrolls into the hole later to trigger fill. Empty local is the
        # exception: a cursorless load with nothing stored falls through
        # to a cursorless MAM fetch (first open of a chat pulls its
        # newest archive page).
        if {[llength $localMessages] >= $limit
            || ([llength $localMessages] > 0
                && (!$bounded || !$hasCursor))} {
            {*}$callback $localMessages
            return
        }

        # For -after queries with no hole ahead, skip MAM when
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

        $self QueryServer $chatJid $before $after $limit $callback $tag \
            $bounded 0
    }

    # Fire one MAM page anchored on the nearest citizen in the queried
    # direction (oldest at-or-after $before, newest at-or-before $after), or
    # cursorless when none exists. `attempt` bounds the OnFetch retry loop.
    method QueryServer {chatJid before after limit callback tag wasBounded \
                        attempt} {
        set direction [expr {$after ne "" ? "newer" : "older"}]
        set mamArgs [list -max $limit]
        set cursorId ""
        if {$before ne ""} {
            set cursorId [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
                  AND timestamp >= $before
                ORDER BY timestamp ASC LIMIT 1
            }]
            if {$cursorId ne ""} { lappend mamArgs -before $cursorId }
        } elseif {$after ne ""} {
            set cursorId [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
                  AND timestamp <= $after
                ORDER BY timestamp DESC LIMIT 1
            }]
            if {$cursorId ne ""} { lappend mamArgs -after $cursorId }
        } else {
            set cursorId [$client db onecolumn {
                SELECT server_id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
                ORDER BY timestamp ASC LIMIT 1
            }]
            if {$cursorId ne ""} { lappend mamArgs -before $cursorId }
        }

        lappend mamArgs -command [mymethod OnFetch $chatJid $before $after \
            $limit $callback $tag $direction $wasBounded $cursorId $attempt]

        $client mam queryChat $chatJid {*}$mamArgs
    }

    method OnFetch {chatJid before after limit callback tag direction \
                    wasBounded cursorId attempt mamResult} {
        if {[dict exists $mamResult error]} {
            if {$tag ne "" && ![info exists ActiveTags($tag)]} return
            # item-not-found means the cursor id was never archived (a poisoned
            # live stanza-id, or a wrong `by`): demote the row and retry from
            # the next citizen. Other errors just fall back to local.
            set cond [expr {[dict exists $mamResult error_condition]
                ? [dict get $mamResult error_condition] : ""}]
            if {$cond eq "item-not-found" && $cursorId ne ""
                && $attempt < $MaxCursorRetries} {
                $messagestore demote $chatJid $cursorId
                $self QueryServer $chatJid $before $after $limit $callback \
                    $tag $wasBounded [expr {$attempt + 1}]
                return
            }
            set local [$self GetLocal $chatJid $before $after $limit]
            {*}$callback [dict get $local messages]
            return
        }

        # Only `new` messages are stored; `parsed` keeps every verdict
        # (each carries a timestamp) so the hole ops below still span the
        # true archive range.
        lassign [$self IngestMamBatch $chatJid $mamResult] parsed toStore
        # Store the new batch (even if cancelled - data is useful)
        if {[llength $toStore] > 0} {
            $messagestore store $toStore
        }
        $self SweepFetchedRange $chatJid $parsed $direction $before $after

        set cancelled [expr {$tag ne "" && ![info exists ActiveTags($tag)]}]
        set local [$self GetLocal $chatJid $before $after $limit]
        set complete [dict get $mamResult complete]
        set pageSize [llength [dict get $mamResult messages]]

        # A page can be entirely empty-body stanzas (receipts, chatstates).
        # Responding with nothing displayable would strand the GUI: its
        # scroll-back cursor only advances on displayed messages, so it
        # would re-issue the same query forever. Page on by this page's far
        # edge only while the local read still has nothing; short pages are
        # returned immediately and the GUI's thirst loop drives further
        # fetching. The pageSize>0 guard stops a complete=false empty
        # response from spinning.
        if {!$cancelled
            && [llength [dict get $local messages]] == 0
            && !$complete && $pageSize > 0} {
            set nextCursor [expr {$direction eq "older"
                ? [dict get $mamResult first] : [dict get $mamResult last]}]
            if {$nextCursor ne ""} {
                set rsmFlag [expr {$direction eq "older" ? "-before" : "-after"}]
                $client mam queryChat $chatJid -max $limit $rsmFlag $nextCursor \
                    -command [mymethod OnFetch $chatJid $before $after $limit \
                        $callback $tag $direction $wasBounded "" $attempt]
                return
            }
        }

        # Terminal page (enough collected, archive exhausted, no cursor to
        # advance, or cancelled): finalise the queried-direction boundary.
        if {$complete} {
            $self ClearBoundingHole $chatJid $direction $before $after \
                $wasBounded
        } else {
            $self PlaceFarEdgeHole $chatJid $parsed $direction
        }

        if {$cancelled} return
        {*}$callback [dict get $local messages]
    }

    # Cursor timestamp on the queried side (older->before, newer->after);
    # empty on an initial open, where there's no anchor.
    proc fetch_cursor_ts {direction before after} {
        expr {$direction eq "older" ? $before : $after}
    }

    # Sweep holes between the cursor and the batch's far edge. RSM
    # guarantees that range is contiguous, so any hole there was a false
    # positive (paginated past, or stale). No-op without a cursor or batch.
    method SweepFetchedRange {chatJid messages direction before after} {
        set cursorTs [fetch_cursor_ts $direction $before $after]
        if {[llength $messages] == 0 || $cursorTs eq ""} return
        set tsList [lmap m $messages {dict get $m timestamp}]
        if {$direction eq "older"} {
            $messagestore hole removeBetween $chatJid \
                [tcl::mathfunc::min {*}$tsList] $cursorTs
        } else {
            $messagestore hole removeBetween $chatJid \
                $cursorTs [tcl::mathfunc::max {*}$tsList]
        }
    }

    # Mark "archive continues beyond here, not yet fetched" at the batch's far
    # edge. Only once the fill loop stops short (complete=false): on an
    # intermediate page it would truncate the next page on the cursorless path.
    method PlaceFarEdgeHole {chatJid messages direction} {
        if {[llength $messages] == 0} return
        set tsList [lmap m $messages {dict get $m timestamp}]
        if {$direction eq "older"} {
            $messagestore hole add $chatJid older [tcl::mathfunc::min {*}$tsList]
        } else {
            $messagestore hole add $chatJid newer [tcl::mathfunc::max {*}$tsList]
        }
    }

    # Remove the bounding hole proven false by complete=true: the server
    # confirms nothing exists past the cursor in this direction. Applies even
    # for an empty terminal page.
    method ClearBoundingHole {chatJid direction before after wasBounded} {
        set cursorTs [fetch_cursor_ts $direction $before $after]
        if {$wasBounded && $cursorTs ne ""} {
            $messagestore hole remove $chatJid $direction $cursorTs
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

        lassign [$self IngestMamBatch $chatJid $mamResult] _ toStore
        if {[llength $toStore] > 0} {
            $messagestore store $toStore
        }

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set result [$messagestore get around $chatJid $date $limit]
        {*}$callback $result
    }

    # gotoReply -chat $jid -reply_id $rid ?-reply_to $jid? ?-limit 50?
    #           ?-tag $tag? -command $cb
    # Resolve an XEP-0461 reply target in the local store and jump to it
    # via `goto`. An uncached target yields an empty result; remote fetch
    # by stanza-id is not implemented.
    method gotoReply {args} {
        set defaults [dict create -limit 50 -tag "" -reply_to ""]
        set opts [dict merge $defaults $args]

        set chatJid  [dict get $opts -chat]
        set replyId  [dict get $opts -reply_id]
        set replyTo  [dict get $opts -reply_to]
        set limit    [dict get $opts -limit]
        set tag      [dict get $opts -tag]
        set callback [dict get $opts -command]

        set ts [$messagestore resolveReply $chatJid $replyId $replyTo]
        if {$ts eq ""} {
            {*}$callback [dict create messages {} anchor ""]
            return
        }
        $self goto -chat $chatJid -date $ts -source local \
            -limit $limit -tag $tag -command $callback
    }

    # search -chat $jid -query "text" ?-before $serverId? ?-limit 20?
    #        ?-tag $tag? -command $cb
    #
    # Full text search via MAM. Always server-side.
    # Results are stored to the local cache and wrapped with holes
    # on each side — a hit is an isolated island whose surroundings we
    # know nothing about, so future pagination across it must fall
    # through to MAM. `hole add` is a no-op when the target gap is
    # already holeed, so repeated searches don't accumulate.
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
            set r [$self ParseResultNode $resultNode $chatJid]
            set verdict [dict get $r verdict]
            if {$verdict eq "reaction"} {
                $self ApplyReactionVerdict $chatJid $r
                continue
            }
            if {$verdict eq "confirmed"} {
                $self HandleConfirmation $chatJid [list [dict get $r reconciled]]
                continue
            }
            if {$verdict ne "new"} continue
            set result [$messagestore store [list [dict get $r msg]]]
            set ins [dict get $result inserted]
            if {[llength $ins] > 0} {
                set storedTs [lindex $ins 0]
                $messagestore hole add $chatJid older $storedTs
                $messagestore hole add $chatJid newer $storedTs
                lappend messages [lindex [$messagestore get ids $chatJid $ins] 0]
            }
        }

        set complete [dict get $mamResult complete]
        set last [dict get $mamResult last]

        {*}$callback [dict create messages $messages complete $complete last $last]
    }

    # Walk a single-chat MAM batch through Classify, firing <Patch> for each
    # envelope-confirmed send. Returns {parsed toStore}: `parsed` is every
    # verdict (so callers can reason about the true archive span when
    # placing/sweeping holes) and `toStore` the new message dicts to
    # persist in one store call.
    method IngestMamBatch {chatJid mamResult} {
        set parsed {}
        set toStore {}
        foreach resultNode [dict get $mamResult messages] {
            set r [$self ParseResultNode $resultNode $chatJid]
            lappend parsed $r
            switch [dict get $r verdict] {
                reaction {
                    $self ApplyReactionVerdict $chatJid $r
                }
                confirmed {
                    $self HandleConfirmation $chatJid \
                        [list [dict get $r reconciled]]
                }
                new { lappend toStore [dict get $r msg] }
            }
        }
        return [list $parsed $toStore]
    }

    # MAM preamble: pull the envelope (archive id, server stamp, ids) off one
    # <result>/<forwarded> wrapper, then hand to the shared Classify core.
    method ParseResultNode {resultNode chatJid} {
        set serverId [xsearch $resultNode -get @id]
        set fwdNode [lindex [xsearch $resultNode forwarded -ns urn:xmpp:forward:0] 0]
        set ts [ParseTimestamp \
            [xsearch $fwdNode delay -ns urn:xmpp:delay -get @stamp]]
        set msgNode [lindex [xsearch $fwdNode message] 0]
        set ids [$self ExtractEnvelopeIds $msgNode $chatJid -server_id $serverId]
        return [$self Classify $chatJid $msgNode $ts $ids]
    }

    # The single ingestion core, shared by the live path (ingestLive) and
    # every MAM path (via ParseResultNode). Envelope-first: reconcile on the
    # ids BEFORE decrypting, so a known send is confirmed and a known citizen
    # flagged duplicate without a decrypt; only a genuinely new message is
    # decrypted and parsed. `ids` is the {serverId ownId originId} triple the
    # caller extracted (the sources differ in where each id comes from).
    # Returns one verdict; `timestamp` (server stamp) rides every verdict
    # so the MAM loops can reason over the true archive span:
    #   {verdict confirmed timestamp T reconciled V}  pending send echoed
    #   {verdict duplicate timestamp T}               already a citizen
    #   {verdict drop      timestamp T}               new but displayless
    #   {verdict new       timestamp T msg M}         new, store M
    #   {verdict reaction  timestamp T ...}           XEP-0444 reaction
    method Classify {chatJid msgNode ts ids} {
        set reaction [$self ParseReaction $chatJid $msgNode]
        if {$reaction ne ""} {
            # `timestamp` keeps the reaction verdict uniform with the
            # others so the MAM parsed-list consumers (SweepFetchedRange /
            # PlaceFarEdgeHole) can span it; it's also the LWW ts.
            return [dict create verdict reaction timestamp $ts {*}$reaction]
        }
        lassign $ids serverId ownId originId
        set v [$messagestore reconcile $chatJid $serverId $ownId $originId $ts]
        switch [dict get $v verdict] {
            confirmed {
                return [dict create verdict confirmed \
                    timestamp $ts reconciled $v]
            }
            duplicate {
                return [dict create verdict duplicate timestamp $ts]
            }
        }

        # decryptForwarded yields a synthesised plaintext stanza, or the
        # original on failure / when already plaintext (the live path is
        # decrypted upstream, so this is a no-op there); ParseMessage returns
        # "" for a displayless one.
        set msgNode [$client omemo decryptForwarded $msgNode]
        set msg [$self ParseMessage $msgNode \
            -chat_jid $chatJid -timestamp $ts \
            -server_id $serverId -own_id $ownId -origin_id $originId]
        if {$msg eq ""} {
            return [dict create verdict drop timestamp $ts]
        }
        return [dict create verdict new timestamp $ts msg $msg]
    }

    # Extract an XEP-0444 reaction from a <message> node into a descriptor,
    # or "" when the stanza carries no reactions. Resolves reactor identity
    # per chat kind: 1:1 uses the bare sender jid; MUC uses the XEP-0421
    # occupant-id (fail-closed - a groupchat reaction with no occupant-id
    # that isn't our own is dropped). Own-detection: bare jid in 1:1, nick
    # in a MUC (own reactions are keyed by nick, since we don't track our
    # own occupant-id). `emojis` is the reactor's full set ('' = retracted).
    method ParseReaction {chatJid msgNode} {
        set rxNode [lindex [xsearch $msgNode reactions -ns urn:xmpp:reactions:0] 0]
        if {$rxNode eq ""} { return "" }
        set targetId [xsearch $rxNode -get @id]
        if {$targetId eq ""} { return "" }
        set emojis [xsearch $rxNode reaction -gather body]
        set sender [$self resolveSender $chatJid $msgNode]
        set senderId [dict get $sender sender_id]
        set isOwn [dict get $sender is_own]
        # Fail-closed: a remote MUC reaction with no occupant-id has no
        # stable identity to attribute it to, so drop it.
        if {!$isOwn && $senderId eq ""} { return "" }
        if {[IsMucChatJid $chatJid]} {
            set senderLabel [jid resource [xsearch $msgNode -get @from]]
        } else {
            set senderLabel $senderId
        }
        return [dict create target_id $targetId sender_id $senderId \
            sender_label $senderLabel is_own $isOwn emojis $emojis]
    }

    # Resolve who sent a stanza into {sender_id is_own}. sender_id is the
    # stable identity to key/compare on: bare jid in 1:1, XEP-0421
    # occupant-id in a MUC. is_own carries the fail-open-to-nick policy, so
    # it is not derivable from sender_id alone (in a non-0421 room every
    # occupant-id is "", including ours). The display label is a per-feature
    # concern the caller attaches from the nick it already holds.
    method resolveSender {chatJid msgNode} {
        set rawFrom [xsearch $msgNode -get @from]
        if {![IsMucChatJid $chatJid]} {
            set bare [jid norm [jid bare $rawFrom]]
            return [dict create sender_id $bare \
                is_own [expr {$bare eq [jid bare [$client cget -jid]]}]]
        }
        regsub {\?join$} $chatJid {} roomJid
        set roomJid [jid bare $roomJid]
        set occ [xsearch $msgNode occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        set myOcc [$client muc myOccupantId -jid $roomJid]
        set nick [jid resource $rawFrom]
        # Compare by occupant-id only when both ours and the stanza's are
        # known; otherwise fall back to nick equality.
        if {$occ ne "" && $myOcc ne ""} {
            set isOwn [expr {$occ eq $myOcc}]
        } else {
            set isOwn [expr {$nick eq [$client muc myNick -jid $roomJid]}]
        }
        # Key on the occupant-id whenever the stanza carries one (stable, ours
        # and peers'); else our nick for our own row (fail-open); else "" -
        # a remote sender with no stable identity, which the caller drops.
        if {$occ ne ""} {
            set senderId $occ
        } elseif {$isOwn} {
            set senderId $nick
        } else {
            set senderId ""
        }
        return [dict create sender_id $senderId is_own $isOwn]
    }

    # Apply a `reaction` verdict to the store and, when the target
    # message is present locally, emit a <Patch> refreshing its aggregated
    # reactions. Shared by the live and every MAM dispatch path.
    method ApplyReactionVerdict {chatJid verdict} {
        set targetTs [$messagestore applyReaction $chatJid \
            [dict get $verdict target_id] [dict get $verdict sender_id] \
            [dict get $verdict sender_label] [dict get $verdict is_own] \
            [dict get $verdict emojis] [dict get $verdict timestamp]]
        if {$targetTs eq ""} return
        $self EmitReactionPatch $chatJid $targetTs
    }

    method EmitReactionPatch {chatJid targetTs} {
        set agg [$messagestore reactionsForMessage $chatJid $targetTs]
        $client emit message <Patch> -jid $chatJid \
            -messages [list [dict create timestamp $targetTs reactions $agg]]
    }

    # {serverId ownId originId} off a <message>, derived once for the dedup
    # check and the parser. Callers override -server_id (MAM <result @id>)
    # and -own_id (live carbon). Otherwise server_id from <stanza-id>;
    # origin_id from <origin-id>, else @id; own_id from @id when the stanza
    # is from our own bare JID (it equals the own_id we stored on send, so
    # the row confirms rather than duplicates).
    method ExtractEnvelopeIds {msgNode chatJid args} {
        if {[dict exists $args -server_id]} {
            set serverId [dict get $args -server_id]
        } else {
            set serverId [xsearch $msgNode stanza-id -ns urn:xmpp:sid:0 -get @id]
        }
        set originId [xsearch $msgNode origin-id -ns urn:xmpp:sid:0 -get @id]
        if {$originId eq ""} {
            set originId [xsearch $msgNode -get @id]
        }
        if {[dict exists $args -own_id]} {
            set ownId [dict get $args -own_id]
        } else {
            set rawFrom [xsearch $msgNode -get @from]
            if {$rawFrom ne "" && [jid bare $rawFrom] eq [jid bare [$client cget -jid]]} {
                set ownId [xsearch $msgNode -get @id]
            } else {
                set ownId ""
            }
        }
        return [list $serverId $ownId $originId]
    }

    # Build a message dict from a (decrypted) <message> node. Caller
    # supplies -chat_jid, -timestamp and the envelope ids
    # (-server_id/-own_id/-origin_id) from ExtractEnvelopeIds. Returns ""
    # for a displayless stanza (control type or bodyless payload).
    method ParseMessage {msgNode args} {
        set chatJid [dict get $args -chat_jid]
        lassign [reply::parse $msgNode] replyId replyTo
        set body [xsearch $msgNode body -get body]
        if {$replyId ne ""} {
            set body [reply::strip_fallback $msgNode $body]
        }
        if {[ClassifyMessage $msgNode $body] ne "message"} {
            return ""
        }
        set rawFrom [xsearch $msgNode -get @from]
        set fromJid [NormalizeAuthorJid $chatJid $rawFrom]
        set fromRes [SplitFromResource $chatJid $rawFrom]
        # Encryption stamp from the EME marker (XEP-0380), which the decrypt
        # path (SynthesisePlain) leaves on decrypted messages; plaintext has
        # none. Drives the lock on peer messages.
        set emeNs [xsearch $msgNode encryption -ns urn:xmpp:eme:0 -get @namespace]
        set enc [expr {$emeNs eq "eu.siacs.conversations.axolotl" ? "omemo" : ""}]
        set ownId [expr {[dict exists $args -own_id] \
            ? [dict get $args -own_id] : ""}]
        set originId [expr {[dict exists $args -origin_id] \
            ? [dict get $args -origin_id] : ""}]
        dict create \
            timestamp  [dict get $args -timestamp] \
            chat_jid   $chatJid \
            from_jid   $fromJid \
            from_resource $fromRes \
            body       $body \
            server_id  [dict get $args -server_id] \
            own_id     $ownId \
            origin_id  $originId \
            occupant_id [xsearch $msgNode occupant-id \
                -ns urn:xmpp:occupant-id:0 -get @id] \
            reply_id   $replyId \
            reply_to   $replyTo \
            raw_xml    [jwrite $msgNode] \
            attachments [ExtractAttachments $msgNode $body] \
            server_status "" \
            encryption $enc
    }
}

# A <body> is a "message"; a bodyless stanza is a control type
# (receipt/marker/chatstate) or "" for any other bodyless payload (e.g. a
# decrypted keytransport). Only "message" is stored; the rest are dropped.
proc ClassifyMessage {msgNode body} {
    if {$body ne ""} { return message }
    foreach {kind ns} {
        receipt   urn:xmpp:receipts
        marker    urn:xmpp:chat-markers:0
        chatstate http://jabber.org/protocol/chatstates
        reaction  urn:xmpp:reactions:0
    } {
        if {[llength [xsearch $msgNode * -ns $ns]] > 0} { return $kind }
    }
    return ""
}

# Derive the attachment list for an incoming <message>. An attachment is
# signalled by an XEP-0066 Out-of-Band <x><url/></x> child (what
# Conversations/Dino/Gajim send for XEP-0363 shares). A plaintext body that
# merely *is* a URL is just a link, not an attachment, so it is left as text.
#
# XEP-0454 (OMEMO media) is the exception: the encrypted share has no OOB (the
# aesgcm:// URL carries the key and so lives only in the OMEMO body), so a body
# that is itself an aesgcm:// URL is recognised as the attachment.
# Returns a (possibly empty) Tcl list of attachment dicts.
proc ExtractAttachments {msgNode body} {
    set atts {}
    xsearch $msgNode x -ns jabber:x:oob url -script u {
        set url [dict get $u body]
        if {$url ne ""} { lappend atts [attachment_dict $url] }
    }
    if {[llength $atts] == 0 && [is_aesgcm_url [string trim $body]]} {
        lappend atts [attachment_dict [string trim $body]]
    }
    return $atts
}

proc attachment_dict {url} {
    dict create url $url type [attachment_kind $url] \
        name [attachment_basename $url] size "" mime ""
}

# Display text for a message with attachments: the body, emptied when it is
# just the (OOB-duplicated) attachment URL, kept when it carries real text.
proc attachment_caption {body attachments} {
    set trimmed [string trim $body]
    foreach att $attachments {
        if {$trimmed eq [dict get $att url]} { return "" }
    }
    return $body
}

# Single-element attachment list for an outgoing send. `url` is the local
# path while uploading, then the public URL once known; `path` is always the
# local file (drives name/size/mime).
proc OutgoingAttachment {url path} {
    list [dict create url $url type [attachment_kind $path] \
        name [file tail $path] \
        size [expr {[file isfile $path] ? [file size $path] : ""}] \
        mime [attachment_mime $path]]
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
