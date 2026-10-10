package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require tacky::testwait

namespace eval ::test::calls_int {

    variable HOST "example.local"
    variable TIMEOUT 15000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    # Per-test event captures (cleared by reset).
    variable IncomingSid    ""
    variable IncomingFrom   ""
    variable OutgoingSid    ""
    variable OutgoingTo     ""
    variable RomeoStates    {}
    variable JulietStates   {}
    variable RomeoWarnings    {}
    variable JulietWarnings   {}
    variable RomeoVerified    {}
    variable JulietVerified   {}

    variable _rtcmaHandleSeq 0
    variable _rtcmaMuted     0

    proc reset {} {
        variable IncomingSid    ""
        variable IncomingFrom   ""
        variable OutgoingSid    ""
        variable OutgoingTo     ""
        variable RomeoStates    {}
        variable JulietStates   {}
        variable RomeoWarnings    {}
        variable JulietWarnings   {}
        variable RomeoVerified    {}
        variable JulietVerified   {}
    }

    # Stub the audio-device commands out with unique integer handles so
    # no real device is opened. rtc::* stays real: DTLS/ICE must run.
    proc muteRtcma {} {
        variable _rtcmaMuted
        if {$_rtcmaMuted} return
        # Loaded here, not left to whichever test file ran before this one.
        package require rtcma
        foreach cmd {::rtcma::player::new ::rtcma::capturer::new} {
            if {[info commands $cmd] ne ""} {
                rename $cmd ${cmd}__real
            }
            proc $cmd args {
                return [incr ::test::calls_int::_rtcmaHandleSeq]
            }
        }
        foreach cmd {
            ::rtcma::player::start    ::rtcma::player::attach
            ::rtcma::player::detach   ::rtcma::player::destroy
            ::rtcma::capturer::start  ::rtcma::capturer::attach
            ::rtcma::capturer::detach ::rtcma::capturer::destroy
        } {
            if {[info commands $cmd] ne ""} {
                rename $cmd ${cmd}__real
            }
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

    proc onIncoming {argsL} {
        variable IncomingSid
        variable IncomingFrom
        set IncomingSid  [dict get $argsL -sid]
        set IncomingFrom [dict get $argsL -from]
    }
    proc onOutgoing {argsL} {
        variable OutgoingSid
        variable OutgoingTo
        set OutgoingSid [dict get $argsL -sid]
        set OutgoingTo  [dict get $argsL -to]
    }
    # Funnel the per-event listeners into one States list per side.
    proc appendRomeo  state { variable RomeoStates;  lappend RomeoStates  $state }
    proc appendJuliet state { variable JulietStates; lappend JulietStates $state }
    proc onRomeoWarning {argsL} {
        variable RomeoWarnings
        lappend RomeoWarnings [dict get $argsL -reason]
    }
    proc onJulietWarning {argsL} {
        variable JulietWarnings
        lappend JulietWarnings [dict get $argsL -reason]
    }

    # Spin the event loop until $body (evaluated at uplevel 1) is true.
    # It re-runs after every event, so it must test accumulated state.
    proc waitUntil {body {timeout 0}} {
        variable TIMEOUT
        if {$timeout == 0} { set timeout $TIMEOUT }
        set deadline [expr {[clock milliseconds] + $timeout}]
        while {![uplevel 1 [list expr $body]]} {
            set remaining [expr {$deadline - [clock milliseconds]}]
            if {$remaining <= 0} {
                error "waitUntil timeout: $body"
            }
            set afterId [after [expr {min($remaining, 50)}] \
                [list set [namespace current]::_wakeup 1]]
            vwait [namespace current]::_wakeup
            after cancel $afterId
        }
    }

    proc setup {} {
        variable HOST
        variable ROMEO
        variable JULIET

        reset
        muteRtcma

        tacky_init

        # The rig has no mod_external_services, so the extdisco fetch
        # comes back empty; ICE converges off host candidates alone.

        tacky account add {*}$::tacky_test_account_args -acc $ROMEO  -password romeopass \
            -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass \
            -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET

        wait_events {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
        }

        tacky listen -tag calls_int calls <Outgoing> -acc $ROMEO \
            ::test::calls_int::onOutgoing
        tacky listen -tag calls_int calls <Incoming> -acc $JULIET \
            ::test::calls_int::onIncoming
        foreach {event tag} {<Ringing> ringing <Active> active <Ended> ended <Failed> failed} {
            tacky listen -tag calls_int calls $event -acc $ROMEO \
                [list apply {{t ev} {::test::calls_int::appendRomeo $t}} $tag]
            tacky listen -tag calls_int calls $event -acc $JULIET \
                [list apply {{t ev} {::test::calls_int::appendJuliet $t}} $tag]
        }
        tacky listen -tag calls_int calls <Warning> -acc $ROMEO \
            ::test::calls_int::onRomeoWarning
        tacky listen -tag calls_int calls <Warning> -acc $JULIET \
            ::test::calls_int::onJulietWarning
        foreach {acc var} [list $ROMEO RomeoVerified $JULIET JulietVerified] {
            tacky listen -tag calls_int calls <Verified> -acc $acc \
                [list apply {{var ev} {
                    lappend ::test::calls_int::$var \
                        [list [dict get $ev -verified] [dict get $ev -fingerprint]]
                }} $var]
        }
    }

    # A call from Romeo that Juliet accepts, up until both are active, then
    # (after $whileActive, at the caller's level) hung up. Returns the sid.
    proc activeCall {{whileActive ""}} {
        variable ROMEO
        variable JULIET
        set sid [tacky calls start -acc $ROMEO -to $JULIET]
        waitUntil {[set ::test::calls_int::IncomingSid] eq $sid}
        tacky calls accept -acc $JULIET -sid $sid
        waitUntil {
            "active" in [set ::test::calls_int::RomeoStates] &&
            "active" in [set ::test::calls_int::JulietStates]
        } 30000
        uplevel 1 $whileActive
        tacky calls hangup -acc $ROMEO -sid $sid
        waitUntil {
            "ended" in [set ::test::calls_int::RomeoStates] &&
            "ended" in [set ::test::calls_int::JulietStates]
        }
        return $sid
    }

    # Each side's last <Verified>, the key compared with the other's own.
    proc verdicts {} {
        variable ROMEO
        variable JULIET
        variable RomeoVerified
        variable JulietVerified
        set romeoKey [tacky omemo own_fingerprint -acc $ROMEO]
        set julietKey [tacky omemo own_fingerprint -acc $JULIET]
        lassign [lindex $RomeoVerified end] rv rfp
        lassign [lindex $JulietVerified end] jv jfp
        list romeo $rv [expr {$rfp eq "" ? "none" : $rfp eq $julietKey}] \
            juliet $jv [expr {$jfp eq "" ? "none" : $jfp eq $romeoKey}]
    }

    # Each side trusts the device the other's call came from.
    proc trustEachOther {} {
        variable ROMEO
        variable JULIET
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set dev [tacky omemo device_id -acc $peer]
            tacky omemo trust -acc $acc -jid $peer -device $dev -state trusted
        }
    }

    proc cleanup {} {
        catch {tacky unlisten calls_int}
        catch {tacky destroy}
        unmuteRtcma
    }

    set common {
        -constraints {withServer && !wasm}
        -setup    { ::test::calls_int::setup }
        -cleanup  { ::test::calls_int::cleanup }
    }

    # --- Callee rejects an incoming JMI propose ---

    test calls-int-jmi-reject \
        {Juliet rejects Romeo's JMI propose before any Jingle IQ flows} \
        {*}$common -body {
            set sid [tacky calls start -acc $ROMEO -to $JULIET]

            waitUntil {[set ::test::calls_int::IncomingSid] eq $sid}

            tacky calls reject -acc $JULIET -sid $sid

            waitUntil {"ended" in [set ::test::calls_int::RomeoStates]}

            list \
                [expr {[set ::test::calls_int::OutgoingSid]  eq $sid}] \
                [expr {[set ::test::calls_int::IncomingFrom] eq $::test::calls_int::ROMEO}] \
                [expr {"ended" in [set ::test::calls_int::RomeoStates]}] \
                [llength [set ::test::calls_int::JulietWarnings]]
        } -result {1 1 1 0}

    # --- Caller retracts the propose before callee answers ---

    test calls-int-retract \
        {Romeo cancels a ringing call; Juliet sees ended via retract} \
        {*}$common -body {
            set sid [tacky calls start -acc $ROMEO -to $JULIET]

            waitUntil {[set ::test::calls_int::IncomingSid] eq $sid}

            tacky calls hangup -acc $ROMEO -sid $sid

            waitUntil {"ended" in [set ::test::calls_int::JulietStates]}

            list \
                [expr {[set ::test::calls_int::OutgoingSid] eq $sid}] \
                [expr {"ended" in [set ::test::calls_int::JulietStates]}]
        } -result {1 1}

    # --- Full call: accept, both sides reach active, caller hangs up ---

    test calls-int-accept-active-hangup \
        {Romeo calls Juliet, Juliet accepts, both reach active, Romeo hangs up} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm} -body {
            set sid [tacky calls start -acc $ROMEO -to $JULIET]

            waitUntil {[set ::test::calls_int::IncomingSid] eq $sid}

            tacky calls accept -acc $JULIET -sid $sid

            # Loopback DTLS lands well under 10s; the rest is slack for
            # cold libdatachannel init.
            waitUntil {
                "active" in [set ::test::calls_int::RomeoStates] &&
                "active" in [set ::test::calls_int::JulietStates]
            } 30000

            tacky calls hangup -acc $ROMEO -sid $sid

            waitUntil {
                "ended" in [set ::test::calls_int::RomeoStates] &&
                "ended" in [set ::test::calls_int::JulietStates]
            }

            list \
                [expr {"active" in [set ::test::calls_int::RomeoStates]}] \
                [expr {"active" in [set ::test::calls_int::JulietStates]}] \
                [expr {"ended"  in [set ::test::calls_int::RomeoStates]}] \
                [expr {"ended"  in [set ::test::calls_int::JulietStates]}] \
                [llength [set ::test::calls_int::RomeoWarnings]] \
                [llength [set ::test::calls_int::JulietWarnings]]
        } -result {1 1 1 1 0 0}

    # --- Verification through OMEMO, with real DTLS ---
    #
    # Each side's fingerprint is OMEMO-encrypted for the other's device.
    # The call only reaches active if the decrypted fingerprints match the
    # certificates DTLS sees.

    test calls-int-verified-by-each-others-key \
        {each side's fingerprint is authenticated by the other's OMEMO key, which blind trust accepts as it would for a message} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm} -body {
            ::test::calls_int::activeCall
            ::test::calls_int::verdicts
        } -result {romeo 1 1 juliet 1 1}

    test calls-int-verified-once-trusted \
        {without blind trust, trusting each other's key mid-call turns the call verified, and the next one is from the start} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm} -body {
            foreach acc [list $::test::calls_int::ROMEO $::test::calls_int::JULIET] {
                tacky omemo setBlindTrust -acc $acc -value 0
            }
            ::test::calls_int::activeCall {
                set before [::test::calls_int::verdicts]
                ::test::calls_int::trustEachOther
                set during [::test::calls_int::verdicts]
            }
            ::test::calls_int::reset
            ::test::calls_int::activeCall
            list $before $during [::test::calls_int::verdicts]
        } -result {{romeo 0 1 juliet 0 1} {romeo 1 1 juliet 1 1} {romeo 1 1 juliet 1 1}}

    test calls-int-plain-with-omemo-off \
        {with OMEMO off for the chat on one side, the call is plain both ways and still connects} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm} -body {
            tacky omemo setEnabled -acc $::test::calls_int::JULIET \
                -jid $::test::calls_int::ROMEO -value 0
            ::test::calls_int::activeCall
            ::test::calls_int::verdicts
        } -result {romeo 0 none juliet 0 none}
}
