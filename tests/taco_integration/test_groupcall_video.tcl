package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# Video group calls end to end: three accounts in hosted calls on Prosody,
# over libtacky_webrtc.so ($TACKY_WEBRTC_LIB, default dist/) with its fake
# camera and dummy audio. Frames are counted: each leg's incoming video, and
# the self-view, which must keep running as peers leave. The accounts share
# the process, and so one camera.
namespace eval ::test::groupcall_video {

    variable HOST "example.local"
    variable TIMEOUT 15000
    variable LIVE_TIMEOUT 30000

    variable ROMEO  "romeo@example.local"
    variable JULIET "juliet@example.local"
    variable TEST   "test@example.local"
    variable PASS   {romeo@example.local romeopass juliet@example.local julietpass
                     test@example.local testpass}
    variable NICK   {romeo@example.local romeo juliet@example.local juliet
                     test@example.local test}

    variable RoomSeq 0
    variable ROOM ""
    variable Events
    variable Legs

    variable LIB [expr {[info exists ::env(TACKY_WEBRTC_LIB)] ? $::env(TACKY_WEBRTC_LIB)
        : [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] \
            dist libtacky_webrtc.so]}]
    ::tcltest::testConstraint webrtcLib [file exists $LIB]

    proc waitUntil {body {timeout 0}} {
        variable TIMEOUT
        if {$timeout == 0} { set timeout $TIMEOUT }
        set deadline [expr {[clock milliseconds] + $timeout}]
        while {![uplevel 1 [list expr $body]]} {
            set remaining [expr {$deadline - [clock milliseconds]}]
            if {$remaining <= 0} { error "waitUntil timeout: $body" }
            set id [after [expr {min($remaining, 50)}] [list set [namespace current]::_wake 1]]
            vwait [namespace current]::_wake
            after cancel $id
        }
    }

    proc settle {ms} {
        after $ms [list set [namespace current]::_settled 1]
        vwait [namespace current]::_settled
    }

    proc onGroupcall {acc event argsL} {
        variable Events
        lappend Events($acc) [list $event [dict remove $argsL -acc]]
    }

    proc onLeg {acc state argsL} {
        variable Legs
        lappend Legs($acc,[dict get $argsL -sid]) $state
    }

    proc events {acc event} {
        variable Events
        if {![info exists Events($acc)]} { return {} }
        set out {}
        foreach e $Events($acc) {
            if {[lindex $e 0] eq $event} { lappend out [lindex $e 1] }
        }
        return $out
    }

    proc has {acc event} { expr {[llength [events $acc $event]] > 0} }

    # Peer bare JID -> sid of every group leg $acc has now.
    proc legsOf {acc} {
        set out {}
        foreach row [tacky calls list -acc $acc] {
            if {[dict get $row group] eq ""} continue
            dict set out [dict get $row peer] [dict get $row sid]
        }
        return $out
    }

    proc legActive {acc sid} {
        variable Legs
        expr {[info exists Legs($acc,$sid)] && "active" in $Legs($acc,$sid)}
    }

    # Everyone in $accs has a live leg to each of the others.
    proc meshLive {accs} {
        foreach acc $accs {
            set legs [legsOf $acc]
            if {[dict size $legs] < [llength $accs] - 1} { return 0 }
            dict for {peer sid} $legs {
                if {![legActive $acc $sid]} { return 0 }
            }
        }
        return 1
    }

    # -- Frames ---------------------------------------------------------------

    # Frames decoded so far on $acc's leg to $peer (a bare JID).
    proc incoming {acc peer} {
        set legs [legsOf $acc]
        if {![dict exists $legs $peer]} { return -1 }
        set sid [dict get $legs $peer]
        set h [lindex [array names ::tacky::media::PcCb */$sid] 0]
        if {$h eq ""} { return -1 }
        dict get [::tacky::media::webrtc::Op test-streams $h] incoming
    }

    proc camera {} { ::tacky::media::webrtc::Op test-camera }

    # $script's count grows by $by within the live timeout: frames flowing now.
    proc grows {script {by 10}} {
        variable LIVE_TIMEOUT
        set start [uplevel 1 $script]
        if {$start < 0} { return 0 }
        set deadline [expr {[clock milliseconds] + $LIVE_TIMEOUT}]
        while {[clock milliseconds] < $deadline} {
            settle 100
            if {[uplevel 1 $script] >= $start + $by} { return 1 }
        }
        return 0
    }

    # Every leg of every $accs is decoding video right now.
    proc allFlowing {accs} {
        foreach acc $accs {
            foreach peer [dict keys [legsOf $acc]] {
                if {![grows [list incoming $acc $peer]]} { return "$acc<-$peer" }
            }
        }
        return ok
    }

    proc previewFlowing {} { grows {dict get [camera] preview} }

    # -- Room and calls -------------------------------------------------------

    proc enterRoom {acc} {
        variable ROOM
        variable NICK
        tacky muc join -acc $acc -jid $ROOM -nick [dict get $NICK $acc]
        waitUntil {[tacky muc isJoined -acc $acc -jid $ROOM]}
    }

    proc createRoom {} {
        variable ROMEO
        variable ROOM
        variable RoomSeq
        set ROOM "gv[incr RoomSeq]-[clock milliseconds]@conference.example.local"
        enterRoom $ROMEO
        [tacky client $ROMEO] muc configGet -jid $ROOM \
            -command [list apply {{f} { set ::test::groupcall_video::_form $f }}]
        waitUntil {[info exists ::test::groupcall_video::_form]}
        set form [::tacky::forms::apply $::test::groupcall_video::_form \
            {muc#roomconfig_whois anyone}]
        unset ::test::groupcall_video::_form
        [tacky client $ROMEO] muc configSet -jid $ROOM -form $form \
            -command [list apply {{s} { set ::test::groupcall_video::_set 1 }}]
        waitUntil {[info exists ::test::groupcall_video::_set]}
        unset ::test::groupcall_video::_set
    }

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

    # Romeo starts a video call; each of $order answers it in turn, with
    # video unless named in $audioOnly. Returns the call's room.
    proc videoCall {order {audioOnly {}}} {
        variable ROMEO
        variable ROOM
        variable LIVE_TIMEOUT
        foreach acc $order { enterRoom $acc }
        tacky groupcall start -acc $ROMEO -chat $ROOM -video 1
        waitUntil {[has $ROMEO <Started>]}
        set call [dict get [lindex [events $ROMEO <Started>] 0] -jid]
        waitUntil {[has $ROMEO <Joined>]}
        foreach acc $order {
            waitUntil {[llength [callRows $acc]] > 0}
            tacky groupcall join -acc $acc -chat $ROOM?join \
                -timestamp [lindex [callRows $acc] end 0] -video [expr {$acc ni $audioOnly}]
            waitUntil {[has $acc <Joined>]}
        }
        waitUntil {[meshLive [list $ROMEO {*}$order]]} $LIVE_TIMEOUT
        return $call
    }

    proc leave {acc call} { tacky groupcall leave -acc $acc -jid $call }

    # -- Setup ----------------------------------------------------------------

    proc setup {} {
        variable HOST
        variable PASS
        variable LIB
        variable Events
        variable Legs
        array unset Events
        array unset Legs
        set ::env(TACKY_WEBRTC_FAKE_CAMERA) 1
        set ::env(TACKY_WEBRTC_DUMMY_AUDIO) 1
        tacky_init -media-backend webrtc -webrtc-lib $LIB
        foreach {acc pass} $PASS {
            tacky account add -acc $acc -password $pass \
                -domain $HOST -username [lindex [split $acc @] 0]
            tacky account enable -acc $acc
        }
        wait_events [lmap {acc pass} $PASS {
            list conn <State> -acc $acc -state connected
        }]
        foreach {acc pass} $PASS {
            foreach ev {<Joined> <PeerJoined> <PeerLeft> <Left> <Warning>
                        <Started> <StartFailed> <VideoPreview>} {
                tacky listen -tag gc_video groupcall $ev -acc $acc \
                    [list ::test::groupcall_video::onGroupcall $acc $ev]
            }
            foreach {ev state} {<Active> active <Ended> ended <Failed> failed} {
                tacky listen -tag gc_video calls $ev -acc $acc \
                    [list ::test::groupcall_video::onLeg $acc $state]
            }
        }
        createRoom
    }

    proc cleanup {} {
        catch {tacky unlisten gc_video}
        catch {tacky destroy}
    }

    set common {
        -constraints {withServer && notMongoose && notEjabberd && !wasm && webrtcLib}
        -setup   { ::test::groupcall_video::setup }
        -cleanup { ::test::groupcall_video::cleanup }
    }

    # == Three with video ======================================================

    test groupcall-video-three-mesh \
        {three with video: every leg decodes, one camera serves every sender and self-view} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            set cam [camera]
            list [allFlowing [list $ROMEO $JULIET $TEST]] [previewFlowing] \
                [dict get $cam open] [dict get $cam users] \
                [llength [events $ROMEO <VideoPreview>]]
        } -result {ok 1 1 9 1}

    test groupcall-video-one-leaves {one of three leaving: the other two keep seeing each other} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            leave $JULIET $call
            waitUntil {[dict size [legsOf $ROMEO]] == 1 && [dict size [legsOf $TEST]] == 1}
            list [allFlowing [list $ROMEO $TEST]] [previewFlowing] [dict get [camera] users]
        } -result {ok 1 4}

    # The bug that started this: the self-view froze when the only peer left.
    test groupcall-video-alone-self-view {everyone else gone: our self-view keeps running} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            leave $TEST $call
            leave $JULIET $call
            waitUntil {[dict size [legsOf $ROMEO]] == 0}
            settle 500
            set cam [camera]
            list [dict get $cam open] [dict get $cam users] [previewFlowing] \
                [expr {[dict get [lindex [tacky groupcall list -acc $ROMEO] 0] preview] ne ""}]
        } -result {1 1 1 1}

    test groupcall-video-starter-leaves {the starter leaving: the two who joined keep their video} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            leave $ROMEO $call
            waitUntil {[dict size [legsOf $JULIET]] == 1 && [dict size [legsOf $TEST]] == 1}
            allFlowing [list $JULIET $TEST]
        } -result ok

    test groupcall-video-rejoin {back into a call still going: video both ways with everyone} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            variable ROOM
            variable LIVE_TIMEOUT
            set call [videoCall [list $JULIET $TEST]]
            leave $JULIET $call
            waitUntil {[dict size [legsOf $ROMEO]] == 1}
            settle 1000
            array unset ::test::groupcall_video::Events $JULIET
            tacky groupcall start -acc $JULIET -chat $ROOM -video 1
            waitUntil {[has $JULIET <Joined>]}
            waitUntil {[meshLive [list $ROMEO $JULIET $TEST]]} $LIVE_TIMEOUT
            list [has $JULIET <Started>] [allFlowing [list $ROMEO $JULIET $TEST]] \
                [dict get [camera] users]
        } -result {0 ok 9}

    test groupcall-video-one-drops {one of three dropping off the network: the others' video goes on} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            [tacky client $TEST] disconnect
            waitUntil {![dict exists [legsOf $ROMEO] test@example.local]
                       && ![dict exists [legsOf $JULIET] test@example.local]} 60000
            list [allFlowing [list $ROMEO $JULIET]] [previewFlowing]
        } -result {ok 1}

    test groupcall-video-audio-only-joiner {an audio-only joiner holds no camera; the others' video still flows} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST] [list $TEST]]
            set videoLegs {}
            foreach row [tacky calls list -acc $TEST] {
                lappend videoLegs [dict get $row video_local]
            }
            list [grows [list incoming $ROMEO juliet@example.local]] \
                [grows [list incoming $JULIET romeo@example.local]] \
                [has $TEST <VideoPreview>] [lsort -unique $videoLegs] \
                [dict get [camera] users]
        } -result {1 1 0 0 4}

    test groupcall-video-all-leave-camera-off {the last of us leaving closes the camera} \
        {*}$common -body {
            variable ROMEO
            variable JULIET
            variable TEST
            set call [videoCall [list $JULIET $TEST]]
            foreach acc [list $JULIET $ROMEO $TEST] { leave $acc $call }
            waitUntil {[dict get [camera] open] == 0}
            dict get [camera] users
        } -result 0
}
