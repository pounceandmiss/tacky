# Unit tests for taco_calls
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers

set calls_env [tacky_env -mock conn -capture-emit 1 -taco-client {
    -host test.example.com -port 5222
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

# Point a pc id at $sid so the rtc callbacks can be driven without a real
# peer connection behind them.
proc calls_fake_pc {sid pc} {
    foreach v [c.calls info vars] {
        if {[string match *::PcToSid $v]} {
            set ${v}($pc) $sid
            return
        }
    }
    error "calls: no PcToSid variable"
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
    } -result {{ringing tk-in1} ringing {{<Incoming> -sid tk-in1 -from peer@example.com}}}

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

test calls-pc-disconnected-warns {a faltering media path warns without ending the call} \
    {*}$calls_env -body {
        c.conn feed [calls_jmi_in propose tk-in11 $::PEER]
        c.calls accept -sid tk-in11
        calls_fake_pc tk-in11 7
        c.calls OnPcState 7 disconnected
        list \
            [lindex [calls_events] end] \
            [dict get [dict get [calls_state] tk-in11] state]
    } -result {{<Warning> -sid tk-in11 -reason {media path interrupted}} proceeded}

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

# -- Codec filtering --

test calls-filter-opus-only {non-opus payload-types are stripped, other children kept} \
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
        set filtered [c.calls FilterOpusOnly $jingle]
        set desc [xsearch $filtered content description \
            -ns urn:xmpp:jingle:apps:rtp:1 -get node]
        list \
            [xsearch $desc payload-type -gather @name] \
            [llength [xsearch $desc rtcp-mux -gather node]]
    } -result {opus 1}
