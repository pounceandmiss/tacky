# Durable message delivery
# ========================
#
# Message dict keys:
#   timestamp, chat_jid, from_jid, body, server_id, origin_id,
#   raw_xml, server_status
#
# chat_jid assignment:
#   MUC groupchat:  room@muc?join   (appended by muc.say / OnGroupchatMessage)
#   MUC PM:         room@muc/nick   (set by OnPrivateMessage)
#   1:1 DM:         bare JID        (set by OnMessage from stanza @from)
#   MAM catchup:    derived from @from/@to vs own bare JID
#
# origin_id / dedup:
#   Outgoing messages use origin_id = timestamp (= <message id="...">).
#   Incoming messages get origin_id from the stanza's @id attribute.
#   IsDuplicate matches by server_id or origin_id (or content fallback).
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
#       1. ts = clock microseconds; origin_id = ts
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
#       → message.store
#         → ParseMessage: extracts server_id from <stanza-id>
#         → messagestore.store batch:
#           IsDuplicate finds pending row by origin_id
#           UPDATE server_status='received', captures server_id
#           Returns confirmed list
#         → Emit <Confirmed> (GUI shows checkmark)
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
#               → messagestore.confirmByOriginIds:
#                 UPDATE server_status='received' WHERE pending
#               → Emit <Confirmed> per confirmed message
#
#   For MUC, both paths may fire — confirmation is idempotent
#   (second confirm finds no pending rows, does nothing).
#
# === Incoming ===
#
#   1:1: server stanza
#     → message.OnMessage
#       → message.store
#         → store batch: INSERT (server_status="")
#         → Emit <Received> → GUI displays
#
#   MUC: server stanza
#     → muc.OnGroupchatMessage
#       → message.store (same path as above)
#
# === Retry on reconnect ===
#
#   message.OnReady
#     → RetryPending: SELECT WHERE server_status='pending'
#       1:1 messages: resend immediately via RetrySend
#       MUC messages: stash in PendingRetry($roomJid)
#     → client.emit intercepts muc <Joined>
#       → message.OnMucJoined: flush PendingRetry for that room
#         → RetrySend: rebuild stanza with same origin_id, $client write
#     → Echo/ack cycle confirms them normally
#
#   OnDisconnect clears PendingRetry (next OnReady re-queries DB).
#
# === GUI events ===
#
#   <Sent>      → OnLiveMessage: insert message (is_outgoing=1, no checkmark)
#   <Received>  → OnLiveMessage: insert message (is_outgoing=0)
#                  Dedup by timestamp/id — skips if already displayed
#   <Confirmed> → OnConfirmed: $hull receipt update $ts delivered (checkmark)
#
snit::type taco_message {
    option -client -readonly yes

    component messagestore -public messagestore

    variable client
    variable PubSubHandlers
    variable SyncedChats
    variable PendingRetry
    variable liveRegion ""
    variable ActiveTags

    constructor {args} {
	$self configurelist $args
	set client $options(-client)
	install messagestore using taco_messagestore $self.messagestore \
	    -db [$client cget -db]
	array set PubSubHandlers {}
	array set SyncedChats {}
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
	$self DoCatchup
	$self RetryPending
    }

    method DoCatchup {} {
	$client mam query -before {} -max 50 \
	    -command [mymethod OnCatchup]
    }

    method OnCatchup {mamResult} {
	if {[dict exists $mamResult error]} {
	    $client emit message <CatchupDone> -count 0
	    return
	}

	set myBareJid [jid bare [$client cget -jid]]
	set groups [dict create]

	foreach resultNode [dict get $mamResult messages] {
	    set fwdNode [lindex [xsearch $resultNode forwarded \
				    -ns urn:xmpp:forward:0] 0]
	    set msgNode [lindex [xsearch $fwdNode message] 0]

	    set fromBare [jid bare [xsearch $msgNode -get @from]]
	    set toBare   [jid bare [xsearch $msgNode -get @to]]

	    if {[string equal -nocase $fromBare $myBareJid]} {
		set chatJid $toBare
	    } else {
		set chatJid $fromBare
	    }

	    set msg [$self ParseResultNode $resultNode $chatJid]
	    if {[dict get $msg body] eq ""} continue

	    dict lappend groups $chatJid $msg
	}

	$messagestore region new catchupRegion
	set totalCount 0

	dict for {chatJid messages} $groups {
	    $messagestore store batch $messages catchupRegion
	    incr totalCount [llength $messages]
	}

	$client emit message <CatchupDone> -count $totalCount
    }

    method OnDisconnect {args} {
	array unset SyncedChats
	array unset PendingRetry
	set liveRegion ""
    }

    method OnMessage {stanza} {
	# Check for PubSub event -> dispatch
	set eventNodes [xsearch $stanza event -ns http://jabber.org/protocol/pubsub#event]
	if {[llength $eventNodes] > 0} {
	    set node [xsearch [lindex $eventNodes 0] items -get @node]
	    if {$node ne "" && [info exists PubSubHandlers($node)]} {
		{*}$PubSubHandlers($node) $stanza
		return
	    }
	}
	$self store [jid bare [xsearch $stanza -get @from]] $stanza
    }

    # Parse a live message stanza, store it, and emit message <Received>.
    # Called directly by OnMessage (DMs) and by the MUC module
    # (groupchat with room@muc?join, PMs with room@muc/nick).
    method store {chatJid stanza} {
	set body [xsearch $stanza body -get body]
	if {$body eq ""} return
	set stamp [xsearch $stanza delay -ns urn:xmpp:delay -get @stamp]
	set ts [expr {$stamp ne "" ? [ParseTimestamp $stamp] : [clock microseconds]}]
	set serverId [xsearch $stanza stanza-id -ns urn:xmpp:sid:0 -get @id]
	set msg [$self ParseMessage $stanza \
	    -chat_jid $chatJid -timestamp $ts -server_id $serverId]
	if {$liveRegion eq ""} {
	    $messagestore region new liveRegion
	}
	set result [$messagestore store batch [list $msg] liveRegion]
	set confirmed [dict get $result confirmed]
	if {[llength $confirmed] > 0} {
	    foreach c $confirmed {
		$client emit message <Confirmed> \
		    -jid $chatJid -timestamp [dict get $c timestamp]
	    }
	} elseif {[dict get $result inserted] > 0} {
	    $client emit message <Received> \
		-jid $chatJid -from [xsearch $stanza -get @from] -body $body \
		-message $msg
	}
    }

    # Durable message send — store before transmit, confirm on echo/ack.
    #
    # 1. Generate a unique ID, persist to DB with server_status='pending'.
    # 2. Emit <Sent> so the GUI can display immediately (optimistic).
    # 3. Write stanza to server (if this throws, message is safe in DB).
    #
    # Confirmation (pending → received) happens via two paths:
    #   MUC:  server echoes the message back with our id; the echo hits
    #         `store`, where `store batch` dedup finds the pending row
    #         and flips it to 'received'.
    #   1:1:  SM ack confirms the server received the stanza; `OnSmAck`
    #         calls `confirmByOriginIds` on the messagestore.
    # Both paths emit <Confirmed> so the GUI can show the checkmark.
    #
    # On reconnect, `RetryPending` resends any still-pending messages
    # with the same id, so the echo/ack cycle can complete.
    method send {args} {
	set chatJid [dict get $args -chat_jid]
	set body [dict get $args -body]

	set ts [clock microseconds]
	set oid $ts

	if {[string match "*?join" $chatJid]} {
	    set type groupchat
	    regsub {\?join$} $chatJid {} toJid
	    set nick [$client muc myNick -jid $toJid]
	    set fromJid $toJid/$nick
	} else {
	    set toJid $chatJid
	    set fromJid [$client cget -jid]
	}

	set stanza [j message -to $toJid -type $type -id $oid {
	    j body #body $body
	}]

	set msg [dict create \
	    timestamp $ts \
	    chat_jid $chatJid \
	    from_jid $fromJid \
	    body $body \
	    server_id "" \
	    origin_id $oid \
	    raw_xml [jwrite $stanza] \
	    server_status pending]

	if {$liveRegion eq ""} {
	    $messagestore region new liveRegion
	}
	$messagestore store batch [list $msg] liveRegion

	$client emit message <Sent> \
	    -jid $chatJid -body $body -message $msg

	$client write $stanza
    }

    method OnSmAck {args} {
	set stanzas [dict get $args -stanzas]
	set originIds {}
	foreach stanza $stanzas {
	    if {[dict get $stanza tag] ne "message"} continue
	    set oid [xsearch $stanza -get @id]
	    if {$oid ne ""} {
		lappend originIds $oid
	    }
	}
	if {[llength $originIds] == 0} return
	set confirmed [$messagestore confirmByOriginIds $originIds]
	foreach c $confirmed {
	    $client emit message <Confirmed> \
		-jid [dict get $c chat_jid] \
		-timestamp [dict get $c timestamp]
	}
    }

    method RetryPending {} {
	set pending {}
	$client db eval {
	    SELECT chat_jid, body, origin_id FROM chat_message
	    WHERE server_status='pending'
	    ORDER BY timestamp
	} row {
	    lappend pending [dict create \
		chat_jid $row(chat_jid) body $row(body) \
		origin_id $row(origin_id)]
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
	set oid [dict get $msg origin_id]
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

    method "pubsub handler" {node command} {
	set PubSubHandlers($node) $command
    }

    method "pubsub unhandler" {node} {
	unset -nocomplain PubSubHandlers($node)
    }

    # rawxml -chat $chatJid -timestamp $ts -command $cb
    tackymethod rawxml {args} {
	set chatJid [dict get $args -chat]
	set ts [dict get $args -timestamp]
	$client db onecolumn {
	    SELECT raw_xml FROM chat_message
	    WHERE chat_jid=$chatJid AND timestamp=$ts
	}
    }

    # history -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50?
    #         ?-tag $tag? -command $cb
    # Always async — calls -command with result list.
    # -tag: if given, the callback can be cancelled via `cancel -tag $tag`.
    #
    # Local-first: tries the local store before the server.
    # messagestore get is region-scoped, so it only returns messages from
    # the same contiguous region as the cursor.  When the region is
    # exhausted (local returns empty) and the chat isn't fully synced,
    # MAM backfill kicks in to fetch the next batch from the server.
    method history {args} {
	set defaults [dict create -before "" -after "" -limit 50 -command "" -tag "" -no-local 0]
	set opts [dict merge $defaults $args]

	set chatJid [dict get $opts -chat]
	set limit   [dict get $opts -limit]
	set callback [dict get $opts -command]
	set before [dict get $opts -before]
	set after [dict get $opts -after]
	set tag [dict get $opts -tag]
	set noLocal [dict get $opts -no-local]

	if {$tag ne ""} {
	    set ActiveTags($tag) 1
	}

	# Try local store first (unless caller opts out, e.g. goto-date)
	set getArgs [list -limit $limit]
	if {$before ne ""} { lappend getArgs -before $before }
	if {$after ne ""}  { lappend getArgs -after $after }
	set local [$messagestore get $chatJid {*}$getArgs]

	if {[llength $local] > 0 || [info exists SyncedChats($chatJid)]} {
	    if {!$noLocal || [info exists SyncedChats($chatJid)]} {
		{*}$callback $local
		return
	    }
	}

	# No local data and not synced — query the server
	$messagestore region new backfillRegion

	set mamArgs [list -max $limit]
	if {$before ne ""} {
	    # Time-anchored: fetch messages ending at this timestamp
	    lappend mamArgs -end [FormatTimestampISO $before] -before {}
	    set cursor ""
	} elseif {$after ne ""} {
	    # Time-anchored: fetch messages starting at this timestamp
	    lappend mamArgs -start [FormatTimestampISO $after]
	    set cursor ""
	} else {
	    # Cursor-based: page backwards from earliest known server_id
	    set cursor [$client db onecolumn {
		SELECT server_id FROM chat_message
		WHERE chat_jid=$chatJid AND server_id != ''
		ORDER BY timestamp ASC LIMIT 1
	    }]
	    if {$cursor ne ""} {
		lappend mamArgs -before $cursor
	    }
	}
	lappend mamArgs -command [mymethod OnBackfill $chatJid $cursor \
				      $before $after $limit $callback $tag \
				      $backfillRegion]

	$client mam queryChat $chatJid {*}$mamArgs
    }

    method OnBackfill {chatJid cursor before after limit callback tag backfillRegion mamResult} {
	if {[dict exists $mamResult error]} {
	    if {$tag ne "" && ![info exists ActiveTags($tag)]} return
	    set getArgs [list -limit $limit]
	    if {$before ne ""} {
		lappend getArgs -before $before
	    } elseif {$after ne ""} {
		lappend getArgs -after $after
	    }
	    set local [$messagestore get $chatJid {*}$getArgs]
	    {*}$callback $local
	    return
	}

	# Parse result nodes into message dicts
	set messages {}
	foreach resultNode [dict get $mamResult messages] {
	    lappend messages [$self ParseResultNode $resultNode $chatJid]
	}

	# Store the backfill batch (even if cancelled — data is still useful)
	if {[llength $messages] > 0} {
	    $messagestore store batch $messages backfillRegion
	}

	# Bridge backfill region to live region if cursor came from local data
	if {$cursor ne ""} {
	    set liveRegion [$client db onecolumn {
		SELECT region FROM chat_message
		WHERE chat_jid=$chatJid AND server_id=$cursor
	    }]
	    if {$liveRegion ne "" && $liveRegion != $backfillRegion} {
		$messagestore bridge $chatJid backfillRegion liveRegion
	    }
	}

	# Mark synced if MAM says archive start reached
	if {[dict get $mamResult complete]} {
	    set SyncedChats($chatJid) 1
	}

	if {$tag ne "" && ![info exists ActiveTags($tag)]} return

	# Re-query local and deliver
	set getArgs [list -limit $limit]
	if {$before ne ""} {
	    lappend getArgs -before $before
	} elseif {$after ne ""} {
	    lappend getArgs -after $after
	}
	set local [$messagestore get $chatJid {*}$getArgs]
	{*}$callback $local
    }

    method cancel {args} {
	set tag [dict get $args -tag]
	unset -nocomplain ActiveTags($tag)
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
	dict create \
	    timestamp  [dict get $args -timestamp] \
	    chat_jid   [dict get $args -chat_jid] \
	    from_jid   [xsearch $msgNode -get @from] \
	    body       [xsearch $msgNode body -get body] \
	    server_id  [dict get $args -server_id] \
	    origin_id  [xsearch $msgNode -get @id] \
	    raw_xml    [jwrite $msgNode] \
	    server_status ""
    }
}
