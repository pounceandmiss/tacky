# Unit tests for taco_message
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

set msg_common [tacky_env -mock conn -account $acc]

# Helper: build a message dict
proc msg_msg {args} {
    set defaults {
        timestamp 1000000 chat_jid alice@example.com
        from_jid alice@example.com/phone body hello
        server_id "" own_id "" raw_xml ""
    }
    return [dict merge $defaults $args]
}

# Helper: store messages directly via the message module's messagestore
proc msg_store {msgs} {
    $::_client message messagestore store $msgs
}

# Helper: unwrap {messages bounded} from get
proc msg_store_latest {jid args} {
    dict get [$::_client message messagestore get latest $jid {*}$args] messages
}

# Helper: call history and collect result via -command
proc msg_history {args} {
    set ::_msg_hist_result {}
    tacky message history -acc $::acc {*}$args \
        -command [list apply {{result} { set ::_msg_hist_result $result }}]
    set ::_msg_hist_result
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

# Helper: number of MAM query IQs written so far (the fill loop issues one
# per page, so this counts how many archive pages were requested).
proc mam_iq_count {} {
    set n 0
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""} { incr n }
    }
    return $n
}

# Helper: respond to the most recently written MAM query IQ. `specs` is a
# list of dicts, each passed to `mam_result` (with the live queryid filled
# in) to build a <result>; then a <fin> closes the page. RSM first/last
# default to the edge result ids; override via -first/-last for a page with
# no results (so the fill loop still has a cursor to advance from).
proc msg_mam_respond {specs args} {
    set opts [dict merge {-complete true -first "" -last ""} $args]
    set iqStanza ""
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""} { set iqStanza $stanza }
    }
    set iqId [dict get $iqStanza attrs id]
    set qid [xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid]
    set ids {}
    foreach spec $specs {
        set rn [mam_result {*}[dict merge $spec [list queryid $qid]]]
        lappend ids [xsearch $rn -get @id]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is $rn
        }]
    }
    set first [dict get $opts -first]
    set last [dict get $opts -last]
    if {$first eq "" && [llength $ids] > 0} {
        set first [lindex $ids 0]
        set last [lindex $ids end]
    }
    $::_client iq feed [j iq -type result -id $iqId {
        j fin -ns urn:xmpp:mam:2 -complete [dict get $opts -complete] {
            j set -ns http://jabber.org/protocol/rsm {
                if {$first ne ""} {
                    j first #body $first
                    j last #body $last
                }
            }
        }
    }]
}

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

# Helper: call goto and collect result via -command
proc msg_goto {args} {
    set ::_msg_goto_result {}
    tacky message goto -acc $::acc {*}$args \
        -command [list apply {{result} { set ::_msg_goto_result $result }}]
    set ::_msg_goto_result
}

# Helper: call search and collect result via -command
proc msg_search {args} {
    set ::_msg_search_result {}
    tacky message search -acc $::acc {*}$args \
        -command [list apply {{result} { set ::_msg_search_result $result }}]
    set ::_msg_search_result
}

# =============================================================================
# ParseResultNode
# =============================================================================

test message-parseresultnode-basic {ParseResultNode extracts all fields} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid42 from juliet@capulet.li/phone \
                    body "hello romeo" stamp 2024-06-15T12:30:00Z origin_id oid99]
        set msg [dict get [$::_client message ParseResultNode $rn chat@example.com] msg]
        list [dict get $msg server_id] \
             [dict get $msg from_jid] \
             [dict get $msg body] \
             [dict get $msg own_id] \
             [dict get $msg chat_jid] \
             [expr {[dict get $msg timestamp] > 0}]
    } -result {sid42 juliet@capulet.li {hello romeo} {} chat@example.com 1}

test message-parseresultnode-keeps-muc-resource {ParseResultNode keeps resource on MUC chats (resource is the nick)} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid7 from room@muc.example.com/alice \
                    body "hi all" stamp 2024-06-15T12:30:00Z]
        set msg [dict get [$::_client message ParseResultNode $rn room@muc.example.com?join] msg]
        dict get $msg from_jid
    } -result {room@muc.example.com/alice}

test message-parseresultnode-keeps-muc-pm-resource {ParseResultNode keeps resource on MUC PM chats} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid8 from room@muc.example.com/alice \
                    body "psst" stamp 2024-06-15T12:30:00Z]
        set msg [dict get [$::_client message ParseResultNode $rn room@muc.example.com/alice] msg]
        dict get $msg from_jid
    } -result {room@muc.example.com/alice}

test message-parseresultnode-1to1-captures-from-resource {1:1 from_resource captures the sending client tag} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid9 from juliet@capulet.li/phone \
                    body "hi" stamp 2024-06-15T12:30:00Z]
        set msg [dict get [$::_client message ParseResultNode $rn juliet@capulet.li] msg]
        dict get $msg from_resource
    } -result {phone}

test message-parseresultnode-muc-empty-from-resource {MUC from_resource is empty (nick already lives in from_jid)} \
    {*}$msg_common \
    -body {
        set rn [mam_result id sid10 from room@muc.example.com/alice \
                    body "hi" stamp 2024-06-15T12:30:00Z]
        set msg [dict get [$::_client message ParseResultNode $rn room@muc.example.com?join] msg]
        dict get $msg from_resource
    } -result {}

# =============================================================================
# Live message receiving
# =============================================================================

test message-live-fields {stored live message has correct fields} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id orig7 -from alice@example.com/phone {
            j body #body hi
            j stanza-id -ns urn:xmpp:sid:0 -id srv42
        }]
        set msg [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $msg chat_jid] \
             [dict get $msg from_jid] \
             [dict get $msg body] \
             [dict get $msg server_id] \
             [dict get $msg own_id] \
             [expr {[dict get $msg timestamp] > 0}] \
             [expr {[dict get $msg raw_xml] ne ""}]
    } -result {alice@example.com alice@example.com hi srv42 {} 1 1}

test message-live-delayed-uses-stamp {delayed message uses delay timestamp} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "offline msg"
            j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
        }]
        set msg [lindex [msg_store_latest alice@example.com] 0]
        set expected [ParseTimestamp 2024-06-15T12:00:00Z]
        expr {[dict get $msg timestamp] == $expected}
    } -result {1}

test message-live-no-body-ignored {message without body is not stored} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j active -ns http://jabber.org/protocol/chatstates
        }]
        llength [msg_store_latest alice@example.com]
    } -result {0}

test message-live-pubsub-not-stored {PubSub messages are dispatched, not stored} \
    {*}$msg_common \
    -body {
        set got 0
        $::_client pubsub handler urn:xmpp:avatar:metadata \
            [list apply {{stanza} { set ::got 1 }}]
        $::_client conn feed [j message -from alice@example.com {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node urn:xmpp:avatar:metadata
            }
        }]
        list $got [llength [msg_store_latest alice@example.com]]
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
            WHERE chat_jid='alice@example.com' AND kind='message'
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
            WHERE chat_jid='alice@example.com' AND kind='message'
        } row {
            set sid $row(server_id)
            set ts  $row(timestamp)
            set xml $row(raw_xml)
        }
        list [expr {$sid eq "archive-uuid-42"}] \
             [expr {$sid ne $ts}] \
             [string match {*<message*} $xml]
    } -result {1 1 1}

test message-live-emits-event {incoming message emits message <New>} \
    {*}$msg_common \
    -body {
        set ::_got {}
        tacky listen message <New> {apply {{ev} {
            set ::_got $ev
        }}}
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "event test"
        }]
        list [dict get $_got -jid] \
             [dict get $_got -message from_jid] \
             [dict get $_got -message body]
    } -result {alice@example.com alice@example.com {event test}}

test message-live-dup-no-event {duplicate message does not emit <New>} \
    {*}$msg_common \
    -body {
        set ::_count 0
        tacky listen message <New> {apply {{ev} {
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

# =============================================================================
# Send (outgoing -> pending -> confirmed)
# =============================================================================

test message-send-stored-as-pending {sent message stored with empty server_id and pending status} \
    {*}$msg_common \
    -body {
        # Plaintext-path test — OMEMO defaults on, so disable it here.
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "outgoing"
        set msg [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $msg server_id] \
             [dict get $msg server_status] \
             [expr {[dict get $msg own_id] ne ""}]
    } -result {{} pending 1}

# The message row dict carries `encryption` (intent) and `fail_reason`
# (why a send failed) so the GUI can tell "couldn't encrypt" from a
# delivery failure and render the right resend affordance. fail_reason
# is distinct from encryption — outcome vs intent.
test message-row-exposes-encryption-and-failreason \
    {get row dicts include the encryption stamp and fail_reason} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg chat_jid alice@example.com body clear own_id o1 \
                encryption "" fail_reason ""] \
            [msg_msg chat_jid alice@example.com body secret own_id o2 \
                encryption omemo server_status failed fail_reason encrypt]]
        set rows [msg_store_latest alice@example.com]
        set r0 [lindex $rows 0]
        set r1 [lindex $rows 1]
        list \
            [dict get $r0 encryption] [dict get $r0 fail_reason] \
            [dict get $r1 encryption] [dict get $r1 fail_reason]
    } -result {{} {} omemo encrypt}

# Incoming encryption stamp: ParseMessage reads the EME marker (XEP-0380)
# the decrypt path leaves on decrypted messages, so peer OMEMO messages
# carry encryption='omemo' (lock shows on their side too). Plaintext
# incoming has no marker -> ''.
test message-incoming-eme-stamps-encryption \
    {ParseMessage derives encryption='omemo' from the EME marker} \
    {*}$msg_common \
    -body {
        set omemoNode [j message -from alice@example.com/x -type chat {
            j body #body "secret"
            j encryption -ns urn:xmpp:eme:0 \
                -namespace eu.siacs.conversations.axolotl -name OMEMO
        }]
        set plainNode [j message -from alice@example.com/x -type chat {
            j body #body "hi there"
        }]
        set m1 [$::_client message ParseMessage $omemoNode \
            -chat_jid alice@example.com -timestamp 1000 -server_id ""]
        set m2 [$::_client message ParseMessage $plainNode \
            -chat_jid alice@example.com -timestamp 1001 -server_id ""]
        list omemo [dict get $m1 encryption] plain [dict get $m2 encryption]
    } -result {omemo omemo plain {}}

# raw_xml stores the readable form, never ciphertext: for OMEMO that's
# the real body + EME marker (the wire stanza, with <encrypted>, is
# separate); for plaintext just the body.
test message-readable-form-not-ciphertext \
    {readable mode yields body (+EME for omemo), never <encrypted>} \
    {*}$msg_common \
    -body {
        set om [$::_client message BuildMessageStanza readable bob@example.com \
            "secret text" o1 chat bob@example.com omemo]
        set pl [$::_client message BuildMessageStanza readable bob@example.com \
            "hi there" o2 chat bob@example.com ""]
        list \
            om_body [xsearch $om body -get body] \
            om_eme [xsearch $om encryption -ns urn:xmpp:eme:0 -get @namespace] \
            om_noct [llength [xsearch $om encrypted]] \
            pl_body [xsearch $pl body -get body] \
            pl_noeme [llength [xsearch $pl encryption]]
    } -result {om_body {secret text} om_eme eu.siacs.conversations.axolotl om_noct 0 pl_body {hi there} pl_noeme 0}

# Self-echo dedup: our own message coming back (self-chat, carbon, MAM)
# carries the @id we set on send, so ExtractEnvelopeIds derives own_id
# from it (for stanzas from our own bare JID) and messagestore dedups
# against the sent row instead of showing a duplicate. Keyed on @id, not
# <origin-id>.
test message-extractenvelopeids-ownid-from-id-when-from-self \
    {ExtractEnvelopeIds sets own_id from @id for our own stanzas, '' for peers} \
    {*}$msg_common -body {
        set mine [j message -from $acc/phone -to bob@example.com -type chat \
                -id uuid-mine { j body #body "from my phone" }]
        set peer [j message -from bob@example.com/x -to $acc -type chat \
                -id peer-id { j body #body "from bob" }]
        lassign [$::_client message ExtractEnvelopeIds $mine bob@example.com] \
            _s1 own1 _o1
        lassign [$::_client message ExtractEnvelopeIds $peer bob@example.com] \
            _s2 own2 _o2
        list mine $own1 peer $own2
    } -result {mine uuid-mine peer {}}

test message-self-echo-dedups-not-duplicate \
    {an echo of our own message (same @id) confirms the sent row, no new row} \
    {*}$msg_common -body {
        # The row we stored on send (pending, on the wire).
        msg_store [list [msg_msg chat_jid bob@example.com body "hello" \
            from_jid $acc own_id uuid-7 server_status pending \
            on_wire 1]]
        # The echo comes back from our own jid (carbon / MAM) with same @id
        # and a server stanza-id; ExtractEnvelopeIds derives own_id from @id,
        # which ParseMessage carries through.
        set echo [j message -from $acc/phone -to bob@example.com -type chat \
                -id uuid-7 {
            j body #body "hello"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-99
        }]
        lassign [$::_client message ExtractEnvelopeIds $echo bob@example.com] \
            sid ownId originId
        set m [$::_client message ParseMessage $echo \
            -chat_jid bob@example.com -timestamp 2000 \
            -server_id $sid -own_id $ownId -origin_id $originId]
        set res [$::_client message messagestore store [list $m]]
        set rows [msg_store_latest bob@example.com]
        list nrows [llength $rows] \
            inserted [llength [dict get $res inserted]] \
            confirmed [llength [dict get $res confirmed]] \
            status [dict get [lindex $rows 0] server_status]
    } -result {nrows 1 inserted 0 confirmed 1 status {}}

# resend: user-driven retry. Default honors the row's stamped
# encryption; -plaintext downgrades (the only path that may).

test message-resend-plaintext-downgrades \
    {resend -plaintext rewrites the stamp to '' and sends cleartext} \
    {*}$msg_common \
    -body {
        # Synthetic stuck OMEMO message: stamped omemo, never wire-built.
        msg_store [list [msg_msg chat_jid alice@example.com body "secret" \
            from_jid $acc own_id oid-pt server_status pending \
            encryption omemo on_wire 0]]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        set before [llength [$::_client conn get_written]]
        tacky message resend -acc $acc -chat alice@example.com \
            -timestamp $ts -plaintext 1
        set last [lindex [$::_client conn get_written] end]
        set db [$::_client message messagestore cget -db]
        set enc [$db onecolumn {
            SELECT encryption FROM chat_message WHERE timestamp=$ts}]
        list enc $enc \
            has_body [expr {[llength [xsearch $last body]] > 0}] \
            has_enc [expr {[llength [xsearch $last encrypted]] > 0}] \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {enc {} has_body 1 has_enc 0 wrote 1}

test message-resend-honors-stamp \
    {plain resend re-attempts OMEMO (no silent downgrade)} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "secret" \
            from_jid $acc own_id oid-st server_status pending \
            encryption omemo on_wire 0]]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        set before [llength [$::_client conn get_written]]
        tacky message resend -acc $acc -chat alice@example.com \
            -timestamp $ts
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, encryption FROM chat_message
            WHERE timestamp=$ts} row {}
        # Store is uninitialised here (no OnReady), so encrypt is
        # NOT_READY: the row stays pending, NOT downgraded to plaintext
        # (encryption still 'omemo', nothing written to the wire).
        list status $row(server_status) enc $row(encryption) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending enc omemo wrote 0}

# Fail-closed against a dropped stamp: if the in-flight retry dict loses
# its `encryption` field (e.g. crossing a thread/process bridge) the
# stored row is still authoritative. A row stamped omemo must stay omemo
# and fail closed (NOT_READY here, store uninit) rather than going out in
# cleartext - the downgrade we observed in the wild.
test message-retrysend-missing-stamp-no-downgrade \
    {RetrySend reads the omemo stamp from the DB when the dict drops it} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "secret" \
            from_jid $acc own_id oid-drop server_status pending \
            encryption omemo on_wire 0]]
        set before [llength [$::_client conn get_written]]
        # Dict deliberately omits `encryption` - the bridge-drop case.
        $::_client message RetrySend [dict create \
            chat_jid alice@example.com body "secret" own_id oid-drop]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, encryption, on_wire FROM chat_message
            WHERE own_id='oid-drop'} row {}
        list status $row(server_status) enc $row(encryption) \
            on_wire $row(on_wire) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending enc omemo on_wire 0 wrote 0}

# OnOmemoSelfReady (fired when omemo's store + own devicelist are ready)
# must retry only OMEMO sends that never reached the wire, never a row
# already on the wire awaiting ack - re-sending those would duplicate.
test message-omemo-selfready-skips-on-wire \
    {OnOmemoSelfReady leaves on-wire rows alone (no double-send)} \
    {*}$msg_common \
    -body {
        # Plaintext row already written (on_wire), awaiting ack.
        msg_store [list [msg_msg chat_jid alice@example.com body clear \
            from_jid $acc own_id o-clear server_status pending \
            encryption "" on_wire 1]]
        # OMEMO row that never reached the wire (encrypt NOT_READY).
        msg_store [list [msg_msg chat_jid bob@example.com body secret \
            from_jid $acc own_id o-omemo server_status pending \
            encryption omemo on_wire 0]]
        set before [llength [$::_client conn get_written]]
        $::_client message OnOmemoSelfReady
        # On-wire plaintext row not re-sent; the omemo row retries but
        # NOT_READYs (store uninit), so the wire count is unchanged.
        expr {[llength [$::_client conn get_written]] - $before}
    } -result {0}

# A re-delivered own message with no displayable body (OMEMO keytransport
# or a dropped EKEYGONE/EUSER duplicate) must still confirm a pending send
# from its envelope - otherwise the send stays pending and gets re-sent.
test message-catchup-displayless-confirms-send \
    {displayless own re-delivery in catchup confirms the pending send} \
    {*}$msg_common \
    -body {
        # Pending OMEMO send, already on the wire, awaiting confirmation.
        msg_store [list [msg_msg chat_jid alice@example.com body "secret" \
            from_jid $acc own_id oid-conf server_status pending \
            encryption omemo on_wire 1]]
        # Our own message comes back via catchup but carries no body.
        set rn [mam_result id arch-1 from $acc to alice@example.com \
            origin_id oid-conf body ""]
        $::_client message OnCatchup [dict create messages [list $rn] complete 1]
        # Confirmed in place (no duplicate inserted, original body intact).
        set rows [msg_store_latest alice@example.com]
        list nrows [llength $rows] \
            status [dict get [lindex $rows 0] server_status] \
            body [dict get [lindex $rows 0] body]
    } -result {nrows 1 status {} body secret}

# =============================================================================
# Envelope-first dedup: messagestore reconcile
# =============================================================================

# A pending send echoed back by the archive is confirmed on its envelope
# alone: flipped to received, server_id captured, timestamp relocated to
# the server value - no decrypt, no duplicate row.
test message-reconcile-confirms-pending \
    {reconcile flips a pending send by own_id, captures server_id, relocates ts} \
    {*}$msg_common -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "hi" \
            from_jid $acc own_id oid-r1 server_status pending \
            encryption omemo on_wire 1 timestamp 1000000]]
        set v [$::_client message messagestore reconcile \
            alice@example.com srv-r1 oid-r1 oid-r1 5000000]
        set rows [msg_store_latest alice@example.com]
        list verdict [dict get $v verdict] \
            nrows [llength $rows] \
            status [dict get [lindex $rows 0] server_status] \
            sid [dict get [lindex $rows 0] server_id] \
            ts [dict get [lindex $rows 0] timestamp]
    } -result {verdict confirmed nrows 1 status {} sid srv-r1 ts 5000000}

# A match against a row we already hold (not pending) is a duplicate: drop
# it, never decrypt.
test message-reconcile-duplicate-on-citizen \
    {reconcile reports duplicate for a non-pending row} \
    {*}$msg_common -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "hi" \
            from_jid bob@example.com/x server_id srv-r2 server_status ""]]
        dict get [$::_client message messagestore reconcile \
            alice@example.com srv-r2 "" "" 5000000] verdict
    } -result {duplicate}

test message-reconcile-new-when-no-match \
    {reconcile reports new when no id matches} \
    {*}$msg_common -body {
        dict get [$::_client message messagestore reconcile \
            alice@example.com srv-missing "" "" 5000000] verdict
    } -result {new}

# An id-less stanza always falls through to new; store's content-based
# dedup is the backstop for those (IRC-bridge messages etc.).
test message-reconcile-new-when-idless \
    {reconcile reports new for an id-less stanza} \
    {*}$msg_common -body {
        dict get [$::_client message messagestore reconcile \
            alice@example.com "" "" "" 5000000] verdict
    } -result {new}

# A duplicate own re-delivery in catchup is dropped on its envelope without
# being re-decrypted (the case that used to produce EKEYGONE noise): the
# row stays put, no second copy.
test message-catchup-duplicate-own-no-redecrypt \
    {a re-delivered own message already received is dropped, not re-stored} \
    {*}$msg_common -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "secret" \
            from_jid $acc own_id oid-dup server_id arch-9 \
            server_status "" encryption omemo on_wire 1]]
        set rn [mam_result id arch-9 from $acc to alice@example.com \
            origin_id oid-dup body ""]
        $::_client message OnCatchup [dict create messages [list $rn] complete 1]
        set rows [msg_store_latest alice@example.com]
        list nrows [llength $rows] \
            body [dict get [lindex $rows 0] body]
    } -result {nrows 1 body secret}

# =============================================================================
# Displayless classification (ParseMessage returns "" for control stanzas)
# =============================================================================

test message-classify-receipt {a receipt is recognised and parses to nothing} \
    {*}$msg_common -body {
        set n [j message -from bob@example.com/x -type chat {
            j received -ns urn:xmpp:receipts -id abc
        }]
        list [ClassifyMessage $n ""] \
            [$::_client message ParseMessage $n \
                -chat_jid bob@example.com -timestamp 1000 -server_id ""]
    } -result {receipt {}}

test message-classify-marker {a chat marker is recognised and parses to nothing} \
    {*}$msg_common -body {
        set n [j message -from bob@example.com/x -type chat {
            j displayed -ns urn:xmpp:chat-markers:0 -id abc
        }]
        list [ClassifyMessage $n ""] \
            [$::_client message ParseMessage $n \
                -chat_jid bob@example.com -timestamp 1000 -server_id ""]
    } -result {marker {}}

test message-classify-chatstate {a chat state is recognised and parses to nothing} \
    {*}$msg_common -body {
        set n [j message -from bob@example.com/x -type chat {
            j composing -ns http://jabber.org/protocol/chatstates
        }]
        list [ClassifyMessage $n ""] \
            [$::_client message ParseMessage $n \
                -chat_jid bob@example.com -timestamp 1000 -server_id ""]
    } -result {chatstate {}}

test message-classify-body-is-message {a body is a normal stored message} \
    {*}$msg_common -body {
        set n [j message -from bob@example.com/x -type chat { j body #body "hi" }]
        list [ClassifyMessage $n "hi"] \
            [dict get [$::_client message ParseMessage $n \
                -chat_jid bob@example.com -timestamp 1000 -server_id ""] body]
    } -result {message hi}

test message-send-then-receive-earlier-ts {incoming with earlier timestamp inserts before sent} \
    {*}$msg_common \
    -body {
        tacky message send -acc $acc -chat alice@example.com -body "outgoing"
        set sentTs [dict get \
            [lindex [msg_store_latest alice@example.com] 0] timestamp]
        # Incoming message with delay stamp placing it 1 second before our send
        set earlyTs [expr {$sentTs - 1000000}]
        set earlyStamp [FormatTimestampISO $earlyTs]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "earlier"
            j delay -ns urn:xmpp:delay -stamp $earlyStamp
        }]
        # Both messages should be in DB
        set all [msg_store_latest alice@example.com]
        # Chronological order: earlier first, then our sent
        list [llength $all] \
             [dict get [lindex $all 0] body] \
             [dict get [lindex $all 1] body]
    } -result {2 earlier outgoing}

test message-get-latest-real-plus-pending {get latest returns real + pending interleaved} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        tacky message send -acc $acc -chat alice@example.com -body "sent"
        set all [msg_store_latest alice@example.com]
        list [llength $all] \
             [dict get [lindex $all 0] body] \
             [dict get [lindex $all 1] body] \
             [dict get [lindex $all 2] body]
    } -result {3 a b sent}

test message-self-echo-confirms {1:1 self-echo confirms pending, emits Patch not Received} \
    {*}$msg_common \
    -body {
        # Plaintext-path test — OMEMO defaults on, so disable it here.
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "echo me"
        set msgs [msg_store_latest alice@example.com]
        set oid [dict get [lindex $msgs 0] own_id]

        set patches {}
        set received {}
        tacky listen -tag selfecho message <Patch> -jid alice@example.com \
            {apply {{ev} { lappend ::patches $ev }}}
        tacky listen -tag selfecho message <New> -jid alice@example.com \
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
            WHERE chat_jid='alice@example.com' AND kind='message'
        }]
        set status [$::_client db onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='alice@example.com' AND kind='message'
        }]
        list $dbRows $status [llength $patches] [llength $received] \
             [dict get [lindex [dict get [lindex $patches 0] -messages] 0] server_status]
    } -result {1 {} 1 0 {}}

# =============================================================================
# History: local-first (no MAM)
# =============================================================================

test message-history-local-satisfies {local result satisfying limit returns without MAM} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b] \
            [msg_msg timestamp 300 server_id s3 body c]]
        set result [msg_history -chat alice@example.com -limit 2]
        list [llength $result] \
             [dict get [lindex $result 0] body] \
             [dict get [lindex $result 1] body]
    } -result {2 b c}

test message-history-local-before {local -before returns correct slice} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b] \
            [msg_msg timestamp 300 server_id s3 body c]]
        set result [msg_history -chat alice@example.com -before 300 -limit 2]
        list [llength $result] \
             [dict get [lindex $result 0] body] \
             [dict get [lindex $result 1] body]
    } -result {2 a b}

test message-history-local-no-hole-no-mam {local data with no hole returns without MAM} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        set written1 [$::_client conn get_written]
        set result [msg_history -chat alice@example.com -limit 50]
        set written2 [$::_client conn get_written]
        list [llength $result] \
             [dict get [lindex $result 0] body] \
             [dict get [lindex $result 1] body] \
             [expr {[llength $written1] == [llength $written2]}]
    } -result {2 a b 1}

test message-history-after-at-latest-no-mam {-after at latest message returns empty without MAM} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 200 server_id s2 body b]]
        set written1 [$::_client conn get_written]
        set result [msg_history -chat alice@example.com -after 200 -limit 50]
        set written2 [$::_client conn get_written]
        list [llength $result] \
             [expr {[llength $written1] == [llength $written2]}]
    } -result {0 1}

test message-history-preserves-join {history preserves ?join suffix in chatJid} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 chat_jid room@muc.example.com?join server_id s1 body hi]]
        set result [msg_history -chat room@muc.example.com?join -limit 1]
        list [llength $result] [dict get [lindex $result 0] body]
    } -result {1 hi}

# =============================================================================
# History: MAM fallback
# =============================================================================

test message-history-before-empty-queries-mam {-before with empty local still queries MAM} \
    {*}$msg_common \
    -body {
        # Store one message as the cursor anchor
        msg_store [list [msg_msg timestamp 500 server_id s1 body anchor]]
        set written1 [$::_client conn get_written]
        # -before 500: no local data before the cursor -> should trigger MAM
        tacky message history -acc $acc -chat alice@example.com \
            -before 500 -limit 50 \
            -command [list apply {{r} {}}]
        set written2 [$::_client conn get_written]
        expr {[llength $written2] > [llength $written1]}
    } -result {1}

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
    } -result {2 {first msg} bob@example.com mam1 {} alice@example.com 1 1 {second msg} mam2}

test message-history-mam-before-timestamp {-before with no local citizen sends a cursorless MAM page (no time fallback)} \
    {*}$msg_common \
    -body {
        set ts [ParseTimestamp 2024-06-15T12:00:00Z]
        tacky message history -acc $acc -chat alice@example.com \
            -before $ts -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # No citizen to anchor on -> bare newest page: no time bounds, no cursor
        set hasEnd [expr {[xsearch $qnode x field @var end] ne ""}]
        set hasStart [expr {[xsearch $qnode x field @var start] ne ""}]
        set hasBefore [expr {[xsearch $qnode set before] ne ""}]
        list $hasEnd $hasStart $hasBefore
    } -result {0 0 0}

test message-history-mam-after-timestamp {-after with no at-or-before citizen sends a cursorless MAM page (no time fallback)} \
    {*}$msg_common \
    -body {
        set ts [ParseTimestamp 2024-06-15T12:00:00Z]
        # Store a message newer than the cursor so MAM fires (latestTs > after)
        msg_store [list [msg_msg timestamp [expr {$ts + 1000000}] \
            chat_jid alice@example.com server_id s-later body later]]
        # Place a hole between cursor and latest so get after is bounded
        $::_client message messagestore hole add alice@example.com newer $ts
        tacky message history -acc $acc -chat alice@example.com \
            -after $ts -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # The only citizen is newer than the cursor, so none anchors -after:
        # bare newest page with no time bounds and no cursor.
        set hasStart [expr {[xsearch $qnode x field @var start] ne ""}]
        set hasEnd [expr {[xsearch $qnode x field @var end] ne ""}]
        set hasAfter [expr {[xsearch $qnode set after] ne ""}]
        list $hasStart $hasEnd $hasAfter
    } -result {0 0 0}

test message-history-mam-default-cursor {default (no timestamp) uses cursor-based -before} \
    {*}$msg_common \
    -body {
        # Pre-store a message so there's a cursor server_id
        msg_store [list [msg_msg timestamp 100 chat_jid bob@example.com \
            server_id srv99 body old]]
        # Use a different chat that has no local data -> triggers cursor-less MAM
        tacky message history -acc $acc -chat carol@example.com -limit 10 \
            -command [list apply {{r} { set ::result $r }}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        # Should NOT have start or end fields
        set hasStart [expr {[xsearch $qnode x field @var start] ne ""}]
        set hasEnd [expr {[xsearch $qnode x field @var end] ne ""}]
        list $hasStart $hasEnd
    } -result {0 0}

# =============================================================================
# History: poisoned-cursor recovery (demote on item-not-found + retry)
# =============================================================================

test message-history-nearest-citizen-skips-noncitizen \
    {cursor selection skips a non-citizen boundary row and anchors on the nearest citizen} \
    {*}$msg_common \
    -body {
        set tsN [ParseTimestamp 2024-03-01T10:00:00Z]
        set tsC [ParseTimestamp 2024-03-01T11:00:00Z]
        # Boundary row is a non-citizen (no server_id); a citizen sits just newer.
        msg_store [list \
            [msg_msg timestamp $tsN server_id "" body n] \
            [msg_msg timestamp $tsC server_id Cgood body c]]
        tacky message history -acc $acc -chat alice@example.com \
            -before $tsN -limit 50 \
            -command [list apply {{r} {}}]
        set q1 [lindex [xsearch [lindex [$::_client conn get_written] end] \
            query -ns urn:xmpp:mam:2] 0]
        xsearch $q1 set before -get body
    } -result {Cgood}

test message-history-demote-retry-recovers-older \
    {item-not-found on a poisoned cursor demotes it and retries from the next citizen} \
    {*}$msg_common \
    -body {
        set tsP [ParseTimestamp 2024-03-01T10:00:00Z]
        set tsQ [ParseTimestamp 2024-03-01T11:00:00Z]
        # Two citizens at/after the boundary; the nearer one carries a poisoned
        # server_id (a live stanza-id the server never archived).
        msg_store [list \
            [msg_msg timestamp $tsP server_id Pbad body p] \
            [msg_msg timestamp $tsQ server_id Qgood body q]]

        set ::result {}
        tacky message history -acc $acc -chat alice@example.com \
            -before $tsP -limit 50 \
            -command [list apply {{r} { set ::result $r }}]

        # First page must carry the nearest citizen, Pbad.
        set iq1 [lindex [$::_client conn get_written] end]
        set firstCursor [xsearch [lindex [xsearch $iq1 query -ns urn:xmpp:mam:2] 0] \
            set before -get body]

        # Server rejects it: not present in the archive.
        $::_client iq feed [j iq -type error -id [dict get $iq1 attrs id] {
            j error -type cancel {
                j item-not-found -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]

        # Retry must reselect the next citizen, Qgood.
        set iq2 [lindex [$::_client conn get_written] end]
        set retryCursor [xsearch [lindex [xsearch $iq2 query -ns urn:xmpp:mam:2] 0] \
            set before -get body]

        # That page succeeds with an older archived message.
        msg_mam_respond {{id arcA from bob@example.com body {older one} stamp 2024-01-01T09:00:00Z}} -complete true

        set db [$::_client message messagestore cget -db]
        set pSid [$db onecolumn {SELECT server_id FROM chat_message
            WHERE chat_jid='alice@example.com' AND body='p'}]

        list $firstCursor $retryCursor $pSid [llength $::result] \
            [dict get [lindex $::result 0] body]
    } -result {Pbad Qgood {} 1 {older one}}

test message-history-transient-error-no-demote \
    {a transient MAM error does not demote the cursor or retry} \
    {*}$msg_common \
    -body {
        set tsP [ParseTimestamp 2024-03-01T10:00:00Z]
        msg_store [list [msg_msg timestamp $tsP server_id Pbad body p]]
        set ::result none
        tacky message history -acc $acc -chat alice@example.com \
            -before $tsP -limit 50 \
            -command [list apply {{r} { set ::result $r }}]
        set queriesBefore [mam_iq_count]
        set iq1id [dict get [lindex [$::_client conn get_written] end] attrs id]
        $::_client iq feed [j iq -type error -id $iq1id {
            j error -type wait {
                j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        set queriesAfter [mam_iq_count]
        set db [$::_client message messagestore cget -db]
        set pSid [$db eval {SELECT server_id FROM chat_message
            WHERE chat_jid='alice@example.com' AND body='p'}]
        list $queriesBefore $queriesAfter $pSid [llength $::result]
    } -result {1 1 Pbad 0}

# =============================================================================
# History: empty-body filtering + internal fill loop
# =============================================================================

test message-history-mam-drops-empty-body {empty-body MAM stanzas (receipts/markers) are parsed but never stored} \
    {*}$msg_common \
    -body {
        set result {}
        tacky message history -acc $acc -chat alice@example.com -limit 50 \
            -command [list apply {{r} { set ::result $r }}]
        msg_mam_respond {
            {id m1 from bob@example.com body "" stamp 2024-01-01T09:00:00Z}
            {id m2 from bob@example.com body "real" stamp 2024-01-01T09:01:00Z}
        } -complete true
        list [llength $result] \
             [dict get [lindex $result 0] body] \
             [llength [msg_store_latest alice@example.com]]
    } -result {1 real 1}

test message-history-mam-fill-loop-stops-on-progress {a page with any displayable message responds immediately} \
    {*}$msg_common \
    -body {
        set result {}
        tacky message history -acc $acc -chat alice@example.com -limit 3 \
            -command [list apply {{r} { set ::result $r }}]
        set pagesBefore [mam_iq_count]
        # 3 stanzas, 1 displayable, archive not exhausted: one message is
        # progress enough; scroll-back paging fetches the rest later
        msg_mam_respond {
            {id e1 from bob@example.com body "" stamp 2024-01-01T09:00:00Z}
            {id r1 from bob@example.com body "one" stamp 2024-01-01T09:01:00Z}
            {id e2 from bob@example.com body "" stamp 2024-01-01T09:02:00Z}
        } -complete false
        list [lmap m $result { dict get $m body }] \
            [expr {[mam_iq_count] == $pagesBefore}]
    } -result {one 1}

test message-history-mam-fill-loop-stops-on-complete {fill loop stops at archive end even with a short page} \
    {*}$msg_common \
    -body {
        set result {}
        tacky message history -acc $acc -chat alice@example.com -limit 5 \
            -command [list apply {{r} { set ::result $r }}]
        set pagesBefore [mam_iq_count]
        msg_mam_respond {
            {id r1 from bob@example.com body "only" stamp 2024-01-01T09:00:00Z}
        } -complete true
        list [llength $result] [expr {[mam_iq_count] == $pagesBefore}]
    } -result {1 1}

test message-history-mam-fill-loop-pages-through-empty {a wholly empty-body page is paged through, not surfaced as a stall} \
    {*}$msg_common \
    -body {
        set result {}
        tacky message history -acc $acc -chat alice@example.com -limit 2 \
            -command [list apply {{r} { set ::result $r }}]
        # page 1: entirely receipts/markers, more behind them
        msg_mam_respond {
            {id e1 from bob@example.com body "" stamp 2024-01-01T09:00:00Z}
            {id e2 from bob@example.com body "" stamp 2024-01-01T09:01:00Z}
        } -complete false
        # page 2: the real messages
        msg_mam_respond {
            {id r1 from bob@example.com body "x" stamp 2024-01-01T08:00:00Z}
            {id r2 from bob@example.com body "y" stamp 2024-01-01T08:30:00Z}
        } -complete true
        lmap m $result { dict get $m body }
    } -result {x y}

# =============================================================================
# History: hole-aware
# =============================================================================

test message-history-hole-triggers-mam-on-pagination {cursor-based pagination across a hole triggers MAM fill} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a] \
            [msg_msg timestamp 500 server_id s5 body e]]
        $::_client message messagestore hole add alice@example.com newer 100
        # -before 500: local returns empty (hole sits between 100
        # and 500, truncating). bounded=true with cursor -> MAM fires.
        set written1 [$::_client conn get_written]
        tacky message history -acc $acc -chat alice@example.com \
            -before 500 -limit 50 \
            -command [list apply {{r} {}}]
        set written2 [$::_client conn get_written]
        expr {[llength $written2] > [llength $written1]}
    } -result {1}

test message-history-hole-initial-no-mam {bounded result on initial load (no cursor) does not trigger MAM} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body a]]
        $::_client message messagestore hole add alice@example.com newer 100
        msg_store [list \
            [msg_msg timestamp 500 server_id s5 body e]]
        # get latest returns [e], bounded=true. Initial load (no
        # cursor): we show what we have without firing MAM. User
        # triggers fill by scrolling into the hole.
        set written1 [$::_client conn get_written]
        tacky message history -acc $acc -chat alice@example.com -limit 50 \
            -command [list apply {{r} {}}]
        set written2 [$::_client conn get_written]
        expr {[llength $written2] == [llength $written1]}
    } -result {1}

test message-history-mam-sweeps-bounding-hole {MAM response with overlap sweeps prior hole} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body anchor]]
        $::_client message messagestore hole add alice@example.com newer 100
        set sentBefore [llength [$::_client message messagestore hole list alice@example.com]]
        # Trigger -before pagination past the hole (should hit MAM)
        tacky message history -acc $acc -chat alice@example.com \
            -before 100 -limit 50 \
            -command [list apply {{r} {}}]
        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]
        # MAM returns older history (no overlap with current cache,
        # complete=false -> places a new hole at the far older edge)
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id mam1 queryid $qid \
                from alice@example.com/phone body older \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete false {
                j set -ns http://jabber.org/protocol/rsm {
                    j first #body mam1
                    j last #body mam1
                }
            }
        }]
        set sentAfter [llength [$::_client message messagestore hole list alice@example.com]]
        # Sweep removed the cursor-side hole; placement added a new
        # one at the far older edge. Net: still 1.
        list $sentBefore $sentAfter
    } -result {1 1}

test message-history-mam-complete-removes-bounding-hole {MAM complete=true on a bounded fetch clears the bounding hole} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 server_id s1 body anchor]]
        $::_client message messagestore hole add alice@example.com older 100
        # -before 100: local empty + bounded (hole older than cursor)
        # -> MAM fires. Server says "complete=true" -> archive exhausted
        # in the older direction. The bounding hole must clear.
        tacky message history -acc $acc -chat alice@example.com \
            -before 100 -limit 50 \
            -command [list apply {{r} {}}]
        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        $::_client iq feed [j iq -type result -id $iqId {
            j fin -ns urn:xmpp:mam:2 -complete true {
                j set -ns http://jabber.org/protocol/rsm
            }
        }]
        llength [$::_client message messagestore hole list \
            alice@example.com]
    } -result {0}

# =============================================================================
# History: cancel
# =============================================================================

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
        set local [msg_store_latest bob@example.com]
        list [llength $local] [dict get [lindex $local 0] body]
    } -result {1 {stored msg}}

test message-history-no-tag-unaffected-by-cancel {cancel with unknown tag is harmless} \
    {*}$msg_common \
    -body {
        tacky message cancel -acc $acc -tag nonexistent
        set result [msg_history -chat bob@example.com -limit 50]
        # Should proceed normally (triggers MAM since no local)
        set written [$::_client conn get_written]
        expr {[llength $written] > 0}
    } -result 1

# =============================================================================
# Goto
# =============================================================================

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

# =============================================================================
# Catchup
# =============================================================================

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
        set msgs [msg_store_latest alice@example.com]
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
        set msgs [msg_store_latest bob@example.com]
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
        llength [msg_store_latest alice@example.com]
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
        llength [msg_store_latest alice@example.com]
    } -result {1}

test message-catchup-dedup-no-ids {catchup deduplicates messages without server/origin IDs (IRC bridges)} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
                chat_jid alice@example.com from_jid alice@example.com \
                body "bridge msg" server_id "" own_id ""] \
            [msg_msg timestamp [ParseTimestamp 2024-01-01T11:00:00Z] \
                chat_jid alice@example.com from_jid alice@example.com \
                body "bridge msg 2" server_id "" own_id ""]]
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
        $db eval {
            SELECT count(*) FROM chat_message
            WHERE chat_jid='alice@example.com' AND kind='message'
        }
    } -result {2}

test message-catchup-per-message-received {each catchup message fires its own <New>} \
    {*}$msg_common \
    -body {
        set ::_count 0
        tacky listen message <New> {apply {{ev} { incr ::_count }}}
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [mam_result id s1 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg1 stamp 2024-01-01T10:00:00Z] \
            [mam_result id s2 queryid $qid \
                from bob@example.com/phone to user@test.example.com \
                body msg2 stamp 2024-01-01T11:00:00Z] \
            [mam_result id s3 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg3 stamp 2024-01-01T12:00:00Z]]
        set ::_count
    } -result {3}

test message-catchup-overlap-clears-reconnect-hole {catchup overlap sweeps the reconnect hole} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp [ParseTimestamp 2024-01-01T09:00:00Z] \
                chat_jid alice@example.com server_id s_old body anchor]]
        msg_ready
        set sentBefore [llength [$::_client message messagestore hole list \
            alice@example.com]]
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        # Catchup returns the existing anchor + a newer message -> overlap proven
        msg_catchup_finish [list \
            [mam_result id s_old queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body anchor stamp 2024-01-01T09:00:00Z] \
            [mam_result id s_new queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body "new live" stamp 2024-01-01T11:00:00Z]]
        set sentAfter [llength [$::_client message messagestore hole list \
            alice@example.com]]
        list $sentBefore $sentAfter
    } -result {1 0}

test message-catchup-incomplete-places-hole {catchup with complete=false places older-edge hole for new chats} \
    {*}$msg_common \
    -body {
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [mam_result id s1 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg1 stamp 2024-01-01T10:00:00Z]] false
        # alice@example.com had no pre-existing citizens, so catchup
        # adds an older-edge hole below the catchup message.
        llength [$::_client message messagestore hole list alice@example.com]
    } -result {1}

# =============================================================================
# Reconnect holes
# =============================================================================

test message-reconnect-places-holes {OnReady places newer-hole after each chat's newest citizen} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 chat_jid alice@example.com \
                server_id s1 body alice-old]]
        msg_store [list \
            [msg_msg timestamp 200 chat_jid bob@example.com \
                server_id b1 body bob-old]]
        msg_ready
        list [llength [$::_client message messagestore hole list \
                  alice@example.com]] \
             [llength [$::_client message messagestore hole list \
                  bob@example.com]]
    } -result {1 1}

test message-reconnect-no-hole-without-citizens {chats without citizens get no hole} \
    {*}$msg_common \
    -body {
        # Pending outgoing exists but no real citizens
        msg_store [list \
            [msg_msg timestamp 100 chat_jid alice@example.com \
                own_id oid1 body pending server_status pending]]
        msg_ready
        llength [$::_client message messagestore hole list alice@example.com]
    } -result {0}

test message-reconnect-idempotent {repeated reconnects without progress don't pile up holes} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 chat_jid alice@example.com \
                server_id s1 body anchor]]
        msg_ready
        msg_ready
        msg_ready
        llength [$::_client message messagestore hole list \
            alice@example.com]
    } -result {1}

# =============================================================================
# Search
# =============================================================================

test message-search-sends-mam-fulltext {search sends MAM query with fulltext field} \
    {*}$msg_common \
    -body {
        msg_prime_search
        tacky message search -acc $acc -chat alice@example.com \
            -query "hello world" -limit 10 \
            -command [list apply {{r} {}}]
        set iqStanza [lindex [$::_client conn get_written] end]
        set qnode [lindex [xsearch $iqStanza query -ns urn:xmpp:mam:2] 0]
        set ftVal [xsearch $qnode x field @var withtext value -get body]
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
        set dbCount [$db eval {
            SELECT count(*) FROM chat_message
            WHERE chat_jid='alice@example.com' AND kind='message'
        }]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 0] server_id] \
             [dict get [lindex $msgs 1] body] \
             [dict get $result complete] \
             [dict get $result last] \
             $dbCount
    } -result {2 {found it} sid1 {found another} 0 sid2 2}

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

# Search: hole wrapping
#
# A remote search hit is an island — we know nothing about the messages
# surrounding it in archive time. OnSearch wraps each newly-inserted hit
# with older+newer holes so future pagination across the hit falls
# through to MAM.

test message-search-wraps-inserted-hit-with-holes {a new search hit gets older and newer holes} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "needle" -limit 10 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "needle in haystack" \
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

        set hitTs [dict get [lindex [dict get $result messages] 0] timestamp]
        set sents [$::_client message messagestore hole list alice@example.com]
        # Two holes straddling the hit (BumpTs places them +-1us).
        list [llength $sents] \
             [expr {[lindex $sents 0] < $hitTs}] \
             [expr {[lindex $sents 1] > $hitTs}]
    } -result {2 1 1}

test message-search-dedup-hit-adds-no-holes {a search hit that dedups against a citizen adds no holes} \
    {*}$msg_common \
    -body {
        # Pre-seed an existing citizen with server_id="sid1" so the
        # search result will dedup against it.
        msg_store [list [msg_msg timestamp 1000000 server_id sid1 \
            body "needle in haystack"]]

        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "needle" -limit 10 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "needle in haystack" \
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

        # Dedup path returns empty inserted -> no holes and no
        # message in callback output.
        list [llength [dict get $result messages]] \
             [llength [$::_client message messagestore hole list \
                          alice@example.com]]
    } -result {0 0}

test message-search-repeat-does-not-pile-holes {repeating the same search does not pile up holes} \
    {*}$msg_common \
    -body {
        msg_prime_search

        # Run the same search twice; second run dedups (same server_id),
        # so hole count must not change.
        for {set i 0} {$i < 2} {incr i} {
            tacky message search -acc $acc -chat alice@example.com \
                -query "needle" -limit 10 \
                -command [list apply {{r} {}}]
            set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
            set qid [mam_queryid]
            $::_client mam onResultMessage [j message -from user@test.example.com {
                j /as-is [mam_result id sid1 queryid $qid \
                    from alice@example.com/phone body "needle in haystack" \
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
        }
        llength [$::_client message messagestore hole list alice@example.com]
    } -result 2

test message-search-multiple-hits-share-middle-hole {two hits with no citizens between them share the in-between hole} \
    {*}$msg_common \
    -body {
        msg_prime_search
        set result {}
        tacky message search -acc $acc -chat alice@example.com \
            -query "needle" -limit 10 \
            -command [list apply {{r} { set ::result $r }}]

        set iqId [dict get [lindex [$::_client conn get_written] end] attrs id]
        set qid [mam_queryid]

        # Two hits, far apart in archive time.
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid1 queryid $qid \
                from alice@example.com/phone body "needle one" \
                stamp 2024-01-01T10:00:00Z]
        }]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is [mam_result id sid2 queryid $qid \
                from alice@example.com/phone body "needle two" \
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

        # Three gaps total: (-inf, hit1), (hit1, hit2), (hit2, +inf) —
        # each holds one hole. The "newer than hit1" hole
        # placed by hit1's wrap is in the same gap as the "older than
        # hit2" hole hit2 would otherwise add, so hit2's older-add
        # is a no-op (at-most-one-per-gap invariant).
        set sents [$::_client message messagestore hole list alice@example.com]
        set msgs [dict get $result messages]
        set ts1 [dict get [lindex $msgs 0] timestamp]
        set ts2 [dict get [lindex $msgs 1] timestamp]
        list [llength $sents] \
             [expr {[lindex $sents 0] < $ts1}] \
             [expr {[lindex $sents 1] > $ts1 && [lindex $sents 1] < $ts2}] \
             [expr {[lindex $sents 2] > $ts2}]
    } -result {3 1 1 1}

# XEP-0461 replies: ingest parsing + gotoReply

test message-live-reply-fields {reply target id + author parsed into stored fields} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id origA -from alice@example.com/phone {
            j body #body "my reply"
            j stanza-id -ns urn:xmpp:sid:0 -id srvA
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id TARGET99
        }]
        set msg [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $msg reply_id] [dict get $msg reply_to]
    } -result {TARGET99 alice@example.com}

test message-reply-fallback-codepoints {fallback offsets count Unicode codepoints, not bytes} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id rf3 -from alice@example.com/phone {
            j body #body "> café\nreply"
            j stanza-id -ns urn:xmpp:sid:0 -id srvRF3
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id TGT
            j fallback -ns urn:xmpp:fallback:0 -for urn:xmpp:reply:0 {
                j body -start 0 -end 7
            }
        }]
        $::_client db onecolumn {SELECT body FROM chat_message WHERE server_id='srvRF3'}
    } -result {reply}

test message-reply-fallback-for-mismatch {a fallback for a different feature is left in the body} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id rf2 -from alice@example.com/phone {
            j body #body "> hi\nactual reply"
            j stanza-id -ns urn:xmpp:sid:0 -id srvRF2
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id TGT
            j fallback -ns urn:xmpp:fallback:0 -for urn:xmpp:other:0 {
                j body -start 0 -end 5
            }
        }]
        $::_client db onecolumn {SELECT body FROM chat_message WHERE server_id='srvRF2'}
    } -result "> hi\nactual reply"

test message-live-origin-id-captured {origin-id element is captured and resolvable} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id atA -from alice@example.com/phone {
            j body #body hi
            j stanza-id -ns urn:xmpp:sid:0 -id srvX
            j origin-id -ns urn:xmpp:sid:0 -id ORIG-A
        }]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        expr {[$::_client message messagestore resolveReply \
                   alice@example.com ORIG-A alice@example.com] == $ts}
    } -result {1}

test message-live-origin-id-fallback {origin_id falls back to @id when no origin-id element} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id ATID -from alice@example.com/phone {
            j body #body hi
            j stanza-id -ns urn:xmpp:sid:0 -id srvB
        }]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        expr {[$::_client message messagestore resolveReply \
                   alice@example.com ATID alice@example.com] == $ts}
    } -result {1}

test message-live-nonreply-empty {non-reply message has empty reply fields} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body plain
        }]
        set msg [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $msg reply_id] [dict get $msg reply_to]
    } -result {{} {}}

test message-gotoreply-local {gotoReply resolves a reply target locally and returns it as the anchor} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id t1 -from alice@example.com/phone {
            j body #body "the original"
            j stanza-id -ns urn:xmpp:sid:0 -id SRV-TGT
        }]
        $::_client conn feed [j message -type chat -id r1 -from alice@example.com/phone {
            j body #body "the reply"
            j stanza-id -ns urn:xmpp:sid:0 -id SRV-RPL
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id SRV-TGT
        }]
        set ::_gr {}
        tacky message gotoReply -acc $acc -chat alice@example.com \
            -reply_id SRV-TGT -reply_to alice@example.com -source local \
            -command [list apply {{r} {set ::_gr $r}}]
        set bodies {}
        foreach m [dict get $::_gr messages] { lappend bodies [dict get $m body] }
        list [expr {[dict get $::_gr anchor] ne ""}] \
             [expr {"the original" in $bodies}]
    } -result {1 1}

test message-send-reply-stanza {1:1 reply cites origin-id, quotes the full multi-line body, stores a clean reply} \
    {*}$msg_common \
    -body {
        # Plaintext-path test — OMEMO defaults on, so disable it here.
        $::_client omemo setEnabled -jid alice@example.com -value 0
        set orig "line one\nline two is long enough to clearly exceed the eighty-character display preview cap"
        $::_client conn feed [j message -type chat -id tOrig -from alice@example.com/phone {
            j body #body $orig
            j stanza-id -ns urn:xmpp:sid:0 -id SRV1
            j origin-id -ns urn:xmpp:sid:0 -id ORIG1
        }]
        set tgtTs [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message send -acc $acc -chat alice@example.com \
            -body "my answer" -reply_to_ts $tgtTs
        set stanza [lindex [$::_client conn get_written] end]
        set fb [lindex [xsearch $stanza fallback -ns urn:xmpp:fallback:0] 0]
        set fbEnd [xsearch [lindex [xsearch $fb body] 0] -get @end]
        set wireBody [xsearch $stanza body -get body]
        set stored [lindex [msg_store_latest alice@example.com] end]
        set quote "> line one\n> line two is long enough to clearly exceed the eighty-character display preview cap\n"
        list [xsearch $stanza reply -ns urn:xmpp:reply:0 -get @id] \
             [xsearch $stanza reply -ns urn:xmpp:reply:0 -get @to] \
             [expr {$wireBody eq "${quote}my answer"}] \
             [expr {$fbEnd == [string length $quote]}] \
             [dict get $stored body] \
             [dict get $stored reply_id]
    } -result {ORIG1 alice@example.com 1 1 {my answer} ORIG1}

test message-send-reply-own-pending {replying to our own pending message cites its origin/own id (no server_id yet)} \
    {*}$msg_common \
    -body {
        # Plaintext-path test — OMEMO defaults on, so disable it here.
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "mine"
        set own [lindex [msg_store_latest alice@example.com] end]
        set ownTs [dict get $own timestamp]
        set ownOid [dict get $own own_id]
        tacky message send -acc $acc -chat alice@example.com \
            -body "follow up" -reply_to_ts $ownTs
        set stanza [lindex [$::_client conn get_written] end]
        set reply [lindex [msg_store_latest alice@example.com] end]
        list [dict get $own server_id] \
             [expr {[xsearch $stanza reply -ns urn:xmpp:reply:0 -get @id] eq $ownOid}] \
             [expr {[dict get $reply reply_id] eq $ownOid}]
    } -result {{} 1 1}

test message-maxts-ignores-hole \
    {maxTimestamp reflects the newest message, not a tail hole} \
    {*}$msg_common \
    -body {
        set room room@muc.example.com?join
        set ts [clock microseconds]
        msg_store [list [msg_msg chat_jid $room timestamp $ts \
            from_jid $room/someone server_id sid-1]]
        # A 'newer' hole marks an unfetched tail gap one usec past the
        # newest message; it must not be mistaken for the newest message.
        $::_client message messagestore hole add $room newer $ts
        expr {[$::_client message maxTimestamp -chat $room] == $ts}
    } -result 1

test message-maxts-after-confirm-move \
    {maxTimestamp tracks a pending row whose timestamp moves on confirmation} \
    {*}$msg_common \
    -body {
        set room room@muc.example.com?join
        set oid [clock microseconds]
        msg_store [list [msg_msg chat_jid $room timestamp $oid \
            from_jid $room/someone own_id $oid server_status pending]]
        # Room echoes it back with a later stamp; the pending row's timestamp
        # is moved in place via UPDATE (which the insert trigger misses).
        set echoTs [expr {$oid + 5000}]
        msg_store [list [msg_msg chat_jid $room timestamp $echoTs \
            from_jid $room/someone own_id $oid server_id sid-echo]]
        expr {[$::_client message maxTimestamp -chat $room] == $echoTs}
    } -result 1
