# Unit tests for taco_calls
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set calls_env [tacky_env -mock conn -stub-emit 1 -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
} -bound-jid user@test.example.com/res]

# -- Helpers --

# The live per-call state, keyed by sid. The snit instance number varies
# per test, so find the variable rather than naming the instance.
proc calls_state {} {
    foreach v [c.calls info vars] {
        if {[string match *::Calls $v]} { return [set $v] }
    }
    error "calls: no Calls variable"
}

# Drive a call to the window between our <proceed> and the peer's
# session-initiate, where inbound candidates have no pc to go to yet.
proc calls_accepted {sid peer} {
    c.conn feed [j message -from $peer -to user@test.example.com -type chat {
        j propose -ns urn:xmpp:jingle-message:0 -id $sid {
            j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio
        }
    }]
    c.calls accept -sid $sid
    c.conn clear
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

# -- transport-info --

test calls-transport-info-skips-unusable-candidate \
    {a tcp candidate is dropped; the udp one still buffers and the iq is acked} \
    {*}$calls_env -body {
        set peer peer@example.com/phone
        calls_accepted tk-test1 $peer
        c.conn feed [calls_transport_info tk-test1 $peer]
        set call [dict get [calls_state] tk-test1]
        list \
            [dict get $call pending_remote_candidates] \
            [xsearch [lindex [c.conn get_written] 0] -get @type]
    } -result {{{audio {candidate:2 1 udp 2122260222 192.0.2.1 54321 typ host}}} result}
