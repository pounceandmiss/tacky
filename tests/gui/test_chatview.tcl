# Unit tests for chatview — end-to-end from stanza to widget

set acc user@test.example.com

# -- helpers --------------------------------------------------------------------

# Feed a chat message stanza through the mock client.
proc cv_feed {body sid args} {
    $::_client conn feed [j message -type chat \
	-from alice@example.com/phone {
	j body #body $body
	j stanza-id -ns urn:xmpp:sid:0 -id $sid
	if {[dict exists $args -stamp]} {
	    j delay -ns urn:xmpp:delay -stamp [dict get $args -stamp]
	}
    }]
}

# Build a MAM <result> node wrapping a message.
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

# Find MAM IQs with a specific 'with' filter among written stanzas.
# Returns the first match, or all matches with -all.
proc cv_find_mam_iq {jid args} {
    set all [expr {"-all" in $args}]
    set result {}
    foreach stanza [$::_client conn get_written] {
	set qnode [xsearch $stanza query -ns urn:xmpp:mam:2]
	if {$qnode eq ""} continue
	set withVal [xsearch [lindex $qnode 0] x field @var with value -get body]
	if {$withVal eq $jid} {
	    if {!$all} { return $stanza }
	    lappend result $stanza
	}
    }
    if {$all} { return $result }
    return ""
}

# Complete a MAM IQ with messages and fin.
# messages: list of {id body stamp} triples
# complete: whether to mark the archive as fully fetched
proc cv_complete_mam_with {iqStanza messages {complete true}} {
    set iqId [dict get $iqStanza attrs id]
    set qid [xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid]

    foreach {id body stamp} $messages {
	set rn [mam_result id $id queryid $qid \
	    from alice@example.com/phone body $body stamp $stamp]
	$::_client mam onResultMessage [j message -from user@test.example.com {
	    j /as-is $rn
	}]
    }

    set first [lindex $messages 0]
    set last  [lindex $messages end-2]

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

# Complete all pending MAM queries with empty archives.
proc cv_complete_mam {} {
    foreach stanza [$::_client conn get_written] {
	if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""} {
	    cv_complete_mam_with $stanza {}
	}
    }
    $::_client conn clear
}

# Create tacky + mock client + avatarcache. Pair with cv_cleanup.
proc cv_setup {} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc user@test.example.com
    set ::_client [tacky client user@test.example.com]
    $::_client.conn configure -bound-jid user@test.example.com/res1
    $::_client.conn fire_ready 0
    $::_client.conn clear
}

proc cv_cleanup {} {
    destroy .cv
    catch { destroy .menubar }
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
}

# Create chatview. Options:
#   -pack    — pack the widget and set a small geometry (for thirst tests)
#   -nomam   — don't complete the initial MAM query (test completes it)
proc cv_create {args} {
    menu .menubar
    chatview .cv -acc user@test.example.com \
	-jid alice@example.com -menubar .menubar
    if {"-pack" in $args} {
	pack .cv -fill both -expand yes
	wm geometry . 400x200
    }
    wait
    if {"-nomam" ni $args} {
	cv_complete_mam
	wait
    }
}

# -- common setup: tacky + empty chatview ready for live messages ---------------

set cv_common {
    -setup   { cv_setup; cv_create }
    -cleanup { cv_cleanup }
}

# -- live message ---------------------------------------------------------------

test chatview-live-message {stanza fed through client appears in chatview} \
    {*}$cv_common \
    -body {
	cv_feed "hello world" srv1
	wait
	set ids [.cv messages ids]
	list [llength $ids] [expr {[.cv messages newest] ne ""}]
    } -result {1 1}

test chatview-live-dedup {duplicate stanza-id does not create second message} \
    {*}$cv_common \
    -body {
	cv_feed "hello" srv1
	wait
	cv_feed "hello" srv1
	wait
	llength [.cv messages ids]
    } -result {1}

test chatview-multiple-messages {multiple messages appear in order} \
    {*}$cv_common \
    -body {
	cv_feed "first" srv1
	cv_feed "second" srv2
	wait
	llength [.cv messages ids]
    } -result {2}

test chatview-no-body-ignored {message without body does not appear} \
    {*}$cv_common \
    -body {
	$::_client conn feed [j message -type chat \
	    -from alice@example.com/phone {
	    j active -ns http://jabber.org/protocol/chatstates
	}]
	wait
	llength [.cv messages ids]
    } -result {0}

# -- sent + confirmed -----------------------------------------------------------

test chatview-sent-appears {sent message appears in chatview} \
    {*}$cv_common \
    -body {
	tacky message send -acc $::acc -chat_jid alice@example.com \
	    -body "outgoing msg"
	wait
	llength [.cv messages ids]
    } -result {1}

test chatview-confirmed-updates-receipt {server echo triggers receipt update} \
    {*}$cv_common \
    -body {
	tacky message send -acc $::acc -chat_jid alice@example.com \
	    -body "outgoing msg"
	wait
	set sentId [.cv messages newest]
	set sentStanza [lindex [$::_client conn get_written] end]
	set oid [xsearch $sentStanza -get @id]
	$::_client conn feed [j message -type chat \
	    -from alice@example.com/phone -id $oid {
	    j body #body "outgoing msg"
	    j stanza-id -ns urn:xmpp:sid:0 -id srv-echo-1
	}]
	wait
	expr {$sentId in [.cv messages ids]}
    } -result {1}

# -- catchup reload --------------------------------------------------------------

test chatview-catchup-reloads {CatchupDone triggers goto end which reloads} \
    {*}$cv_common \
    -body {
	cv_feed "before catchup" srv1
	wait
	set countBefore [llength [.cv messages ids]]
	tacky emit message <CatchupDone> -count 5
	wait
	cv_complete_mam
	wait
	set countAfter [llength [.cv messages ids]]
	list before=$countBefore after=$countAfter
    } -result {before=1 after=1}

# -- history loading -------------------------------------------------------------

test chatview-initial-load-shows-history {pre-seeded messages appear after construction} \
    -setup {
	cv_setup
	cv_feed "seeded msg 1" seed1
	cv_feed "seeded msg 2" seed2
	cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
	llength [.cv messages ids]
    } -result {2}

test chatview-initial-load-mam {empty DB triggers MAM and results appear in widget} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	set mamIq [cv_find_mam_iq alice@example.com]
	if {$mamIq eq ""} { error "no MAM IQ for alice@example.com" }
	cv_complete_mam_with $mamIq {
	    sid1 "mam msg 1" 2024-01-01T10:00:00Z
	    sid2 "mam msg 2" 2024-01-01T11:00:00Z
	    sid3 "mam msg 3" 2024-01-01T12:00:00Z
	}
	wait
	llength [.cv messages ids]
    } -result {3}

test chatview-scroll-up-loads-more {initial MAM load then thirst fetches older via MAM} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	# 1. Complete initial MAM with 3 messages, incomplete archive
	set mamIq [cv_find_mam_iq alice@example.com]
	if {$mamIq eq ""} { error "no initial MAM IQ" }
	cv_complete_mam_with $mamIq {
	    sid1 "msg 1" 2024-01-01T10:00:00Z
	    sid2 "msg 2" 2024-01-01T11:00:00Z
	    sid3 "msg 3" 2024-01-01T12:00:00Z
	} false
	$::_client conn clear
	wait

	set countAfterInitial [llength [.cv messages ids]]

	# 2. Thirst should have fired for "old" and sent a -before MAM query
	set mamIq2 [cv_find_mam_iq alice@example.com]
	if {$mamIq2 eq ""} { error "no scroll-up MAM IQ" }

	# 3. Feed 2 older messages
	cv_complete_mam_with $mamIq2 {
	    sid-old1 "older 1" 2024-01-01T08:00:00Z
	    sid-old2 "older 2" 2024-01-01T09:00:00Z
	}
	wait

	set countAfterScroll [llength [.cv messages ids]]
	list initial=$countAfterInitial scrolled=$countAfterScroll
    } -result {initial=3 scrolled=5}

test chatview-scroll-up-multi-page {thirst fires again after each MAM backfill page} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	# 1. Complete initial MAM with 3 messages, incomplete archive
	set mamIq [cv_find_mam_iq alice@example.com]
	if {$mamIq eq ""} { error "no initial MAM IQ" }
	cv_complete_mam_with $mamIq {
	    sid1 "msg 1" 2024-01-01T10:00:00Z
	    sid2 "msg 2" 2024-01-01T11:00:00Z
	    sid3 "msg 3" 2024-01-01T12:00:00Z
	} false
	$::_client conn clear
	wait

	set countAfterInitial [llength [.cv messages ids]]

	# 2. Thirst should have fired → first backfill MAM query
	set mamIq2 [cv_find_mam_iq alice@example.com]
	if {$mamIq2 eq ""} { error "no first backfill MAM IQ" }
	cv_complete_mam_with $mamIq2 {
	    sid-old1 "older 1" 2024-01-01T08:00:00Z
	    sid-old2 "older 2" 2024-01-01T09:00:00Z
	} false
	$::_client conn clear
	wait

	set countAfterFirst [llength [.cv messages ids]]

	# 3. Second backfill — "new" direction is short-circuited by
	#    DB check (cursor at latest), so only "old" MAM fires.
	set mamIq3 [cv_find_mam_iq alice@example.com]
	if {$mamIq3 eq ""} { error "no second backfill MAM IQ" }
	cv_complete_mam_with $mamIq3 {
	    sid-old3 "oldest 1" 2024-01-01T06:00:00Z
	    sid-old4 "oldest 2" 2024-01-01T07:00:00Z
	} false
	$::_client conn clear
	wait

	set countAfterSecond [llength [.cv messages ids]]

	# 4. Third backfill — the "new" direction's complete=true
	#    must not have blocked this.
	set mamIq4 [cv_find_mam_iq alice@example.com]
	if {$mamIq4 eq ""} { error "no third backfill MAM IQ — synced too early?" }
	cv_complete_mam_with $mamIq4 {
	    sid-old5 "oldest 3" 2024-01-01T04:00:00Z
	    sid-old6 "oldest 4" 2024-01-01T05:00:00Z
	}
	wait

	set countAfterThird [llength [.cv messages ids]]
	list initial=$countAfterInitial first=$countAfterFirst \
	    second=$countAfterSecond third=$countAfterThird
    } -result {initial=3 first=5 second=7 third=9}

test chatview-thirst-loads-older {thirst loads older messages from local DB} \
    -setup {
	cv_setup
	foreach {sid body stamp} {
	    s1 "older 1" 2024-01-01T08:00:00Z
	    s2 "older 2" 2024-01-01T09:00:00Z
	    s3 "msg 3"   2024-01-01T10:00:00Z
	    s4 "msg 4"   2024-01-01T11:00:00Z
	    s5 "msg 5"   2024-01-01T12:00:00Z
	} {
	    cv_feed $body $sid -stamp $stamp
	}
	cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
	llength [.cv messages ids]
    } -result {5}

# -- goto (jump to date) --------------------------------------------------------

test chatview-goto-timestamp {goto -source remote fetches MAM then displays around anchor} \
    -setup {
	cv_setup
	cv_feed "recent 1" r1
	cv_feed "recent 2" r2
	cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
	set countBefore [llength [.cv messages ids]]

	# Jump to a date in the past (remote fetch)
	$::_client conn clear
	.cv goto [ParseTimestamp 2024-06-15T12:00:00Z] -source remote
	wait 500

	set countPending [llength [.cv messages ids]]

	# Complete the MAM query — OnGoto stores results, getAround
	# returns them, OnGotoDone clears and reloads
	set mamIq [cv_find_mam_iq alice@example.com]
	if {$mamIq eq ""} { error "no MAM IQ" }
	cv_complete_mam_with $mamIq {
	    s1 "msg 1" 2024-06-15T12:00:01Z
	    s2 "msg 2" 2024-06-15T12:30:00Z
	    s3 "msg 3" 2024-06-15T13:00:00Z
	}

	set countAfter [llength [.cv messages ids]]

	# First result should be visible (anchor is nearest to target date)
	set firstId [ParseTimestamp 2024-06-15T12:00:01Z]
	set hasFirst [expr {$firstId in [.cv messages ids]}]
	list before=$countBefore pending=$countPending \
	    after=$countAfter hasFirst=$hasFirst
    } -result {before=2 pending=2 after=3 hasFirst=1}

# -- stale cursor guard ---------------------------------------------------------

test chatview-stale-old-discarded {cleanup invalidation discards stale old-direction response} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	# Initial load, incomplete archive → thirst fires for old
	set mamIq [cv_find_mam_iq alice@example.com]
	cv_complete_mam_with $mamIq {
	    sid1 "msg 1" 2024-01-01T10:00:00Z
	    sid2 "msg 2" 2024-01-01T11:00:00Z
	    sid3 "msg 3" 2024-01-01T12:00:00Z
	} false
	$::_client conn clear
	wait

	set countBefore [llength [.cv messages ids]]

	# Old-direction MAM query is now in flight
	set mamIq2 [cv_find_mam_iq alice@example.com]
	if {$mamIq2 eq ""} { error "no thirst MAM IQ" }

	# Simulate DoCleanup cleaning the old direction while the
	# response is in flight.  This clears LoadToken, unlistens
	# the callback, and cancels the backend query — so the stale
	# response should never reach OnLoadDone.
	.cv OnThirst {old} no [.cv messages oldest] [.cv messages newest]

	# Complete the now-stale MAM response
	cv_complete_mam_with $mamIq2 {
	    sid-old1 "older 1" 2024-01-01T08:00:00Z
	    sid-old2 "older 2" 2024-01-01T09:00:00Z
	}
	wait

	set countAfter [llength [.cv messages ids]]
	list before=$countBefore after=$countAfter
    } -result {before=3 after=3}

test chatview-fresh-load-after-invalidation {new thirst re-requests and loads after invalidation} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	# Initial load, incomplete
	set mamIq [cv_find_mam_iq alice@example.com]
	cv_complete_mam_with $mamIq {
	    sid1 "msg 1" 2024-01-01T10:00:00Z
	    sid2 "msg 2" 2024-01-01T11:00:00Z
	    sid3 "msg 3" 2024-01-01T12:00:00Z
	} false
	$::_client conn clear
	wait

	# Old thirst in flight
	set mamIq2 [cv_find_mam_iq alice@example.com]
	if {$mamIq2 eq ""} { error "no first thirst MAM IQ" }

	# Invalidate
	.cv OnThirst {old} no [.cv messages oldest] [.cv messages newest]
	$::_client conn clear

	# Kick a new cleanup cycle — in real use the user is scrolling,
	# but here the widget is idle so we nudge it.
	event generate .cv.text <<Yview>>
	wait

	# Thirst should re-fire with a fresh cursor → new MAM query
	set mamIq3 [cv_find_mam_iq alice@example.com]
	if {$mamIq3 eq ""} { error "no re-requested MAM IQ after invalidation" }

	# Complete the fresh request
	cv_complete_mam_with $mamIq3 {
	    sid-old1 "older 1" 2024-01-01T08:00:00Z
	    sid-old2 "older 2" 2024-01-01T09:00:00Z
	}
	wait

	llength [.cv messages ids]
    } -result {5}

test chatview-goto-cancels-inflight {goto end discards in-flight thirst response} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
	# Initial load, incomplete
	set mamIq [cv_find_mam_iq alice@example.com]
	cv_complete_mam_with $mamIq {
	    sid1 "msg 1" 2024-01-01T10:00:00Z
	    sid2 "msg 2" 2024-01-01T11:00:00Z
	    sid3 "msg 3" 2024-01-01T12:00:00Z
	} false
	$::_client conn clear
	wait

	# Old thirst in flight
	set mamIq2 [cv_find_mam_iq alice@example.com]
	if {$mamIq2 eq ""} { error "no thirst MAM IQ" }

	# goto end — cancels in-flight loads via unlisten + message cancel
	.cv goto end
	$::_client conn clear
	wait
	cv_complete_mam
	wait

	set countAfterGoto [llength [.cv messages ids]]

	# Complete stale old-direction MAM
	cv_complete_mam_with $mamIq2 {
	    sid-old1 "older 1" 2024-01-01T08:00:00Z
	    sid-old2 "older 2" 2024-01-01T09:00:00Z
	}
	wait

	set countAfterStale [llength [.cv messages ids]]
	list goto=$countAfterGoto stale=$countAfterStale
    } -result {goto=3 stale=3}

# -- chatarea apply tests -------------------------------------------------------

# Helper: build a message dict suitable for chatarea apply
proc ca_msg {id prev body} {
    dict create id $id prev $prev body $body \
	display_name test avatar_jid "" \
	timestamp $id is_outgoing 0 receipt_status ""
}

proc ca_hollow {id prev} {
    dict create id $id prev $prev hollow 1
}

set ca_common {
    -setup   { chatarea .ca; update }
    -cleanup { destroy .ca }
}

test chatarea-apply-forward {forward batch chains via prev} \
    {*}$ca_common \
    -body {
	.ca apply [list \
	    [ca_msg 100 "" "msg A"] \
	    [ca_msg 200 100 "msg B"] \
	    [ca_msg 300 200 "msg C"]]
	.ca messages ids
    } -result {100 200 300}

test chatarea-apply-backward {reversed backward batch chains via rexists} \
    {*}$ca_common \
    -body {
	# Bootstrap with one message
	.ca apply [list [ca_msg 500 400 "msg E"]]
	# Simulate reversed backward page: hollow + newest-first
	.ca apply [list \
	    [ca_hollow 500 400] \
	    [ca_msg 400 300 "msg D"] \
	    [ca_msg 300 200 "msg C"] \
	    [ca_msg 200 "" "msg B"]]
	.ca messages ids
    } -result {200 300 400 500}

test chatarea-apply-tombstone-in-chain {empty-body messages maintain prev chain} \
    {*}$ca_common \
    -body {
	.ca apply [list \
	    [ca_msg 100 "" "msg A"] \
	    [ca_msg 200 100 ""] \
	    [ca_msg 300 200 "msg C"] \
	    [ca_msg 400 300 ""] \
	    [ca_msg 500 400 "msg E"]]
	.ca messages ids
    } -result {100 200 300 400 500}

test chatarea-apply-hollow-patches {hollow patches displayed message prev} \
    {*}$ca_common \
    -body {
	.ca apply [list [ca_msg 500 "" "msg E"]]
	# Hollow updates E's prev, then D chains via rexists
	.ca apply [list \
	    [ca_hollow 500 400] \
	    [ca_msg 400 "" "msg D"]]
	.ca messages ids
    } -result {400 500}

test chatarea-apply-hollow-skipped-when-not-displayed {hollow for non-displayed message is ignored} \
    {*}$ca_common \
    -body {
	.ca apply [list [ca_msg 500 "" "msg E"]]
	# Hollow targets 999 which isn't displayed — entire batch skipped
	.ca apply [list \
	    [ca_hollow 999 400] \
	    [ca_msg 400 "" "msg D"]]
	.ca messages ids
    } -result {500}

test chatarea-apply-dedup {already displayed message is patched not duplicated} \
    {*}$ca_common \
    -body {
	.ca apply [list \
	    [ca_msg 100 "" "msg A"] \
	    [ca_msg 200 100 "msg B"]]
	# Re-apply same messages
	.ca apply [list \
	    [ca_msg 100 "" "msg A"] \
	    [ca_msg 200 100 "msg B"]]
	.ca messages ids
    } -result {100 200}
