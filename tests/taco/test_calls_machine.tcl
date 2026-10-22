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
package require tacky::callsmachine

set cm_env [tacky_env -mock conn -capture-emit 1 -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky
} -bound-jid user@test.example.com/res -extra-setup {
    mockmedia::reset
    ::tacky::media open mock
}]

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
    } -result {{idle+new=idle: idle+connecting=checking: idle+connected=connected:<Active> idle+disconnected=interrupted: idle+failed=gone:<Failed> idle+closed=gone:<Ended> checking+new=checking: checking+connecting=checking: checking+connected=connected:<Active> checking+disconnected=interrupted: checking+failed=gone:<Failed> checking+closed=gone:<Ended> connected+new=connected: connected+connecting=checking: connected+connected=connected: connected+disconnected=interrupted: connected+failed=gone:<Failed> connected+closed=gone:<Ended> interrupted+new=interrupted: interrupted+connecting=checking: interrupted+connected=connected:<Active> interrupted+disconnected=interrupted: interrupted+failed=gone:<Failed> interrupted+closed=gone:<Ended>} {}}

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
