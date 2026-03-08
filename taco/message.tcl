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

    method OnReady {} {
	$self DoCatchup
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
	    foreach msg $messages {
		$client emit message <Received> \
		    -jid $chatJid \
		    -from [dict get $msg from_jid] \
		    -body [dict get $msg body] \
		    -message $msg
	    }
	}

	$client emit message <CatchupDone> -count $totalCount
    }

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
	$messagestore store batch [list $msg] liveRegion
	$client emit message <Received> \
	    -jid $chatJid -from [xsearch $stanza -get @from] -body $body \
	    -message $msg
    }

    method "pubsub handler" {node command} {
	set PubSubHandlers($node) $command
    }

    method "pubsub unhandler" {node} {
	unset -nocomplain PubSubHandlers($node)
    }

    # history -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50? -command $cb
    # Always async — calls -command with result list.
    # Always queries the server unless the chat is already synchronized.
    method history {args} {
	set defaults [dict create -before "" -after "" -limit 50 -command ""]
	set opts [dict merge $defaults $args]

	set chatJid [dict get $opts -chat]
	set limit   [dict get $opts -limit]
	set callback [dict get $opts -command]
	set before [dict get $opts -before]
	set after [dict get $opts -after]

	if {[info exists SyncedChats($chatJid)]} {
	    # Chat fully synced — serve from local store
	    set getArgs [list -limit $limit]
	    if {$before ne ""} { lappend getArgs -before $before }
	    if {$after ne ""}  { lappend getArgs -after $after }
	    set local [$messagestore get $chatJid {*}$getArgs]
	    {*}$callback $local
	    return
	}

	# Not synced — query the server
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
	lappend mamArgs -command [mymethod OnBackfill $chatJid $cursor \
				      $before $limit $callback \
				      $backfillRegion]

	$client mam queryChat $chatJid {*}$mamArgs
    }

    method OnBackfill {chatJid cursor before limit callback backfillRegion mamResult} {
	if {[dict exists $mamResult error]} {
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
