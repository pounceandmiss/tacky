snit::type taco_message {
    option -client -readonly yes

    component messagestore -public messagestore

    variable client
    variable PubSubHandlers
    variable SyncedChats
    variable liveRegion ""

    constructor {args} {
	$self configurelist $args
	set client $options(-client)
	install messagestore using taco_messagestore $self.messagestore \
	    -db [$client cget -db]
	array set PubSubHandlers {}
	array set SyncedChats {}
    }

    destructor {
	catch {$messagestore destroy}
    }

    method OnReady {} {}

    method OnDisconnect {} {
	array unset SyncedChats
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

	# Skip groupchat (MUC) for now
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "groupchat"} { return }

	# Live chat message — must have a body
	set body [xsearch $stanza body -get body]
	if {$body eq ""} { return }

	set msg [$self ParseLiveMessage $stanza]

	# Lazy-allocate live region for this connection session
	if {$liveRegion eq ""} {
	    $messagestore region new liveRegion
	}
	$messagestore store batch [list $msg] liveRegion

	set chatJid [dict get $msg chat_jid]
	set fromJid [dict get $msg from_jid]
	$client emit message <Received> \
	    -jid $chatJid -from $fromJid -body $body
    }

    method ParseLiveMessage {stanza} {
	# Timestamp: use <delay> if present (offline/delayed), else now
	set stamp [xsearch $stanza delay -ns urn:xmpp:delay -get @stamp]
	if {$stamp ne ""} {
	    set ts [ParseTimestamp $stamp]
	} else {
	    set ts [clock microseconds]
	}

	set serverId [xsearch $stanza stanza-id -ns urn:xmpp:sid:0 -get @id]

	$self ParseMessage $stanza \
	    -chat_jid [jid bare [xsearch $stanza -get @from]] \
	    -timestamp $ts \
	    -server_id $serverId
    }

    method "pubsub handler" {node command} {
	set PubSubHandlers($node) $command
    }

    method "pubsub unhandler" {node} {
	unset -nocomplain PubSubHandlers($node)
    }

    # history -chat $chatJid ?-before $ts? ?-limit 50? -command $cb
    tackymethod history {args} {
	set defaults [dict create -before "" -limit 50 -command ""]
	set opts [dict merge $defaults $args]

	set chatJid [dict get $opts -chat]
	regsub {\?join$} $chatJid {} chatJid
	set limit   [dict get $opts -limit]

	# Build local query args
	set getArgs [list -limit $limit]
	set before [dict get $opts -before]
	if {$before ne ""} {
	    lappend getArgs -before $before
	}

	set local [$messagestore get $chatJid {*}$getArgs]

	# Enough local data or chat fully synced — return immediately
	if {[llength $local] >= $limit || [info exists SyncedChats($chatJid)]} {
	    return $local
	}

	# Need MAM backfill
	set cursor [$client db onecolumn {
	    SELECT server_id FROM chat_message
	    WHERE chat_jid=$chatJid AND server_id != ''
	    ORDER BY timestamp ASC LIMIT 1
	}]

	$messagestore region new backfillRegion

	set mamArgs [list -max $limit]
	if {$cursor ne ""} {
	    lappend mamArgs -before $cursor
	}
	set callback [dict get $opts -command]
	lappend mamArgs -command [mymethod OnBackfill $chatJid $cursor \
				      $before $limit $callback \
				      $backfillRegion]

	# Prevent tackymethod from auto-firing the callback;
	# OnBackfill will call it after MAM completes.
	dict unset args -command

	$client mam queryChat $chatJid {*}$mamArgs
    }

    method OnBackfill {chatJid cursor before limit callback backfillRegion mamResult} {
	if {[dict exists $mamResult error]} {
	    # MAM failed — return whatever local data we had
	    set getArgs [list -limit $limit]
	    if {$before ne ""} {
		lappend getArgs -before $before
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

	# Store the backfill batch
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

	# Re-query local and deliver
	set getArgs [list -limit $limit]
	if {$before ne ""} {
	    lappend getArgs -before $before
	}
	set local [$messagestore get $chatJid {*}$getArgs]
	{*}$callback $local
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
	    origin_id  [xsearch $msgNode origin-id -ns urn:xmpp:sid:0 -get @id] \
	    raw_xml    [jwrite $msgNode]
    }
}
