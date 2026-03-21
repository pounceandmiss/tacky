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
        server_id "" own_id "" raw_xml ""
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
        # result[0..1] are chronological, result[2] is hollow for cursor
        list [llength $result] \
             [dict get [lindex $result 0] body] \
             [dict get [lindex $result 1] body]
    } -result {3 a b}

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
             [dict get $m1 server_id] [dict get $m1 own_id] \
             [dict get $m1 chat_jid] \
             [expr {[dict get $m1 timestamp] > 0}] \
             [expr {[dict get $m1 raw_xml] ne ""}] \
             [dict get $m2 body] [dict get $m2 server_id]
    } -result {2 {first msg} bob@example.com/phone mam1 {} alice@example.com 1 1 {second msg} mam2}

# -- history: -after at latest skips MAM ----------------------------------------

test message-history-after-at-latest-no-mam {-after at latest message returns empty without MAM} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        set written1 [$::_client conn get_written]
        # -after the latest timestamp — nothing newer exists
        set result [msg_history -chat alice@example.com -after 200 -limit 50]
        set written2 [$::_client conn get_written]
        list [llength $result] \
             [expr {[llength $written1] == [llength $written2]}]
    } -result {0 1}

# -- history: -before with empty local still queries MAM -----------------------

test message-history-before-empty-queries-mam {-before with empty local still queries MAM} \
    {*}$msg_common \
    -body {
        # Store one message as the cursor anchor
        msg_store [list [msg_msg timestamp 500 server_id s1 body anchor]]
        set written1 [$::_client conn get_written]
        # -before 500: no local data before the cursor → should trigger MAM
        tacky message history -acc $acc -chat alice@example.com \
            -before 500 -limit 50 \
            -command [list apply {{r} {}}]
        set written2 [$::_client conn get_written]
        expr {[llength $written2] > [llength $written1]}
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
             [dict get $msg own_id] \
             [dict get $msg chat_jid] \
             [expr {[dict get $msg timestamp] > 0}]
    } -result {sid42 juliet@capulet.li/phone {hello romeo} {} chat@example.com 1}

test message-history-preserves-join {history preserves ?join suffix in chatJid} \
    {*}$msg_common \
    -body {
        msg_sync room@muc.example.com?join
        msg_store [list \
            [msg_msg timestamp 100 chat_jid room@muc.example.com?join server_id s1 body hi]]
        set result [msg_history -chat room@muc.example.com?join -limit 1]
        list [llength $result] [dict get [lindex $result 0] body]
    } -result {1 hi}

test message-parseresultnode-no-own-id {ParseResultNode returns empty own_id} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid1 from bob@example.com body test stamp 2024-01-01T00:00:00Z]
        set msg [$::_client message ParseResultNode $rn bob@example.com]
        dict get $msg own_id
    } -result {}

# -- history: cancel -----------------------------------------------------------

test message-history-cancel-suppresses-callback {cancel tag prevents fetch callback} \
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
        set local [$::_client message messagestore get latest bob@example.com]
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
        set msg [lindex [$::_client message messagestore get latest alice@example.com] 0]
        list [dict get $msg chat_jid] \
             [dict get $msg from_jid] \
             [dict get $msg body] \
             [dict get $msg server_id] \
             [dict get $msg own_id] \
             [expr {[dict get $msg timestamp] > 0}] \
             [expr {[dict get $msg raw_xml] ne ""}]
    } -result {alice@example.com alice@example.com/phone hi srv42 {} 1 1}

test message-live-delayed-uses-stamp {delayed message uses delay timestamp} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "offline msg"
            j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
        }]
        set msg [lindex [$::_client message messagestore get latest alice@example.com] 0]
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
        llength [$::_client message messagestore get latest alice@example.com]
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
        list $got [llength [$::_client message messagestore get latest alice@example.com]]
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
             [dict get $_got -message from_jid] \
             [dict get $_got -message body]
    } -result {alice@example.com alice@example.com/phone {event test}}

test message-live-dup-no-event {duplicate message does not emit <Received>} \
    {*}$msg_common \
    -body {
        set ::_count 0
        tacky listen message <Received> {apply {{ev} {
            incr ::_count
        }}}
        set stanza [j message -type chat -from alice@example.com/phone \
            -id dup-test {
            j body #body "dup test"
            j stanza-id -xmlns urn:xmpp:sid:0 -id sid-dup1
        }]
        $::_client conn feed $stanza
        $::_client conn feed $stanza
        set ::_count
    } -result {1}

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
        set msgs [$::_client message messagestore get latest alice@example.com]
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
        set msgs [$::_client message messagestore get latest bob@example.com]
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
        llength [$::_client message messagestore get latest alice@example.com]
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
        llength [$::_client message messagestore get latest alice@example.com]
    } -result {1}

test message-catchup-dedup-no-ids {catchup deduplicates messages without server/origin IDs (IRC bridges)} \
    {*}$msg_common \
    -body {
        # Pre-store messages without IDs (simulating previous catchup)
        msg_store [list \
            [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
                chat_jid alice@example.com from_jid alice@example.com/phone \
                body "bridge msg" server_id "" own_id ""] \
            [msg_msg timestamp [ParseTimestamp 2024-01-01T11:00:00Z] \
                chat_jid alice@example.com from_jid alice@example.com/phone \
                body "bridge msg 2" server_id "" own_id ""]]
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

# -- history: time-anchored MAM -----------------------------------------------

test message-history-mam-before-timestamp {-before with empty local sends MAM with -end and empty -before} \
    {*}$msg_common \
    -body {
        # Use a known timestamp (2024-06-15T12:00:00Z in microseconds)
        set ts [ParseTimestamp 2024-06-15T12:00:00Z]
        tacky message history -acc $acc -chat alice@example.com \
            -before $ts -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # Should have end field with ISO timestamp
        set endVal [xsearch $qnode x field @var end value -get body]
        # Should have empty before (request from end of archive)
        set beforeVal [xsearch $qnode set before -get body]
        # Should NOT have start field
        set hasStart [expr {[xsearch $qnode x field @var start] ne ""}]
        list [expr {$endVal eq "2024-06-15T12:00:00Z"}] \
             [expr {$beforeVal eq ""}] \
             $hasStart
    } -result {1 1 0}

test message-history-mam-after-timestamp {-after with empty local sends MAM with -start} \
    {*}$msg_common \
    -body {
        set ts [ParseTimestamp 2024-06-15T12:00:00Z]
        # Store a message newer than the cursor so MAM fires (latestTs > after)
        msg_store [list [msg_msg timestamp [expr {$ts + 1000000}] \
            chat_jid alice@example.com server_id s-later body later]]
        tacky message history -acc $acc -chat alice@example.com \
            -after $ts -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # Should have start field with ISO timestamp
        set startVal [xsearch $qnode x field @var start value -get body]
        # Should NOT have end field
        set hasEnd [expr {[xsearch $qnode x field @var end] ne ""}]
        # Should NOT have before (no cursor)
        set hasBefore [expr {[xsearch $qnode set before] ne ""}]
        list [expr {$startVal eq "2024-06-15T12:00:00Z"}] \
             $hasEnd $hasBefore
    } -result {1 0 0}

test message-history-mam-default-cursor {default (no timestamp) uses cursor-based -before} \
    {*}$msg_common \
    -body {
        # Pre-store a message so there's a cursor server_id
        msg_store [list [msg_msg timestamp 100 chat_jid bob@example.com \
            server_id srv99 body old]]
        # Mark as having local data, then clear so MAM triggers
        # Actually: need no local data for the requested chat to trigger MAM
        # Use a different chat that has no local data
        tacky message history -acc $acc -chat carol@example.com -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # Should NOT have start or end fields
        set hasStart [expr {[xsearch $qnode x field @var start] ne ""}]
        set hasEnd [expr {[xsearch $qnode x field @var end] ne ""}]
        list $hasStart $hasEnd
    } -result {0 0}

# -- history: fetch bridges into anchor region ----------------------------------

test message-history-fetch-bridges-before {MAM fetch via -before bridges into anchor region} \
    {*}$msg_common \
    -body {
        # Live message arrives — stored in its own region
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "live msg"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-live
        }]
        set liveTs [dict get \
            [lindex [$::_client message messagestore get latest alice@example.com] 0] \
            timestamp]

        # history -before $liveTs: local returns empty (only message IS the
        # cursor), so MAM fires.  Feed fetch results.
        set ::_result {}
        tacky message history -acc $acc -chat alice@example.com \
            -before $liveTs -limit 50 \
            -command [list apply {{r} { set ::_result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id mam1 queryid $qid \
                from alice@example.com/phone body "old msg 1" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id mam2 queryid $qid \
                from alice@example.com/phone body "old msg 2" \
                stamp 2024-01-01T11:00:00Z]
        }]

        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body mam1
                    j last #body mam2
                }
            }
        }]

        # The callback should see the fetched messages (bridged into
        # the live message's region, so the re-query finds them).
        # result[0..1] are chronological, result[2] is hollow for cursor
        list [llength $::_result] \
             [dict get [lindex $::_result 0] body] \
             [dict get [lindex $::_result 1] body]
    } -result {3 {old msg 1} {old msg 2}}

test message-history-fetch-live-during {live message during fetch ends up in same region} \
    {*}$msg_common \
    -body {
        # Live message arrives — stored in liveRegion
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "live msg"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-live
        }]
        set liveTs [dict get \
            [lindex [$::_client message messagestore get latest alice@example.com] 0] \
            timestamp]

        # history -before triggers MAM
        set ::_result {}
        tacky message history -acc $acc -chat alice@example.com \
            -before $liveTs -limit 50 \
            -command [list apply {{r} { set ::_result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        # Second live message arrives DURING the MAM query
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "live msg 2"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-live2
        }]

        # MAM response arrives
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id mam1 queryid $qid \
                from alice@example.com/phone body "old msg" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body mam1
                    j last #body mam1
                }
            }
        }]

        # All three messages (fetched + both live) should be in one region
        # result includes hollow message for cursor + 1 real message
        set db [$::_client message messagestore cget -db]
        set regions [$db eval {
            SELECT COUNT(DISTINCT region) FROM chat_message
            WHERE chat_jid='alice@example.com'
        }]
        list [llength $::_result] $regions
    } -result {2 1}

test message-history-fetch-live-after {live message after fetch lands in same region} \
    {*}$msg_common \
    -body {
        # Live message arrives
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "live msg"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-live
        }]
        set liveTs [dict get \
            [lindex [$::_client message messagestore get latest alice@example.com] 0] \
            timestamp]

        # Backfill via -before
        set ::_result {}
        tacky message history -acc $acc -chat alice@example.com \
            -before $liveTs -limit 50 \
            -command [list apply {{r} { set ::_result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id mam1 queryid $qid \
                from alice@example.com/phone body "old msg" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body mam1
                    j last #body mam1
                }
            }
        }]

        # NEW live message arrives AFTER fetch completes
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "live msg 2"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-live2
        }]

        # GetLatest should see all 3 messages in one region
        set all [$::_client message messagestore get latest alice@example.com]
        set db [$::_client message messagestore cget -db]
        set regions [$db eval {
            SELECT COUNT(DISTINCT region) FROM chat_message
            WHERE chat_jid='alice@example.com'
        }]
        list [llength $all] $regions
    } -result {3 1}

# -- goto ----------------------------------------------------------------------

# Helper: call goto and collect result via -command
proc msg_goto {args} {
    set ::_msg_goto_result {}
    tacky message goto -acc $::acc {*}$args \
        -command [list apply {{result} { set ::_msg_goto_result $result }}]
    set ::_msg_goto_result
}

test message-goto-local {goto -source local returns getAround result with anchor} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 body a] \
            [msg_msg timestamp 200 body b] \
            [msg_msg timestamp 300 body c] \
            [msg_msg timestamp 400 body d] \
            [msg_msg timestamp 500 body e]]
        set written1 [$::_client conn get_written]
        set result [msg_goto -chat alice@example.com -date 300 -source local -limit 4]
        set written2 [$::_client conn get_written]
        set msgs [dict get $result messages]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 2] body] \
             [dict get [lindex $msgs end] body] \
             [dict get $result anchor] \
             [expr {[llength $written1] == [llength $written2]}]
    } -result {5 a c e 300 1}

test message-goto-remote {goto -source remote fetches MAM then returns getAround} \
    {*}$msg_common \
    -body {
        set result {}
        tacky message goto -acc $acc -chat alice@example.com \
            -date [ParseTimestamp 2024-06-15T12:00:00Z] \
            -source remote -limit 50 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "remote msg" \
                stamp 2024-06-15T12:00:00Z]
        }]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body sid1
                    j last #body sid1
                }
            }
        }]

        set msgs [dict get $result messages]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [expr {[dict get $result anchor] ne ""}]
    } -result {1 {remote msg} 1}

test message-goto-remote-error-falls-back {goto -source remote falls back to local on MAM error} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg timestamp 100 body local-only]]
        set result {}
        tacky message goto -acc $acc -chat alice@example.com \
            -date 100 -source remote -limit 50 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        $::_client iq feed [j iq -type error -id $iqId {
            j error -type cancel { j feature-not-implemented }
        }]

        set msgs [dict get $result messages]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 local-only}

# -- prev on live messages -----------------------------------------------------

test message-live-prev-first {first live message has empty prev} \
    {*}$msg_common \
    -body {
        set ::_got {}
        tacky listen message <Received> {apply {{ev} {
            set ::_got $ev
        }}}
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "first"
        }]
        dict get [dict get $_got -message] prev
    } -result {}

test message-live-prev-chain {second live message prev points to first} \
    {*}$msg_common \
    -body {
        set ::_events {}
        tacky listen message <Received> {apply {{ev} {
            lappend ::_events $ev
        }}}
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "first"
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "second"
        }]
        set msg1 [dict get [lindex $::_events 0] -message]
        set msg2 [dict get [lindex $::_events 1] -message]
        expr {[dict get $msg2 prev] == [dict get $msg1 timestamp]}
    } -result {1}

test message-sent-prev {sent message has prev in event} \
    {*}$msg_common \
    -body {
        # Pre-store a message so send has a predecessor
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "incoming"
        }]
        set ::_got {}
        tacky listen message <Sent> {apply {{ev} {
            set ::_got $ev
        }}}
        tacky message send -acc $acc -chat_jid alice@example.com -body "reply"
        set msg [dict get $_got -message]
        # prev should point to the incoming message's timestamp
        set stored [$::_client message messagestore get latest alice@example.com]
        set incomingTs [dict get [lindex $stored 0] timestamp]
        expr {[dict get $msg prev] == $incomingTs}
    } -result {1}

# -- send then receive ordering ------------------------------------------------

test message-send-uses-outgoing-region {sent message uses outgoing region, incoming uses liveRegion} \
    {*}$msg_common \
    -body {
        tacky message send -acc $acc -chat_jid alice@example.com -body "outgoing"
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "incoming"
        }]
        set db [$::_client message messagestore cget -db]
        set sentRegion [$db onecolumn {
            SELECT region FROM chat_message
            WHERE chat_jid='alice@example.com' AND own_id != ''
        }]
        set recvRegion [$db onecolumn {
            SELECT region FROM chat_message
            WHERE chat_jid='alice@example.com' AND own_id = ''
        }]
        list [expr {$sentRegion == -1}] [expr {$recvRegion > 0}]
    } -result {1 1}

test message-send-then-receive-prev-chain {incoming after send has prev pointing to sent message} \
    {*}$msg_common \
    -body {
        set ::_sent {}
        set ::_recv {}
        tacky listen message <Sent> {apply {{ev} { set ::_sent $ev }}}
        tacky listen message <Received> {apply {{ev} { set ::_recv $ev }}}
        # Send
        tacky message send -acc $acc -chat_jid alice@example.com -body "outgoing"
        set sentTs [dict get [dict get $_sent -message] timestamp]
        # Receive
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "incoming"
        }]
        set recvMsg [dict get $_recv -message]
        # Incoming message's prev should point to our sent message
        expr {[dict get $recvMsg prev] == $sentTs}
    } -result {1}

test message-send-then-receive-earlier-ts {incoming with earlier timestamp inserts before sent} \
    {*}$msg_common \
    -body {
        # Send a message — gets a clock microseconds timestamp
        tacky message send -acc $acc -chat_jid alice@example.com -body "outgoing"
        set sentTs [dict get \
            [lindex [$::_client message messagestore get latest alice@example.com] 0] \
            timestamp]
        # Incoming message with delay stamp placing it 1 second before our send
        set earlyTs [expr {$sentTs - 1000000}]
        set earlyStamp [FormatTimestampISO $earlyTs]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "earlier"
            j delay -ns urn:xmpp:delay -stamp $earlyStamp
        }]
        # Both messages should be in DB
        set all [$::_client message messagestore get latest alice@example.com]
        # Chronological order: earlier first, then our sent
        list [llength $all] \
             [dict get [lindex $all 0] body] \
             [dict get [lindex $all 1] body] \
             [expr {[dict get [lindex $all 1] prev] == [dict get [lindex $all 0] timestamp]}]
    } -result {2 earlier outgoing 1}

test message-send-then-receive-earlier-ts-event-prev {Received event for earlier msg has correct prev} \
    {*}$msg_common \
    -body {
        set ::_recv {}
        tacky listen message <Received> {apply {{ev} { set ::_recv $ev }}}
        # Send a message
        tacky message send -acc $acc -chat_jid alice@example.com -body "outgoing"
        set sentTs [dict get \
            [lindex [$::_client message messagestore get latest alice@example.com] 0] \
            timestamp]
        # Incoming with timestamp before our send
        set earlyTs [expr {$sentTs - 1000000}]
        set earlyStamp [FormatTimestampISO $earlyTs]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "earlier"
            j delay -ns urn:xmpp:delay -stamp $earlyStamp
        }]
        set recvMsg [dict get $_recv -message]
        # The earlier message's prev should be empty (nothing before it)
        dict get $recvMsg prev
    } -result {}

# -- outgoing region cross-region queries ---------------------------------------

test message-send-prev-crosses-region {sent message prev crosses into prior real region} \
    {*}$msg_common \
    -body {
        # Store history in a real region
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        set ::_got {}
        tacky listen message <Sent> {apply {{ev} { set ::_got $ev }}}
        tacky message send -acc $acc -chat_jid alice@example.com -body "reply"
        set msg [dict get $_got -message]
        # prev should point to message b (ts=200), even though it's in a
        # different region
        expr {[dict get $msg prev] == 200}
    } -result {1}

test message-get-latest-outgoing-plus-real {get latest returns real region + outgoing mixed} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        tacky message send -acc $acc -chat_jid alice@example.com -body "sent"
        set all [$::_client message messagestore get latest alice@example.com]
        list [llength $all] \
             [dict get [lindex $all 0] body] \
             [dict get [lindex $all 1] body] \
             [dict get [lindex $all 2] body]
    } -result {3 a b sent}

test message-get-before-from-outgoing-cursor {get before from outgoing cursor finds real region} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        tacky message send -acc $acc -chat_jid alice@example.com -body "sent"
        set latest [$::_client message messagestore get latest alice@example.com]
        set sentTs [dict get [lindex $latest end] timestamp]
        set before [$::_client message messagestore get before alice@example.com $sentTs]
        list [llength $before] \
             [dict get [lindex $before 0] body] \
             [dict get [lindex $before 1] body]
    } -result {2 a b}

# -- hollow messages in backward pagination ------------------------------------

test message-history-before-hollow {backward pagination prepends hollow message} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b] \
            [msg_msg timestamp 300 server_id s3 body c]]
        set result [msg_history -chat alice@example.com -before 300]
        # Last entry should be hollow: timestamp=300 (cursor), prev=200 (last real msg)
        set real1 [lindex $result 0]
        set real2 [lindex $result 1]
        set hollow [lindex $result 2]
        list [dict get $hollow timestamp] \
             [dict get $hollow prev] \
             [dict get $hollow hollow] \
             [dict get $real1 body] \
             [dict get $real2 body]
    } -result {300 200 1 a b}

test message-history-after-no-hollow {forward pagination has no hollow message} \
    {*}$msg_common \
    -body {
        msg_sync alice@example.com
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b] \
            [msg_msg timestamp 300 server_id s3 body c]]
        set result [msg_history -chat alice@example.com -after 100]
        # All entries should be real messages (have body)
        set allHaveBody 1
        foreach msg $result {
            if {![dict exists $msg body]} { set allHaveBody 0 }
        }
        list [llength $result] $allHaveBody
    } -result {2 1}

test message-history-before-empty-no-hollow {backward pagination with no results has no hollow} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg timestamp 100 server_id s1 body only]]
        set result [msg_history -chat alice@example.com -before 100]
        llength $result
    } -result {0}

# -- search --------------------------------------------------------------------

# Helper: prime MAM fulltext field cache (avoids formfields discovery IQ in search tests)
proc msg_prime_search {{chatJid alice@example.com}} {
    if {[regexp {(.*)\?join$} $chatJid -> mucjid]} {
        $::_client mam discoverFields -to $mucjid
    } else {
        $::_client mam discoverFields
    }
    set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
    $::_client iq feed [j iq -type result -id $iqId {
        j query -ns urn:xmpp:mam:2 {
            j x -ns jabber:x:data -type form {
                j field -var FORM_TYPE -type hidden {
                    j value #body urn:xmpp:mam:2
                }
                j field -var with
                j field -var start
                j field -var end
                j field -var withtext
            }
        }
    }]
}

# Helper: call search and collect result via -command
proc msg_search {args} {
    set ::_msg_search_result {}
    tacky message search -acc $::acc {*}$args \
        -command [list apply {{result} { set ::_msg_search_result $result }}]
    set ::_msg_search_result
}

test message-search-sends-mam-fulltext {search sends MAM query with fulltext field} \
    {*}$msg_common \
    -body {
        msg_prime_search
        tacky message search -acc $acc -chat alice@example.com \
            -query "hello world" -limit 10 \
            -command [list apply {{r} {}}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # Should have withtext field with query text
        set ftVal [xsearch $qnode x field @var withtext value -get body]
        # Should have empty before (newest-first default)
        set beforeVal [xsearch $qnode set before -get body]
        list [expr {$ftVal eq "hello world"}] \
             [expr {$beforeVal eq ""}]
    } -result {1 1}

test message-search-results-parsed-and-stored {search results parsed and stored in DB} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" -limit 10 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "found it" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid2 queryid $qid \
                from alice@example.com/phone body "found another" \
                stamp 2024-06-15T12:00:00Z]
        }]

        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete false {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body sid1
                    j last #body sid2
                }
            }
        }]

        set msgs [dict get $result messages]
        set db [$::_client message messagestore cget -db]
        set dbCount [$db eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 0] server_id] \
             [dict get [lindex $msgs 1] body] \
             [dict get $result complete] \
             [dict get $result last] \
             $dbCount
    } -result {2 {found it} sid1 {found another} 0 sid2 2}

test message-search-results-separate-regions {search results stored in separate regions} \
    {*}$msg_common \
    -body {
        msg_prime_search
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" -limit 10 \
            -command [list apply {{r} {}}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "msg one" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid2 queryid $qid \
                from alice@example.com/phone body "msg two" \
                stamp 2024-06-15T12:00:00Z]
        }]

        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body sid1
                    j last #body sid2
                }
            }
        }]

        set db [$::_client message messagestore cget -db]
        $db eval {SELECT COUNT(DISTINCT region) FROM chat_message WHERE chat_jid='alice@example.com'}
    } -result {2}

test message-search-pagination-before {search with -before sends RSM before element} \
    {*}$msg_common \
    -body {
        msg_prime_search
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" -before "page-cursor-id" -limit 10 \
            -command [list apply {{r} {}}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        set beforeVal [xsearch $qnode set before -get body]
        expr {$beforeVal eq "page-cursor-id"}
    } -result {1}

test message-search-cancel-suppresses-callback {cancel tag prevents search callback} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set ::result UNTOUCHED
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" -tag searchtag \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        # Cancel before MAM response arrives
        tacky message cancel -acc $acc -tag searchtag

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "found" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body sid1
                    j last #body sid1
                }
            }
        }]

        set ::result
    } -result UNTOUCHED

test message-search-error-returns-error-dict {search error returns error dict} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        $::_client iq feed [j iq -type error -id $iqId {
            j error -type cancel { j feature-not-implemented }
        }]

        list [dict get $result error] \
             [dict get $result messages] \
             [dict get $result complete]
    } -result {1 {} 0}

# -- 1:1 self-echo (carbon/reflection) -----------------------------------------

test message-self-echo-confirms {1:1 self-echo confirms pending, emits Patch not Received} \
    {*}$msg_common \
    -body {
        # Send a 1:1 message (stores as pending with own_id)
        tacky message send -acc $acc -chat_jid alice@example.com -body "echo me"
        set msgs [$::_client message messagestore get latest alice@example.com]
        set oid [dict get [lindex $msgs 0] own_id]

        set patches {}
        set received {}
        tacky listen -tag selfecho message <Patch> -jid alice@example.com \
            {apply {{ev} { lappend ::patches $ev }}}
        tacky listen -tag selfecho message <Received> -jid alice@example.com \
            {apply {{ev} { lappend ::received $ev }}}

        # Server reflects the message back: from=self, to=contact, same @id
        $::_client conn feed [j message -type chat \
            -from user@test.example.com/res \
            -to alice@example.com \
            -id $oid {
            j body #body "echo me"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-echo1
        }]

        tacky unlisten selfecho

        # DB should have exactly one row, now confirmed
        set dbRows [$::_client db eval {
            SELECT count(*) FROM chat_message
            WHERE chat_jid='alice@example.com'
        }]
        set status [$::_client db onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='alice@example.com'
        }]
        list $dbRows $status [llength $patches] [llength $received] \
             [dict get [lindex $patches 0] -message server_status]
    } -result {1 received 1 0 received}

test message-search-skips-empty-body {search skips results with empty body} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "test" \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        # Feed one result with empty body and one with content
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid2 queryid $qid \
                from alice@example.com/phone body "has content" \
                stamp 2024-01-01T11:00:00Z]
        }]

        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body sid1
                    j last #body sid2
                }
            }
        }]

        set msgs [dict get $result messages]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {has content}}
