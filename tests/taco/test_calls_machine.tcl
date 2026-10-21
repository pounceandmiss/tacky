# Unit tests for taco_calls' two state machines (see the file header of
# lib/taco/modules/calls.tcl): every session state against every inbound
# Jingle action, every transport state against every backend connection
# state, and the paths that end a call. Runs against the mock media backend,
# which does nothing by itself: each test drives the events a backend would
# produce.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers
package require tacky::mockmedia

set cm_env [tacky_env -mock conn -capture-emit 1 -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky
} -bound-jid user@test.example.com/res -extra-setup {
    mockmedia::reset
    ::tacky::media open mock
}]

set CM_PEER peer@example.com/phone
set cm_seq 0
set CM_ME user@test.example.com/res

# -- Helpers --

proc cm_sdp {{ufrag abc} {pwd xyzxyzxyzxyzxyzxyzxyzx}} {
    return "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:$ufrag\r\na=ice-pwd:$pwd\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"
}

proc cm_pc {sid} {
    dict get [dict get [calls_state] $sid] pc
}

proc cm_field {sid key} {
    dict get [dict get [calls_state] $sid] $key
}

# A Jingle IQ from the peer: an audio content with an ice-udp transport,
# which the description and transport actions all carry.
proc cm_jingle {action sid {from ""} {id cm1}} {
    if {$from eq ""} { set from $::CM_PEER }
    j iq -type set -from $from -to $::CM_ME -id $id {
        j jingle -ns urn:xmpp:jingle:1 -action $action -sid $sid {
            j content -creator initiator -name audio -senders both {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                }
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                    -ufrag def -pwd defdefdefdefdefdefdefd {
                    j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 \
                        -hash sha-256 -setup actpass -body CC:DD
                    j candidate -foundation 1 -component 1 -protocol udp \
                        -priority 2122260223 -ip 192.0.2.7 -port 7777 \
                        -type host -id c1 -generation 0
                }
            }
            if {$action eq "session-terminate"} {
                j reason { j success }
            }
        }
    }
}

proc cm_answer_extdisco {} {
    set id ""
    foreach w [c.conn get_written] {
        if {[dict get $w tag] ne "iq"} continue
        set child [lindex [dict get $w children] 0]
        if {$child ne "" && [dict get $child tag] eq "services"} {
            set id [xsearch $w -get @id]
        }
    }
    if {$id eq ""} { error "no extdisco request was written" }
    c.conn feed [j iq -type result -from test.example.com -to $::CM_ME -id $id {
        j services -ns urn:xmpp:extdisco:2
    }]
}

# Our reply to the IQ with $id, or "" if none went out.
proc cm_reply {{id cm1}} {
    foreach w [c.conn get_written] {
        if {[dict get $w tag] eq "iq" && [xsearch $w -get @id] eq $id
                && [xsearch $w -get @type] in {result error}} {
            return $w
        }
    }
    return ""
}

proc cm_reply_word {{id cm1}} {
    set w [cm_reply $id]
    if {$w eq ""} { return none }
    if {[xsearch $w -get @type] eq "result"} { return result }
    return [xsearch $w error * -ns urn:ietf:params:xml:ns:xmpp-stanzas -get tag]
}

# The <jingle> actions and JMI elements we wrote, in order.
proc cm_wire {} {
    set out {}
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $w -get @type] eq "set"} {
            lappend out [xsearch $jn -get @action]
            continue
        }
        foreach a {propose proceed ringing reject retract finish} {
            if {[xsearch $w $a -ns urn:xmpp:jingle-message:0 -get node] ne ""} {
                lappend out jmi-$a
            }
        }
    }
    return $out
}

# The last session-terminate we sent.
proc cm_terminate {} {
    set out ""
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $jn -get @action] eq "session-terminate"} {
            set out $jn
        }
    }
    return $out
}

proc cm_events {} {
    lmap e [calls_events] { lindex $e 0 }
}

proc cm_terminal_count {} {
    llength [lsearch -all -regexp [cm_events] {^<(Ended|Failed)>$}]
}

# Calls in each session state. Each returns the sid and leaves the wire
# cleared, so what a test sees is what its own input caused.
proc cm_in {state role} {
    set sid [cm_reach $state $role tk-cm[incr ::cm_seq]]
    if {[cm_field $sid state] ne $state} {
        error "cm_in: $role is in [cm_field $sid state], not $state"
    }
    c.conn clear
    set ::_emitted {}
    return $sid
}

proc cm_reach {state role sid} {
    switch -- $role,$state {
        caller,proposed {
            set sid [c.calls start -to peer@example.com]
        }
        caller,proceeded {
            set sid [c.calls start -to peer@example.com]
            c.conn feed [calls_jmi_in proceed $sid $::CM_PEER]
        }
        caller,pending {
            set sid [cm_reach proceeded caller $sid]
            cm_answer_extdisco
            mockmedia::drive localDescription [cm_pc $sid] [cm_sdp] offer
        }
        caller,established {
            set sid [cm_reach pending caller $sid]
            c.conn feed [cm_jingle session-accept $sid $::CM_PEER cm0]
        }
        callee,ringing {
            c.conn feed [calls_jmi_in propose $sid $::CM_PEER]
        }
        callee,proceeded {
            cm_reach ringing callee $sid
            c.calls accept -sid $sid
        }
        callee,pending {
            cm_reach proceeded callee $sid
            c.conn feed [cm_jingle session-initiate $sid $::CM_PEER cm0]
            cm_answer_extdisco
        }
        callee,established {
            cm_reach pending callee $sid
            mockmedia::drive localDescription [cm_pc $sid] [cm_sdp ghi] answer
        }
        default { error "cm_reach: no $role in $state" }
    }
    return $sid
}

# A call in $state with its media path brought to $transport.
proc cm_transport {transport {role caller}} {
    set sid [cm_in established $role]
    set pc [cm_pc $sid]
    switch -- $transport {
        idle        {}
        checking    { mockmedia::drive connectionState $pc connecting }
        connected   { mockmedia::drive connectionState $pc connected }
        interrupted {
            mockmedia::drive connectionState $pc connected
            mockmedia::drive connectionState $pc disconnected
        }
    }
    if {[cm_field $sid transport] ne $transport} {
        error "cm_transport: in [cm_field $sid transport], not $transport"
    }
    c.conn clear
    set ::_emitted {}
    return $sid
}

# Whatever is still up goes, so the next case is not turned away as busy.
proc cm_drop_all {} {
    foreach row [c.calls list] {
        c.calls hangup -sid [dict get $row sid]
    }
    c.conn clear
    set ::_emitted {}
}

proc cm_wait {ms} {
    after $ms {set ::cm_waited 1}
    vwait ::cm_waited
}

# -- The session table --

set CM_ACTIONS {
    session-initiate session-accept session-terminate transport-info
    session-info content-add content-modify content-remove transport-replace
    description-info security-info bogus-action
}
set CM_SESSIONS {
    proposed caller ringing callee proceeded caller proceeded callee
    pending caller pending callee established caller established callee
}

test calls-machine-session-table-is-complete {every session state names what each inbound action gets} \
    {*}$cm_env -body {
        set missing {}
        foreach state [dict keys $::taco_calls::SESSION_NEXT] {
            if {![dict exists $::taco_calls::JINGLE_IN $state]} {
                lappend missing $state
                continue
            }
            if {![dict exists [dict get $::taco_calls::JINGLE_IN $state] *]} {
                lappend missing $state/*
            }
        }
        set missing
    } -result {}

test calls-machine-session-every-action-in-every-state {each state x action: one reply, the table's refusal where it refuses, a legal move, at most one end} \
    {*}$cm_env -body {
        set bad {}
        foreach {state role} $::CM_SESSIONS {
            foreach action $::CM_ACTIONS {
                set sid [cm_in $state $role]
                set word [c.calls JingleIn $sid $action]
                if {[catch {c.conn feed [cm_jingle $action $sid]} err]} {
                    lappend bad [list $state $role $action raised $err]
                    cm_drop_all
                    continue
                }
                set reply [cm_reply_word]
                if {$reply eq "none"} {
                    lappend bad [list $state $role $action no-reply]
                }
                if {$word ne "handle" && $reply ne $word} {
                    lappend bad [list $state $role $action want $word got $reply]
                }
                if {[cm_terminal_count] > 1} {
                    lappend bad [list $state $role $action ended [cm_events]]
                }
                if {[dict exists [calls_state] $sid] && [cm_terminal_count]} {
                    lappend bad [list $state $role $action ended-but-kept]
                }
                cm_drop_all
            }
        }
        list $bad $::taco_calls::IllegalMoves
    } -result {{} {}}

test calls-machine-session-terminate-ends-in-every-state {a terminate from the peer ends the call whatever its state, and is acked} \
    {*}$cm_env -body {
        set out {}
        foreach {state role} $::CM_SESSIONS {
            set sid [cm_in $state $role]
            c.conn feed [cm_jingle session-terminate $sid]
            lappend out [list $state $role [cm_reply_word] \
                [dict exists [calls_state] $sid] [cm_events]]
            cm_drop_all
        }
        set out
    } -result {{proposed caller result 0 <Ended>} {ringing callee result 0 <Ended>} {proceeded caller result 0 <Ended>} {proceeded callee result 0 <Ended>} {pending caller result 0 <Ended>} {pending callee result 0 <Ended>} {established caller result 0 <Ended>} {established callee result 0 <Ended>}}

test calls-machine-stranger-refused-in-every-state {an action from anyone but the peer is refused whatever the state, and moves nothing} \
    {*}$cm_env -body {
        set out {}
        foreach {state role} $::CM_SESSIONS {
            set sid [cm_in $state $role]
            c.conn feed [cm_jingle session-terminate $sid mallory@example.com/x]
            c.conn feed [cm_jingle transport-info $sid mallory@example.com/x cm2]
            lappend out [list [cm_reply_word cm2] [cm_field $sid state] [cm_events]]
            cm_drop_all
        }
        lsort -unique $out
    } -result {{item-not-found established {}} {item-not-found pending {}} {item-not-found proceeded {}} {item-not-found proposed {}} {item-not-found ringing {}}}

# -- The transport table --

set CM_PC_STATES {new connecting connected disconnected failed closed}

test calls-machine-transport-every-backend-state {each transport state x backend connection state moves as the table says} \
    {*}$cm_env -body {
        set out {}
        foreach transport {idle checking connected interrupted} {
            foreach pcState $::CM_PC_STATES {
                set sid [cm_transport $transport]
                mockmedia::drive connectionState [cm_pc $sid] $pcState
                if {[dict exists [calls_state] $sid]} {
                    set after [cm_field $sid transport]
                } else {
                    set after gone
                }
                lappend out "$transport+$pcState=$after:[join [cm_events] ,]"
                cm_drop_all
            }
        }
        list $out $::taco_calls::IllegalMoves
    } -result {{idle+new=idle: idle+connecting=checking: idle+connected=connected:<Active> idle+disconnected=interrupted: idle+failed=gone:<Failed> idle+closed=gone:<Ended> checking+new=checking: checking+connecting=checking: checking+connected=connected:<Active> checking+disconnected=interrupted: checking+failed=gone:<Failed> checking+closed=gone:<Ended> connected+new=connected: connected+connecting=checking: connected+connected=connected:<Active> connected+disconnected=interrupted: connected+failed=gone:<Failed> connected+closed=gone:<Ended> interrupted+new=interrupted: interrupted+connecting=checking: interrupted+connected=connected:<Active> interrupted+disconnected=interrupted: interrupted+failed=gone:<Failed> interrupted+closed=gone:<Ended>} {}}

test calls-machine-failed-path-terminates {a failed path tells the peer with connectivity-error, then <finish/>} \
    {*}$cm_env -body {
        set sid [cm_transport connected]
        mockmedia::drive connectionState [cm_pc $sid] failed
        list [cm_wire] [lindex [calls_events] end]
    } -result {{session-terminate jmi-finish} {<Failed> -sid * -reason {media path failed (ICE/DTLS)}}} \
    -match glob

test calls-machine-list-connection {list names the media path: connecting, connected, interrupted, reconnecting} \
    {*}$cm_env -body {
        set sid [cm_in established caller]
        set pc [cm_pc $sid]
        set out [list [dict get [lindex [c.calls list] 0] connection]]
        foreach s {connected disconnected connecting connected} {
            mockmedia::drive connectionState $pc $s
            set row [lindex [c.calls list] 0]
            lappend out [dict get $row state]/[dict get $row connection]
        }
        set out
    } -result {connecting active/connected connecting/interrupted connecting/reconnecting active/connected}

# -- <Connection> --

set cm_grace_env $cm_env
dict append cm_grace_env -setup "\nset ::taco_calls::DISCONNECT_GRACE_MS 20"
dict append cm_grace_env -cleanup "\nset ::taco_calls::DISCONNECT_GRACE_MS 2000"

test calls-machine-connection-interrupted-and-back {an interruption that lasts is said, and so is its end} \
    {*}$cm_grace_env -body {
        set sid [cm_transport connected]
        mockmedia::drive connectionState [cm_pc $sid] disconnected
        cm_wait 60
        mockmedia::drive connectionState [cm_pc $sid] connected
        lsearch -all -inline [calls_events] <Connection>*
    } -result {{<Connection> -sid * -state interrupted} {<Connection> -sid * -state connected}} \
    -match glob

test calls-machine-connection-blip-unsaid {an interruption over within the grace is never said, either way} \
    {*}$cm_grace_env -body {
        set sid [cm_transport connected]
        mockmedia::drive connectionState [cm_pc $sid] disconnected
        mockmedia::drive connectionState [cm_pc $sid] connected
        cm_wait 60
        lsearch -all -inline [calls_events] <Connection>*
    } -result {}

# -- Setup timeout --

set cm_setup_env $cm_env
dict append cm_setup_env -setup "\nset ::taco_calls::SETUP_TIMEOUT_MS 20"
dict append cm_setup_env -cleanup "\nset ::taco_calls::SETUP_TIMEOUT_MS 60000"

test calls-machine-setup-timeout-callee {answered, but no session-initiate ever comes: the call fails with timeout} \
    {*}$cm_setup_env -body {
        set sid [cm_in proceeded callee]
        cm_wait 60
        list [dict exists [calls_state] $sid] [lindex [calls_events] end 0] \
            [cm_wire] [xsearch [cm_terminate] reason * -get tag]
    } -result {0 <Failed> session-terminate timeout}

test calls-machine-setup-timeout-caller {an initiate never accepted fails the call with timeout} \
    {*}$cm_setup_env -body {
        set sid [cm_in pending caller]
        cm_wait 60
        list [dict exists [calls_state] $sid] [lindex [calls_events] end] [cm_wire]
    } -result {0 {<Failed> -sid * -reason {no media path within 0 s}} {session-terminate jmi-finish}} \
    -match glob

test calls-machine-setup-timeout-spares-connected {once media flowed, the setup timer is gone: a call that drops later is not timed out} \
    {*}$cm_setup_env -body {
        set sid [cm_transport connected]
        mockmedia::drive connectionState [cm_pc $sid] disconnected
        cm_wait 60
        list [dict exists [calls_state] $sid] [cm_events]
    } -result {1 {}}

test calls-machine-setup-timer-not-left-behind {a call that ends leaves no setup timer} \
    {*}$cm_setup_env -body {
        set sid [cm_in proceeded callee]
        set timer [cm_field $sid setup_timer]
        c.calls hangup -sid $sid
        expr {$timer in [after info]}
    } -result 0

# -- Ending: what goes on the wire --

test calls-machine-hangup-established-finishes {hanging up a session terminates it, then says <finish/> to the peer's device} \
    {*}$cm_env -body {
        set sid [cm_in established caller]
        c.calls hangup -sid $sid
        set fin [lindex [c.conn get_written] end]
        list [cm_wire] [xsearch $fin -get @to] \
            [xsearch $fin finish -ns urn:xmpp:jingle-message:0 reason * -get tag] \
            [lindex [calls_events] end 0]
    } -result [list {session-terminate jmi-finish} $CM_PEER success <Ended>]

test calls-machine-hangup-ringing-declines {hanging up on a ring declines it: a JMI reject, no session to terminate} \
    {*}$cm_env -body {
        set sid [cm_in ringing callee]
        c.calls hangup -sid $sid
        list [cm_wire] [lindex [calls_events] end]
    } -result {jmi-reject {<Ended> -sid * -reason declined}} -match glob

test calls-machine-hangup-proposed-retracts {hanging up before an answer retracts, with no <finish/>} \
    {*}$cm_env -body {
        set sid [cm_in proposed caller]
        c.calls hangup -sid $sid
        cm_wire
    } -result jmi-retract

test calls-machine-retract-after-proceed {a caller retracting after we answered, before its initiate, ends the call unmissed} \
    {*}$cm_env -body {
        set sid [cm_in proceeded callee]
        c.conn feed [calls_jmi_in retract $sid $::CM_PEER]
        list [dict exists [calls_state] $sid] [cm_events] [calls_events]
    } -result {0 <Ended> {{<Ended> -sid * -reason retracted}}} -match glob

test calls-machine-retract-after-initiate-ignored {a retract once the session started changes nothing} \
    {*}$cm_env -body {
        set sid [cm_in pending callee]
        c.conn feed [calls_jmi_in retract $sid $::CM_PEER]
        list [cm_field $sid state] [cm_events]
    } -result {pending {}}

test calls-machine-fatal-media-error-terminates {a pc the backend gives up on fails the call and tells the peer} \
    {*}$cm_env -body {
        set sid [cm_transport connected]
        ::tacky::media::emit [cm_pc $sid] error op somethingElse \
            reason "engine died" fatal 1
        list [cm_wire] [lindex [calls_events] end] \
            [xsearch [cm_terminate] reason * -get tag]
    } -result {{session-terminate jmi-finish} {<Failed> -sid * -reason {engine died}} general-error} \
    -match glob

test calls-machine-peer-terminate-finishes {the peer's terminate is acked and we say <finish/> too} \
    {*}$cm_env -body {
        set sid [cm_in established callee]
        c.conn feed [cm_jingle session-terminate $sid]
        list [cm_reply_word] [cm_wire] [lindex [calls_events] end]
    } -result {result jmi-finish {<Ended> -sid * -reason hangup}} -match glob

# -- Descriptions out of turn --

test calls-machine-offer-out-of-turn-not-sent {a second local offer on a session already up goes nowhere} \
    {*}$cm_env -body {
        set sid [cm_in established caller]
        mockmedia::drive localDescription [cm_pc $sid] [cm_sdp zzz] offer
        list [cm_wire] [cm_field $sid state]
    } -result {{} established}

test calls-machine-answer-from-caller-not-sent {an answer from the caller's pc is never a session-accept} \
    {*}$cm_env -body {
        set sid [cm_in pending caller]
        mockmedia::drive localDescription [cm_pc $sid] [cm_sdp zzz] answer
        cm_wire
    } -result {}

# -- A fresh stream --

test calls-machine-fresh-stream-keeps-live-call {a call up with media flowing survives a fresh stream that binds the same JID} \
    {*}$cm_env -body {
        set sid [cm_transport connected]
        c.conn fire_ready 0
        list [dict exists [calls_state] $sid] [cm_events]
    } -result {1 {}}

test calls-machine-fresh-stream-other-jid-ends {a fresh stream bound to another resource ends the call} \
    {*}$cm_env -body {
        set sid [cm_transport connected]
        c.conn configure -bound-jid user@test.example.com/other
        c.conn fire_ready 0
        list [dict exists [calls_state] $sid] [lindex [calls_events] end]
    } -result {0 {<Ended> -sid * -reason reset}} -match glob

test calls-machine-fresh-stream-ends-unconnected {a fresh stream ends a call whose media is not flowing, and a ring} \
    {*}$cm_env -body {
        set a [cm_transport interrupted]
        set ::_emitted {}
        c.conn fire_ready 0
        list [dict exists [calls_state] $a] [cm_events]
    } -result {0 <Ended>}

test calls-machine-resumed-stream-keeps-everything {resumption ends nothing, connected or not} \
    {*}$cm_env -body {
        set a [cm_transport interrupted]
        c.conn fire_ready 1
        list [dict exists [calls_state] $a] [cm_events]
    } -result {1 {}}

# -- Bookkeeping --

# IllegalMoves is never reset, so this covers every call test run before it.
test calls-machine-no-illegal-moves {nothing so far moved a machine its table forbids} \
    {*}$cm_env -body {
        set ::taco_calls::IllegalMoves
    } -result {}
