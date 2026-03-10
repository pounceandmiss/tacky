# Tests for durable message send (store-before-send, confirmation, retry)

# -- messagestore: server_status -----------------------------------------------

set ds_ms_common {
    -setup {
	sqlite3 testdb :memory:
	taco_messagestore create store -db testdb
    }
    -cleanup {
	store destroy
	testdb close
    }
}

proc ds_msg {args} {
    set defaults {
	timestamp 1000000 chat_jid alice@example.com
	from_jid alice@example.com/phone body hello
	server_id "" origin_id "" raw_xml "" server_status ""
    }
    return [dict merge $defaults $args]
}

proc ds_batch {messages {jid alice@example.com}} {
    store region new r
    store store batch $messages r
}

test ds-ms-store-server-status {server_status is stored and returned in get} \
    {*}$ds_ms_common \
    -body {
	ds_batch [list \
	    [ds_msg timestamp 100 origin_id oid1 body sent server_status pending]]
	set msgs [store get alice@example.com]
	dict get [lindex $msgs 0] server_status
    } -result {pending}

test ds-ms-store-null-status {messages without server_status default to empty} \
    {*}$ds_ms_common \
    -body {
	ds_batch [list \
	    [ds_msg timestamp 100 origin_id oid1 body incoming]]
	set msgs [store get alice@example.com]
	dict get [lindex $msgs 0] server_status
    } -result {}

test ds-ms-confirm-on-echo {duplicate with pending status is confirmed to received} \
    {*}$ds_ms_common \
    -body {
	# Store outgoing message as pending
	ds_batch [list \
	    [ds_msg timestamp 100 origin_id oid1 body sent server_status pending]]
	# Incoming echo with same origin_id — triggers confirmation
	set confirmed [ds_batch [list \
	    [ds_msg timestamp 200 origin_id oid1 body sent]]]
	# Check DB status changed
	set status [testdb eval {
	    SELECT server_status FROM chat_message WHERE origin_id='oid1'
	}]
	list $status [llength $confirmed] \
	     [dict get [lindex $confirmed 0] origin_id] \
	     [dict get [lindex $confirmed 0] timestamp]
    } -result {received 1 oid1 100}

test ds-ms-no-confirm-non-pending {duplicate without pending status is not confirmed} \
    {*}$ds_ms_common \
    -body {
	# Store a received message (empty status)
	ds_batch [list \
	    [ds_msg timestamp 100 origin_id oid1 body hello]]
	# Feed same origin_id again
	set confirmed [ds_batch [list \
	    [ds_msg timestamp 200 origin_id oid1 body hello]]]
	llength $confirmed
    } -result {0}

test ds-ms-confirm-by-origin-ids {confirmByOriginIds updates pending to received} \
    {*}$ds_ms_common \
    -body {
	ds_batch [list \
	    [ds_msg timestamp 100 origin_id oid1 body msg1 server_status pending] \
	    [ds_msg timestamp 200 origin_id oid2 body msg2 server_status pending] \
	    [ds_msg timestamp 300 origin_id oid3 body msg3]]
	set confirmed [store confirmByOriginIds {oid1 oid2 oid3}]
	set statuses [testdb eval {
	    SELECT server_status FROM chat_message ORDER BY timestamp
	}]
	list [llength $confirmed] $statuses
    } -result {2 {received received {}}}

# -- message module: send method -----------------------------------------------

# Helper: build a MUC self-presence for joining
proc ds_muc_presence {args} {
    set defaults {
	from room@muc.example.com/me
	role participant affiliation member
    }
    set opts [dict merge $defaults $args]
    j presence -from [dict get $opts from] {
	j x -ns http://jabber.org/protocol/muc#user {
	    j item -role [dict get $opts role] \
		-affiliation [dict get $opts affiliation]
	    j status -code 110
	}
    }
}

# Helper: simulate a full MUC join
proc ds_muc_join {room nick} {
    c muc join -jid $room -nick $nick
    c.conn feed [ds_muc_presence from $room/$nick]
}

set ds_msg_common {
    -setup {
	tacky_type create tacky

	rename conn _real_conn
	rename mock_conn conn

	taco_client c \
	    -host test.example.com -port 5222 \
	    -username user -password pass -resource res
    }
    -cleanup {
	catch {c destroy}
	rename conn mock_conn
	rename _real_conn conn
	tacky destroy
    }
}

test ds-send-stores-pending {send stores message with pending status before writing} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c.conn clear
	c message send -chat_jid room@muc.example.com?join \
	    -body "hello" -type groupchat
	# Check DB
	set status [c db eval {
	    SELECT server_status FROM chat_message
	    WHERE chat_jid='room@muc.example.com?join'
	}]
	# Check stanza was written
	set written [c.conn get_written]
	set m [lindex $written end]
	list $status \
	     [xsearch $m -get @type] \
	     [xsearch $m body -get body] \
	     [expr {[xsearch $m -get @id] ne ""}]
    } -result {pending groupchat hello 1}

test ds-send-emits-sent {send emits message <Sent> event} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	set got {}
	tacky listen message <Sent> \
	    -jid room@muc.example.com?join \
	    {apply {{ev} { set ::got $ev }}}
	c message send -chat_jid room@muc.example.com?join \
	    -body "hi" -type groupchat
	list [dict get $got -jid] [dict get $got -body] \
	     [dict get [dict get $got -message] server_status]
    } -result {room@muc.example.com?join hi pending}

test ds-send-from-jid-muc {send sets correct from_jid for MUC} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c message send -chat_jid room@muc.example.com?join \
	    -body "test" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	dict get [lindex $msgs 0] from_jid
    } -result {room@muc.example.com/me}

test ds-send-id-on-stanza {send sets message id matching DB origin_id} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c.conn clear
	c message send -chat_jid room@muc.example.com?join \
	    -body "test" -type groupchat
	set m [lindex [c.conn get_written] end]
	set stanzaId [xsearch $m -get @id]
	set msgs [c message messagestore get room@muc.example.com?join]
	set dbOid [dict get [lindex $msgs 0] origin_id]
	expr {$stanzaId eq $dbOid && $stanzaId ne ""}
    } -result {1}

# -- echo confirmation ---------------------------------------------------------

test ds-echo-confirms-pending {MUC echo of sent message confirms pending to received} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	# Send a message (stores as pending)
	c message send -chat_jid room@muc.example.com?join \
	    -body "echo me" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set oid [dict get [lindex $msgs 0] origin_id]
	# Simulate server echo with same origin_id
	set confirmed {}
	tacky listen message <Confirmed> \
	    -jid room@muc.example.com?join \
	    {apply {{ev} { lappend ::confirmed $ev }}}
	c.conn feed [j message -type groupchat -id $oid \
	    -from room@muc.example.com/me {
	    j body #body "echo me"
	}]
	# Check DB status updated
	set status [c db eval {
	    SELECT server_status FROM chat_message
	    WHERE chat_jid='room@muc.example.com?join'
	}]
	list $status [llength $confirmed]
    } -result {received 1}

test ds-echo-no-received {echo of own message does not emit <Received>} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c message send -chat_jid room@muc.example.com?join \
	    -body "echo me" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set oid [dict get [lindex $msgs 0] origin_id]
	set received {}
	tacky listen message <Received> \
	    -jid room@muc.example.com?join \
	    {apply {{ev} { lappend ::received $ev }}}
	c.conn feed [j message -type groupchat -id $oid \
	    -from room@muc.example.com/me {
	    j body #body "echo me"
	}]
	llength $received
    } -result {0}

test ds-echo-captures-server-id {echo updates server_id on confirmed message} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c message send -chat_jid room@muc.example.com?join \
	    -body "echo me" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set oid [dict get [lindex $msgs 0] origin_id]
	c.conn feed [j message -type groupchat -id $oid \
	    -from room@muc.example.com/me {
	    j body #body "echo me"
	    j stanza-id -ns urn:xmpp:sid:0 -id srv99
	}]
	set sid [c db onecolumn {
	    SELECT server_id FROM chat_message
	    WHERE chat_jid='room@muc.example.com?join'
	}]
	set sid
    } -result {srv99}

# -- SM ack confirmation -------------------------------------------------------

test ds-sm-ack-confirms {OnSmAck confirms pending messages by origin_id} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	# Send a message
	c message send -chat_jid room@muc.example.com?join \
	    -body "ack me" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set oid [dict get [lindex $msgs 0] origin_id]
	# Simulate SM ack with the sent stanza
	set confirmed {}
	tacky listen message <Confirmed> \
	    -jid room@muc.example.com?join \
	    {apply {{ev} { lappend ::confirmed $ev }}}
	set stanza [j message -to room@muc.example.com -type groupchat -id $oid {
	    j body #body "ack me"
	}]
	c message OnSmAck [list $stanza]
	set status [c db eval {
	    SELECT server_status FROM chat_message
	    WHERE chat_jid='room@muc.example.com?join'
	}]
	list $status [llength $confirmed]
    } -result {received 1}

# -- retry on connect ----------------------------------------------------------

test ds-retry-pending-on-ready {RetryPending defers MUC until room joined} \
    {*}$ds_msg_common \
    -body {
	# Store a pending message directly in DB
	c message messagestore region new r
	c message messagestore store batch [list [dict create \
	    timestamp 100 chat_jid room@muc.example.com?join \
	    from_jid room@muc.example.com/me body "retry me" \
	    server_id "" origin_id retry-oid1 raw_xml "" \
	    server_status pending]] r
	c.conn clear
	# Trigger retry — MUC message should NOT be sent yet
	c message RetryPending
	set beforeCount [llength [c.conn get_written]]
	# Now join the room — OnMucJoined flushes the pending retry
	ds_muc_join room@muc.example.com me
	# Find the retried message among written stanzas
	set retried {}
	foreach s [c.conn get_written] {
	    if {[xsearch $s -get @id] eq "retry-oid1"} {
		set retried $s
		break
	    }
	}
	list $beforeCount [expr {$retried ne ""}] \
	     [xsearch $retried -get @type] \
	     [xsearch $retried -get @to] \
	     [xsearch $retried body -get body]
    } -result {0 1 groupchat room@muc.example.com {retry me}}

test ds-retry-1to1-pending {RetryPending sends 1:1 pending as chat type} \
    {*}$ds_msg_common \
    -body {
	c message messagestore region new r
	c message messagestore store batch [list [dict create \
	    timestamp 100 chat_jid bob@example.com \
	    from_jid user@test.example.com/res body "retry dm" \
	    server_id "" origin_id retry-oid2 raw_xml "" \
	    server_status pending]] r
	c.conn clear
	c message RetryPending
	set written [c.conn get_written]
	set m [lindex $written end]
	list [xsearch $m -get @type] \
	     [xsearch $m -get @to] \
	     [xsearch $m body -get body]
    } -result {chat bob@example.com {retry dm}}

# -- SM module: -ack-command ---------------------------------------------------

test ds-sm-ack-command-fires {SM -ack-command fires on <a> with acked stanzas} \
    -setup {
	set acked {}
	sm create testsm \
	    -write [list apply {{s} {}}] \
	    -ack-command [list apply {{stanzas} { set ::acked $stanzas }}]
    } \
    -cleanup {
	testsm destroy
    } \
    -body {
	# Enable SM
	testsm onFeatures [j features { j sm -ns urn:xmpp:sm:3 }]
	testsm onConnect
	testsm inStanza [j enabled -ns urn:xmpp:sm:3 -id sid1]
	# Send two stanzas
	set s1 [j message -to a@b { j body #body one }]
	set s2 [j message -to c@d { j body #body two }]
	testsm outStanza $s1
	testsm outStanza $s2
	# Server acks both
	testsm inStanza [j a -ns urn:xmpp:sm:3 -h 2]
	list [llength $acked] \
	     [xsearch [lindex $acked 0] body -get body] \
	     [xsearch [lindex $acked 1] body -get body]
    } -result {2 one two}

test ds-sm-ack-command-on-resume {SM -ack-command fires on resume for acked stanzas} \
    -setup {
	set acked {}
	sm create testsm \
	    -write [list apply {{s} {}}] \
	    -ack-command [list apply {{stanzas} { set ::acked $stanzas }}]
    } \
    -cleanup {
	testsm destroy
    } \
    -body {
	# First session: enable SM, send one stanza, disconnect
	testsm onFeatures [j features { j sm -ns urn:xmpp:sm:3 }]
	testsm onConnect
	testsm inStanza [j enabled -ns urn:xmpp:sm:3 -id sid1]
	set s1 [j message -to a@b { j body #body queued }]
	testsm outStanza $s1
	testsm onDisconnect
	# Resume — server acks the queued stanza
	testsm onConnect
	testsm inStanza [j resumed -ns urn:xmpp:sm:3 -previd sid1 -h 1]
	list [llength $acked] \
	     [xsearch [lindex $acked 0] body -get body]
    } -result {1 queued}

# -- incoming messages ---------------------------------------------------------

test ds-parse-message-has-server-status {ParseMessage includes server_status in dict} \
    {*}$ds_msg_common \
    -body {
	set got {}
	tacky listen message <Received> \
	    {apply {{ev} { set ::got $ev }}}
	c.conn feed [j message -from alice@example.com/phone {
	    j body #body "incoming"
	}]
	dict get [dict get $got -message] server_status
    } -result {}

test ds-incoming-emits-received {incoming 1:1 message emits <Received>} \
    {*}$ds_msg_common \
    -body {
	set got {}
	tacky listen message <Received> \
	    -jid alice@example.com \
	    {apply {{ev} { set ::got $ev }}}
	c.conn feed [j message -from alice@example.com/phone {
	    j body #body "hey"
	}]
	list [dict get $got -jid] [dict get $got -body] \
	     [dict get [dict get $got -message] server_status]
    } -result {alice@example.com hey {}}

test ds-incoming-stores-empty-status {incoming message stored with empty server_status} \
    {*}$ds_msg_common \
    -body {
	c.conn feed [j message -from alice@example.com/phone {
	    j body #body "hey"
	}]
	set status [c db onecolumn {
	    SELECT server_status FROM chat_message
	    WHERE chat_jid='alice@example.com'
	}]
	set status
    } -result {}

# -- idempotent confirmation ---------------------------------------------------

test ds-double-confirm-idempotent {echo + SM ack double confirm is harmless} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c message send -chat_jid room@muc.example.com?join \
	    -body "double" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set oid [dict get [lindex $msgs 0] origin_id]
	set confirmed {}
	tacky listen message <Confirmed> \
	    -jid room@muc.example.com?join \
	    {apply {{ev} { lappend ::confirmed $ev }}}
	# First: MUC echo confirms
	c.conn feed [j message -type groupchat -id $oid \
	    -from room@muc.example.com/me {
	    j body #body "double"
	}]
	# Second: SM ack also fires
	set stanza [j message -to room@muc.example.com -type groupchat -id $oid {
	    j body #body "double"
	}]
	c message OnSmAck [list $stanza]
	set status [c db onecolumn {
	    SELECT server_status FROM chat_message
	    WHERE chat_jid='room@muc.example.com?join'
	}]
	# Only one <Confirmed> — SM ack finds no pending rows
	list $status [llength $confirmed]
    } -result {received 1}

# -- disconnect clears retry state ---------------------------------------------

test ds-disconnect-clears-pending-retry {OnDisconnect clears PendingRetry} \
    {*}$ds_msg_common \
    -body {
	# Store a pending MUC message and trigger retry (stashes it)
	c message messagestore region new r
	c message messagestore store batch [list [dict create \
	    timestamp 100 chat_jid room@muc.example.com?join \
	    from_jid room@muc.example.com/me body "stale" \
	    server_id "" origin_id stale-oid raw_xml "" \
	    server_status pending]] r
	c message RetryPending
	# Disconnect clears stashed retries
	c message OnDisconnect
	# Now join — should NOT flush any stale retries
	c.conn clear
	ds_muc_join room@muc.example.com me
	set retried {}
	foreach s [c.conn get_written] {
	    if {[xsearch $s -get @id] eq "stale-oid"} {
		set retried $s
	    }
	}
	expr {$retried eq ""}
    } -result {1}

# -- origin_id matches timestamp -----------------------------------------------

test ds-origin-id-equals-timestamp {origin_id is same as timestamp} \
    {*}$ds_msg_common \
    -body {
	ds_muc_join room@muc.example.com me
	c message send -chat_jid room@muc.example.com?join \
	    -body "test" -type groupchat
	set msgs [c message messagestore get room@muc.example.com?join]
	set msg [lindex $msgs 0]
	expr {[dict get $msg origin_id] == [dict get $msg timestamp]}
    } -result {1}
