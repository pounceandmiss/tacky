package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# XEP-0272 (Muji) group calls in a real Prosody room: presence, who calls
# whom, Jingle legs going live, leaving, and join failures only a real server
# shows (a nick shared with another session of the same account). Audio is
# stubbed as in test_calls.tcl; DTLS and ICE run for real.

::tcltest::testConstraint smServer [info exists ::env(XMPP_SM)]

namespace eval ::test::groupcall_int {

    variable HOST "example.local"
    variable TIMEOUT 15000
    # A leg going live: loopback DTLS, with slack for a cold libdatachannel.
    variable LIVE_TIMEOUT 30000

    variable ROMEO  "romeo@example.local"
    variable JULIET "juliet@example.local"
    variable TEST   "test@example.local"
    variable PASS   {romeo@example.local romeopass juliet@example.local julietpass
                     test@example.local testpass}
    variable NICK   {romeo@example.local romeo juliet@example.local juliet
                     test@example.local test}

    # A room per test, so no test inherits another's occupants or call.
    variable RoomSeq 0
    variable ROOM ""

    # acc -> list of {event argsDict}, groupcall events in arrival order.
    variable Events
    # acc,sid -> list of leg states (active, ended, failed).
    variable Legs
    variable Twin ""

    variable _rtcmaHandleSeq 0
    variable _rtcmaMuted     0

    # -- Audio stubs (as test_calls.tcl) ------------------------------------

    proc muteRtcma {} {
        variable _rtcmaMuted
        if {$_rtcmaMuted} return
        foreach cmd {::rtcma::player::new ::rtcma::capturer::new} {
            if {[info commands $cmd] ne ""} { rename $cmd ${cmd}__real }
            proc $cmd args { return [incr ::test::groupcall_int::_rtcmaHandleSeq] }
        }
        foreach cmd {
            ::rtcma::player::start    ::rtcma::player::attach
            ::rtcma::player::detach   ::rtcma::player::destroy
            ::rtcma::capturer::start  ::rtcma::capturer::attach
            ::rtcma::capturer::detach ::rtcma::capturer::destroy
        } {
            if {[info commands $cmd] ne ""} { rename $cmd ${cmd}__real }
            proc $cmd args { return 0 }
        }
        set _rtcmaMuted 1
    }

    proc unmuteRtcma {} {
        variable _rtcmaMuted
        if {!$_rtcmaMuted} return
        foreach cmd {
            ::rtcma::player::new      ::rtcma::player::start
            ::rtcma::player::attach   ::rtcma::player::detach
            ::rtcma::player::destroy
            ::rtcma::capturer::new    ::rtcma::capturer::start
            ::rtcma::capturer::attach ::rtcma::capturer::detach
            ::rtcma::capturer::destroy
        } {
            catch {rename $cmd ""}
            catch {rename ${cmd}__real $cmd}
        }
        set _rtcmaMuted 0
    }

    # -- Waiting -------------------------------------------------------------

    # Spin the event loop until $body (evaluated at uplevel 1) is true.
    proc waitUntil {body {timeout 0}} {
        variable TIMEOUT
        if {$timeout == 0} { set timeout $TIMEOUT }
        set deadline [expr {[clock milliseconds] + $timeout}]
        while {![uplevel 1 [list expr $body]]} {
            set remaining [expr {$deadline - [clock milliseconds]}]
            if {$remaining <= 0} {
                error "waitUntil timeout: $body\nevents: [dumpEvents]"
            }
            set afterId [after [expr {min($remaining, 50)}] \
                [list set [namespace current]::_wakeup 1]]
            vwait [namespace current]::_wakeup
            after cancel $afterId
        }
    }

    # Let the event loop run for $ms, for asserting that nothing happens.
    proc settle {ms} {
        after $ms [list set [namespace current]::_settled 1]
        vwait [namespace current]::_settled
    }

    # -- Event capture -------------------------------------------------------

    proc onGroupcall {acc event argsL} {
        variable Events
        lappend Events($acc) [list $event [dict remove $argsL -acc]]
    }

    proc onLeg {acc state argsL} {
        variable Legs
        lappend Legs($acc,[dict get $argsL -sid]) $state
    }

    # The args of every $event $acc saw, in order.
    proc events {acc event} {
        variable Events
        set out {}
        if {![info exists Events($acc)]} { return $out }
        foreach e $Events($acc) {
            if {[lindex $e 0] eq $event} { lappend out [lindex $e 1] }
        }
        return $out
    }

    proc has {acc event} { expr {[llength [events $acc $event]] > 0} }

    # nick -> sid of every <PeerJoined> $acc saw.
    proc peers {acc} {
        set out {}
        foreach a [events $acc <PeerJoined>] {
            dict set out [dict get $a -nick] [dict get $a -sid]
        }
        return $out
    }

    # Every leg each of $accs has is live.
    proc allLive {accs} {
        foreach acc $accs {
            dict for {nick sid} [peers $acc] {
                if {![legActive $acc $sid]} { return 0 }
            }
        }
        return 1
    }

    proc legActive {acc sid} {
        variable Legs
        expr {[info exists Legs($acc,$sid)] && "active" in $Legs($acc,$sid)}
    }

    # The direction of $acc's leg $sid: outgoing if $acc initiated it.
    proc direction {acc sid} {
        foreach row [tacky calls list -acc $acc] {
            if {[dict get $row sid] eq $sid} { return [dict get $row direction] }
        }
        return ""
    }

    proc dumpEvents {} {
        variable Events
        set out {}
        foreach k [lsort [array names Events]] {
            append out "\n  $k: [lmap e $Events($k) {lindex $e 0}]"
        }
        return $out
    }

    # -- Room ------------------------------------------------------------------

    # Join $acc to the current room under its usual nick.
    proc enterRoom {acc} {
        variable ROOM
        variable NICK
        tacky muc join -acc $acc -jid $ROOM -nick [dict get $NICK $acc]
        waitUntil {[tacky muc isJoined -acc $acc -jid $ROOM]}
    }

    # Romeo creates the room and configures it. whois: `anyone` shows every
    # occupant's real JID, which Muji needs (sessions go to real JIDs);
    # `moderators` is Prosody's default and hides them from participants.
    proc createRoom {{whois anyone}} {
        variable ROMEO
        variable ROOM
        variable RoomSeq
        set ROOM "gc[incr RoomSeq]-[clock milliseconds]@conference.example.local"
        enterRoom $ROMEO
        set form ""
        [tacky client $ROMEO] muc configGet -jid $ROOM \
            -command [list apply {{f} { set ::test::groupcall_int::_form $f }}] \
            -onerror [list apply {{m} { set ::test::groupcall_int::_form [list error $m] }}]
        waitUntil {[info exists ::test::groupcall_int::_form]}
        set form $::test::groupcall_int::_form
        unset ::test::groupcall_int::_form
        if {[lindex $form 0] eq "error"} { error "room config: [lindex $form 1]" }
        set form [::tacky::forms::apply $form [list muc#roomconfig_whois $whois]]
        [tacky client $ROMEO] muc configSet -jid $ROOM -form $form \
            -command [list apply {{s} { set ::test::groupcall_int::_set 1 }}]
        waitUntil {[info exists ::test::groupcall_int::_set]}
        unset ::test::groupcall_int::_set
    }

    proc joinCall {acc} {
        variable ROOM
        tacky groupcall join -acc $acc -jid $ROOM
    }

    # The call is the chat's own (in-room) unless $call names a hosted one.
    proc leaveCall {acc {call ""}} {
        variable ROOM
        tacky groupcall leave -acc $acc -jid [expr {$call eq "" ? $ROOM : $call}]
    }

    proc status {acc {call ""}} {
        variable ROOM
        tacky groupcall status -acc $acc -jid [expr {$call eq "" ? $ROOM : $call}]
    }

    proc joined {acc {call ""}} { dict get [status $acc $call] joined }

    # -- Setup ---------------------------------------------------------------

    proc setup {{whois anyone}} {
        variable HOST
        variable PASS
        variable Events
        variable Legs
        array unset Events
        array unset Legs
        muteRtcma
        tacky_init
        # No mod_external_services on the rig: ICE runs on host candidates.
        foreach {acc pass} $PASS {
            tacky account add {*}$::tacky_test_account_args -acc $acc -password $pass \
                -domain $HOST -username [lindex [split $acc @] 0]
            tacky account enable -acc $acc
        }
        wait_events [lmap {acc pass} $PASS {
            list conn <State> -acc $acc -state connected
        }]
        foreach {acc pass} $PASS {
            foreach ev {<Changed> <Joined> <PeerJoined> <PeerLeft> <Left>
                        <Warning> <Invited> <Started> <StartFailed>} {
                tacky listen -tag gc_int groupcall $ev -acc $acc \
                    [list ::test::groupcall_int::onGroupcall $acc $ev]
            }
            foreach {ev state} {<Active> active <Ended> ended <Failed> failed} {
                tacky listen -tag gc_int calls $ev -acc $acc \
                    [list ::test::groupcall_int::onLeg $acc $state]
            }
        }
        createRoom $whois
    }

    proc cleanup {} {
        variable Twin
        if {$Twin ne ""} {
            catch {$Twin disconnect}
            catch {$Twin destroy}
            set Twin ""
        }
        catch {tacky unlisten gc_int}
        catch {tacky destroy}
        unmuteRtcma
    }

    # A second session of $acc (another device of the same account), outside
    # tacky's account table, in the room under $acc's usual nick.
    proc twinInRoom {acc} {
        variable Twin
        variable HOST
        variable PASS
        variable NICK
        variable ROOM
        set Twin [taco_client [namespace current]::twin \
            -username [lindex [split $acc @] 0] \
            -password [dict get $PASS $acc] \
            -host $HOST -port $::test::helpers::xmppPort -resource twin -taco ::tacky \
            {*}$::tacky_test_taco_args]
        $Twin connect
        waitUntil {[string match */twin [$Twin cget -jid]]}
        # Bound is not ready; the room join wants the session up.
        settle 500
        $Twin muc join -jid $ROOM -nick [dict get $NICK $acc]
        waitUntil {[$Twin muc isJoined -jid $ROOM]}
    }

    set common {
        -constraints {withServer && notMongoose && notEjabberd && !wasm}
        -setup   { ::test::groupcall_int::setup }
        -cleanup { ::test::groupcall_int::cleanup }
    }

    # == Joining ==============================================================

    test groupcall-int-first-in-alone \
        {the first to join announces alone and is live with nobody to call} \
        {*}$common -body {
            variable ROMEO
            joinCall $ROMEO
            waitUntil {[has $ROMEO <Joined>]}
            list [dict get [status $ROMEO] joined] [dict get [status $ROMEO] count] \
                [peers $ROMEO] [llength [tacky calls list -acc $ROMEO]]
        } -result {1 1 {} 0}

    test groupcall-int-two-join \
        {the second to join calls the first; both legs go live} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            joinCall $ROMEO
            waitUntil {[has $ROMEO <Joined>]}
            joinCall $JULIET
            waitUntil {[dict exists [peers $ROMEO] juliet]
                       && [dict exists [peers $JULIET] romeo]}
            set sid [dict get [peers $JULIET] romeo]
            variable LIVE_TIMEOUT
            waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
            list [expr {[dict get [peers $ROMEO] juliet] eq $sid}] \
                [direction $JULIET $sid] [direction $ROMEO $sid] \
                [dict get [status $ROMEO] count] [dict get [status $JULIET] count] \
                [has $ROMEO <Warning>] [has $JULIET <Warning>]
        } -result {1 outgoing incoming 2 2 0 0}

    test groupcall-int-two-join-reverse \
        {the same with the order reversed: the room's owner joins second and calls} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            joinCall $JULIET
            waitUntil {[has $JULIET <Joined>]}
            joinCall $ROMEO
            waitUntil {[dict exists [peers $ROMEO] juliet]
                       && [dict exists [peers $JULIET] romeo]}
            set sid [dict get [peers $ROMEO] juliet]
            variable LIVE_TIMEOUT
            waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
            list [expr {[dict get [peers $JULIET] romeo] eq $sid}] \
                [direction $ROMEO $sid] [direction $JULIET $sid]
        } -result {1 outgoing incoming}

    test groupcall-int-three-way-mesh \
        {three join one after another: every pair gets exactly one live leg} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable LIVE_TIMEOUT
            enterRoom $JULIET
            enterRoom $TEST
            foreach acc [list $ROMEO $JULIET $TEST] {
                joinCall $acc
                waitUntil {[has $acc <Joined>]}
            }
            waitUntil {[dict size [peers $ROMEO]] == 2
                       && [dict size [peers $JULIET]] == 2
                       && [dict size [peers $TEST]] == 2}
            set sids {}
            foreach acc [list $ROMEO $JULIET $TEST] {
                dict for {nick sid} [peers $acc] { dict set sids $sid 1 }
            }
            waitUntil {[allLive [list $ROMEO $JULIET $TEST]]} $LIVE_TIMEOUT
            # Joiner initiates: the later of each pair has the outgoing leg.
            list [dict size $sids] \
                [lsort [dict keys [peers $TEST]]] \
                [direction $JULIET [dict get [peers $JULIET] romeo]] \
                [direction $TEST [dict get [peers $TEST] romeo]] \
                [direction $TEST [dict get [peers $TEST] juliet]] \
                [dict get [status $ROMEO] count]
        } -result {3 {juliet romeo} outgoing outgoing outgoing 3}

    test groupcall-int-simultaneous-join \
        {two joining at once, each preparing while the other is: one leg between them} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable LIVE_TIMEOUT
            enterRoom $JULIET
            joinCall $ROMEO
            joinCall $JULIET
            waitUntil {[has $ROMEO <Joined>] && [has $JULIET <Joined>]}
            waitUntil {[dict exists [peers $ROMEO] juliet]
                       && [dict exists [peers $JULIET] romeo]}
            set rs [dict get [peers $ROMEO] juliet]
            set js [dict get [peers $JULIET] romeo]
            waitUntil {[legActive $ROMEO $rs] && [legActive $JULIET $js]} $LIVE_TIMEOUT
            # Neither may end up with a second session to the other.
            settle 1000
            list [expr {$rs eq $js}] \
                [llength [tacky calls list -acc $ROMEO]] \
                [llength [tacky calls list -acc $JULIET]]
        } -result {1 1 1}

    test groupcall-int-observer \
        {an occupant not in the call sees it from the room: active, count, who} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable ROOM
            enterRoom $JULIET
            enterRoom $TEST
            joinCall $ROMEO
            waitUntil {[has $ROMEO <Joined>]}
            joinCall $JULIET
            waitUntil {[dict get [tacky groupcall status -acc $TEST -jid $ROOM] count] == 2}
            list [tacky groupcall status -acc $TEST -jid $ROOM] \
                [lsort [lmap p [tacky groupcall participants -acc $TEST -jid $ROOM] {
                    dict get $p nick}]] \
                [llength [tacky calls list -acc $TEST]]
        } -result {{active 1 joined 0 count 2 mode mesh} {juliet romeo} 0}

    # == Leaving ==============================================================

    # Romeo and Juliet in a live call, for the tests that take it apart.
    proc liveCall {} {
        variable ROMEO
        variable JULIET
        variable LIVE_TIMEOUT
        enterRoom $JULIET
        joinCall $ROMEO
        waitUntil {[has $ROMEO <Joined>]}
        joinCall $JULIET
        waitUntil {[dict exists [peers $ROMEO] juliet]
                   && [dict exists [peers $JULIET] romeo]}
        set sid [dict get [peers $JULIET] romeo]
        waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
        return $sid
    }

    test groupcall-int-leave \
        {leaving hangs the leg up; the one left behind is told and stays in} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            set sid [liveCall]
            leaveCall $JULIET
            waitUntil {[llength [events $ROMEO <PeerLeft>]] > 0
                       && [dict get [status $ROMEO] count] == 1}
            set pl [lindex [events $ROMEO <PeerLeft>] 0]
            list [dict get $pl -nick] [dict get $pl -reason] \
                [expr {[dict get $pl -sid] eq $sid}] \
                [has $JULIET <Left>] [joined $JULIET] [joined $ROMEO] \
                [llength [tacky calls list -acc $JULIET]]
        } -result {juliet {left the call} 1 1 0 1 0}

    test groupcall-int-rejoin \
        {leaving and joining again connects afresh, on a new leg} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable Events
            variable LIVE_TIMEOUT
            set first [liveCall]
            leaveCall $JULIET
            waitUntil {[llength [events $ROMEO <PeerLeft>]] > 0}
            array unset Events
            joinCall $JULIET
            waitUntil {[dict exists [peers $JULIET] romeo]
                       && [dict exists [peers $ROMEO] juliet]}
            set second [dict get [peers $JULIET] romeo]
            waitUntil {[legActive $ROMEO $second] && [legActive $JULIET $second]} $LIVE_TIMEOUT
            list [expr {$second ne $first}] [direction $JULIET $second] \
                [dict get [status $ROMEO] count]
        } -result {1 outgoing 2}

    test groupcall-int-last-one-leaves \
        {the last participant leaving clears the call for the room} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable ROOM
            enterRoom $TEST
            liveCall
            leaveCall $JULIET
            leaveCall $ROMEO
            waitUntil {![dict get [tacky groupcall status -acc $TEST -jid $ROOM] active]}
            list [tacky groupcall status -acc $TEST -jid $ROOM] \
                [has $ROMEO <Left>] [has $JULIET <Left>]
        } -result {{active 0 joined 0 count 0 mode mesh} 1 1}

    test groupcall-int-peer-leaves-room \
        {a participant leaving the room altogether leaves the call} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            liveCall
            tacky muc leave -acc $JULIET -jid $ROOM
            waitUntil {[llength [events $ROMEO <PeerLeft>]] > 0}
            list [dict get [lindex [events $ROMEO <PeerLeft>] 0] -nick] \
                [has $JULIET <Left>] [joined $ROMEO] [dict get [status $ROMEO] count]
        } -result {juliet 1 1 1}

    test groupcall-int-peer-connection-drops \
        {a participant whose connection drops is out of the call, on both sides} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            liveCall
            # A drop the session does not survive (past the server's resume
            # window): without a stream to resume, the reconnect is a fresh
            # stream, and the server takes the old session out of the room.
            [[tacky client $JULIET] conn sm] ResumeFailed
            # The path a real network drop takes, not a deliberate close.
            [tacky client $JULIET] conn OnTransportError "simulated drop"
            # Juliet learns on the fresh stream after the reconnect backoff.
            waitUntil {[llength [events $ROMEO <PeerLeft>]] > 0 && [has $JULIET <Left>]} 30000
            list [dict get [lindex [events $ROMEO <PeerLeft>] 0] -nick] \
                [dict get [lindex [events $JULIET <Left>] 0] -reason] \
                [joined $ROMEO] [joined $JULIET]
        } -result {juliet disconnected 1 0}

    # With stream management the same drop is resumed (XEP-0198 5): the
    # server kept the session, so nobody left the room or the call.
    test groupcall-int-peer-connection-resumes \
        {a participant whose dropped connection resumes stays in the call} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm && smServer} -body {
            variable ROMEO
            variable JULIET
            liveCall
            set c [tacky client $JULIET]
            $c conn OnTransportError "simulated drop"
            waitUntil {[dict get [[$c conn sm] getInfo] resumed]
                       && [$c conn isReady]} 30000
            settle 1000
            list [has $ROMEO <PeerLeft>] [has $JULIET <Left>] \
                [joined $ROMEO] [joined $JULIET]
        } -result {0 0 1 1}

    # == Failing ==============================================================

    test groupcall-int-shared-nick \
        {a nick another session of ours holds is reported, never a silent hang} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            joinCall $ROMEO
            waitUntil {[has $ROMEO <Joined>]}
            # Juliet's other device is in the room first, under her nick.
            twinInRoom $JULIET
            enterRoom $JULIET
            joinCall $JULIET
            waitUntil {[has $JULIET <Left>] || [has $JULIET <Warning>]}
            settle 500
            if {[has $JULIET <Left>]} {
                set told [string match "another device of yours*" \
                    [dict get [lindex [events $JULIET <Left>] 0] -reason]]
            } else {
                set told [string match "romeo does not see you in the call*" \
                    [dict get [lindex [events $JULIET <Warning>] 0] -reason]]
            }
            list $told [dict exists [peers $ROMEO] juliet] \
                [llength [tacky calls list -acc $ROMEO]]
        } -result {1 0 0}

    test groupcall-int-hidden-jids \
        {in a room that hides real JIDs a joiner cannot reach the others: warned, no leg} \
        -constraints {withServer && notMongoose && notEjabberd && !wasm} \
        -setup { ::test::groupcall_int::setup moderators } \
        -cleanup { ::test::groupcall_int::cleanup } \
        -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            joinCall $ROMEO
            waitUntil {[has $ROMEO <Joined>]}
            joinCall $JULIET
            waitUntil {[has $JULIET <Joined>] && [has $JULIET <Warning>]}
            settle 500
            list [string match "romeo: JID hidden*" \
                    [dict get [lindex [events $JULIET <Warning>] 0] -reason]] \
                [llength [tacky calls list -acc $JULIET]] \
                [llength [tacky calls list -acc $ROMEO]]
        } -result {1 0 0}

    # == Hosted calls: a room of the call's own ===============================

    # Romeo starts a hosted call from the chat; returns its room.
    proc startHosted {} {
        variable ROMEO
        variable ROOM
        tacky groupcall start -acc $ROMEO -chat $ROOM
        waitUntil {[has $ROMEO <Started>] || [has $ROMEO <StartFailed>]}
        if {[has $ROMEO <StartFailed>]} {
            error "start failed: [dict get [lindex [events $ROMEO <StartFailed>] 0] -reason]"
        }
        set call [dict get [lindex [events $ROMEO <Started>] 0] -jid]
        waitUntil {[has $ROMEO <Joined>]}
        return $call
    }

    proc joinHosted {acc call} {
        variable ROOM
        tacky groupcall join -acc $acc -jid $call -chat $ROOM
    }

    test groupcall-int-hosted-start-join \
        {a hosted call: its own room, hidden, joined from the chat, legs live} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            variable LIVE_TIMEOUT
            enterRoom $JULIET
            set call [startHosted]
            joinHosted $JULIET $call
            waitUntil {[dict exists [peers $ROMEO] [lindex [dict keys [peers $ROMEO]] 0]]
                       && [dict size [peers $JULIET]] == 1}
            set sid [lindex [dict values [peers $JULIET]] 0]
            waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
            list [expr {$call ne $ROOM}] \
                [tacky muc isHidden -acc $ROMEO -jid $call] \
                [expr {$call in [tacky muc rooms -acc $ROMEO]}] \
                [expr {$call in [tacky muc rooms -acc $JULIET]}] \
                [direction $JULIET $sid] [dict get [status $ROMEO $call] count]
        } -result {1 1 0 0 outgoing 2}

    # The case hosted calls exist for: Juliet's other device is in the chat
    # under her nick, which breaks an in-room call (see shared-nick above).
    # In a room of its own each device has a nick of its own.
    test groupcall-int-hosted-shared-nick-works \
        {another device of ours in the chat under our nick does not matter to a hosted call} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable LIVE_TIMEOUT
            twinInRoom $JULIET
            enterRoom $JULIET
            set call [startHosted]
            joinHosted $JULIET $call
            waitUntil {[dict size [peers $JULIET]] == 1}
            set sid [lindex [dict values [peers $JULIET]] 0]
            waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
            list [has $JULIET <Warning>] [has $JULIET <Left>] [dict get [status $JULIET $call] count]
        } -result {0 0 2}

    test groupcall-int-hosted-not-member \
        {someone the call's room was not opened to is refused, and told why} \
        {*}$common -body {
            variable TEST
            set call [startHosted]
            # test is not in the chat, so was never let into the room.
            joinHosted $TEST $call
            waitUntil {[has $TEST <Left>]}
            list [dict get [lindex [events $TEST <Left>] 0] -reason] [has $TEST <Joined>]
        } -result {{you are not on this call's guest list} 0}

    test groupcall-int-hosted-late-arrival \
        {someone entering the chat mid-call is let in and can join} \
        {*}$common -body {
            variable ROMEO
            variable TEST
            variable LIVE_TIMEOUT
            set call [startHosted]
            enterRoom $TEST
            # Romeo, in the call and owning its room, lets test in.
            settle 1000
            joinHosted $TEST $call
            waitUntil {([dict size [peers $TEST]] == 1 && [dict size [peers $ROMEO]] == 1)
                       || [has $TEST <Left>]}
            set sid [lindex [dict values [peers $TEST]] 0]
            waitUntil {[legActive $ROMEO $sid] && [legActive $TEST $sid]} $LIVE_TIMEOUT
            list [has $TEST <Left>] [direction $TEST $sid]
        } -result {0 outgoing}

    test groupcall-int-hosted-ended \
        {joining a hosted call everyone has left: the call has ended} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            set call [startHosted]
            leaveCall $ROMEO $call
            waitUntil {[has $ROMEO <Left>]}
            settle 500
            joinHosted $JULIET $call
            waitUntil {[has $JULIET <Left>]}
            list [dict get [lindex [events $JULIET <Left>] 0] -reason] \
                [expr {$call in [tacky muc rooms -acc $JULIET]}] \
                [tacky muc isJoined -acc $JULIET -jid $call]
        } -result {{the call has ended} 0 0}

    # == Call invites as messages ==============================================

    # The call rows $acc holds in the room's chat, as {timestamp content}.
    proc callRows {acc} {
        variable ROOM
        set out {}
        foreach m [dict get [[tacky client $acc] message messagestore get latest $ROOM?join] messages] {
            if {[dict exists $m content] && [dict get $m content type] eq "call"} {
                lappend out [list [dict get $m timestamp] [dict get $m content]]
            }
        }
        return $out
    }

    proc callState {acc} { dict get [lindex [callRows $acc] end 1] state }

    test groupcall-int-invite-rings-and-answers \
        {a started call rings the chat; answering the stored invite joins it} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            variable LIVE_TIMEOUT
            enterRoom $JULIET
            set call [startHosted]
            waitUntil {[has $JULIET <Invited>]}
            set inv [lindex [events $JULIET <Invited>] 0]
            tacky groupcall join -acc $JULIET -chat [dict get $inv -chat] \
                -timestamp [dict get $inv -timestamp]
            waitUntil {[dict size [peers $JULIET]] == 1}
            set sid [lindex [dict values [peers $JULIET]] 0]
            waitUntil {[legActive $ROMEO $sid] && [legActive $JULIET $sid]} $LIVE_TIMEOUT
            waitUntil {[llength [callRows $ROMEO]] == 1}
            list [expr {[dict get $inv -jid] eq $call}] \
                [expr {[dict get $inv -chat] eq "$ROOM?join"}] [dict get $inv -from] \
                [callState $JULIET] [dict get [lindex [callRows $JULIET] 0 1] active] \
                [callState $ROMEO] [llength [events $ROMEO <Invited>]]
        } -result {1 1 romeo@example.local joined 1 joined 0}

    test groupcall-int-invite-declined \
        {declining the stored invite marks it, and leaves the call alone} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            set call [startHosted]
            waitUntil {[has $JULIET <Invited>]}
            set inv [lindex [events $JULIET <Invited>] 0]
            tacky groupcall decline -acc $JULIET -chat [dict get $inv -chat] \
                -timestamp [dict get $inv -timestamp]
            settle 500
            list [callState $JULIET] [dict get [status $ROMEO $call] count] \
                [has $JULIET <Joined>]
        } -result {declined 1 0}

    test groupcall-int-invite-retracted \
        {the caller leaving before anyone came turns the invite into a missed call} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            enterRoom $JULIET
            set call [startHosted]
            waitUntil {[has $JULIET <Invited>]}
            leaveCall $ROMEO $call
            waitUntil {[callState $JULIET] ne "pending"}
            callState $JULIET
        } -result missed

    # == Hosted calls with three, in every order ===============================

    # $acc answers the newest call invite it holds in the chat.
    proc answerInvite {acc} {
        waitUntil {[llength [callRows $acc]] > 0}
        set ts [lindex [callRows $acc] end 0]
        tacky groupcall join -acc $acc -chat $::test::groupcall_int::ROOM?join -timestamp $ts
    }

    # $acc's newest call row's `live`, once the call's room has answered.
    proc live {acc} {
        waitUntil {[liveNow $acc] ne "?"}
        liveNow $acc
    }

    proc liveNow {acc} {
        set content [lindex [callRows $acc] end 1]
        expr {[dict exists $content live] ? [dict get $content live] : "?"}
    }

    # Everyone in $accs has a live leg to each of the others.
    proc meshLive {accs} {
        foreach acc $accs {
            if {[dict size [peers $acc]] < [llength $accs] - 1} { return 0 }
        }
        allLive $accs
    }

    # The legs $acc has now, peer bare JID -> sid, from the calls module.
    proc legsOf {acc} {
        set out {}
        foreach row [tacky calls list -acc $acc] {
            if {[dict get $row group] eq ""} continue
            dict set out [dict get $row peer] [dict get $row sid]
        }
        return $out
    }

    # Romeo starts; $order says who of juliet and test answers first.
    proc hostedThree {order} {
        variable JULIET
        variable TEST
        variable LIVE_TIMEOUT
        enterRoom $JULIET
        enterRoom $TEST
        set call [startHosted]
        foreach acc $order {
            answerInvite [set $acc]
            waitUntil {[has [set $acc] <Joined>]}
        }
        waitUntil {[meshLive [list $::test::groupcall_int::ROMEO $JULIET $TEST]]} $LIVE_TIMEOUT
        return $call
    }

    foreach {name order} {juliet-first {JULIET TEST} test-first {TEST JULIET}} {
        test groupcall-int-hosted-three-$name \
            "three in a hosted call, answered $name: everyone has a live leg to everyone" \
            {*}$common -body [string map [list @ORDER@ $order] {
                variable ROMEO
                variable JULIET
                variable TEST
                set call [hostedThree {@ORDER@}]
                list [dict get [status $ROMEO $call] count] \
                    [lsort [dict keys [legsOf $ROMEO]]] [lsort [dict keys [legsOf $JULIET]]] \
                    [lsort [dict keys [legsOf $TEST]]]
            }] -result [list 3 {juliet@example.local test@example.local} \
                {romeo@example.local test@example.local} {juliet@example.local romeo@example.local}]
    }

    foreach {name first second} {joiners-first JULIET TEST reverse TEST JULIET} {
        test groupcall-int-hosted-three-leave-$name \
            "the two who joined leave ($name): the starter stays, alone, the call still live" \
            {*}$common -body [string map [list @1 $first @2 $second] {
                variable ROMEO
                variable JULIET
                variable TEST
                set call [hostedThree {JULIET TEST}]
                leaveCall $@1 $call
                waitUntil {[dict size [legsOf $ROMEO]] == 1 && [dict size [legsOf $@2]] == 1}
                set two [list [dict get [status $ROMEO $call] count] \
                    [allLive [list $ROMEO $@2]]]
                leaveCall $@2 $call
                waitUntil {[dict size [legsOf $ROMEO]] == 0}
                settle 500
                list {*}$two [dict get [status $ROMEO $call] count] [joined $ROMEO $call] \
                    [live $ROMEO] [live $@1]
            }] -result {2 1 1 1 1 1}
    }

    test groupcall-int-hosted-three-starter-leaves-first \
        {the starter leaving first: the other two keep their leg, and the call stays live} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [hostedThree {JULIET TEST}]
            leaveCall $ROMEO $call
            waitUntil {[dict size [legsOf $JULIET]] == 1 && [dict size [legsOf $TEST]] == 1}
            settle 500
            list [dict keys [legsOf $JULIET]] [allLive [list $JULIET $TEST]] \
                [live $ROMEO] [live $JULIET] [has $JULIET <Left>]
        } -result {test@example.local 1 1 1 0}

    test groupcall-int-hosted-three-all-leave {everyone gone: every row reads over, and starting makes a new call} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [hostedThree {JULIET TEST}]
            foreach acc [list $TEST $ROMEO $JULIET] { leaveCall $acc $call }
            waitUntil {![live $ROMEO] && ![live $JULIET] && ![live $TEST]}
            array unset ::test::groupcall_int::Events $TEST
            tacky groupcall start -acc $TEST -chat $::test::groupcall_int::ROOM
            waitUntil {[has $TEST <Started>]}
            expr {[dict get [lindex [events $TEST <Started>] 0] -jid] ne $call}
        } -result 1

    test groupcall-int-hosted-rejoin {left a call two others are still in: start takes us back into it} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable LIVE_TIMEOUT
            set call [hostedThree {JULIET TEST}]
            leaveCall $JULIET $call
            waitUntil {[dict size [legsOf $ROMEO]] == 1 && [dict size [legsOf $TEST]] == 1}
            settle 500
            set before [live $JULIET]
            array unset ::test::groupcall_int::Events $JULIET
            array unset ::test::groupcall_int::Legs $JULIET,*
            tacky groupcall start -acc $JULIET -chat $::test::groupcall_int::ROOM
            waitUntil {[has $JULIET <Joined>] || [has $JULIET <Left>]}
            waitUntil {[meshLive [list $ROMEO $JULIET $TEST]]} $LIVE_TIMEOUT
            list $before [has $JULIET <Started>] \
                [expr {[dict get [lindex [tacky groupcall list -acc $JULIET] 0] jid] eq $call}] \
                [lsort [dict keys [legsOf $JULIET]]]
        } -result {1 0 1 {romeo@example.local test@example.local}}

    test groupcall-int-hosted-one-drops {one of three losing their connection: the other two go on together} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [hostedThree {JULIET TEST}]
            set sid [dict get [legsOf $ROMEO] test@example.local]
            # Test vanishes without a word: no <left>, no unavailable of its own.
            [tacky client $TEST] disconnect
            waitUntil {![dict exists [legsOf $ROMEO] test@example.local]
                       && ![dict exists [legsOf $JULIET] test@example.local]} 60000
            list [dict keys [legsOf $ROMEO]] [dict keys [legsOf $JULIET]] \
                [allLive [list $ROMEO $JULIET]] [joined $ROMEO $call] [joined $JULIET $call]
        } -result {juliet@example.local romeo@example.local 1 1 1}

    test groupcall-int-hosted-late-third {a third answering once two are live joins the mesh} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable LIVE_TIMEOUT
            enterRoom $JULIET
            enterRoom $TEST
            set call [startHosted]
            answerInvite $JULIET
            waitUntil {[meshLive [list $ROMEO $JULIET]]} $LIVE_TIMEOUT
            settle 1000
            answerInvite $TEST
            waitUntil {[meshLive [list $ROMEO $JULIET $TEST]]} $LIVE_TIMEOUT
            list [direction $TEST [dict get [legsOf $TEST] romeo@example.local]] \
                [direction $TEST [dict get [legsOf $TEST] juliet@example.local]]
        } -result {outgoing outgoing}
}
