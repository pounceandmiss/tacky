# Unit tests for taco_message

set acc user@test.example.com

set msg_common {
    -setup {
	rename conn _real_conn
	rename mock_conn conn
	tacky_type create tacky
	tacky account add -acc user@test.example.com
	set ::_client [tacky client user@test.example.com]
    }
    -cleanup {
	rename conn mock_conn
	rename _real_conn conn
	unset -nocomplain ::_client
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
    $::_client message messagestore region new r
    $::_client message messagestore store batch $msgs r
}

# Helper: call history and collect result via -command
proc msg_history {args} {
    set ::_msg_hist_result {}
    tacky message history -acc $::acc {*}$args \
	-command [list apply {{result} { set ::_msg_hist_result $result }}]
    set ::_msg_hist_result
}

# Helper: mark a chat as synced by running a MAM query that returns complete=true
proc msg_sync {chatJid} {
    tacky message history -acc $::acc -chat $chatJid -limit 1 \
	-command [list apply {{r} {}}]
    set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
    $::_client iq feed [j iq -type result -id $iqId {
	j fin -ns urn:xmpp:mam:2 -complete true {
	    j set -ns http://jabber.org/protocol/rsm
	}
    }]
}

# Helper: build a MAM <result> node wrapping a message
proc mam_result {args} {
    set defaults {id sid1 queryid "" from alice@example.com to "" body hello stamp 2024-01-01T00:00:00Z origin_id ""}
    set opts [dict merge $defaults $args]
    set oid [dict get $opts origin_id]
    set qid [dict get $opts queryid]
    set rid [dict get $opts id]
    set toJid [dict get $opts to]
    set msgAttrs [list -from [dict get $opts from]]
    if {$toJid ne ""} {
	lappend msgAttrs -to $toJid
    }
    if {$oid ne ""} {
	lappend msgAttrs -id $oid
    }
    j result -ns urn:xmpp:mam:2 -id $rid -queryid $qid {
	j forwarded -ns urn:xmpp:forward:0 {
	    j delay -ns urn:xmpp:delay -stamp [dict get $opts stamp]
	    j message {*}$msgAttrs {
		j body #body [dict get $opts body]
	    }
	}
    }
}

# Helper: extract the MAM queryid from the last written IQ
proc mam_queryid {} {
    set written [$::_client conn get_written]
    set iqStanza [lindex $written end]
    xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid
}

# -- history: synced chat returns local data ------------------------------------

test message-history-synced-returns-local {synced chat returns local data via callback} \
    {*}$msg_common \
    -body {
	msg_sync alice@example.com
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body a] \
	    [msg_msg timestamp 200 server_id s2 body b] \
	    [msg_msg timestamp 300 server_id s3 body c]]
	set result [msg_history -chat alice@example.com -limit 2]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [dict get [lindex $result 1] body]
    } -result {2 b c}

test message-history-synced-before {synced chat with -before returns correct slice} \
    {*}$msg_common \
    -body {
	msg_sync alice@example.com
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body a] \
	    [msg_msg timestamp 200 server_id s2 body b] \
	    [msg_msg timestamp 300 server_id s3 body c]]
	set result [msg_history -chat alice@example.com -before 300 -limit 2]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [dict get [lindex $result 1] body]
    } -result {2 a b}

# -- history: synced prevents MAM -----------------------------------------------

test message-history-synced-no-mam {synced chat returns local data without MAM query} \
    {*}$msg_common \
    -body {
	msg_sync alice@example.com
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body only]]
	# Now synced — should not send another MAM query
	set written1 [$::_client conn get_written]
	set result [msg_history -chat alice@example.com -limit 50]
	set written2 [$::_client conn get_written]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [expr {[llength $written1] == [llength $written2]}]
    } -result {1 only 1}

# -- history: local-first -----------------------------------------------------

test message-history-local-first {history with local data returns local without MAM query} \
    {*}$msg_common \
    -body {
	msg_store [list \
	    [msg_msg timestamp 100 server_id s1 body a] \
	    [msg_msg timestamp 200 server_id s2 body b]]
	# Not synced, but has local data — should return local, no MAM
	set written1 [$::_client conn get_written]
	set result [msg_history -chat alice@example.com -limit 50]
	set written2 [$::_client conn get_written]
	list [llength $result] \
	     [dict get [lindex $result 0] body] \
	     [dict get [lindex $result 1] body] \
	     [expr {[llength $written1] == [llength $written2]}]
    } -result {2 a b 1}

# -- history: MAM triggered ---------------------------------------------------

test message-history-mam-results-parsed-and-stored {MAM results are correctly parsed, stored, and retrievable} \
    {*}$msg_common \
    -body {
	set result {}
	tacky message history -acc $acc -chat alice@example.com -limit 5 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
	set qid [mam_queryid]

	# Feed two MAM result messages with full fields
	foreach {sid from body stamp oid} {
	    mam1 bob@example.com/phone  "first msg"  2024-01-01T10:00:00Z  orig1
	    mam2 bob@example.com/laptop "second msg" 2024-01-01T11:00:00Z  orig2
	} {
	    set rn [mam_result id $sid queryid $qid from $from body $body \
			stamp $stamp origin_id $oid]
	    $::_client mam onResultMessage [j message -from user@test.example.com {
		j /as-is $rn
	    }]
	}

	$::_client iq feed [j iq -type result -id $iqId {
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

test message-history-mam-complete-marks-synced {MAM complete=true marks chat as synced} \
    {*}$msg_common \
    -body {
	set result {}
	tacky message history -acc $acc -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result $r }}]

	set written [$::_client conn get_written]
	set iqStanza [lindex $written end]
	set iqId [dict get $iqStanza attrs id]

	# Feed fin with complete=true (empty archive)
	$::_client iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm
	    }
	}]

	# Now a second query should not send MAM
	set written1 [$::_client conn get_written]
	set result2 [msg_history -chat bob@example.com -limit 50]
	set written2 [$::_client conn get_written]
	# No new IQ should have been sent
	list [llength $result2] [expr {[llength $written1] == [llength $written2]}]
    } -result {0 1}

# -- history: disconnect clears synced -----------------------------------------

test message-history-disconnect-clears-synced {disconnect clears SyncedChats state} \
    {*}$msg_common \
    -body {
	# Get chat synced
	set result {}
	tacky message history -acc $acc -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
	$::_client iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm
	    }
	}]

	# Verify synced
	set r [msg_history -chat bob@example.com -limit 50]

	# Disconnect
	$::_client conn fire_disconnect "gone"

	# After disconnect, should trigger MAM again (async)
	set result2 {}
	tacky message history -acc $acc -chat bob@example.com -limit 50 \
	    -command [list apply {{r} { set ::result2 $r }}]
	set written [$::_client conn get_written]
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
	set msg [$::_client message ParseResultNode $rn chat@example.com]
	list [dict get $msg server_id] \
	     [dict get $msg from_jid] \
	     [dict get $msg body] \
	     [dict get $msg origin_id] \
	     [dict get $msg chat_jid] \
	     [expr {[dict get $msg timestamp] > 0}]
    } -result {sid42 juliet@capulet.li/phone {hello romeo} oid99 chat@example.com 1}

test message-history-preserves-join {history preserves ?join suffix in chatJid} \
    {*}$msg_common \
    -body {
	msg_sync room@muc.example.com?join
	msg_store [list \
	    [msg_msg timestamp 100 chat_jid room@muc.example.com?join server_id s1 body hi]]
	set result [msg_history -chat room@muc.example.com?join -limit 1]
	list [llength $result] [dict get [lindex $result 0] body]
    } -result {1 hi}

test message-parseresultnode-no-origin-id {ParseResultNode handles missing origin-id} \
    {*}$msg_common \
    -body {
	set rn [mam_result id sid1 from bob@example.com body test stamp 2024-01-01T00:00:00Z]
	set msg [$::_client message ParseResultNode $rn bob@example.com]
	dict get $msg origin_id
    } -result {}

# -- history: cancel -----------------------------------------------------------

test message-history-cancel-suppresses-callback {cancel tag prevents backfill callback} \
    {*}$msg_common \
    -body {
	set ::result UNTOUCHED
	tacky message history -acc $acc -chat bob@example.com -limit 50 \
	    -tag mytag \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
	set qid [mam_queryid]

	# Cancel before MAM response arrives
	tacky message cancel -acc $acc -tag mytag

	# Feed a MAM result + fin
	$::_client mam onResultMessage [j message -from user@test.example.com {
	    j /as-is [mam_result id sid1 queryid $qid from bob@example.com \
			  body "hello" stamp 2024-01-01T10:00:00Z]
	}]
	$::_client iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body sid1
		    j last #body sid1
		}
	    }
	}]

	# Callback should NOT have fired
	set ::result
    } -result UNTOUCHED

test message-history-cancel-still-stores {cancel suppresses callback but stores messages} \
    {*}$msg_common \
    -body {
	tacky message history -acc $acc -chat bob@example.com -limit 50 \
	    -tag mytag \
	    -command [list apply {{r} {}}]

	set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
	set qid [mam_queryid]

	tacky message cancel -acc $acc -tag mytag

	$::_client mam onResultMessage [j message -from user@test.example.com {
	    j /as-is [mam_result id sid1 queryid $qid from bob@example.com \
			  body "stored msg" stamp 2024-01-01T10:00:00Z]
	}]
	$::_client iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body sid1
		    j last #body sid1
		}
	    }
	}]

	# Messages should still be in local store
	set local [$::_client message messagestore get bob@example.com]
	list [llength $local] [dict get [lindex $local 0] body]
    } -result {1 {stored msg}}

test message-history-no-tag-unaffected-by-cancel {cancel with unknown tag is harmless} \
    {*}$msg_common \
    -body {
	tacky message cancel -acc $acc -tag nonexistent
	set result [msg_history -chat bob@example.com -limit 50]
	# Should proceed normally (triggers MAM since not synced)
	set written [$::_client conn get_written]
	expr {[llength $written] > 0}
    } -result 1

# -- live message receiving ----------------------------------------------------

test message-live-fields {stored live message has correct fields} \
    {*}$msg_common \
    -body {
	$::_client conn feed [j message -type chat -id orig7 -from alice@example.com/phone {
	    j body #body hi
	    j stanza-id -ns urn:xmpp:sid:0 -id srv42
	}]
	set msg [lindex [$::_client message messagestore get alice@example.com] 0]
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
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "offline msg"
	    j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
	}]
	set msg [lindex [$::_client message messagestore get alice@example.com] 0]
	# ParseTimestamp of 2024-06-15T12:00:00Z
	set expected [ParseTimestamp 2024-06-15T12:00:00Z]
	expr {[dict get $msg timestamp] == $expected}
    } -result {1}

test message-live-no-body-ignored {message without body is not stored} \
    {*}$msg_common \
    -body {
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j active -ns http://jabber.org/protocol/chatstates
	}]
	llength [$::_client message messagestore get alice@example.com]
    } -result {0}

test message-live-pubsub-not-stored {PubSub messages are dispatched, not stored} \
    {*}$msg_common \
    -body {
	set got 0
	$::_client message pubsub handler urn:xmpp:avatar:metadata \
	    [list apply {{stanza} { set ::got 1 }}]
	$::_client conn feed [j message -from alice@example.com {
	    j event -ns http://jabber.org/protocol/pubsub#event {
		j items -node urn:xmpp:avatar:metadata
	    }
	}]
	list $got [llength [$::_client message messagestore get alice@example.com]]
    } -result {1 0}

test message-live-server-id-not-timestamp {server_id in DB is the stanza-id, not the timestamp} \
    {*}$msg_common \
    -body {
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body hi
	    j stanza-id -ns urn:xmpp:sid:0 -id srv42
	    j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
	}]
	set db [$::_client message messagestore cget -db]
	$db eval {
	    SELECT server_id, timestamp, raw_xml FROM chat_message
	    WHERE chat_jid='alice@example.com'
	} row {
	    set sid $row(server_id)
	    set ts  $row(timestamp)
	    set xml $row(raw_xml)
	}
	list [expr {$sid eq "srv42"}] \
	     [expr {$sid ne $ts}] \
	     [string match {*<message*} $xml]
    } -result {1 1 1}

test message-mam-server-id-not-timestamp {MAM result server_id in DB is archive ID, not timestamp} \
    {*}$msg_common \
    -body {
	set result {}
	tacky message history -acc $acc -chat alice@example.com -limit 5 \
	    -command [list apply {{r} { set ::result $r }}]

	set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
	set qid [mam_queryid]

	$::_client mam onResultMessage [j message -from user@test.example.com {
	    j /as-is [mam_result id archive-uuid-42 queryid $qid \
		from alice@example.com/phone body "mam msg" \
		stamp 2024-06-15T12:00:00Z]
	}]

	$::_client iq feed [j iq -type result -id $iqId {
	    j fin -ns urn:xmpp:mam:2 -complete true {
		j set -ns http://jabber.org/protocol/rsm {
		    j first #body archive-uuid-42
		    j last #body archive-uuid-42
		}
	    }
	}]

	set db [$::_client message messagestore cget -db]
	$db eval {
	    SELECT server_id, timestamp, raw_xml FROM chat_message
	    WHERE chat_jid='alice@example.com'
	} row {
	    set sid $row(server_id)
	    set ts  $row(timestamp)
	    set xml $row(raw_xml)
	}
	list [expr {$sid eq "archive-uuid-42"}] \
	     [expr {$sid ne $ts}] \
	     [string match {*<message*} $xml]
    } -result {1 1 1}

test message-live-shared-region {messages to different chats share one live region} \
    {*}$msg_common \
    -body {
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "hi alice"
	}]
	$::_client conn feed [j message -type chat -from bob@example.com/laptop {
	    j body #body "hi bob"
	}]
	[$::_client message messagestore cget -db] eval {
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
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "event test"
	}]
	list [dict get $_got -jid] \
	     [dict get $_got -from] \
	     [dict get $_got -body]
    } -result {alice@example.com alice@example.com/phone {event test}}

test message-live-disconnect-clears-region {disconnect resets liveRegion} \
    {*}$msg_common \
    -body {
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body msg1
	}]
	$::_client conn fire_disconnect "gone"
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body msg2
	}]
	# After disconnect, a new region should be allocated
	[$::_client message messagestore cget -db] eval {
	    SELECT COUNT(DISTINCT region) FROM chat_message
	}
    } -result {2}

# -- catchup at startup -------------------------------------------------------

# Helper: trigger OnReady (sets bound-jid, fires ready)
proc msg_ready {} {
    $::_client conn configure -bound-jid user@test.example.com/res
    $::_client conn fire_ready 0
}

# Helper: find the MAM IQ among written stanzas (multiple modules write IQs on ready)
proc mam_catchup_iq {} {
    foreach stanza [$::_client conn get_written] {
	if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""} {
	    return $stanza
	}
    }
    return ""
}

# Helper: complete a catchup by feeding MAM results + fin IQ
proc msg_catchup_finish {results {complete true}} {
    set iqStanza [mam_catchup_iq]
    set iqId [dict get $iqStanza attrs id]
    set qid [xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid]

    foreach rn $results {
	$::_client mam onResultMessage [j message -from user@test.example.com {
	    j /as-is $rn
	}]
    }

    set first ""
    set last ""
    if {[llength $results] > 0} {
	set first [xsearch [lindex $results 0] -get @id]
	set last [xsearch [lindex $results end] -get @id]
    }

    $::_client iq feed [j iq -type result -id $iqId {
	j fin -ns urn:xmpp:mam:2 -complete $complete {
	    j set -ns http://jabber.org/protocol/rsm {
		if {$first ne ""} {
		    j first #body $first
		    j last #body $last
		}
	    }
	}
    }]
}

test message-catchup-on-ready {OnReady sends global MAM query with before and no with} \
    {*}$msg_common \
    -body {
	msg_ready
	set iq [mam_catchup_iq]
	set qnode [lindex [xsearch $iq query -ns urn:xmpp:mam:2] 0]
	set hasWith [expr {[xsearch $qnode x field @var with] ne ""}]
	set hasBefore [expr {[xsearch $iq query set before] ne ""}]
	list [expr {!$hasWith}] $hasBefore
    } -result {1 1}

test message-catchup-routes-incoming {catchup stores incoming message under sender's bare JID} \
    {*}$msg_common \
    -body {
	msg_ready
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id s1 queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body "hi there" stamp 2024-01-01T10:00:00Z]]
	set msgs [$::_client message messagestore get alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {hi there}}

test message-catchup-routes-outgoing {catchup stores outgoing message under recipient's bare JID} \
    {*}$msg_common \
    -body {
	msg_ready
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id s1 queryid $qid \
		from user@test.example.com/res to bob@example.com \
		body "hey bob" stamp 2024-01-01T10:00:00Z]]
	set msgs [$::_client message messagestore get bob@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {hey bob}}

test message-catchup-emits-done {catchup emits CatchupDone with correct count} \
    {*}$msg_common \
    -body {
	set ::_done {}
	tacky listen message <CatchupDone> {apply {{ev} { set ::_done $ev }}}
	msg_ready
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id s1 queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body msg1 stamp 2024-01-01T10:00:00Z] \
	    [mam_result id s2 queryid $qid \
		from bob@example.com/laptop to user@test.example.com \
		body msg2 stamp 2024-01-01T11:00:00Z]]
	dict get $_done -count
    } -result {2}

test message-catchup-mam-error {MAM error emits CatchupDone with count 0} \
    {*}$msg_common \
    -body {
	set ::_done {}
	tacky listen message <CatchupDone> {apply {{ev} { set ::_done $ev }}}
	msg_ready
	set iqId [dict get [mam_catchup_iq] attrs id]
	$::_client iq feed [j iq -type error -id $iqId {
	    j error -type cancel {
		j feature-not-implemented
	    }
	}]
	dict get $_done -count
    } -result {0}

test message-catchup-skips-empty-body {catchup skips messages without body} \
    {*}$msg_common \
    -body {
	msg_ready
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id s1 queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body "" stamp 2024-01-01T10:00:00Z]]
	set ::_done {}
	;# already emitted, check store
	llength [$::_client message messagestore get alice@example.com]
    } -result {0}

test message-catchup-dedup-with-live {catchup deduplicates against live messages} \
    {*}$msg_common \
    -body {
	msg_ready
	# Live message arrives with server_id
	$::_client conn feed [j message -type chat -from alice@example.com/phone {
	    j body #body "live msg"
	    j stanza-id -ns urn:xmpp:sid:0 -id s1
	}]
	# Catchup returns same message
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id s1 queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body "live msg" stamp 2024-01-01T10:00:00Z]]
	llength [$::_client message messagestore get alice@example.com]
    } -result {1}

test message-catchup-dedup-no-ids {catchup deduplicates messages without server/origin IDs (IRC bridges)} \
    {*}$msg_common \
    -body {
	# Pre-store messages without IDs (simulating previous catchup)
	msg_store [list \
	    [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
		chat_jid alice@example.com from_jid alice@example.com/phone \
		body "bridge msg" server_id "" origin_id ""] \
	    [msg_msg timestamp [ParseTimestamp 2024-01-01T11:00:00Z] \
		chat_jid alice@example.com from_jid alice@example.com/phone \
		body "bridge msg 2" server_id "" origin_id ""]]
	# Now catchup returns the same messages (no IDs, as IRC bridges do)
	msg_ready
	set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
	msg_catchup_finish [list \
	    [mam_result id "" queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body "bridge msg" stamp 2024-01-01T10:00:00Z] \
	    [mam_result id "" queryid $qid \
		from alice@example.com/phone to user@test.example.com \
		body "bridge msg 2" stamp 2024-01-01T11:00:00Z]]
	set db [$::_client message messagestore cget -db]
	list [$db eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}] \
	     [$db eval {SELECT COUNT(DISTINCT region) FROM chat_message WHERE chat_jid='alice@example.com'}]
    } -result {2 1}
