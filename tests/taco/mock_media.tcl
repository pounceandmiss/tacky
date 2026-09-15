# A tacky::media backend that does nothing but remember. Where mock_rtc.tcl
# stands in for the three extensions, this stands in for a whole backend, so
# the signaling half of taco_calls can be driven without one - and so the
# conformance script has a second implementation to run against.
#
# It is deliberately not self-driving: nothing here invents a local
# description or a connection state. Tests fire those with mockmedia::drive,
# the same driver interface the conformance script asks every backend for.
package provide tacky::mockmedia 0.1

package require tacky::media

namespace eval mockmedia {
    variable Log {}
    variable Fail {}
    variable Caps {}
    variable Seq 0
    variable Tracks   ;# pc,track -> kind
    array set Tracks {}

    variable DEFAULT_CAPS {
        audioDevices 1 audioVolume 1 cameras 1 videoDevice 1 videoChannel 1
        autoAnswer 1 sdpSanitize 1 trickleIce 1
    }
}

::tacky::media register mock ::mockmedia::Op

proc mockmedia::reset {} {
    variable Log
    variable Fail
    variable Caps
    variable Seq
    variable Tracks
    variable DEFAULT_CAPS
    set Log {}
    set Fail {}
    set Caps $DEFAULT_CAPS
    set Seq 0
    array unset Tracks
}

mockmedia::reset

# Declare a different capability set before opening, to exercise a caller's
# gating (a backend with no cameras, a host backend that owns volume itself).
proc mockmedia::capabilities {caps} {
    variable Caps
    set Caps $caps
}

proc mockmedia::log {} {
    variable Log
    return $Log
}

proc mockmedia::calls {op} {
    variable Log
    set out {}
    foreach entry $Log {
        if {[lindex $entry 0] eq $op} { lappend out [lrange $entry 1 end] }
    }
    return $out
}

proc mockmedia::fail {op msg {pattern *}} {
    variable Fail
    lappend Fail [list $op $pattern $msg]
}

# The driver the conformance script uses: make the backend produce one event.
proc mockmedia::drive {what pc args} {
    variable Seq
    variable Tracks
    switch -- $what {
        localDescription {
            lassign $args sdp type
            ::tacky::media::emit $pc localDescription sdp $sdp sdpType $type
        }
        iceCandidate {
            lassign $args cand mid
            # A real backend knows which m-line an empty mid means; a
            # caller naming a Jingle content cannot guess.
            if {$mid eq ""} { set mid audio }
            ::tacky::media::emit $pc iceCandidate candidate $cand mid $mid
        }
        connectionState {
            ::tacky::media::emit $pc connectionState state [lindex $args 0]
        }
        gatheringState {
            ::tacky::media::emit $pc gatheringState state [lindex $args 0]
        }
        remoteTrack {
            # A peer's own mid scheme, not the labels a caller picks.
            set kind [lindex $args 0]
            set tr mt[incr Seq]
            set Tracks($pc,$tr) $kind
            ::tacky::media::emit $pc track track $tr kind $kind mid [incr Seq]
            return $tr
        }
        default { error "mockmedia: cannot drive $what" }
    }
    return
}

proc mockmedia::Op {op args} {
    variable Log
    variable Fail
    variable Caps
    variable Seq
    variable Tracks

    lappend Log [linsert $args 0 $op]
    foreach rule $Fail {
        lassign $rule failOp pattern msg
        if {$op eq $failOp && [string match $pattern $args]} {
            error $msg
        }
    }

    switch -- $op {
        Capabilities { return $Caps }
        Codecs       { return {audio {} video {}} }
        AddTrack {
            lassign $args pc track
            set opts [lrange $args 2 end]
            set Tracks($pc,$track) [dict get $opts -kind]
        }
        ClosePeer {
            set pc [lindex $args 0]
            array unset Tracks $pc,*
        }
        AttachVideoSender {
            if {[dict get $Caps videoChannel]} {
                lassign $args pc track
                ::tacky::media::emit $pc videoChannel track $track \
                    direction preview mid video channel [Channel $pc $track]
            }
        }
        AttachVideoReceiver {
            if {[dict get $Caps videoChannel]} {
                lassign $args pc track
                ::tacky::media::emit $pc videoChannel track $track \
                    direction incoming mid video channel [Channel $pc $track]
            }
        }
        EnumerateAudioDevices {
            set opts $args
            uplevel #0 [list {*}[dict get $opts -command] [dict create \
                capture  [list [dict create name "Mock mic" id mic1 default 1]] \
                playback [list [dict create name "Mock out" id out1 default 1]]]]
        }
        EnumerateCameras {
            set opts $args
            uplevel #0 [list {*}[dict get $opts -command] \
                [list [dict create name "Mock cam" id cam1 facing 0]]]
        }
    }
    return
}

# The shm form, so a caller that maps rings by name works against the mock
# exactly as it does against rtc.
proc mockmedia::Channel {pc track} {
    variable Seq
    set n [incr Seq]
    return [dict create kind shm name "/tv-mock$n" channel "vc-mock$n" \
        slots 6 slotBytes 1400000 maxWidth 1280 maxHeight 720 format I420]
}
