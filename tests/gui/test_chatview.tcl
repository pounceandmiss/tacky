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

# Simulate a server echo (MUC-style) for a previously sent message.
# sentTs: the timestamp (= own_id) of the sent message
# echoSid: server_id for the echo
# echoStamp: ISO timestamp for the echo (defaults to same as sentTs)
proc cv_muc_echo {sentTs echoSid {echoStamp ""}} {
    if {$echoStamp eq ""} {
        set echoStamp [FormatTimestampISO $sentTs]
    }
    $::_client message store alice@example.com [j message -type chat \
        -from alice@example.com/phone -id $sentTs {
        j body #body "echo"
        j stanza-id -ns urn:xmpp:sid:0 -id $echoSid
        j delay -ns urn:xmpp:delay -stamp $echoStamp
    }] 1
}

# Create tacky + chatview packed with 15 messages so the view overflows.
# direction: incoming | outgoing. Pair with cv_cleanup.
proc cv_overflow_setup {{direction incoming}} {
    cv_setup
    for {set i 0} {$i < 15} {incr i} {
        if {$direction eq "outgoing"} {
            tacky message send -acc $::acc \
                -chat_jid alice@example.com -body "fill $i"
        } else {
            cv_feed "fill $i" seed$i
        }
    }
    cv_create -pack
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

test chatview-sm-ack-shows-receipt {SM ack triggers Patch and shows checkmark} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com \
            -body "outgoing msg"
        wait
        set sentId [.cv messages newest]
        # Check no checkmark yet (pending)
        set tag item.$sentId.receipt
        set ranges [.cv.text tag ranges $tag]
        set before [.cv.text get {*}$ranges]
        # Trigger SM ack
        set sentStanza [lindex [$::_client conn get_written] end]
        $::_client message OnSmAck \
            -stanzas [list $sentStanza]
        wait
        set ranges [.cv.text tag ranges $tag]
        set after [.cv.text get {*}$ranges]
        list before=$before after=$after
    } -result "{before= } {after= \u2713}"

test chatview-multiple-outgoing-order {multiple outgoing messages appear in send order} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com -body "one"
        wait
        tacky message send -acc $::acc -chat_jid alice@example.com -body "two"
        wait
        tacky message send -acc $::acc -chat_jid alice@example.com -body "three"
        wait
        llength [.cv messages ids]
    } -result {3}

test chatview-outgoing-interleaved {outgoing interleaved with incoming in correct order} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com -body "out1"
        wait
        set ts1 [.cv messages newest]
        cv_feed "incoming" srv-in
        wait
        tacky message send -acc $::acc -chat_jid alice@example.com -body "out2"
        wait
        set ids [.cv messages ids]
        list [llength $ids] [expr {[lindex $ids 0] == $ts1}]
    } -result {3 1}

test chatview-muc-echo-same-ts {echo with same timestamp confirms in place} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com -body "hello"
        wait
        set sentId [.cv messages newest]
        cv_muc_echo $sentId echo-sid1
        wait
        set tag item.$sentId.receipt
        set ranges [.cv.text tag ranges $tag]
        set receipt [.cv.text get {*}$ranges]
        list [llength [.cv messages ids]] receipt=$receipt
    } -result "1 {receipt= \u2713}"

test chatview-muc-echo-different-ts {echo with different timestamp moves message} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com -body "hello"
        wait
        set sentId [.cv messages newest]
        # Echo at 1 second later
        set echoTs [expr {$sentId + 1000000}]
        set echoStamp [FormatTimestampISO $echoTs]
        cv_muc_echo $sentId echo-sid2 $echoStamp
        wait
        set ids [.cv messages ids]
        set newId [lindex $ids 0]
        # Old id should be gone, new id should be present
        set tag item.$newId.receipt
        set ranges [.cv.text tag ranges $tag]
        set receipt [.cv.text get {*}$ranges]
        list [llength $ids] [expr {$sentId ni $ids}] \
            [expr {$newId == $echoTs}] receipt=$receipt
    } -result "1 1 1 {receipt= \u2713}"

test chatview-muc-echo-reorders {echo reorders message among interleaved messages} \
    {*}$cv_common \
    -body {
        cv_feed "A" srv-a -stamp 2025-01-01T12:00:00Z
        wait
        set tsA [.cv messages newest]
        tacky message send -acc $::acc -chat_jid alice@example.com -body "X"
        wait
        set tsX [.cv messages newest]
        cv_feed "B" srv-b
        wait
        set tsB [.cv messages newest]
        set countBefore [llength [.cv messages ids]]
        # Echo X at timestamp after B
        set echoTs [expr {$tsB + 1000000}]
        cv_muc_echo $tsX echo-reorder [FormatTimestampISO $echoTs]
        wait
        set ids [.cv messages ids]
        # Expected: A, B, X' — X moved after B
        list count=$countBefore \
            [llength $ids] \
            [expr {[lindex $ids 0] == $tsA}] \
            [expr {[lindex $ids 1] == $tsB}] \
            [expr {[lindex $ids 2] == $echoTs}]
    } -result {count=3 3 1 1 1}

test chatview-muc-echo-reorders-4msg {MUC echo with new timestamp reorders 4-message view} \
    {*}$cv_common \
    -body {
        # Setup: A(100) → X(200,pending) → B(300) → C(400)
        cv_feed "A" srv-a -stamp 2025-01-01T12:00:00Z
        wait
        set tsA [.cv messages newest]
        tacky message send -acc $::acc -chat_jid alice@example.com -body "X"
        wait
        set tsX [.cv messages newest]
        cv_feed "B" srv-b
        wait
        set tsB [.cv messages newest]
        cv_feed "C" srv-c
        wait
        set tsC [.cv messages newest]
        # Verify initial order: A, X, B, C
        set before [.cv messages ids]
        # Echo X at timestamp between B and C
        set echoTs [expr {$tsB + ($tsC - $tsB) / 2}]
        cv_muc_echo $tsX echo-4msg [FormatTimestampISO $echoTs]
        wait
        set after [.cv messages ids]
        # Expected: A, B, X', C — X moved between B and C
        list [llength $before] [llength $after] \
            [expr {[lindex $after 0] == $tsA}] \
            [expr {[lindex $after 1] == $tsB}] \
            [expr {[lindex $after 2] == $echoTs}] \
            [expr {[lindex $after 3] == $tsC}]
    } -result {4 4 1 1 1 1}

test chatview-outgoing-region-is-negative {outgoing-only chat has region -1} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat_jid alice@example.com -body "out"
        wait
        list old=[.cv messages regionForDirection old] \
            new=[.cv messages regionForDirection new]
    } -result {old=-1 new=-1}

test chatview-mixed-region-derivation {region derivation skips outgoing messages} \
    {*}$cv_common \
    -body {
        cv_feed "incoming" srv1
        wait
        # With only incoming, region must be real (not -1)
        set regionBefore [.cv messages regionForDirection old]
        tacky message send -acc $::acc -chat_jid alice@example.com -body "out"
        wait
        # After adding outgoing, region should still resolve to the real one
        set regionAfter [.cv messages regionForDirection old]
        list [expr {$regionBefore != -1}] [expr {$regionAfter == $regionBefore}]
    } -result {1 1}

foreach {direction seedCmd} {
    outgoing {tacky message send -acc $::acc -chat_jid alice@example.com -body "pending"}
    incoming {cv_feed "before catchup" srv1}
} {
    test chatview-${direction}-survives-catchup \
        "$direction still visible after CatchupDone reload" \
        {*}$cv_common \
        -body {
            eval $seedCmd
            wait
            set countBefore [llength [.cv messages ids]]
            tacky emit message <CatchupDone> -count 5
            wait
            cv_complete_mam
            wait
            set countAfter [llength [.cv messages ids]]
            list before=$countBefore after=$countAfter
        } -result {before=1 after=1}
}

# -- scroll-to-bottom on incoming/outgoing ---------------------------------------

# Parameterised scroll test: direction × scroll position.
#   direction: incoming | outgoing
#   scrollPos: at-end  | scrolled-up
foreach {direction scrollPos result} {
    outgoing at-end      {before=1 after=1}
    outgoing scrolled-up {before=0 after=0}
    incoming at-end      {before=1 after=1}
    incoming scrolled-up {before=0 after=0}
} {
    test chatview-${direction}-scroll-${scrollPos} \
        "$direction while $scrollPos" \
        -setup { cv_overflow_setup $direction } \
        -cleanup { cv_cleanup } \
        -body {
            if {$scrollPos eq "scrolled-up"} {
                .cv.text yview moveto 0
                wait
            }
            set atEndBefore [expr {[lindex [.cv.text yview] 1] >= 1.0}]
            if {$direction eq "outgoing"} {
                tacky message send -acc $::acc \
                    -chat_jid alice@example.com -body "one more"
            } else {
                cv_feed "new msg" srv-new
            }
            wait
            set atEndAfter [expr {[lindex [.cv.text yview] 1] >= 1.0}]
            list before=$atEndBefore after=$atEndAfter
        } -result $result
}

# -- scroll button visibility ----------------------------------------------------

test chatview-scrollbtn-hidden-at-end {scroll button hidden when at bottom} \
    -setup { cv_overflow_setup } \
    -cleanup { cv_cleanup } \
    -body {
        expr {[place info .cv.scrollbtn] eq ""}
    } -result {1}

test chatview-scrollbtn-shown-when-scrolled-up {scroll button appears when scrolled up and hides on return} \
    -setup { cv_overflow_setup } \
    -cleanup { cv_cleanup } \
    -body {
        .cv.text yview moveto 0
        event generate .cv.text <<Yview>>
        wait
        set shownAfterScroll [expr {[place info .cv.scrollbtn] ne ""}]
        .cv.text see end
        event generate .cv.text <<Yview>>
        wait
        set hiddenAfterReturn [expr {[place info .cv.scrollbtn] eq ""}]
        list shown=$shownAfterScroll hidden=$hiddenAfterReturn
    } -result {shown=1 hidden=1}

# -- history loading -------------------------------------------------------------

test chatview-live-after-history {live message appears when history is already displayed} \
    -setup {
        cv_setup
        cv_feed "seeded 1" seed1
        cv_feed "seeded 2" seed2
        cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
        set countBefore [llength [.cv messages ids]]
        cv_feed "live msg" srv-live
        wait
        set countAfter [llength [.cv messages ids]]
        list before=$countBefore after=$countAfter
    } -result {before=2 after=3}

test chatview-live-after-mam-history {live message appears when MAM history is displayed} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        set mamIq [cv_find_mam_iq alice@example.com]
        cv_complete_mam_with $mamIq {
            sid1 "mam 1" 2024-01-01T10:00:00Z
            sid2 "mam 2" 2024-01-01T11:00:00Z
        }
        wait
        set countBefore [llength [.cv messages ids]]
        cv_feed "live msg" srv-live
        wait
        set countAfter [llength [.cv messages ids]]
        list before=$countBefore after=$countAfter
    } -result {before=2 after=3}

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
        .cv OnCulled {old}

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
        .cv OnCulled {old}
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

test chatview-live-dropped-when-tail-culled {live message ignored after new-direction cull} \
    {*}$cv_common \
    -body {
        cv_feed "anchor" srv-anchor
        wait
        set countBefore [llength [.cv messages ids]]
        # Simulate chatarea culling the tail. AtTail flips false, so
        # subsequent live <Received> events should be dropped.
        .cv OnCulled {new}
        cv_feed "while-paused" srv-paused
        wait
        set countAfter [llength [.cv messages ids]]
        list before=$countBefore after=$countAfter
    } -result {before=1 after=1}

# -- chatarea apply tests -------------------------------------------------------

# Helper: build a message dict suitable for chatarea apply
proc ca_msg {id body} {
    dict create id $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 0 server_status ""
}

proc ca_outgoing {id body {status pending}} {
    dict create id $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 1 server_status $status
}

proc ca_patch {id} {
    dict create id $id server_status received
}

set ca_common {
    -setup   { chatarea .ca; update }
    -cleanup { destroy .ca }
}

test chatarea-apply-forward {forward batch lands in timestamp order} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"] \
            [ca_msg 300 "msg C"]]
        .ca messages ids
    } -result {100 200 300}

test chatarea-apply-backward {newest-first batch lands in timestamp order} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 500 "msg E"]]
        .ca apply [list \
            [ca_msg 400 "msg D"] \
            [ca_msg 300 "msg C"] \
            [ca_msg 200 "msg B"]]
        .ca messages ids
    } -result {200 300 400 500}

test chatarea-apply-tombstone {empty-body messages still take a slot in the timeline} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 ""] \
            [ca_msg 300 "msg C"] \
            [ca_msg 400 ""] \
            [ca_msg 500 "msg E"]]
        .ca messages ids
    } -result {100 200 300 400 500}

test chatarea-apply-patch-on-displayed {patch entry alongside a new insert applies and inserts} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 500 "msg E"]]
        .ca apply [list \
            [ca_patch 500] \
            [ca_msg 400 "msg D"]]
        .ca messages ids
    } -result {400 500}

test chatarea-apply-out-of-order {batch with non-monotonic timestamps lands sorted} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "A"] \
            [ca_msg 300 "C"] \
            [ca_msg 200 "B"]]
        .ca messages ids
    } -result {100 200 300}

test chatarea-apply-dedup {already displayed message is patched not duplicated} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        # Re-apply same messages
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        .ca messages ids
    } -result {100 200}

test chatarea-patch-receipt {Patch with server_status updates receipt checkmark} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_outgoing 100 "hello"]]
        # Receipt tag should exist but show no checkmark (pending)
        set tag item.100.receipt
        set ranges [.ca.text tag ranges $tag]
        set before [expr {[llength $ranges] > 0
            ? [.ca.text get {*}$ranges] : "MISSING"}]
        # Patch: server confirms receipt
        .ca apply [list [dict create id 100 server_status received]]
        set ranges [.ca.text tag ranges $tag]
        set after [expr {[llength $ranges] > 0
            ? [.ca.text get {*}$ranges] : "MISSING"}]
        list before=$before after=$after
    } -result "{before= } {after= \u2713}"

# -- highlight / system ---------------------------------------------------------

test chatarea-highlight-message {highlight applies yellow and clears previous} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        .ca highlight message 100
        set bg1 [.ca.text tag cget item.100 -background]
        .ca highlight message 200
        set bg1after [.ca.text tag cget item.100 -background]
        set bg2 [.ca.text tag cget item.200 -background]
        list first=$bg1 first_after=$bg1after second=$bg2
    } -result {first=yellow first_after= second=yellow}

test chatarea-highlight-clear {highlight clear removes background} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 100 "msg A"]]
        .ca highlight message 100
        set before [.ca.text tag cget item.100 -background]
        .ca highlight clear
        set after [.ca.text tag cget item.100 -background]
        list before=$before after=$after
    } -result {before=yellow after=}

test chatarea-system-insert {system message is inserted with system tag} \
    {*}$ca_common \
    -body {
        .ca system insert "Connection lost"
        set content [.ca.text get 1.0 end-1c]
        set tags [.ca.text tag names 1.0]
        list [string match *Connection\ lost* $content] \
            [expr {"system" in $tags}]
    } -result {1 1}

# -- chatarea pagination signals ------------------------------------------------

# Wrap .ca.text so 'count -ypixels' returns values from the global ::mock_above
# / ::mock_below. Each is read fresh on every call, so DoCleanup's while-loop
# sees decreasing pixels as messages are deleted (callers can adjust between
# calls or use a proc-style global that tracks llength).
proc ca_install_pixel_mock {} {
    rename .ca.text _real_ca_text
    proc ::.ca.text args {
        if {[lindex $args 0] eq "count" && [lindex $args 1] eq "-ypixels"} {
            set startIdx [lindex $args 2]
            if {$startIdx eq "0.0"} {
                return [expr {$::mock_above}]
            } else {
                return [expr {$::mock_below}]
            }
        }
        return [_real_ca_text {*}$args]
    }
}
proc ca_uninstall_pixel_mock {} {
    catch {rename ::.ca.text {}}
    catch {rename _real_ca_text {}}
}

set ca_signals_common {
    -setup {
        set ::ca_thirsty {}
        set ::ca_culled {}
        set ::mock_above 0
        set ::mock_below 0
        chatarea .ca \
            -thirst-command [list apply {{dir id} {lappend ::ca_thirsty [list $dir $id]}}] \
            -cull-command   [list apply {{dirs} {lappend ::ca_culled $dirs}}]
        pack .ca -fill both -expand yes
        wm geometry . 400x200
        update
        ca_install_pixel_mock
    }
    -cleanup {
        ca_uninstall_pixel_mock
        destroy .ca
        unset -nocomplain ::ca_thirsty ::ca_culled ::mock_above ::mock_below
    }
}

test chatarea-thirsty-fires-per-direction {-thirst-command fires once per thirsty direction with edge id} \
    {*}$ca_signals_common \
    -body {
        # Both directions below load threshold (default 500): each fires once
        # with its own edge id.
        set ::mock_above 100
        set ::mock_below 100
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        .ca DoCleanup
        set ::ca_thirsty
    } -result {{old 100} {new 300}}

test chatarea-cull-fires-with-directions {-cull-command fires with the list of culled directions} \
    {*}$ca_signals_common \
    -body {
        # Pixel mock above above clean threshold; messages get culled until
        # MessageIds drains (mock returns constant high value, so the
        # loop's `[llength $MessageIds] > 0` guard is what stops it).
        set ::mock_above 9999
        set ::mock_below 0
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        .ca DoCleanup
        set ::ca_culled
    } -result {old}

test chatarea-no-thirst-for-just-culled-direction {a direction culled this pass does not also fire thirst} \
    {*}$ca_signals_common \
    -body {
        # Cull old; mock_above stays high so loop drains MessageIds; once
        # empty, the empty-display guard prevents any thirst fire — including
        # the suppressed "old" we just culled. Verifies no {old ...} entry
        # leaks into ::ca_thirsty even when above-pixels look thirsty.
        set ::mock_above 9999
        set ::mock_below 0
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        .ca DoCleanup
        # No "old" entry in thirsty calls; cull happened.
        set hasOld 0
        foreach call $::ca_thirsty {
            if {[lindex $call 0] eq "old"} { set hasOld 1 }
        }
        list culled=$::ca_culled hasOldThirst=$hasOld
    } -result {culled=old hasOldThirst=0}
