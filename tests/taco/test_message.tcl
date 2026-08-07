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
    set defaults {id sid1 queryid "" from alice@example.com to "" body hello stamp 2024-01-01T00:00:00Z origin_id "" type ""}
    set opts [dict merge $defaults $args]
    set oid [dict get $opts origin_id]
    set qid [dict get $opts queryid]
    set rid [dict get $opts id]
    set toJid [dict get $opts to]
    set msgType [dict get $opts type]
    set msgAttrs [list -from [dict get $opts from]]
    if {$toJid ne ""} {
        lappend msgAttrs -to $toJid
    }
    if {$msgType ne ""} {
        lappend msgAttrs -type $msgType
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

# Helper: the MAM query IQ addressed to $toJid. Room archives are queried
# with the room as `to`, so several queries can be outstanding at once and
# picking by position isn't safe.
proc mam_iq_to {toJid} {
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""
            && [xsearch $stanza -get @to] eq $toJid} {
            return $stanza
        }
    }
    return ""
}

# Helper: simulate a room join - send it, then feed back the self-presence
# that makes muc emit <Joined>.
proc msg_muc_join {room nick} {
    $::_client muc join -jid $room -nick $nick
    $::_client conn feed [j presence -from $room/$nick {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -role participant -affiliation member
            j status -code 110
        }
    }]
}

# Helper: complete a catchup by feeding MAM results + fin IQ
proc msg_catchup_finish {results {complete true}} {
    msg_mam_finish [mam_catchup_iq] $results $complete
}

# Helper: feed MAM results + fin for one specific query IQ. A room query is
# addressed to the room, so both its results and its fin must come back from
# the room - mam drops mismatched results, and iq keys responses on from+id.
proc msg_mam_finish {iqStanza results {complete true}} {
    set iqId [dict get $iqStanza attrs id]
    set qid [xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid]
    set queriedTo [xsearch $iqStanza -get @to]
    set archive [expr {$queriedTo ne "" ? $queriedTo : "user@test.example.com"}]
    set finAttrs [list -type result -id $iqId]
    if {$queriedTo ne ""} {
        lappend finAttrs -from $queriedTo
    }

    foreach rn $results {
        $::_client mam onResultMessage [j message -from $archive {
            j /as-is $rn
        }]
    }

    set first ""
    set last ""
    if {[llength $results] > 0} {
        set first [xsearch [lindex $results 0] -get @id]
        set last [xsearch [lindex $results end] -get @id]
    }

    $::_client iq feed [j iq {*}$finAttrs {
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
            j stanza-id -ns urn:xmpp:sid:0 -id srv42 -by user@test.example.com
        }]
        set msg [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $msg chat_jid] \
             [dict get $msg from_jid] \
             [dict get $msg content body] \
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
            j stanza-id -ns urn:xmpp:sid:0 -id srv42 -by user@test.example.com
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

test message-live-foreign-stanza-id-ignored \
    {a <stanza-id> stamped by anyone but our archive is not the server_id} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body hi
            j stanza-id -ns urn:xmpp:sid:0 -id forged -by alice@example.com
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] server_id
    } -result {}

test message-live-stanza-id-picks-archive-owner \
    {the archive owner's <stanza-id> wins over one injected ahead of it} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body hi
            j stanza-id -ns urn:xmpp:sid:0 -id forged -by alice@example.com
            j stanza-id -ns urn:xmpp:sid:0 -id genuine -by user@test.example.com
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] server_id
    } -result {genuine}

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
             [dict get $_got -message content body]
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

# Incoming encryption stamp comes from the decrypt path's `decrypted` key,
# not the EME marker. A peer can put an EME marker on a cleartext body, so
# reading it would show the lock on an unencrypted message.
test message-incoming-decrypted-stamps-encryption \
    {ParseMessage stamps encryption='omemo' only for decrypted nodes} \
    {*}$msg_common \
    -body {
        set decryptedNode [j message -from alice@example.com/x -type chat {
            j body #body "secret"
            j encryption -ns urn:xmpp:eme:0 \
                -namespace eu.siacs.conversations.axolotl -name OMEMO
        }]
        dict set decryptedNode decrypted 1
        # Same stanza off the wire: EME marker, but never decrypted.
        set spoofedNode [j message -from alice@example.com/x -type chat {
            j body #body "not really encrypted"
            j encryption -ns urn:xmpp:eme:0 \
                -namespace eu.siacs.conversations.axolotl -name OMEMO
        }]
        set plainNode [j message -from alice@example.com/x -type chat {
            j body #body "hi there"
        }]
        set m1 [$::_client message ParseMessage $decryptedNode \
            -chat_jid alice@example.com -timestamp 1000 -server_id ""]
        set m2 [$::_client message ParseMessage $spoofedNode \
            -chat_jid alice@example.com -timestamp 1001 -server_id ""]
        set m3 [$::_client message ParseMessage $plainNode \
            -chat_jid alice@example.com -timestamp 1002 -server_id ""]
        list decrypted [dict get $m1 encryption] \
            spoofed [dict get $m2 encryption] \
            plain [dict get $m3 encryption]
    } -result {decrypted omemo spoofed {} plain {}}

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
           ]]
        # The echo comes back from our own jid (carbon / MAM) with same @id
        # and a server stanza-id; ExtractEnvelopeIds derives own_id from @id,
        # which ParseMessage carries through.
        set echo [j message -from $acc/phone -to bob@example.com -type chat \
                -id uuid-7 {
            j body #body "hello"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-99 -by user@test.example.com
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
            encryption omemo]]
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
            encryption omemo]]
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
            encryption omemo]]
        set before [llength [$::_client conn get_written]]
        # Dict deliberately omits `encryption` - the bridge-drop case.
        $::_client message RetrySend [dict create \
            chat_jid alice@example.com body "secret" own_id oid-drop]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, encryption FROM chat_message
            WHERE own_id='oid-drop'} row {}
        list status $row(server_status) enc $row(encryption) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending enc omemo wrote 0}

# OnOmemoSelfReady must retry only sends that aren't currently in flight -
# never one SM is still holding, which would duplicate it.
test message-omemo-selfready-skips-on-wire \
    {OnOmemoSelfReady leaves in-flight rows alone (no double-send)} \
    {*}$msg_common \
    -body {
        # Plaintext row already written and awaiting ack.
        msg_store [list [msg_msg chat_jid alice@example.com body clear \
            from_jid $acc own_id o-clear server_status pending \
            encryption ""]]
        $::_client message MarkWired o-clear
        # OMEMO row that never reached the wire (encrypt NOT_READY).
        msg_store [list [msg_msg chat_jid bob@example.com body secret \
            from_jid $acc own_id o-omemo server_status pending \
            encryption omemo]]
        set before [llength [$::_client conn get_written]]
        $::_client message OnOmemoSelfReady
        # In-flight plaintext row not re-sent; the omemo row retries but
        # NOT_READYs (store uninit), so the wire count is unchanged.
        expr {[llength [$::_client conn get_written]] - $before}
    } -result {0}

# The omemo scopes feed the warm retry ticks, so they must exclude rows SM
# is still holding - re-sending one would duplicate it. (The sibling test
# above can't prove this: its in-flight row is plaintext, so the scope's
# encryption filter excludes it regardless.)
test message-pendingsends-omemo-scope-excludes-in-flight \
    {parked-omemo skips an OMEMO row that is in flight} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body wired \
            from_jid $acc own_id o-wired server_status pending \
            encryption omemo timestamp 1000000]]
        msg_store [list [msg_msg chat_jid alice@example.com body parked \
            from_jid $acc own_id o-parked server_status pending \
            encryption omemo timestamp 2000000]]
        $::_client message MarkWired o-wired
        lmap m [$::_client message PendingSends parked-omemo] {
            dict get $m own_id
        }
    } -result {o-parked}

# encrypt() holds a send until every announced device is warm, so a peer
# with several devices coming online produces several NOT_READY retries in
# a row. None of them may fail the message: warming ends on its own (omemo's
# per-device fetch deadline), and a row that never gets out is failed by the
# archive-floor rule on the next connect, not by an attempt counter here.
test message-omemo-warming-ticks-keep-row-pending \
    {repeated NOT_READY retries during warming do not fail the message} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid bob@example.com body secret \
            from_jid $acc own_id o-warm server_status pending \
            encryption omemo]]
        # Store is uninitialised here, so every retry NOT_READYs.
        for {set i 0} {$i < 20} {incr i} {
            $::_client message OnOmemoSessionReady -jid bob@example.com
        }
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='o-warm'} row {}
        list status $row(server_status) reason $row(fail_reason)
    } -result {status pending reason {}}

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
            encryption omemo]]
        # Our own message comes back via catchup but carries no body.
        set rn [mam_result id arch-1 from $acc to alice@example.com \
            origin_id oid-conf body ""]
        $::_client message OnCatchup [dict create messages [list $rn] complete 1]
        # Confirmed in place (no duplicate inserted, original body intact).
        set rows [msg_store_latest alice@example.com]
        list nrows [llength $rows] \
            status [dict get [lindex $rows 0] server_status] \
            body [dict get [lindex $rows 0] content body]
    } -result {nrows 1 status {} body secret}

# =============================================================================
# Stranded sends: settle pending rows against the archive after catchup
#
# A send that reached the wire but never got an SM ack survives a restart as
# `pending`, with nothing in memory marking it in flight. The reconnect
# catchup confirms whatever the server really archived; RetryPending then
# judges the rest by the span catchup
# covered. Inside that span the archive would have shown the message and
# didn't, so the server never got it -> re-send. Older than the span the
# archive can't say either way -> fail, and let the user decide.
# =============================================================================

# 2024-01-01T00:00:00Z, the floor the fixtures below establish.
set ::floor_2024 1704067200000000
# Between that floor and now.
set ::inside_2025 1735689600000000

test message-catchup-resends-row-inside-archive-span \
    {a pending row newer than the archive floor is re-sent} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "stranded" \
            from_jid $acc own_id oid-inside server_status pending \
            encryption "" timestamp $::inside_2025]]
        set before [llength [$::_client conn get_written]]
        # Archive floor is 2024; the row sits above it and was not echoed.
        $::_client message OnCatchup [dict create complete 0 messages [list \
            [mam_result id arch-a from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-inside'} row {}
        list status $row(server_status) reason $row(fail_reason) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending reason {} wrote 1}

test message-catchup-fails-row-predating-archive \
    {a pending row older than the archive floor is marked delivery-failed} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "ancient" \
            from_jid $acc own_id oid-old server_status pending \
            encryption "" timestamp 1000000]]
        set before [llength [$::_client conn get_written]]
        $::_client message OnCatchup [dict create complete 0 messages [list \
            [mam_result id arch-b from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-old'} row {}
        list status $row(server_status) reason $row(fail_reason) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status failed reason delivery wrote 0}

# complete=1 means the page IS the whole archive, so nothing falls outside
# the evidence and age can never be the reason to give up.
test message-catchup-complete-archive-never-fails \
    {with a complete archive even an ancient row is re-sent, not failed} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "ancient" \
            from_jid $acc own_id oid-comp server_status pending \
            encryption "" timestamp 1000000]]
        $::_client message OnCatchup [dict create complete 1 messages [list \
            [mam_result id arch-c from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-comp'} row {}
        list status $row(server_status) reason $row(fail_reason)
    } -result {status pending reason {}}

# A failed MAM query is no evidence at all - it must not be read as proof
# that anything went undelivered.
test message-catchup-error-retries-without-failing \
    {a MAM error retries pending rows and fails none} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "ancient" \
            from_jid $acc own_id oid-err server_status pending \
            encryption "" timestamp 1000000]]
        set before [llength [$::_client conn get_written]]
        $::_client message OnCatchup [dict create error timeout]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-err'} row {}
        list status $row(server_status) reason $row(fail_reason) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending reason {} wrote 1}

# The floor must come from EVERY archived item, not just the citizens the
# storing loop keeps. A displayless (drop-verdict) node that predates the
# citizens still proves the page reached that far back, so a row between
# the two is inside the evidence and must be re-sent rather than failed.
test message-catchup-floor-spans-displayless-nodes \
    {a displayless archive node still lowers the floor} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "mid" \
            from_jid $acc own_id oid-mid server_status pending \
            encryption "" timestamp 1500000000000000]]
        $::_client message OnCatchup [dict create complete 0 messages [list \
            [mam_result id arch-d from bob@example.com to $acc \
                body "" stamp 2017-01-01T00:00:00Z] \
            [mam_result id arch-e from bob@example.com to $acc \
                body "later" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-mid'} row {}
        list status $row(server_status) reason $row(fail_reason)
    } -result {status pending reason {}}

# Catchup runs while the connection is live, so a message sent during the
# round-trip is in flight and owned by SM's replay queue - not ours to
# re-send or judge. Note it predates the archive floor, so without the
# in-flight check it would be judged undelivered, not merely re-sent.
test message-catchup-skips-send-made-during-catchup \
    {a row in flight on this stream is left alone} \
    {*}$msg_common \
    -body {
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_store [list [msg_msg chat_jid alice@example.com body "live" \
            from_jid $acc own_id oid-live server_status pending \
            encryption "" timestamp 1000000]]
        # Written to the current stream, awaiting its ack.
        $::_client message MarkWired oid-live
        set before [llength [$::_client conn get_written]]
        msg_catchup_finish [list \
            [mam_result id arch-f queryid $qid from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]] false
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-live'} row {}
        list status $row(server_status) reason $row(fail_reason) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status pending reason {} wrote 0}

# Confirmation has to win over both other outcomes: the row is settled
# before RetryPending ever looks at it, even though it predates the floor.
test message-catchup-confirmed-row-not-resent-or-failed \
    {a row the archive confirms is neither re-sent nor failed} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "landed" \
            from_jid $acc own_id oid-conf2 server_status pending \
            encryption "" timestamp 1000000]]
        set before [llength [$::_client conn get_written]]
        $::_client message OnCatchup [dict create complete 0 messages [list \
            [mam_result id arch-g from $acc to alice@example.com \
                origin_id oid-conf2 body "landed" stamp 2024-06-01T00:00:00Z] \
            [mam_result id arch-h from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-conf2'} row {}
        list status $row(server_status) reason $row(fail_reason) \
            wrote [expr {[llength [$::_client conn get_written]] > $before}]
    } -result {status {} reason {} wrote 0}

# The account archive holds no room traffic, so the floor can say nothing
# about a MUC send: it keeps waiting for the join instead.
test message-catchup-muc-row-defers-not-failed \
    {an old MUC row defers to the room join rather than being failed} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid room@conf.example.com?join \
            body "to room" from_jid $acc own_id oid-muc \
            server_status pending encryption "" timestamp 1000000]]
        $::_client message OnCatchup [dict create complete 0 messages [list \
            [mam_result id arch-i from bob@example.com to $acc \
                body "other" stamp 2024-01-01T00:00:00Z]]]
        set db [$::_client message messagestore cget -db]
        $db eval {
            SELECT server_status, fail_reason FROM chat_message
            WHERE own_id='oid-muc'} row {}
        list status $row(server_status) reason $row(fail_reason)
    } -result {status pending reason {}}

# In-flight is per-connection state held in memory, so a row left pending
# by a previous run can never look in flight - there is nothing to reset.
test message-previous-run-row-not-in-flight \
    {a pending row from a previous run is not treated as in flight} \
    {*}$msg_common \
    -body {
        # Freshly constructed module, as at process start.
        msg_store [list [msg_msg chat_jid alice@example.com body "p" \
            from_jid $acc own_id oid-prev server_status pending \
            timestamp 1000000]]
        $::_client message IsWired oid-prev
    } -result 0

# ...and a row wired on an earlier stream stops being in flight when a
# fresh <Ready> arrives, so it becomes retryable again. This is the
# stranding regression: it used to stay marked and be skipped forever.
test message-fresh-ready-releases-previous-stream \
    {a row wired on an earlier stream is released by the next fresh Ready} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg chat_jid alice@example.com body "s" \
            from_jid $acc own_id oid-strand server_status pending \
            timestamp 1000000]]
        $::_client message MarkWired oid-strand
        set duringStream [$::_client message IsWired oid-strand]
        msg_ready
        list during $duringStream after [$::_client message IsWired oid-strand]
    } -result {during 1 after 0}

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
            encryption omemo timestamp 1000000]]
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
            server_status "" encryption omemo]]
        set rn [mam_result id arch-9 from $acc to alice@example.com \
            origin_id oid-dup body ""]
        $::_client message OnCatchup [dict create messages [list $rn] complete 1]
        set rows [msg_store_latest alice@example.com]
        list nrows [llength $rows] \
            body [dict get [lindex $rows 0] content body]
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

# Incoming read receipts / chat markers advance remote_status (XEP-0184/0333).
test message-marker-received-marks-delivered \
    {a XEP-0184 receipt from the peer advances the sent message to delivered} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j received -ns urn:xmpp:receipts -id $oid
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] remote_status
    } -result delivered

test message-marker-displayed-marks-read \
    {a XEP-0333 displayed marker advances the sent message to read} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j displayed -ns urn:xmpp:chat-markers:0 -id $oid
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] remote_status
    } -result read

test message-marker-displayed-then-received-no-regress \
    {a receipt arriving after a displayed marker does not downgrade read} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j displayed -ns urn:xmpp:chat-markers:0 -id $oid
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j received -ns urn:xmpp:receipts -id $oid
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] remote_status
    } -result read

test message-marker-wrong-peer-ignored \
    {a marker from a different peer leaves the sent message untouched} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from carol@example.com/x {
            j displayed -ns urn:xmpp:chat-markers:0 -id $oid
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] remote_status
    } -result none

test message-marker-not-stored-as-message \
    {a marker stanza is consumed, not stored as its own message row} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j received -ns urn:xmpp:receipts -id $oid
        }]
        llength [msg_store_latest alice@example.com]
    } -result 1

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
             [dict get [lindex $all 0] content body] \
             [dict get [lindex $all 1] content body]
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
             [dict get [lindex $all 0] content body] \
             [dict get [lindex $all 1] content body] \
             [dict get [lindex $all 2] content body]
    } -result {3 a b sent}

test message-self-echo-confirms {1:1 self-echo confirms pending, emits Confirmed not New} \
    {*}$msg_common \
    -body {
        # Plaintext-path test — OMEMO defaults on, so disable it here.
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "echo me"
        set msgs [msg_store_latest alice@example.com]
        set oid [dict get [lindex $msgs 0] own_id]

        set patches {}
        set received {}
        tacky listen -tag selfecho message <Confirmed> -jid alice@example.com \
            {apply {{ev} { lappend ::patches $ev }}}
        tacky listen -tag selfecho message <New> -jid alice@example.com \
            {apply {{ev} { lappend ::received $ev }}}

        # Server reflects the message back: from=self, to=contact, same @id
        $::_client conn feed [j message -type chat \
            -from user@test.example.com/res \
            -to alice@example.com \
            -id $oid {
            j body #body "echo me"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-echo1 -by user@test.example.com
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
             [dict get [lindex $patches 0] -server_status]
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
             [dict get [lindex $result 0] content body] \
             [dict get [lindex $result 1] content body]
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
             [dict get [lindex $result 0] content body] \
             [dict get [lindex $result 1] content body]
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
             [dict get [lindex $result 0] content body] \
             [dict get [lindex $result 1] content body] \
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
        list [llength $result] [dict get [lindex $result 0] content body]
    } -result {1 hi}

test message-reply-author-muc {reply_author_jid keeps the room nick for MUC replies} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg \
            timestamp 100 chat_jid room@muc.example.com?join \
            from_jid room@muc.example.com/alice body hi \
            reply_id abc reply_to room@muc.example.com/bob]]
        set m [lindex [msg_history -chat room@muc.example.com?join -limit 1] 0]
        dict get $m reply_author_jid
    } -result {room@muc.example.com/bob}

test message-reply-author-direct {reply_author_jid is bare for 1:1 replies} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg \
            timestamp 100 chat_jid alice@example.com body hi \
            reply_id abc reply_to alice@example.com/phone]]
        set m [lindex [msg_history -chat alice@example.com -limit 1] 0]
        dict get $m reply_author_jid
    } -result {alice@example.com}

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
             [dict get $m1 content body] [dict get $m1 from_jid] \
             [dict get $m1 server_id] [dict get $m1 own_id] \
             [dict get $m1 chat_jid] \
             [expr {[dict get $m1 timestamp] > 0}] \
             [expr {[dict get $m1 raw_xml] ne ""}] \
             [dict get $m2 content body] [dict get $m2 server_id]
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
            [dict get [lindex $::result 0] content body]
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
             [dict get [lindex $result 0] content body] \
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
        list [lmap m $result { dict get $m content body }] \
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
        lmap m $result { dict get $m content body }
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
        list [llength $local] [dict get [lindex $local 0] content body]
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
             [dict get [lindex $msgs 0] content body] \
             [dict get [lindex $msgs 2] content body] \
             [dict get [lindex $msgs end] content body] \
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
             [dict get [lindex $msgs 0] content body] \
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
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
    } -result {1 local-only}

# goto -source remote fetches an island: nothing older than -start was
# queried, and a short page leaves archive above it. Both edges get a hole.

test message-goto-remote-wraps-page-with-holes {a short goto page gets holes on both edges} \
    {*}$msg_common \
    -body {
        tacky message goto -acc $acc -chat alice@example.com \
            -date [ParseTimestamp 2024-06-15T12:00:00Z] \
            -source remote -limit 50 \
            -command [list apply {{r} {}}]
        msg_mam_respond {
            {id sid1 body first stamp 2024-06-15T12:00:00Z}
            {id sid2 body second stamp 2024-06-15T12:05:00Z}
        } -complete false

        set holes [$::_client message messagestore hole list alice@example.com]
        set minTs [ParseTimestamp 2024-06-15T12:00:00Z]
        set maxTs [ParseTimestamp 2024-06-15T12:05:00Z]
        list [llength $holes] \
             [expr {[lindex $holes 0] < $minTs}] \
             [expr {[lindex $holes 1] > $maxTs}]
    } -result {2 1 1}

test message-goto-remote-complete-leaves-newer-edge-open {a goto page reaching the archive end gets no newer hole} \
    {*}$msg_common \
    -body {
        tacky message goto -acc $acc -chat alice@example.com \
            -date [ParseTimestamp 2024-06-15T12:00:00Z] \
            -source remote -limit 50 \
            -command [list apply {{r} {}}]
        msg_mam_respond {
            {id sid1 body first stamp 2024-06-15T12:00:00Z}
            {id sid2 body second stamp 2024-06-15T12:05:00Z}
        } -complete true

        set holes [$::_client message messagestore hole list alice@example.com]
        list [llength $holes] \
             [expr {[lindex $holes 0] < [ParseTimestamp 2024-06-15T12:00:00Z]}]
    } -result {1 1}

test message-goto-remote-sweeps-hole-inside-page {jumping to a search hit sweeps the wrap hole the search left inside the fetched run} \
    {*}$msg_common \
    -body {
        msg_prime_search
        tacky message search -acc $acc -chat alice@example.com \
            -query "needle" -limit 10 -command [list apply {{r} {}}]
        msg_mam_respond {
            {id sid1 body "needle in haystack" stamp 2024-06-15T12:00:00Z}
        } -complete true

        # The jump refetches the hit plus its neighbour, proving that span
        # contiguous and the wrap hole between them false.
        set result {}
        tacky message goto -acc $acc -chat alice@example.com \
            -date [ParseTimestamp 2024-06-15T12:00:00Z] \
            -source remote -limit 50 \
            -command [list apply {{r} { set ::result $r }}]
        msg_mam_respond {
            {id sid1 body "needle in haystack" stamp 2024-06-15T12:00:00Z}
            {id sid2 body after stamp 2024-06-15T12:05:00Z}
        } -complete false

        set holes [$::_client message messagestore hole list alice@example.com]
        list [llength [dict get $result messages]] \
             [llength $holes] \
             [expr {[lindex $holes 0] < [ParseTimestamp 2024-06-15T12:00:00Z]}] \
             [expr {[lindex $holes 1] > [ParseTimestamp 2024-06-15T12:05:00Z]}]
    } -result {2 2 1 1}

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
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
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
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
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
            j stanza-id -ns urn:xmpp:sid:0 -id s1 -by user@test.example.com
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

test message-catchup-emits-no-new {catchup stores without announcing arrivals} \
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
        list $::_count \
             [llength [msg_store_latest alice@example.com]] \
             [llength [msg_store_latest bob@example.com]]
    } -result {0 2 1}

test message-catchup-done-per-chat {CatchupDone fires per chat that gained messages, then account-wide} \
    {*}$msg_common \
    -body {
        set ::_events {}
        tacky listen message <CatchupDone> {apply {{ev} {
            lappend ::_events [dict get $ev -jid]:[dict get $ev -count]
        }}}
        # The first chat already holds s1, so that entry dedups and only
        # its second message counts; the other chat is wholly new.
        msg_store [list [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
            chat_jid alice@example.com server_id s1 body msg1]]
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [mam_result id s1 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg1 stamp 2024-01-01T10:00:00Z] \
            [mam_result id s2 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg2 stamp 2024-01-01T11:00:00Z] \
            [mam_result id s3 queryid $qid \
                from bob@example.com/phone to user@test.example.com \
                body msg3 stamp 2024-01-01T12:00:00Z]]
        set ::_events
    } -result {alice@example.com:1 bob@example.com:1 :2}

test message-catchup-done-skips-untouched-chat {a chat whose page entries all dedup emits no CatchupDone} \
    {*}$msg_common \
    -body {
        set ::_jids {}
        tacky listen message <CatchupDone> {apply {{ev} {
            lappend ::_jids [dict get $ev -jid]
        }}}
        msg_store [list [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
            chat_jid alice@example.com server_id s1 body msg1]]
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [mam_result id s1 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg1 stamp 2024-01-01T10:00:00Z]]
        set ::_jids
    } -result {{}}

test message-catchup-brackets-account-sync {the account sync opens with CatchupStarted and closes with CatchupDone} \
    {*}$msg_common \
    -body {
        set ::_events {}
        foreach ev {<CatchupStarted> <CatchupDone>} {
            tacky listen message $ev [list apply {{name ev} {
                lappend ::_events $name:[dict get $ev -jid]
            }} $ev]
        }
        msg_ready
        set opened $::_events
        msg_catchup_finish {}
        list $opened $::_events
    } -result {<CatchupStarted>: {<CatchupStarted>: <CatchupDone>:}}

test message-catchup-disconnect-closes-bracket {a disconnect settles a sync whose results never arrive} \
    {*}$msg_common \
    -body {
        set ::_events {}
        tacky listen message <CatchupDone> {apply {{ev} {
            lappend ::_events [dict get $ev -jid]:[dict get $ev -count]
        }}}
        msg_ready
        set before $::_events
        # mam discards the pending callback here without invoking it, so
        # nothing else will ever close this bracket.
        $::_client conn fire_disconnect "network gone"
        list $before $::_events
    } -result {{} :0}

test message-muc-catchup-start-carries-room {a room sync opens under the room's jid, not the account's} \
    {*}$msg_common \
    -body {
        set ::_jids {}
        tacky listen message <CatchupStarted> {apply {{ev} {
            lappend ::_jids [dict get $ev -jid]
        }}}
        msg_ready
        msg_catchup_finish {}
        set ::_jids {}
        msg_muc_join room@muc.example.com me
        set ::_jids
    } -result {room@muc.example.com?join}

test message-catchup-still-moves-chatlist {a stored catchup message still updates chat ordering} \
    {*}$msg_common \
    -body {
        set ::_updated {}
        tacky listen chats <Updated> {apply {{ev} {
            lappend ::_updated [dict get $ev -jid]
        }}}
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [mam_result id s1 queryid $qid \
                from alice@example.com/phone to user@test.example.com \
                body msg1 stamp 2024-01-01T10:00:00Z]]
        # chats debounces its emits on `after idle`.
        update idletasks
        set ::_updated
    } -result {alice@example.com}

test message-catchup-still-patches {a reaction in a catchup page still patches in place} \
    {*}$msg_common \
    -body {
        set ::_reactions 0
        tacky listen message <Reactions> {apply {{ev} { incr ::_reactions }}}
        msg_store [list [msg_msg timestamp [ParseTimestamp 2024-01-01T10:00:00Z] \
            chat_jid alice@example.com server_id s1 body target]]
        msg_ready
        set qid [xsearch [mam_catchup_iq] query -ns urn:xmpp:mam:2 -get @queryid]
        msg_catchup_finish [list \
            [j result -ns urn:xmpp:mam:2 -id r1 -queryid $qid {
                j forwarded -ns urn:xmpp:forward:0 {
                    j delay -ns urn:xmpp:delay -stamp 2024-01-01T11:00:00Z
                    j message -from alice@example.com/phone \
                            -to user@test.example.com {
                        j reactions -ns urn:xmpp:reactions:0 -id s1 {
                            j reaction #body 👍
                        }
                    }
                }
            }]]
        set ::_reactions
    } -result {1}

test message-muc-catchup-on-join {joining a room queries its own archive} \
    {*}$msg_common \
    -body {
        msg_ready
        msg_muc_join room@muc.example.com me
        set iq [mam_iq_to room@muc.example.com]
        set qnode [lindex [xsearch $iq query -ns urn:xmpp:mam:2] 0]
        set hasWith [expr {[xsearch $qnode x field @var with] ne ""}]
        list [expr {$iq ne ""}] [expr {!$hasWith}] \
             [expr {[xsearch $iq query set before] ne ""}]
    } -result {1 1 1}

test message-muc-catchup-stores-under-join-jid {room catchup stores under the ?join chat JID} \
    {*}$msg_common \
    -body {
        msg_ready
        msg_muc_join room@muc.example.com me
        set iq [mam_iq_to room@muc.example.com]
        set qid [xsearch $iq query -ns urn:xmpp:mam:2 -get @queryid]
        msg_mam_finish $iq [list \
            [mam_result id r1 queryid $qid \
                from room@muc.example.com/alice type groupchat \
                body "room msg" stamp 2024-01-01T10:00:00Z]]
        list [llength [msg_store_latest room@muc.example.com?join]] \
             [llength [msg_store_latest room@muc.example.com]] \
             [dict get [lindex [msg_store_latest room@muc.example.com?join] 0] \
                content body]
    } -result {1 0 {room msg}}

test message-muc-catchup-done-carries-room {room catchup settles with the room's jid} \
    {*}$msg_common \
    -body {
        set ::_events {}
        tacky listen message <CatchupDone> {apply {{ev} {
            lappend ::_events [dict get $ev -jid]:[dict get $ev -count]
        }}}
        msg_ready
        msg_catchup_finish {}
        set ::_events {}
        msg_muc_join room@muc.example.com me
        set iq [mam_iq_to room@muc.example.com]
        set qid [xsearch $iq query -ns urn:xmpp:mam:2 -get @queryid]
        msg_mam_finish $iq [list \
            [mam_result id r1 queryid $qid \
                from room@muc.example.com/alice type groupchat \
                body "room msg" stamp 2024-01-01T10:00:00Z]]
        set ::_events
    } -result {room@muc.example.com?join:1}

test message-muc-catchup-incomplete-places-hole {an incomplete room catchup leaves an older-edge hole} \
    {*}$msg_common \
    -body {
        msg_ready
        msg_muc_join room@muc.example.com me
        set iq [mam_iq_to room@muc.example.com]
        set qid [xsearch $iq query -ns urn:xmpp:mam:2 -get @queryid]
        msg_mam_finish $iq [list \
            [mam_result id r1 queryid $qid \
                from room@muc.example.com/alice type groupchat \
                body "room msg" stamp 2024-01-01T10:00:00Z]] false
        llength [$::_client message messagestore hole list \
            room@muc.example.com?join]
    } -result {1}

test message-muc-catchup-dedups-join-replay {a replayed message already stored is not duplicated} \
    {*}$msg_common \
    -body {
        msg_ready
        msg_muc_join room@muc.example.com me
        # The room replays a message before the catchup page lands.
        $::_client conn feed [j message -type groupchat \
            -from room@muc.example.com/alice {
            j body #body "room msg"
            j stanza-id -ns urn:xmpp:sid:0 -id r1 -by room@muc.example.com
            j delay -ns urn:xmpp:delay -stamp 2024-01-01T10:00:00Z
        }]
        set iq [mam_iq_to room@muc.example.com]
        set qid [xsearch $iq query -ns urn:xmpp:mam:2 -get @queryid]
        msg_mam_finish $iq [list \
            [mam_result id r1 queryid $qid \
                from room@muc.example.com/alice type groupchat \
                body "room msg" stamp 2024-01-01T10:00:00Z]]
        llength [msg_store_latest room@muc.example.com?join]
    } -result {1}

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
             [dict get [lindex $msgs 0] content body] \
             [dict get [lindex $msgs 0] server_id] \
             [dict get [lindex $msgs 1] content body] \
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
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
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

# Search: source local (synchronous LIKE over the local store)

test message-search-local-basic {source local returns matching message dicts newest-first with complete/last} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 body {find me}] \
            [msg_msg timestamp 200 body {find me too}] \
            [msg_msg timestamp 300 body other]]
        set r [msg_search -chat alice@example.com -query {find me} -source local]
        list [lmap m [dict get $r messages] {dict get $m timestamp}] \
             [dict get [lindex [dict get $r messages] 0] content body] \
             [dict get $r complete] \
             [dict get $r last]
    } -result {{200 100} {find me too} 1 100}

test message-search-local-complete-flag {source local marks complete false and reports last when the limit is hit} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 body x1] \
            [msg_msg timestamp 200 body x2] \
            [msg_msg timestamp 300 body x3]]
        set r [msg_search -chat alice@example.com -query x -source local -limit 2]
        list [lmap m [dict get $r messages] {dict get $m timestamp}] \
             [dict get $r complete] \
             [dict get $r last]
    } -result {{300 200} 0 200}

test message-search-local-before {source local -before pages to older matches} \
    {*}$msg_common \
    -body {
        msg_store [list \
            [msg_msg timestamp 100 body x1] \
            [msg_msg timestamp 200 body x2] \
            [msg_msg timestamp 300 body x3]]
        set r [msg_search -chat alice@example.com -query x -source local -before 300]
        lmap m [dict get $r messages] {dict get $m timestamp}
    } -result {200 100}

# XEP-0461 replies: ingest parsing + gotoReply

test message-live-reply-fields {reply target id + author parsed into stored fields} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id origA -from alice@example.com/phone {
            j body #body "my reply"
            j stanza-id -ns urn:xmpp:sid:0 -id srvA -by user@test.example.com
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
            j stanza-id -ns urn:xmpp:sid:0 -id srvRF3 -by user@test.example.com
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
            j stanza-id -ns urn:xmpp:sid:0 -id srvRF2 -by user@test.example.com
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
            j stanza-id -ns urn:xmpp:sid:0 -id srvX -by user@test.example.com
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
            j stanza-id -ns urn:xmpp:sid:0 -id srvB -by user@test.example.com
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
            j stanza-id -ns urn:xmpp:sid:0 -id SRV-TGT -by user@test.example.com
        }]
        $::_client conn feed [j message -type chat -id r1 -from alice@example.com/phone {
            j body #body "the reply"
            j stanza-id -ns urn:xmpp:sid:0 -id SRV-RPL -by user@test.example.com
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id SRV-TGT
        }]
        set ::_gr {}
        tacky message gotoReply -acc $acc -chat alice@example.com \
            -reply_id SRV-TGT -reply_to alice@example.com -source local \
            -command [list apply {{r} {set ::_gr $r}}]
        set bodies {}
        foreach m [dict get $::_gr messages] { lappend bodies [dict get $m content body] }
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
            j stanza-id -ns urn:xmpp:sid:0 -id SRV1 -by user@test.example.com
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
             [dict get $stored content body] \
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

# The GUI tracks the conversation tail from the pushed message <Tail> event
# instead of polling maxTimestamp (which only resolves inline in the direct
# transport). A live insert must push the current newest timestamp.
test message-tail-emitted-on-live \
    {a live message emits message <Tail> carrying the newest timestamp} \
    {*}$msg_common \
    -body {
        set ::_tail ""
        tacky listen message <Tail> -jid alice@example.com \
            {apply {{ev} { set ::_tail [dict get $ev -timestamp] }}}
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "hi"
        }]
        expr {$::_tail ne ""
            && $::_tail == [$::_client message maxTimestamp -chat alice@example.com]}
    } -result 1

# The confirmation rekey (echo stamp replaces the local send stamp) can move
# the tail, so HandleConfirmation must re-push <Tail> with the corrected max.
test message-tail-repushed-on-confirm-move \
    {a self-echo that moves the pending row's timestamp re-emits message <Tail>} \
    {*}$msg_common \
    -body {
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "echo me"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        set ::_tail ""
        tacky listen -tag tailmove message <Tail> -jid alice@example.com \
            {apply {{ev} { set ::_tail [dict get $ev -timestamp] }}}
        $::_client conn feed [j message -type chat \
            -from user@test.example.com/res -to alice@example.com -id $oid {
            j body #body "echo me"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-echo-tail -by user@test.example.com
        }]
        tacky unlisten tailmove
        expr {$::_tail ne ""
            && $::_tail == [$::_client message maxTimestamp -chat alice@example.com]}
    } -result 1

# XEP-0184/0333 marker sending.

# Id of the first written marker <element> in namespace $ns, or "".
proc msg_written_marker {element ns} {
    foreach s [$::_client conn get_written] {
        set id [xsearch $s $element -ns $ns -get @id]
        if {$id ne ""} { return $id }
    }
    return ""
}

# Count of written <message> stanzas bearing <element xmlns=ns>.
proc msg_written_marker_count {element ns} {
    set n 0
    foreach s [$::_client conn get_written] {
        if {[llength [xsearch $s $element -ns $ns]] > 0} { incr n }
    }
    return $n
}

test message-autoreceipt-request \
    {incoming <request> triggers a XEP-0184 received echoing the message id} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id m1 -from alice@example.com/phone {
            j body #body hi
            j request -ns urn:xmpp:receipts
        }]
        msg_written_marker received urn:xmpp:receipts
    } -result m1

test message-autoreceipt-markable \
    {incoming <markable> triggers a XEP-0333 received echoing the message id} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id m2 -from alice@example.com/phone {
            j body #body hi
            j markable -ns urn:xmpp:chat-markers:0
        }]
        msg_written_marker received urn:xmpp:chat-markers:0
    } -result m2

test message-autoreceipt-none \
    {a plain message triggers no receipt} \
    {*}$msg_common \
    -body {
        $::_client conn feed [j message -type chat -id m3 -from alice@example.com/phone {
            j body #body hi
        }]
        list [msg_written_marker_count received urn:xmpp:receipts] \
             [msg_written_marker_count received urn:xmpp:chat-markers:0]
    } -result {0 0}

test message-autoreceipt-disabled \
    {send_chat_markers=0 suppresses the auto receipt} \
    {*}$msg_common \
    -body {
        [$::_client cget -taco] setting set -key send_chat_markers -value 0
        $::_client conn feed [j message -type chat -id m4 -from alice@example.com/phone {
            j body #body hi
            j request -ns urn:xmpp:receipts
        }]
        msg_written_marker_count received urn:xmpp:receipts
    } -result 0

test message-markdisplayed-sends \
    {markDisplayed sends a displayed marker referencing the stored origin id} \
    {*}$msg_common \
    -body {
        msg_store [list [msg_msg timestamp 5000000 origin_id oid9]]
        tacky message markDisplayed -acc $acc \
            -chat alice@example.com -timestamp 5000000
        msg_written_marker displayed urn:xmpp:chat-markers:0
    } -result oid9

test message-markdisplayed-muc-noop \
    {markDisplayed is a no-op for MUC chats} \
    {*}$msg_common \
    -body {
        tacky message markDisplayed -acc $acc \
            -chat room@conf.example.com?join -timestamp 6000000
        msg_written_marker_count displayed urn:xmpp:chat-markers:0
    } -result 0

test message-markdisplayed-disabled \
    {send_chat_markers=0 suppresses the displayed marker} \
    {*}$msg_common \
    -body {
        [$::_client cget -taco] setting set -key send_chat_markers -value 0
        msg_store [list [msg_msg timestamp 7000000 origin_id oid7]]
        tacky message markDisplayed -acc $acc \
            -chat alice@example.com -timestamp 7000000
        msg_written_marker_count displayed urn:xmpp:chat-markers:0
    } -result 0

test message-outgoing-requests-markers \
    {1:1 outgoing message asks for delivery and read markers} \
    {*}$msg_common \
    -body {
        set s [$::_client message BuildMessageStanza wire \
            alice@example.com body oid1 chat alice@example.com ""]
        list [llength [xsearch $s request -ns urn:xmpp:receipts]] \
             [llength [xsearch $s markable -ns urn:xmpp:chat-markers:0]]
    } -result {1 1}

test message-outgoing-groupchat-no-markers \
    {groupchat outgoing omits receipt/marker requests} \
    {*}$msg_common \
    -body {
        set s [$::_client message BuildMessageStanza wire \
            room@conf.example.com body oid2 groupchat room@conf.example.com ""]
        list [llength [xsearch $s request -ns urn:xmpp:receipts]] \
             [llength [xsearch $s markable -ns urn:xmpp:chat-markers:0]]
    } -result {0 0}

# =============================================================================
# Reactions (XEP-0444)
# =============================================================================

test message-classify-reaction {a reactions stanza is recognised as a reaction control kind} \
    {*}$msg_common -body {
        set n [j message -from bob@example.com/x -type chat {
            j reactions -ns urn:xmpp:reactions:0 -id abc { j reaction #body 👍 }
        }]
        ClassifyMessage $n ""
    } -result reaction

test message-reaction-incoming-1to1 {a peer reaction aggregates onto the target message} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j reactions -ns urn:xmpp:reactions:0 -id $oid { j reaction #body 👍 }
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] reactions
    } -result {👍 {reactors alice@example.com mine 0}}

test message-react-sends-reactions {react writes a <reactions> carrying the emoji and a store hint} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message react -acc $acc -chat alice@example.com -timestamp $ts -emoji 👍
        set stanza [lindex [$::_client conn get_written] end]
        list [xsearch $stanza reactions -ns urn:xmpp:reactions:0 reaction -get body] \
             [llength [xsearch $stanza store -ns urn:xmpp:hints]]
    } -result {👍 1}

test message-react-own-shows-mine {our own reaction is marked mine on the message} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message react -acc $acc -chat alice@example.com -timestamp $ts -emoji 👍
        dict get [lindex [msg_store_latest alice@example.com] 0] reactions
    } -result {👍 {reactors user@test.example.com mine 1}}

test message-react-toggle-off-retracts {toggling the same emoji twice sends an empty reactions set} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message react -acc $acc -chat alice@example.com -timestamp $ts -emoji 👍
        tacky message react -acc $acc -chat alice@example.com -timestamp $ts -emoji 👍
        set stanza [lindex [$::_client conn get_written] end]
        list [llength [xsearch $stanza reactions -ns urn:xmpp:reactions:0 reaction]] \
             [dict exists [lindex [msg_store_latest alice@example.com] 0] reactions]
    } -result {0 0}

test message-reaction-from-mam {a reaction arriving via MAM catchup aggregates onto the target} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        set rn [j result -ns urn:xmpp:mam:2 -id arch-r {
            j forwarded -ns urn:xmpp:forward:0 {
                j delay -ns urn:xmpp:delay -stamp 2024-01-02T00:00:00Z
                j message -type chat -from alice@example.com/phone -to $acc {
                    j reactions -ns urn:xmpp:reactions:0 -id $oid {
                        j reaction #body 👍
                    }
                }
            }
        }]
        $::_client message OnCatchup [dict create messages [list $rn] complete 1]
        dict get [lindex [msg_store_latest alice@example.com] 0] reactions
    } -result {👍 {reactors alice@example.com mine 0}}

test message-reaction-mam-parsed-has-timestamp \
    {a reaction in a scroll-back MAM page carries a timestamp so hole-sweep can span it} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        set rn [j result -ns urn:xmpp:mam:2 -id arch-r {
            j forwarded -ns urn:xmpp:forward:0 {
                j delay -ns urn:xmpp:delay -stamp 2024-01-02T00:00:00Z
                j message -type chat -from alice@example.com/phone -to $acc {
                    j reactions -ns urn:xmpp:reactions:0 -id $oid {
                        j reaction #body 👍
                    }
                }
            }
        }]
        lassign [$::_client message IngestMamBatch alice@example.com \
            [dict create messages [list $rn]]] parsed toStore
        # SweepFetchedRange / PlaceFarEdgeHole lmap `dict get $m timestamp`
        # over parsed; a reaction disp lacking the key would throw here.
        list [llength [lmap m $parsed {dict get $m timestamp}]] [llength $toStore]
    } -result {1 0}

# --- Edits (XEP-0308) / retractions (XEP-0424), 1:1 ------------------------

test message-edit-incoming-1to1 {a peer correction swaps the body and marks edited} \
    {*}$msg_common -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m1 {
            j origin-id -ns urn:xmpp:sid:0 -id m1
            j body #body "helo"
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m2 {
            j replace -ns urn:xmpp:message-correct:0 -id m1
            j body #body "hello world"
        }]
        set m [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $m content body] [dict get $m edited] \
             [llength [msg_store_latest alice@example.com]]
    } -result {{hello world} 1 1}

# Feed an incoming message the decrypt path's way: `decrypted` and `sender_fp`
# ride the node dict, not the XML.
proc msg_feed_decrypted {id body fp {replaceId ""}} {
    set node [j message -type chat -from alice@example.com/phone -id $id {
        j origin-id -ns urn:xmpp:sid:0 -id $id
        j body #body $body
        if {$replaceId ne ""} {
            j replace -ns urn:xmpp:message-correct:0 -id $replaceId
        }
    }]
    dict set node decrypted 1
    dict set node sender_fp $fp
    $::_client conn feed $node
}

# A correction inherits the target row's padlock, so an unencrypted one must
# not rewrite an encrypted message: authorship alone is server-asserted.
test message-edit-cleartext-cannot-rewrite-omemo \
    {a cleartext correction of an OMEMO message is not applied in place} \
    {*}$msg_common -body {
        msg_feed_decrypted m1 "secret" "aabb ccdd"
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m2 {
            j replace -ns urn:xmpp:message-correct:0 -id m1
            j body #body "attacker text"
        }]
        set rows [msg_store_latest alice@example.com]
        set m [lindex $rows 0]
        list [dict get $m content body] [dict get $m encryption] \
             [dict get $m edited] [llength $rows]
    } -result {secret omemo 0 2}

test message-edit-other-identity-cannot-rewrite-omemo \
    {an encrypted correction from a different sender identity is not applied} \
    {*}$msg_common -body {
        msg_feed_decrypted m1 "secret" "aabb ccdd"
        msg_feed_decrypted m2 "attacker text" "eeff 0011" m1
        set rows [msg_store_latest alice@example.com]
        set m [lindex $rows 0]
        list [dict get $m content body] [dict get $m edited] [llength $rows]
    } -result {secret 0 2}

test message-edit-same-identity-rewrites-omemo \
    {an encrypted correction from the same sender identity swaps the body} \
    {*}$msg_common -body {
        msg_feed_decrypted m1 "helo" "aabb ccdd"
        msg_feed_decrypted m2 "hello world" "aabb ccdd" m1
        set rows [msg_store_latest alice@example.com]
        set m [lindex $rows 0]
        list [dict get $m content body] [dict get $m encryption] \
             [dict get $m edited] [llength $rows]
    } -result {{hello world} omemo 1 1}

test message-edit-own-1to1 {editing our own message swaps its body and marks edited} \
    {*}$msg_common -body {
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "helo"
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message edit -acc $acc -chat alice@example.com -timestamp $ts -body "hello"
        set m [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $m content body] [dict get $m edited]
    } -result {hello 1}

test message-edit-sends-replace {edit puts <replace> referencing the original id on the wire} \
    {*}$msg_common -body {
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $acc -chat alice@example.com -body "helo"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message edit -acc $acc -chat alice@example.com -timestamp $ts -body "hello"
        set stanza [lindex [$::_client conn get_written] end]
        list [expr {[xsearch $stanza replace -ns urn:xmpp:message-correct:0 -get @id] eq $oid}] \
             [xsearch $stanza body -get body]
    } -result {1 hello}

test message-edit-preserves-reaction-target \
    {a reaction still resolves onto a message after it is edited} \
    {*}$msg_common -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m1 {
            j origin-id -ns urn:xmpp:sid:0 -id m1
            j body #body "hi"
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j replace -ns urn:xmpp:message-correct:0 -id m1
            j body #body "hi there"
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j reactions -ns urn:xmpp:reactions:0 -id m1 { j reaction #body 👍 }
        }]
        dict get [lindex [msg_store_latest alice@example.com] 0] reactions
    } -result {👍 {reactors alice@example.com mine 0}}

test message-retract-incoming-1to1 {a peer self-retraction tombstones the message} \
    {*}$msg_common -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m1 {
            j origin-id -ns urn:xmpp:sid:0 -id m1
            j body #body "secret"
        }]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j retract -ns urn:xmpp:message-retract:1 -id m1
        }]
        set m [lindex [msg_store_latest alice@example.com] 0]
        list [dict get $m retracted] [llength [msg_store_latest alice@example.com]]
    } -result {1 1}

test message-retract-own-1to1 {retract tombstones our message and sends <retract>} \
    {*}$msg_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "oops"
        set oid [dict get [lindex [msg_store_latest alice@example.com] 0] own_id]
        set ts [dict get [lindex [msg_store_latest alice@example.com] 0] timestamp]
        tacky message retract -acc $acc -chat alice@example.com -timestamp $ts
        set stanza [lindex [$::_client conn get_written] end]
        set m [lindex [msg_store_latest alice@example.com] 0]
        list [expr {[xsearch $stanza retract -ns urn:xmpp:message-retract:1 -get @id] eq $oid}] \
             [dict get $m retracted]
    } -result {1 1}

# Helper: store an incoming room message and return its timestamp. Enters via
# ingestLive, the same door the MUC module uses for groupchat.
proc msg_feed_room {{id srv1}} {
    $::_client message ingestLive room@conf.example.com?join \
        [j message -type groupchat -from room@conf.example.com/bob {
            j body #body "spam"
            j stanza-id -ns urn:xmpp:sid:0 -id $id -by room@conf.example.com
        }]
    dict get [lindex [msg_store_latest room@conf.example.com?join] 0] timestamp
}

# Helper: reply to the last written IQ with an error condition.
proc msg_fail_last_iq {condition} {
    set req [lindex [$::_client conn get_written] end]
    $::_client iq feed [j iq -type error -id [xsearch $req -get @id] \
        -from room@conf.example.com {
        j error -type auth {
            j $condition -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }
    }]
}

test message-moderate-sends-request {moderate asks the room to retract by stanza-id} \
    {*}$msg_common -body {
        set ts [msg_feed_room srv1]
        tacky message moderate -acc $acc -chat room@conf.example.com?join \
            -timestamp $ts -reason spam
        set req [lindex [$::_client conn get_written] end]
        list [xsearch $req moderate -ns urn:xmpp:message-moderate:1 -get @id] \
             [xsearch $req moderate reason -get body]
    } -result {srv1 spam}

test message-moderate-error-maps-condition \
    {a rejected moderation request reports friendly text} \
    {*}$msg_common -body {
        set ts [msg_feed_room srv1]
        set got ""
        tacky message moderate -acc $acc -chat room@conf.example.com?join \
            -timestamp $ts -onerror [list apply {{msg} { set ::got $msg }}]
        msg_fail_last_iq forbidden
        set got
    } -result {You do not have permission to delete messages in this room}

test message-moderate-error-unknown-condition {an unmapped condition still reports} \
    {*}$msg_common -body {
        set ts [msg_feed_room srv1]
        set got ""
        tacky message moderate -acc $acc -chat room@conf.example.com?join \
            -timestamp $ts -onerror [list apply {{msg} { set ::got $msg }}]
        msg_fail_last_iq service-unavailable
        set got
    } -result {The message could not be deleted}

test message-moderate-rejection-leaves-message-intact \
    {a rejected moderation request does not tombstone the message} \
    {*}$msg_common -body {
        set ts [msg_feed_room srv1]
        tacky message moderate -acc $acc -chat room@conf.example.com?join \
            -timestamp $ts -onerror [list apply {{msg} {}}]
        msg_fail_last_iq forbidden
        dict get [lindex [msg_store_latest room@conf.example.com?join] 0] retracted
    } -result {0}

test message-moderate-success-is-silent {a successful moderation request does not report an error} \
    {*}$msg_common -body {
        set ts [msg_feed_room srv1]
        set got none
        tacky message moderate -acc $acc -chat room@conf.example.com?join \
            -timestamp $ts -onerror [list apply {{msg} { set ::got $msg }}]
        set req [lindex [$::_client conn get_written] end]
        $::_client iq feed [j iq -type result -id [xsearch $req -get @id] \
            -from room@conf.example.com]
        set got
    } -result {none}
