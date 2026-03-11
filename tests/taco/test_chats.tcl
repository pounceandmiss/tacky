# Tests for top-chats ordering (last-message)

set chats_common {
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

# Helper: insert a message directly into the store
proc chats_insert {chat_jid args} {
    set defaults [dict create \
	timestamp [clock microseconds] \
	from_jid "$chat_jid/someone" \
	body "hello" \
	server_id "" \
	origin_id [expr {[clock microseconds]}] \
	raw_xml "" \
	server_status ""]
    set msg [dict merge $defaults [dict create chat_jid $chat_jid] $args]
    c message messagestore region new r
    c message messagestore store batch [list $msg] r
}

test chats-latest-ordered {latest returns JIDs ordered by most recent message} \
    {*}$chats_common \
    -body {
	set ts [clock microseconds]
	chats_insert alice@example.com timestamp $ts origin_id oid-a
	chats_insert bob@example.com \
	    timestamp [expr {$ts + 1}] origin_id oid-b
	chats_insert carol@example.com \
	    timestamp [expr {$ts + 2}] origin_id oid-c
	c chats latest
    } -result {carol@example.com bob@example.com alice@example.com}

test chats-latest-strips-join {latest strips ?join suffix from JIDs} \
    {*}$chats_common \
    -body {
	chats_insert room@muc.example.com?join
	c chats latest
    } -result {room@muc.example.com}

test chats-event-new-message {<Updated> fires for new message} \
    {*}$chats_common \
    -body {
	set got {}
	tacky listen chats <Updated> \
	    {apply {{ev} { set ::got $ev }}}
	chats_insert alice@example.com
	update idletasks
	dict get $got -jid
    } -result {alice@example.com}

test chats-event-skips-old {old message after new one does not fire event} \
    {*}$chats_common \
    -body {
	set events {}
	tacky listen chats <Updated> \
	    -jid alice@example.com \
	    {apply {{ev} { lappend ::events $ev }}}
	set now [clock microseconds]
	chats_insert alice@example.com timestamp $now origin_id oid-new
	update idletasks
	# Insert an older message (MAM backfill)
	set old [expr {$now - 1000000}]
	chats_insert alice@example.com timestamp $old origin_id oid-old
	update idletasks
	llength $events
    } -result {1}

test chats-dedup-no-event {duplicate message does not fire event} \
    {*}$chats_common \
    -body {
	set events {}
	tacky listen chats <Updated> \
	    -jid alice@example.com \
	    {apply {{ev} { lappend ::events $ev }}}
	set ts [clock microseconds]
	chats_insert alice@example.com timestamp $ts origin_id oid-dup
	update idletasks
	# Duplicate (same origin_id — dedup in messagestore skips INSERT)
	chats_insert alice@example.com \
	    timestamp [expr {$ts + 1}] origin_id oid-dup
	update idletasks
	llength $events
    } -result {1}

test chats-event-debounced {batch inserts produce one event per JID} \
    {*}$chats_common \
    -body {
	set events {}
	tacky listen chats <Updated> \
	    -jid alice@example.com \
	    {apply {{ev} { lappend ::events $ev }}}
	set ts [clock microseconds]
	set msgs {}
	for {set i 0} {$i < 5} {incr i} {
	    lappend msgs [dict create \
		timestamp [expr {$ts + $i}] \
		chat_jid alice@example.com \
		from_jid alice@example.com/phone \
		body "msg $i" \
		server_id "" \
		origin_id "batch-oid-$i" \
		raw_xml "" \
		server_status ""]
	}
	c message messagestore region new r
	c message messagestore store batch $msgs r
	update idletasks
	llength $events
    } -result {1}
