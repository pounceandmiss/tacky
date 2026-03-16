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
    variable PendingRetry
    variable liveRegion ""
    variable ActiveTags

    constructor {args} {
	$self configurelist $args
	set client $options(-client)
	install messagestore using taco_messagestore $self.messagestore \
	    -db [$client cget -db]
	array set PubSubHandlers {}
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
	    set prevTs [$client db onecolumn {
		SELECT timestamp FROM chat_message
		WHERE chat_jid=$chatJid AND region=$liveRegion
		ORDER BY timestamp DESC LIMIT 1 OFFSET 1
	    }]
	    dict set msg prev $prevTs
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
	array set opts $args

	set ts [clock microseconds]
	set oid $ts

	if {[string match "*?join" $opts(-chat_jid)]} {
	    set type groupchat
	    regsub {\?join$} $opts(-chat_jid) {} toJid
	    set nick [$client muc myNick -jid $toJid]
	    set fromJid $toJid/$nick
	} else {
	    set toJid $opts(-chat_jid)
	    set fromJid [$client cget -jid]
	}

	set stanza [j message -to $toJid -type $type -id $oid {
	    j body #body $opts(-body)
	}]

	set msg [dict create \
	    timestamp $ts \
	    chat_jid $opts(-chat_jid) \
	    from_jid $fromJid \
	    body $opts(-body) \
	    server_id "" \
	    origin_id $oid \
	    raw_xml [jwrite $stanza] \
	    server_status pending]

	if {$liveRegion eq ""} {
	    $messagestore region new liveRegion
	}
	$messagestore store batch [list $msg] liveRegion

	set chatJid $opts(-chat_jid)
	set prevTs [$client db onecolumn {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid=$chatJid AND region=$liveRegion
	    ORDER BY timestamp DESC LIMIT 1 OFFSET 1
	}]
	dict set msg prev $prevTs

	$client emit message <Sent> \
	    -jid $opts(-chat_jid) -body $opts(-body) -message $msg

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
    # Local-first: tries the local store before the server.
    # messagestore get latest/before/after are region-scoped, so they
    # only return messages from the same contiguous region as the cursor.
    # When the region is exhausted (local returns empty) and the chat
    # isn't fully synced, a MAM fetch kicks in to get the next batch
    # from the server.

    # Shared local-store query: dispatches to get before/after/latest
    # and appends a hollow message for backward pagination.
    method GetLocal {chatJid before after limit} {
	if {$before ne ""} {
	    set local [$messagestore get before $chatJid $before $limit]
	} elseif {$after ne ""} {
	    set local [$messagestore get after $chatJid $after $limit]
	} else {
	    set local [$messagestore get latest $chatJid $limit]
	}
	if {$before ne "" && [llength $local] > 0} {
	    set lastTs [dict get [lindex $local end] timestamp]
	    lappend local [dict create timestamp $before prev $lastTs hollow 1]
	}
	return $local
    }

    method history {args} {
	set defaults [dict create -before "" -after "" -limit 50 -command "" -tag ""]
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

	# Try local store first
	set local [$self GetLocal $chatJid $before $after $limit]

	if {[llength $local] > 0} {
	    {*}$callback $local
	    return
	}

	# For -after queries, skip MAM when cursor is at or past the
	# latest stored message — there's nothing newer in the archive.
	if {$after ne ""} {
	    set latestTs [$client db onecolumn {
		SELECT MAX(timestamp) FROM chat_message
		WHERE chat_jid=$chatJid
	    }]
	    if {$latestTs eq "" || $after >= $latestTs} {
		{*}$callback $local
		return
	    }
	}

	# No local data and not synced — query the server
	$messagestore region new fetchRegion

	set mamArgs [list -max $limit]
	set cursorSid ""
	if {$before ne ""} {
	    # Try server_id at cursor for RSM pagination; time-based fallback
	    set cursorSid [$client db onecolumn {
		SELECT server_id FROM chat_message
		WHERE chat_jid=$chatJid AND timestamp=$before AND server_id != ''
	    }]
	    if {$cursorSid ne ""} {
		lappend mamArgs -before $cursorSid
	    } else {
		lappend mamArgs -end [FormatTimestampISO $before] -before {}
	    }
	} elseif {$after ne ""} {
	    set cursorSid [$client db onecolumn {
		SELECT server_id FROM chat_message
		WHERE chat_jid=$chatJid AND timestamp=$after AND server_id != ''
	    }]
	    if {$cursorSid ne ""} {
		lappend mamArgs -after $cursorSid
	    } else {
		lappend mamArgs -start [FormatTimestampISO $after]
	    }
	} else {
	    # Cursor-based: page backwards from earliest known server_id
	    set cursorSid [$client db onecolumn {
		SELECT server_id FROM chat_message
		WHERE chat_jid=$chatJid AND server_id != ''
		ORDER BY timestamp ASC LIMIT 1
	    }]
	    if {$cursorSid ne ""} {
		lappend mamArgs -before $cursorSid
	    }
	}
	lappend mamArgs -command [mymethod OnFetch $chatJid $cursorSid \
				      $before $after $limit $callback $tag \
				      $fetchRegion]

	$client mam queryChat $chatJid {*}$mamArgs
    }

    method OnFetch {chatJid cursorSid before after limit callback tag fetchRegion mamResult} {
	if {[dict exists $mamResult error]} {
	    if {$tag ne "" && ![info exists ActiveTags($tag)]} return
	    {*}$callback [$self GetLocal $chatJid $before $after $limit]
	    return
	}

	# Parse result nodes into message dicts
	set messages {}
	foreach resultNode [dict get $mamResult messages] {
	    lappend messages [$self ParseResultNode $resultNode $chatJid]
	}

	# Store the fetched batch (even if cancelled — data is still useful)
	if {[llength $messages] > 0} {
	    $messagestore store batch $messages fetchRegion
	}

	# Bridge fetch region into the local region it reached.
	if {$cursorSid ne ""} {
	    set anchorRegion [$client db onecolumn {
		SELECT region FROM chat_message
		WHERE chat_jid=$chatJid AND server_id=$cursorSid
	    }]
	} elseif {$before ne ""} {
	    set anchorRegion [$client db onecolumn {
		SELECT region FROM chat_message
		WHERE chat_jid=$chatJid AND timestamp=$before
	    }]
	} elseif {$after ne ""} {
	    set anchorRegion [$client db onecolumn {
		SELECT region FROM chat_message
		WHERE chat_jid=$chatJid AND timestamp=$after
	    }]
	} else {
	    set anchorRegion ""
	}
	if {$anchorRegion ne "" && $anchorRegion != $fetchRegion} {
	    $messagestore region bridge $chatJid anchorRegion fetchRegion
	}

	if {$tag ne "" && ![info exists ActiveTags($tag)]} return

	# Re-query local and deliver
	{*}$callback [$self GetLocal $chatJid $before $after $limit]
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
	$messagestore region new fetchRegion
	$client mam queryChat $chatJid \
	    -start [FormatTimestampISO $date] -max $limit \
	    -command [mymethod OnGoto $chatJid $date $limit $callback \
			  $tag $fetchRegion]
    }

    method OnGoto {chatJid date limit callback tag fetchRegion mamResult} {
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
	    $messagestore store batch $messages fetchRegion
	}

	if {$tag ne "" && ![info exists ActiveTags($tag)]} return

	set result [$messagestore get around $chatJid $date $limit]
	{*}$callback $result
    }

    # search -chat $jid -query "text" ?-before $serverId? ?-limit 20?
    #        ?-tag $tag? -command $cb
    #
    # Full text search via MAM. Always server-side.
    # Each result stored in its own region (sparse islands).
    # Callback receives dict: messages, complete, last
    method search {args} {
	array set opts {-limit 20 -tag ""}
	array set opts $args

	set chatJid $opts(-chat)
	set callback $opts(-command)
	set tag $opts(-tag)

	if {$tag ne ""} {
	    set ActiveTags($tag) 1
	}

	set mamArgs [list -fulltext $opts(-query) -max $opts(-limit)]
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
	    $messagestore region new r
	    $messagestore store batch [list $msg] r
	    lappend messages $msg
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
