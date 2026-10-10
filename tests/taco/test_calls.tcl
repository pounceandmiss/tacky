# Unit tests for taco_calls
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers

set calls_env [tacky_env -mock conn -capture-emit 1 -taco-args {-media-backend rtc} -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
} -bound-jid user@test.example.com/res]

set PEER peer@example.com/phone

# -- Helpers --

# The JMI action carried by a written message, with its sid.
proc calls_jmi_sent {stanza} {
    set ns urn:xmpp:jingle-message:0
    foreach action {propose proceed ringing reject retract} {
        set child [xsearch $stanza $action -ns $ns -get node]
        if {$child ne ""} { return [list $action [xsearch $child -get @id]] }
    }
    return ""
}

proc calls_error_condition {stanza} {
    set node [xsearch $stanza error * \
        -ns urn:ietf:params:xml:ns:xmpp-stanzas -get node]
    if {$node eq ""} { return "" }
    return [dict get $node tag]
}

# Accept an inbound propose, leaving the call proceeded with no pc yet.
proc calls_accepted {sid peer} {
    c.conn feed [calls_jmi_in propose $sid $peer]
    c.calls accept -sid $sid
    c.conn clear
}

proc calls_session_iq {action sid from} {
    j iq -type set -from $from -to user@test.example.com -id si1 {
        j jingle -ns urn:xmpp:jingle:1 -action $action -sid $sid {
            j content -creator initiator -name audio {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                }
            }
        }
    }
}

proc calls_transport_info_flood {sid from count} {
    j iq -type set -from $from -to user@test.example.com -id ti2 {
        j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
            j content -creator initiator -name audio {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 {
                    for {set i 1} {$i <= $count} {incr i} {
                        j candidate -foundation $i -component 1 -protocol udp \
                            -priority 2122260222 -ip 192.0.2.1 \
                            -port [expr {50000 + $i}] -type host
                    }
                }
            }
        }
    }
}

proc calls_transport_info {sid from} {
    j iq -type set -from $from -to user@test.example.com -id ti1 {
        j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
            j content -creator initiator -name audio {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 {
                    j candidate -foundation 1 -component 1 -protocol tcp \
                        -priority 2122260223 -ip 192.0.2.9 -port 9 -type host
                    j candidate -foundation 2 -component 1 -protocol udp \
                        -priority 2122260222 -ip 192.0.2.1 -port 54321 -type host
                }
            }
        }
    }
}

# -- Outbound JMI --

test calls-start-proposes {start rings the bare JID and emits <Outgoing>} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com/phone]
        set m [calls_last_written]
        set desc [xsearch $m propose description \
            -ns urn:xmpp:jingle:apps:rtp:1 -get @media]
        string map [list $sid SID] [list \
            [regexp {^tk-[0-9a-f]{32}$} $sid] \
            [calls_jmi_sent $m] \
            [xsearch $m -get @to] \
            $desc \
            [calls_events]]
    } -result [list 1 {propose SID} peer@example.com audio \
        {{<Outgoing> -sid SID -to peer@example.com}}]

test calls-hangup-while-proposed-retracts {a call cancelled before proceed retracts} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        c.calls hangup -sid $sid
        string map [list $sid SID] [list \
            [calls_jmi_sent [calls_last_written]] \
            [dict exists [calls_state] $sid] \
            [lindex [calls_events] end]]
    } -result [list {retract SID} 0 {<Ended> -sid SID}]

test calls-reject-while-proposed-retracts {rejecting a call we placed retracts it} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        c.calls reject -sid $sid
        string map [list $sid SID] [list \
            [calls_jmi_sent [calls_last_written]] \
            [dict exists [calls_state] $sid] \
            [lindex [calls_events] end]]
    } -result [list {retract SID} 0 {<Ended> -sid SID}]

# -- Inbound JMI --

test calls-propose-alerts {an inbound propose replies <ringing> and emits <Incoming>} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in1 $::PEER]
        list \
            [calls_jmi_sent [calls_last_written]] \
            [dict get [dict get [calls_state] tk-in1] state] \
            [calls_events]
    } -result {{ringing tk-in1} ringing {{<Incoming> -sid tk-in1 -from peer@example.com -video 0}}}

test calls-propose-from-room-occupant-ignored {a propose from an occupant of a room we know never rings} \
    {*}$calls_env -body {
        c db eval {
            INSERT INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 0, 'me', '')
        }
        c muc join -jid other@muc.example.com -nick me
        c.conn clear
        c.conn feed [calls_jmi_in propose tk-r1 room@muc.example.com/eve]
        c.conn feed [calls_jmi_in propose tk-r2 other@muc.example.com/eve]
        set out [list [calls_state] [c.conn get_written] [calls_events]]
        c.conn feed [calls_jmi_in propose tk-r3 $::PEER]
        lappend out [dict exists [calls_state] tk-r3]
    } -result {{} {} {} 1}

test calls-propose-carbon-ignored {our own propose carboned back is not a new call} \
    {*}$calls_env -body {
        c.conn clear
        c.conn feed [calls_jmi_in propose tk-in2 user@test.example.com/other]
        list [calls_state] [c.conn get_written] [calls_events]
    } -result {{} {} {}}

test calls-propose-duplicate-ignored {a repeated sid does not re-ring} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in3 $::PEER]
        c.conn clear
        c.conn feed [calls_jmi_in propose tk-in3 $::PEER]
        list [c.conn get_written] [llength [calls_events]]
    } -result {{} 1}

test calls-accept-proceeds {accept answers <proceed> and latches proceeded} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in4 $::PEER]
        c.conn clear
        c.calls accept -sid tk-in4
        list \
            [calls_jmi_sent [calls_last_written]] \
            [dict get [dict get [calls_state] tk-in4] state]
    } -result {{proceed tk-in4} proceeded}

test calls-reject-declines {reject answers <reject>, ends the call and forgets it} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in5 $::PEER]
        c.conn clear
        c.calls reject -sid tk-in5
        list \
            [calls_jmi_sent [calls_last_written]] \
            [dict exists [calls_state] tk-in5] \
            [lindex [calls_events] end]
    } -result {{reject tk-in5} 0 {<Ended> -sid tk-in5}}

# -- Multi-device carbons --

test calls-proceed-by-sibling-ends-ring {another of our resources answering stops our ring} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in6 $::PEER]
        c.conn clear
        c.conn feed [calls_jmi_in proceed tk-in6 user@test.example.com/desktop]
        list \
            [dict exists [calls_state] tk-in6] \
            [lindex [calls_events] end]
    } -result {0 {<Ended> -sid tk-in6}}

test calls-reject-by-sibling-ends-ring {another of our resources declining stops our ring} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in7 $::PEER]
        c.conn clear
        c.conn feed [calls_jmi_in reject tk-in7 user@test.example.com/desktop]
        list \
            [dict exists [calls_state] tk-in7] \
            [lindex [calls_events] end]
    } -result {0 {<Ended> -sid tk-in7}}

# -- Crossing proposes (XEP-0353 §4.1) --

# The reject a written message carries: {sid reason tie-break?}.
proc calls_reject_sent {stanza} {
    set r [xsearch $stanza reject -ns urn:xmpp:jingle-message:0 -get node]
    if {$r eq ""} { return "" }
    set reason [xsearch $r reason -ns urn:xmpp:jingle:1 * -get node]
    list [xsearch $r -get @id] [expr {$reason eq "" ? "" : [dict get $reason tag]}] \
        [expr {[xsearch $r tie-break -get node] ne ""}]
}

# Our sids are tk-<hex>: zz-... sorts above them, aa-... below.
test calls-crossing-propose-ours-wins {a crossing propose with a higher sid is rejected as a tie-break and never rings} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        c.conn feed [calls_jmi_in propose zz-in $::PEER]
        set w [calls_last_written]
        string map [list $sid SID] [list [xsearch $w -get @to] [calls_reject_sent $w] \
            [dict keys [calls_state]] [dict get [calls_state] $sid state] \
            [lmap e [calls_events] { lindex $e 0 }]]
    } -result [list $PEER {zz-in expired 1} SID proposed <Outgoing>]

test calls-crossing-propose-theirs-wins {a crossing propose with a lower sid ends ours and rings} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        c.conn feed [calls_jmi_in propose aa-in $::PEER]
        string map [list $sid SID] [list [lmap w [c.conn get_written] { calls_jmi_sent $w }] \
            [dict keys [calls_state]] [lrange [calls_events] 1 end]]
    } -result [list {{ringing aa-in}} aa-in \
        [list {<Ended> -sid SID} {<Incoming> -sid aa-in -from peer@example.com -video 0}]]

test calls-crossing-propose-equal-sid-lower-jid {crossing proposes with the same sid: the lower JID wins} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        # peer@... sorts below user@...: theirs wins.
        c.conn feed [calls_jmi_in propose $sid $::PEER]
        set lower [list [dict get [calls_state] $sid initiator] [lindex [calls_events] end 0]]
        set sid2 [c.calls start -to zed@example.com]
        c.conn clear
        # zed@... sorts above user@...: ours wins.
        c.conn feed [calls_jmi_in propose $sid2 zed@example.com/x]
        string map [list $sid2 SID] [list $lower [calls_reject_sent [calls_last_written]] \
            [dict get [calls_state] $sid2 initiator]]
    } -result {{0 <Incoming>} {SID expired 1} 1}

test calls-tie-break-reject-ends-ours {a reject with <tie-break/> ends our proposed call} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn feed [j message -from $::PEER -to user@test.example.com -type chat {
            j reject -ns urn:xmpp:jingle-message:0 -id $sid {
                j reason -ns urn:xmpp:jingle:1 { j expired }
                j tie-break
            }
        }]
        string map [list $sid SID] [list [dict exists [calls_state] $sid] \
            [lindex [calls_events] end]]
    } -result {0 {<Ended> -sid SID}}

test calls-propose-from-another-contact-still-rings {calling one contact, another's propose rings as before} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn feed [calls_jmi_in propose aa-other other@example.com/x]
        list [dict get [calls_state] $sid state] [dict get [calls_state] aa-other state]
    } -result {proposed ringing}

# A <reject> with <tie-break/>, as the winner of crossing proposes sends.
proc calls_tie_break_in {sid from} {
    j message -from $from -to user@test.example.com -type chat {
        j reject -ns urn:xmpp:jingle-message:0 -id $sid {
            j reason -ns urn:xmpp:jingle:1 { j expired }
            j tie-break
        }
    }
}

test calls-tie-break-reject-from-stranger-ignored {a <tie-break/> reject from someone we are not calling leaves our call} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn feed [calls_tie_break_in $sid stranger@example.com/x]
        list [dict get [calls_state] $sid state] [lmap e [calls_events] { lindex $e 0 }]
    } -result {proposed <Outgoing>}

# Another device of ours won the crossing; the carbon of its <tie-break/>
# reject stops the ring here.
test calls-tie-break-by-sibling-ends-ring {our other device rejecting the peer's propose as a tie-break stops our ring} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose zz-in $::PEER]
        c.conn feed [calls_tie_break_in zz-in user@test.example.com/desktop]
        list [dict exists [calls_state] zz-in] [lindex [calls_events] end]
    } -result {0 {<Ended> -sid zz-in}}

test calls-crossing-propose-against-two-of-ours {a crossing propose must beat every propose of ours to that contact} \
    {*}$calls_env -body {
        set a [c.calls start -to peer@example.com]
        set b [c.calls start -to peer@example.com]
        lassign [lsort [list $a $b]] lo hi
        c.conn clear
        # Between ours: the lower of ours wins; neither ends.
        c.conn feed [calls_jmi_in propose ${lo}0 $::PEER]
        set between [list [lindex [calls_reject_sent [calls_last_written]] 2] \
            [expr {[lsort [dict keys [calls_state]]] eq [list $lo $hi]}] \
            [expr {"<Ended>" in [lmap e [calls_events] { lindex $e 0 }]}]]
        # Below both: theirs wins, and both of ours end.
        c.conn feed [calls_jmi_in propose aa-in $::PEER]
        list $between [dict keys [calls_state]] \
            [llength [lsearch -all [lmap e [calls_events] { lindex $e 0 }] <Ended>]]
    } -result {{1 1 0} aa-in 2}

# -- Sender binding --

test calls-ringing-binds-to-peer {only the called account's resources may report ringing} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn feed [calls_jmi_in ringing $sid stranger@example.com/x]
        set afterStranger [llength [calls_events]]
        c.conn feed [calls_jmi_in ringing $sid $::PEER]
        string map [list $sid SID] [list $afterStranger [lindex [calls_events] end]]
    } -result [list 1 {<Ringing> -sid SID}]

test calls-session-initiate-hides-unknown-sid \
    {a guessed sid and a wrong sender get the same answer} \
    {*}$calls_env -body {
        calls_accepted tk-in8 $::PEER
        c.conn feed [calls_session_iq session-initiate tk-nosuch $::PEER]
        set unknown [calls_error_condition [calls_last_written]]
        c.conn feed [calls_session_iq session-initiate tk-in8 stranger@example.com/x]
        set stranger [calls_error_condition [calls_last_written]]
        list $unknown $stranger
    } -result {item-not-found item-not-found}

# -- IQ ordering --

test calls-session-initiate-needs-proceed {a session-initiate we never agreed to is out of order} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in9 $::PEER]
        c.conn clear
        c.conn feed [calls_session_iq session-initiate tk-in9 $::PEER]
        calls_error_condition [calls_last_written]
    } -result out-of-order

test calls-session-accept-needs-pc {a session-accept with no pc yet is out of order} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn clear
        c.conn feed [calls_session_iq session-accept $sid $::PEER]
        calls_error_condition [calls_last_written]
    } -result out-of-order

# -- transport-info --

test calls-transport-info-skips-unusable-candidate \
    {a tcp candidate is dropped; the udp one still buffers and the iq is acked} \
    {*}$calls_env -body {
        calls_accepted tk-test1 $::PEER
        c.conn feed [calls_transport_info tk-test1 $::PEER]
        set call [dict get [calls_state] tk-test1]
        list \
            [dict get $call pending_remote_candidates] \
            [xsearch [calls_last_written] -get @type]
    } -result {{{audio {candidate:2 1 udp 2122260222 192.0.2.1 54321 typ host}}} result}

test calls-transport-info-buffer-capped {a peer cannot buffer candidates without bound} \
    {*}$calls_env -body {
        calls_accepted tk-in10 $::PEER
        c.conn feed [calls_transport_info_flood tk-in10 $::PEER 100]
        set call [dict get [calls_state] tk-in10]
        list \
            [llength [dict get $call pending_remote_candidates]] \
            [xsearch [calls_last_written] -get @type]
    } -result {64 result}

# -- Peer connection state --

# Past the grace period, so the timer has fired.
proc calls_wait_grace {} {
    after [expr {$::taco_calls::DISCONNECT_GRACE_MS + 30}] {set ::calls_grace 1}
    vwait ::calls_grace
}

set calls_grace_env $calls_env
dict append calls_grace_env -setup "\nset ::taco_calls::DISCONNECT_GRACE_MS 20"
dict append calls_grace_env -cleanup "\nset ::taco_calls::DISCONNECT_GRACE_MS 2000"

test calls-pc-disconnected-warns {a media path that stays down warns without ending the call} \
    {*}$calls_grace_env -body {
        c.conn feed [calls_jmi_in propose tk-in11 $::PEER]
        c.calls accept -sid tk-in11
        c.calls OnPcState tk-in11 disconnected
        calls_wait_grace
        list \
            [lindex [calls_events] end] \
            [dict get [dict get [calls_state] tk-in11] state]
    } -result {{<Warning> -sid tk-in11 -reason {media path interrupted}} proceeded}

test calls-pc-disconnected-then-hangup-is-quiet {a hangup inside the grace period warns nothing} \
    {*}$calls_grace_env -body {
        c.conn feed [calls_jmi_in propose tk-in12 $::PEER]
        c.calls accept -sid tk-in12
        c.calls OnPcState tk-in12 disconnected
        c.calls hangup -sid tk-in12
        calls_wait_grace
        lsearch -all -inline [calls_events] <Warning>*
    } -result {}

test calls-pc-disconnected-then-recovers-is-quiet {a path that comes back inside the grace period warns nothing} \
    {*}$calls_grace_env -body {
        c.conn feed [calls_jmi_in propose tk-in13 $::PEER]
        c.calls accept -sid tk-in13
        c.calls OnPcState tk-in13 disconnected
        c.calls OnPcState tk-in13 connected
        calls_wait_grace
        lsearch -all -inline [calls_events] <Warning>*
    } -result {}

# -- Stream reset --

test calls-fresh-stream-ends-calls {a new session invalidates every sid we held} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in12 $::PEER]
        c.conn fire_ready 0
        list [calls_state] [lindex [calls_events] end]
    } -result {{} {<Ended> -sid tk-in12}}

test calls-resumed-stream-keeps-calls {resumption keeps the session, so calls survive} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in13 $::PEER]
        c.conn fire_ready 1
        dict get [dict get [calls_state] tk-in13] state
    } -result ringing

# -- Enumeration --

test calls-list-empty {nothing in flight is an empty list, not an error} \
    {*}$calls_env -body {
        c.calls list
    } -result {}

test calls-list-outgoing {a call we placed reports outgoing, proposed and a bare peer} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com/phone]
        set rows [c.calls list]
        string map [list $sid SID] [list [llength $rows] [lindex $rows 0]]
    } -result {1 {sid SID peer peer@example.com direction outgoing state proposed peer_ringing 0 group {} video_local 0 video_remote 0 verified 0 fingerprint {}}}

test calls-list-incoming {a call rung at us reports incoming, in tacky's own word for it} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in20 $::PEER]
        lindex [c.calls list] 0
    } -result {sid tk-in20 peer peer@example.com direction incoming state ringing peer_ringing 0 group {} video_local 0 video_remote 0 verified 0 fingerprint {}}

test calls-list-peer-ringing {a peer device alerting is recorded, and moves no state} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.conn feed [calls_jmi_in ringing $sid $::PEER]
        set entry [lindex [c.calls list] 0]
        list [dict get $entry peer_ringing] [dict get $entry state] \
            [dict get [dict get [calls_state] $sid] state]
    } -result {1 proposed proposed}

test calls-list-drops-ended {a call that ended is gone, so a snapshot never carries one} \
    {*}$calls_env -body {
        set sid [c.calls start -to peer@example.com]
        c.calls hangup -sid $sid
        c.calls list
    } -result {}

test calls-list-drops-on-fresh-stream {a new session leaves nothing to re-seed from} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in21 $::PEER]
        c.conn fire_ready 0
        c.calls list
    } -result {}

test calls-list-two-calls {nothing caps this at one, and each call keeps its own direction} \
    {*}$calls_env -body {
        c.calls start -to peer@example.com
        c.conn feed [calls_jmi_in propose tk-in22 other@example.com/tablet]
        set out {}
        foreach entry [c.calls list] {
            lappend out [dict get $entry peer] [dict get $entry direction]
        }
        lsort -stride 2 $out
    } -result {other@example.com incoming peer@example.com outgoing}

# -- Codec filtering --

test calls-filter-codecs-audio {non-opus payload-types are stripped from audio, other children kept} -constraints !wasm \
    {*}$calls_env -body {
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j content -creator initiator -name audio {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000
                    j payload-type -id 0 -name PCMU -clockrate 8000
                    j payload-type -id 101 -name telephone-event -clockrate 8000
                    j rtcp-mux -ns urn:xmpp:jingle:apps:rtp:1
                }
            }
        }]
        set filtered [c.calls FilterCodecs $jingle]
        set desc [xsearch $filtered content description \
            -ns urn:xmpp:jingle:apps:rtp:1 -get node]
        list \
            [xsearch $desc payload-type -gather @name] \
            [llength [xsearch $desc rtcp-mux -gather node]]
    } -result {opus 1}

test calls-filter-codecs-video {video keeps VP8, drops H264/VP9/rtx} -constraints !wasm \
    {*}$calls_env -body {
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j content -creator initiator -name video {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media video {
                    j payload-type -id 96 -name VP8 -clockrate 90000
                    j payload-type -id 98 -name VP9 -clockrate 90000
                    j payload-type -id 102 -name H264 -clockrate 90000
                    j payload-type -id 97 -name rtx -clockrate 90000
                    j rtcp-mux -ns urn:xmpp:jingle:apps:rtp:1
                }
            }
        }]
        set filtered [c.calls FilterCodecs $jingle]
        set desc [xsearch $filtered content description \
            -ns urn:xmpp:jingle:apps:rtp:1 -get node]
        xsearch $desc payload-type -gather @name
    } -result {VP8}

# -- other actions --

test calls-other-actions-checked {other jingle actions: unknown session refused, informational ones acked, unknown ones not implemented} \
    {*}$calls_env -body {
        calls_accepted tk-oa1 $::PEER
        set out {}
        foreach {action sid from} [list \
                content-add nosuch $::PEER \
                session-info tk-oa1 mallory@example.com/x \
                session-info tk-oa1 $::PEER \
                content-modify tk-oa1 $::PEER \
                bogus-action tk-oa1 $::PEER] {
            c.conn feed [calls_session_iq $action $sid $from]
            set w [calls_last_written]
            lappend out [expr {[xsearch $w -get @type] eq "result" ? "result"
                               : [calls_error_condition $w]}]
        }
        set out
    } -result {item-not-found item-not-found result result feature-not-implemented}

# XEP-0166 7.2: acked, then turned down, so the call goes on (an IQ error
# here ends a Conversations call when its user taps video).
test calls-content-add-rejected {content-add and transport-replace are acked, then rejected naming the content} \
    {*}$calls_env -body {
        calls_accepted tk-oa2 $::PEER
        set out {}
        foreach action {content-add transport-replace} {
            c.conn clear
            c.conn feed [calls_session_iq $action tk-oa2 $::PEER]
            set w [c.conn get_written]
            set jn [xsearch [lindex $w 1] jingle -ns urn:xmpp:jingle:1 -get node]
            lappend out [llength $w] [xsearch [lindex $w 0] -get @type] \
                [xsearch [lindex $w 1] -get {@type @to}] \
                [xsearch $jn -get {@action @sid}] \
                [xsearch $jn content -get {@creator @name}]
        }
        set out
    } -result [list 2 result [list set $::PEER] {content-reject tk-oa2} {initiator audio} \
                    2 result [list set $::PEER] {transport-reject tk-oa2} {initiator audio}]
