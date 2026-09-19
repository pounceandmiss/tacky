# The host media backend: commands leaving for the embedding app, and the
# app's answers coming back. The contract it shares with every other backend
# is checked by the conformance script (test_media_conformance.tcl); what is
# here is the half only this backend has.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::media
package require tacky::media::host

# Commands for the app land in ::host_cmds, events for a pc in ::host_events.
proc host_sink {args} { lappend ::host_cmds $args }
proc host_pc_sink {ev} { lappend ::host_events $ev }

proc host_setup {} {
    set ::host_was [::tacky::media backend]
    set ::host_cmds {}
    set ::host_events {}
    ::tacky::media open host -emit host_sink
    ::tacky::media createPeer p1 -command host_pc_sink
    set ::host_cmds {}
}

proc host_cleanup {} {
    ::tacky::media close
    if {$::host_was ne ""} { ::tacky::media open $::host_was }
}

proc host_send {args} {
    ::tacky::media::host::event [dict create pc p1 {*}$args]
}

# The first event of that type, or "" - what a caller saw, in other words.
proc host_event {type} {
    foreach ev $::host_events {
        if {[dict get $ev type] eq $type} { return $ev }
    }
    return ""
}

# Put the process-wide backend back the way this file found it. Naming rtc
# outright would tie these tests to a build that has it - a browser build does
# not - and what matters is only that the next test starts from the same
# place as this one did.
proc host_restore {} {
    ::tacky::media close
    foreach name {rtc host} {
        if {$name in [::tacky::media available]} {
            ::tacky::media open $name
            return
        }
    }
}

set host_env [list -setup host_setup -cleanup host_cleanup]

# -- commands out -----------------------------------------------------------

test media-host-createPeer-carries-ice-servers \
    {createPeer reaches the app with the servers tacky fetched} \
    {*}$host_env -body {
        ::tacky::media createPeer p2 -command host_pc_sink \
            -ice-servers {stun:stun.example.com:3478}
        set ::host_cmds
    } -result {{-op createPeer -pc p2 -iceServers stun:stun.example.com:3478 -sid {}}}

test media-host-createPeer-carries-sid \
    {the call a pc serves goes with createPeer, so the app can render per call} \
    {*}$host_env -body {
        ::tacky::media createPeer p2 -command host_pc_sink -sid sid-42
        set ::host_cmds
    } -result {{-op createPeer -pc p2 -iceServers {} -sid sid-42}}

test media-host-sdp-goes-out-typed {an SDP command names its own type} \
    {*}$host_env -body {
        ::tacky::media setRemoteDescription p1 -sdp "v=0" -type offer
        ::tacky::media setLocalDescription p1 -type answer
        set ::host_cmds
    } -result {{-op setRemoteDescription -pc p1 -sdp v=0 -sdpType offer} {-op setLocalDescription -pc p1 -sdp {} -sdpType answer}}

test media-host-attach-audio-carries-devices \
    {attachAudio passes the endpoints and gains through} {*}$host_env -body {
        ::tacky::media addTrack p1 audio -kind audio
        ::tacky::media attachAudio p1 audio -input mic1 -output out1 \
            -input-volume 0.5 -output-volume 1.0
        lindex $::host_cmds 1
    } -result {-op attachAudio -pc p1 -track audio -input mic1 -output out1 -inputVolume 0.5 -outputVolume 1.0}

test media-host-close-tells-the-app {closing the backend says so} -setup {
    host_setup
} -cleanup {
    if {$::host_was ne ""} { ::tacky::media open $::host_was }
} -body {
    ::tacky::media close
    lindex $::host_cmds end
} -result {-op close}

# -- video ------------------------------------------------------------------

# The app renders its own tracks, so the channel descriptor is the track
# handle it already holds rather than a region to map.
test media-host-video-channel-is-the-track {attaching video answers with a host channel} \
    {*}$host_env -body {
        ::tacky::media addTrack p1 video -kind video
        ::tacky::media attachVideoSender p1 video -device-id ""
        set ev [host_event videoChannel]
        list [dict get $ev direction] [dict get $ev mid] [dict get $ev channel]
    } -result {preview video {kind host id video}}

test media-host-video-channel-uses-the-peers-mid \
    {an incoming channel carries the mid the app reported for that track} \
    {*}$host_env -body {
        host_send type track track v7 kind video mid 1
        ::tacky::media attachVideoReceiver p1 v7
        set ev [host_event videoChannel]
        list [dict get $ev direction] [dict get $ev mid] [dict get $ev channel]
    } -result {incoming 1 {kind host id v7}}

# -- events in --------------------------------------------------------------

test media-host-event-reaches-the-pc {an answer lands on the pc that asked} \
    {*}$host_env -body {
        host_send type localDescription sdp "v=0" sdpType offer
        set ev [host_event localDescription]
        list [dict get $ev pc] [dict get $ev sdpType]
    } -result {p1 offer}

# The app sends what its RTCIceCandidate has; sdpMid is optional there.
test media-host-candidate-without-mid-means-audio \
    {a candidate with no mid gets the one m-line a call always has} \
    {*}$host_env -body {
        host_send type iceCandidate candidate "candidate:1 1 udp 1 192.0.2.1 1 typ host"
        dict get [host_event iceCandidate] mid
    } -result audio

test media-host-unknown-event-is-reported {an event type nobody knows comes back as an error} \
    {*}$host_env -body {
        host_send type telepathy
        set ev [host_event error]
        list [dict get $ev fatal] [dict get $ev reason]
    } -result {0 {unknown event type telepathy}}

test media-host-incomplete-event-is-reported {a missing key is the app's bug, not a crash} \
    {*}$host_env -body {
        host_send type track track v7 kind video
        list [dict get [host_event error] reason] [host_event track]
    } -result {{track event has no mid} {}}

test media-host-event-needs-a-pc {an event naming no pc is refused outright} \
    {*}$host_env -body {
        catch {::tacky::media::host::event {type connectionState state failed}} err
        set err
    } -result {host media event: no pc in type connectionState state failed}

# -- selection --------------------------------------------------------------

test media-host-selected-by-name {-media-backend host opens it} -body {
    taco_type create ::taco_mh -transient 1 -media-backend host
    set got [::taco_mh media backend]
    ::taco_mh destroy
    host_restore
    set got
} -result host

test media-host-commands-are-events {a command for the app leaves as media <HostCommand>} -constraints !wasm \
    {*}[tacky_env -capture-emit 1 -extra-setup {
        taco_type create ::taco_mh -transient 1 -media-backend host
    } -extra-cleanup {
        ::taco_mh destroy
        host_restore
    }] -body {
        ::tacky::media createPeer p3 -command host_pc_sink
        set out {}
        foreach e $::_emitted {
            if {[lindex $e 0] eq "media"} { lappend out [lrange $e 1 end] }
        }
        set out
    } -result {{<HostCommand> -op createPeer -pc p3 -iceServers {} -sid {}}}

test media-host-event-needs-the-host-backend \
    {hostEvent on another backend is a mistake worth reporting} -constraints !wasm \
    {*}[tacky_env] -body {
        catch {tacky media hostEvent -pc p1 -type connectionState -state failed} err
        set err
    } -result {media hostEvent: the host backend is not open}

cleanupTests
