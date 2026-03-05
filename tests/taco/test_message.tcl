# Unit tests for taco_message

set msg_common {
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

# Helper: build a message dict
proc msg_msg {args} {
    set defaults {
	timestamp 1000000 chat_jid alice@example.com
	from_jid alice@example.com/phone body hello
	server_id "" origin_id "" raw_xml ""
    }
    return [dict merge $defaults $args]
}

# Helper: store messages in a fresh region via the message module's messagestore
proc msg_store {msgs} {
    c message messagestore region new r
    c message messagestore store batch $msgs r
}

# Helper: build a MAM <result> node wrapping a message
proc mam_result {args} {
    set defaults {id sid1 queryid "" from alice@example.com body hello stamp 2024-01-01T00:00:00Z origin_id ""}
    set opts [dict merge $defaults $args]
    set oid [dict get $opts origin_id]
    set qid [dict get $opts queryid]
    set rid [dict get $opts id]
    j result -ns urn:xmpp:mam:2 -id $rid -queryid $qid {
	j forwarded -ns urn:xmpp:forward:0 {
	    j delay -ns urn:xmpp:delay -stamp [dict get $opts stamp]
	    j message -from [dict get $opts from] {
		j body #body [dict get $opts body]
		if {$oid ne ""} {
		    j origin-id -ns urn:xmpp:sid:0 -id $oid
		}
	    }
	}
    }
}

# Helper: extract the MAM queryid from the last written IQ
proc mam_queryid {} {
    set written [c.conn get_written]
    set iqStanza [lindex $written end]
    xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid
}

# -- history: local sufficient -------------------------------------------------

test message-history-local-sufficient {history returns local data when enough messages exist} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body a] \
	    [msg_msg timestamp 200 server_id s2 body b] \
	    [msg_msg timestamp 300 server_id s3 body c]]
	set result [c message history -chat alice@example.com -limit 2]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [dict get [lindex $result 1] body]
    } -result {2 b c}

test message-history-local-sufficient-before {history with -before returns local data when enough} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body a] \
	    [msg_msg timestamp 200 server_id s2 body b] \
	    [msg_msg timestamp 300 server_id s3 body c]]
	set result [c message history -chat alice@example.com -before 300 -limit 2]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [dict get [lindex $result 1] body]
    } -result {2 a b}

# -- history: synced prevents MAM -----------------------------------------------

test message-history-synced-no-mam {synced chat returns local data without MAM query} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body only]]
	# Simulate a completed MAM backfill by directly setting SyncedChats
	# We trigger this via a backfill that completes
	set result {}
	c message history -chat alice@example.com -limit 50 \
	    -command [list apply {{r} { set ::result $r }} ]
	# MAM query was sent — simulate MAM response with complete=true
	set iqId [dict get [lindex [c.conn get_written] end] attrs id]
	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm
	    }
	}]
	# Now SyncedChats should be set. Query again synchronously.
	set result2 [c message history -chat alice@example.com -limit 50]
	list [llength $result2] [dict get [lindex $result2 0] body]
    } -result {1 only}

# -- history: MAM triggered ---------------------------------------------------

test message-history-mam-triggered {insufficient local data triggers MAM and delivers after response} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body local1]]
	set result {}
	c message history -chat alice@example.com -limit 5 \
	    -command [list apply {{r} { set ::result $r }}]

	# Extract IQ id and MAM queryid
	set written [c.conn get_written]
	set iqStanza [lindex $written end]
	set iqId [dict get $iqStanza attrs id]
	set qid [mam_queryid]

	# Feed MAM result messages
	set resultNode [mam_result id mam1 queryid $qid \
			    from bob@example.com body mam-msg1 \
			    stamp 2023-12-31T23:00:00Z]
	c.mam onResultMessage [j message -from user@test.example.com {
	    j /as-is $resultNode
	}]

	# Feed fin IQ response
	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete false {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body mam1
		    j last #body mam1
		}
	    }
	}]

	# Callback should have been called with messages
	expr {[llength $result] >= 2}
    } -result {1}

test message-history-mam-results-parsed-and-stored {MAM results are correctly parsed, stored, and retrievable} \
    {*}$msg_common \
    -body {
	set result {}
	c message history -chat alice@example.com -limit 5 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [c.conn get_written] end] attrs id]
	set qid [mam_queryid]

	# Feed two MAM result messages with full fields
	foreach {sid from body stamp oid} {
	    mam1 bob@example.com/phone  "first msg"  2024-01-01T10:00:00Z  orig1
	    mam2 bob@example.com/laptop "second msg" 2024-01-01T11:00:00Z  orig2
	} {
	    set rn [mam_result id $sid queryid $qid from $from body $body \
			stamp $stamp origin_id $oid]
	    c.mam onResultMessage [j message -from user@test.example.com {
		j /as-is $rn
	    }]
	}

	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body mam1
		    j last #body mam2
		}
	    }
	}]

	# Verify callback result has correct fields
	set m1 [lindex $result 0]
	set m2 [lindex $result 1]
	list [llength $result] \
	     [dict get $m1 body] [dict get $m1 from_jid] \
	     [dict get $m1 server_id] [dict get $m1 origin_id] \
	     [dict get $m1 chat_jid] \
	     [expr {[dict get $m1 timestamp] > 0}] \
	     [expr {[dict get $m1 raw_xml] ne ""}] \
	     [dict get $m2 body] [dict get $m2 server_id]
    } -result {2 {first msg} bob@example.com/phone mam1 orig1 alice@example.com 1 1 {second msg} mam2}

test message-history-mam-stored-persists {MAM results persist in messagestore after callback} \
    {*}$msg_common \
    -body {
	set result {}
	c message history -chat alice@example.com -limit 5 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [c.conn get_written] end] attrs id]
	set qid [mam_queryid]

	set rn [mam_result id srv1 queryid $qid from bob@example.com \
		    body "persisted" stamp 2024-03-01T12:00:00Z origin_id oid1]
	c.mam onResultMessage [j message -from user@test.example.com {
	    j /as-is $rn
	}]

	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body srv1
		    j last #body srv1
		}
	    }
	}]

	# Query messagestore directly — should find the stored message
	set stored [c message messagestore get alice@example.com]
	list [llength $stored] \
	     [dict get [lindex $stored 0] body] \
	     [dict get [lindex $stored 0] server_id]
    } -result {1 persisted srv1}

test message-history-mam-complete-marks-synced {MAM complete=true marks chat as synced} \
    {*}$msg_common \
    -body {
	set result {}
	c message history -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result $r }}]

	set written [c.conn get_written]
	set iqStanza [lindex $written end]
	set iqId [dict get $iqStanza attrs id]

	# Feed fin with complete=true (empty archive)
	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm
	    }
	}]

	# Now a second query should return synchronously (no MAM)
	set written1 [c.conn get_written]
	set result2 [c message history -chat bob@example.com -limit 50]
	set written2 [c.conn get_written]
	# No new IQ should have been sent
	list [llength $result2] [expr {[llength $written1] == [llength $written2]}]
    } -result {0 1}

# -- history: disconnect clears synced -----------------------------------------

test message-history-disconnect-clears-synced {disconnect clears SyncedChats state} \
    {*}$msg_common \
    -body {
	# Get chat synced
	set result {}
	c message history -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [c.conn get_written] end] attrs id]
	c.iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm
	    }
	}]

	# Verify synced — synchronous return
	set r [c message history -chat bob@example.com -limit 50]

	# Disconnect
	c.conn fire_disconnect "gone"

	# After disconnect, should trigger MAM again (async)
	set result2 {}
	c message history -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result2 $r }}]
	set written [c.conn get_written]
	# Should have sent a new MAM query
	set lastIq [lindex $written end]
	set hasQuery [expr {[xsearch $lastIq query -ns urn:xmpp:mam:2] ne ""}]
	list $hasQuery
    } -result {1}

# -- ParseResultNode ----------------------------------------------------------

test message-parseresultnode-basic {ParseResultNode extracts all fields} \
    {*}$msg_common \
    -body {
	set rn [mam_result id sid42 from juliet@capulet.li/phone \
		    body "hello romeo" stamp 2024-06-15T12:30:00Z origin_id oid99]
	set msg [c.message ParseResultNode $rn chat@example.com]
	list [dict get $msg server_id] \
	     [dict get $msg from_jid] \
	     [dict get $msg body] \
	     [dict get $msg origin_id] \
	     [dict get $msg chat_jid] \
	     [expr {[dict get $msg timestamp] > 0}]
    } -result {sid42 juliet@capulet.li/phone {hello romeo} oid99 chat@example.com 1}

test message-history-strips-join {history strips ?join from chatJid} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 chat_jid room@muc.example.com server_id s1 body hi]]
	set result [c message history -chat room@muc.example.com?join -limit 1]
	list [llength $result] [dict get [lindex $result 0] body]
    } -result {1 hi}

test message-parseresultnode-no-origin-id {ParseResultNode handles missing origin-id} \
    {*}$msg_common \
    -body {
	set rn [mam_result id sid1 from bob@example.com body test stamp 2024-01-01T00:00:00Z]
	set msg [c.message ParseResultNode $rn bob@example.com]
	dict get $msg origin_id
    } -result {}

# -- live message receiving ----------------------------------------------------

test message-live-stored {incoming chat message is stored and retrievable} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "hello there"
	}]
	set msgs [c message messagestore get alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {hello there}}

test message-live-fields {stored live message has correct fields} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body hi
	    j stanza-id -ns urn:xmpp:sid:0 -id srv42
	    j origin-id -ns urn:xmpp:sid:0 -id orig7
	}]
	set msg [lindex [c message messagestore get alice@example.com] 0]
	list [dict get $msg chat_jid] \
	     [dict get $msg from_jid] \
	     [dict get $msg body] \
	     [dict get $msg server_id] \
	     [dict get $msg origin_id] \
	     [expr {[dict get $msg timestamp] > 0}] \
	     [expr {[dict get $msg raw_xml] ne ""}]
    } -result {alice@example.com alice@example.com/phone hi srv42 orig7 1 1}

test message-live-delayed-uses-stamp {delayed message uses delay timestamp} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "offline msg"
	    j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
	}]
	set msg [lindex [c message messagestore get alice@example.com] 0]
	# ParseTimestamp of 2024-06-15T12:00:00Z
	set expected [ParseTimestamp 2024-06-15T12:00:00Z]
	expr {[dict get $msg timestamp] == $expected}
    } -result {1}

test message-live-no-body-ignored {message without body is not stored} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j active -ns http://jabber.org/protocol/chatstates
	}]
	llength [c message messagestore get alice@example.com]
    } -result {0}

test message-live-groupchat-ignored {groupchat messages are skipped for now} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type groupchat -from room@muc.example.com/nick {
	    j body #body "muc message"
	}]
	llength [c message messagestore get room@muc.example.com]
    } -result {0}

test message-live-pubsub-not-stored {PubSub messages are dispatched, not stored} \
    {*}$msg_common \
    -body {
	set got 0
	c.message pubsub handler urn:xmpp:avatar:metadata \
	    [list apply {{stanza} { set ::got 1 }}]
	c.conn feed [j message -from alice@example.com {
	    j event -ns http://jabber.org/protocol/pubsub#event {
		j items -node urn:xmpp:avatar:metadata
	    }
	}]
	list $got [llength [c message messagestore get alice@example.com]]
    } -result {1 0}

test message-live-shared-region {messages to different chats share one live region} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "hi alice"
	}]
	c.conn feed [j message -type chat -from bob@example.com/laptop {
	    j body #body "hi bob"
	}]
	[c.message.messagestore cget -db] eval {
	    SELECT COUNT(DISTINCT region) FROM chat_message
	}
    } -result {1}

test message-live-emits-event {incoming message emits message <Received>} \
    {*}$msg_common \
    -body {
	set ::_got {}
	tacky listen message <Received> {apply {{ev} {
	    set ::_got $ev
	}}}
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "event test"
	}]
	list [dict get $_got -jid] \
	     [dict get $_got -from] \
	     [dict get $_got -body]
    } -result {alice@example.com alice@example.com/phone {event test}}

test message-live-disconnect-clears-region {disconnect resets liveRegion} \
    {*}$msg_common \
    -body {
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body msg1
	}]
	c.conn fire_disconnect "gone"
	c.conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body msg2
	}]
	# After disconnect, a new region should be allocated
	[c.message.messagestore cget -db] eval {
	    SELECT COUNT(DISTINCT region) FROM chat_message
	}
    } -result {2}
