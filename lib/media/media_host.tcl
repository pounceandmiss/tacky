# tacky::media with the media half in the embedding app. Tacky keeps Jingle,
# call state and the SDP; the app drives its own peer connection - a browser's
# RTCPeerConnection, WebRTC.xcframework, Android's org.webrtc - on platforms
# where the WebRTC stack belongs to the host and cannot be linked in.
#
# Every command becomes one event for the app (taco sends it as
# `media <HostCommand>`, with `op` naming the verb); every answer comes back
# through `event` below (taco exposes it as `media hostEvent`). Nothing waits:
# commands are fire and forget, answers arrive whenever the app gets to them,
# and one for a pc that has gone is dropped.
#
# Handles: tacky names the pcs and the tracks it adds, and its own track
# handles double as their mids; the app names the tracks the peer adds and
# reports each with a `track` event.
#
# The app owns its devices - a browser has its own picker and its own volume -
# so this backend declares none and never asks. It does declare `videoChannel`,
# in the host form: the descriptor is the app's own track id.

package provide tacky::media::host 0.1

package require tacky::media

namespace eval ::tacky::media::host {
    variable Emit {}   ;# command prefix commands for the app go out on
    variable Mid {}    ;# pc -> track -> mid, as the app reported them

    # What the app may send, and what each one owes beyond `pc` and `type`.
    variable EVENTS {
        localDescription {sdp sdpType}
        iceCandidate     {candidate}
        gatheringState   {state}
        connectionState  {state}
        track            {track kind mid}
        deviceFallback   {kind id reason}
        error            {op reason}
    }

    # A candidate with no mid means the audio m-line: the one a caller cannot
    # name for itself, and the only m-line a call is guaranteed to have.
    variable DEFAULT_MID audio
}

::tacky::media register host ::tacky::media::host::Op

proc ::tacky::media::host::Op {op args} {
    return [::tacky::media::host::$op {*}$args]
}

namespace eval ::tacky::media::host {
    namespace export Open Close Capabilities Codecs CreatePeer ClosePeer \
        AddTrack SetLocalDescription SetRemoteDescription AddRemoteCandidate \
        AttachAudio SetAudioDevice SetAudioVolume AttachVideoSender \
        AttachVideoReceiver SetVideoEnabled SetVideoDevice \
        EnumerateAudioDevices EnumerateCameras
}

# Lifecycle

# Reopening without -emit keeps the channel the app is already listening on:
# a backend swapped out and back is the same app.
proc ::tacky::media::host::Open {args} {
    variable Emit
    if {[dict exists $args -emit]} {
        set Emit [dict get $args -emit]
    }
    return
}

proc ::tacky::media::host::Close {} {
    variable Mid
    Command close
    set Mid {}
    return
}

proc ::tacky::media::host::Capabilities {} {
    return {
        audioDevices 0 audioVolume 0 cameras 0 videoDevice 0 videoChannel 1
        autoAnswer 0 sdpSanitize 0 trickleIce 1
    }
}

# No opinion: what the app's stack decodes is the app's to know.
proc ::tacky::media::host::Codecs {} {
    return {audio {} video {}}
}

# Peer connections

proc ::tacky::media::host::CreatePeer {h args} {
    set opts [dict merge {-ice-servers {} -sid ""} $args]
    Command createPeer -pc $h -iceServers [dict get $opts -ice-servers] \
        -sid [dict get $opts -sid]
    return
}

proc ::tacky::media::host::ClosePeer {h} {
    variable Mid
    dict unset Mid $h
    Command closePeer -pc $h
    return
}

proc ::tacky::media::host::AddTrack {h track args} {
    set opts [dict merge {-kind audio -direction sendrecv} $args]
    Command addTrack -pc $h -track $track \
        -kind [dict get $opts -kind] -direction [dict get $opts -direction]
    return
}

proc ::tacky::media::host::SetLocalDescription {h args} {
    set opts [dict merge {-sdp "" -type ""} $args]
    Command setLocalDescription -pc $h \
        -sdp [dict get $opts -sdp] -sdpType [dict get $opts -type]
    return
}

proc ::tacky::media::host::SetRemoteDescription {h args} {
    set opts [dict merge {-sdp "" -type ""} $args]
    Command setRemoteDescription -pc $h \
        -sdp [dict get $opts -sdp] -sdpType [dict get $opts -type]
    return
}

proc ::tacky::media::host::AddRemoteCandidate {h args} {
    set opts [dict merge {-candidate "" -mid ""} $args]
    Command addRemoteCandidate -pc $h \
        -candidate [dict get $opts -candidate] -mid [dict get $opts -mid]
    return
}

# Media attachment

proc ::tacky::media::host::AttachAudio {h track args} {
    set opts [dict merge \
        {-input "" -output "" -input-volume 1.0 -output-volume 1.0} $args]
    Command attachAudio -pc $h -track $track \
        -input [dict get $opts -input] -output [dict get $opts -output] \
        -inputVolume [dict get $opts -input-volume] \
        -outputVolume [dict get $opts -output-volume]
    return
}

proc ::tacky::media::host::SetAudioDevice {h args} {
    set opts [dict merge {-kind "" -id ""} $args]
    Command setAudioDevice -pc $h \
        -kind [dict get $opts -kind] -id [dict get $opts -id]
    return
}

proc ::tacky::media::host::SetAudioVolume {h args} {
    set opts [dict merge {-kind "" -volume 1.0} $args]
    Command setAudioVolume -pc $h \
        -kind [dict get $opts -kind] -volume [dict get $opts -volume]
    return
}

# The channel goes out with the command rather than after it: it is the app's
# own track id, so there is nothing to wait for.
proc ::tacky::media::host::AttachVideoSender {h track args} {
    set opts [dict merge {-device-id ""} $args]
    Command attachVideoSender -pc $h -track $track \
        -deviceId [dict get $opts -device-id]
    Channel $h $track preview
    return
}

proc ::tacky::media::host::AttachVideoReceiver {h track args} {
    Command attachVideoReceiver -pc $h -track $track
    Channel $h $track incoming
    return
}

proc ::tacky::media::host::SetVideoEnabled {h args} {
    set opts [dict merge {-on 1} $args]
    Command setVideoEnabled -pc $h -on [dict get $opts -on]
    return
}

proc ::tacky::media::host::SetVideoDevice {h args} {
    set opts [dict merge {-id ""} $args]
    Command setVideoDevice -pc $h -id [dict get $opts -id]
    return
}

# Device enumeration

# No device capability is declared, so a caller that gets here has already
# been told what it will find.
proc ::tacky::media::host::EnumerateAudioDevices {args} {
    Answer $args [dict create capture {} playback {}]
    return
}

proc ::tacky::media::host::EnumerateCameras {args} {
    Answer $args {}
    return
}

proc ::tacky::media::host::Answer {opts value} {
    if {![dict exists $opts -command] || [dict get $opts -command] eq ""} {
        return
    }
    uplevel #0 [list {*}[dict get $opts -command] $value]
    return
}

# The app's half

# One answer from the app: `pc`, `type` and that type's own keys, which reach
# the pc's caller as they stand. An event with no pc or type is thrown back at
# the app; one that only the backend cannot place - an unknown type, a missing
# key - comes back as a non-fatal `error` on the pc.
proc ::tacky::media::host::event {ev} {
    variable EVENTS
    variable DEFAULT_MID
    variable Mid
    foreach key {pc type} {
        if {![dict exists $ev $key]} {
            error "host media event: no $key in $ev"
        }
    }
    set pc   [dict get $ev pc]
    set type [dict get $ev type]
    if {![dict exists $EVENTS $type]} {
        Reject $pc "unknown event type $type"
        return
    }
    set args [dict remove $ev pc type]
    if {$type eq "iceCandidate"
            && (![dict exists $args mid] || [dict get $args mid] eq "")} {
        dict set args mid $DEFAULT_MID
    }
    foreach key [dict get $EVENTS $type] {
        if {![dict exists $args $key]} {
            Reject $pc "$type event has no $key"
            return
        }
    }
    if {$type eq "track"} {
        dict set Mid $pc [dict get $args track] [dict get $args mid]
    }
    ::tacky::media::emit $pc $type {*}$args
    return
}

proc ::tacky::media::host::Reject {pc reason} {
    ::tacky::media::emit $pc error op hostEvent reason $reason fatal 0
    return
}

# Internals

proc ::tacky::media::host::Command {op args} {
    variable Emit
    if {$Emit eq ""} return
    uplevel #0 [list {*}$Emit -op $op {*}$args]
    return
}

proc ::tacky::media::host::Channel {pc track direction} {
    variable Mid
    set mid $track
    if {[dict exists $Mid $pc $track]} { set mid [dict get $Mid $pc $track] }
    ::tacky::media::emit $pc videoChannel track $track direction $direction \
        mid $mid channel [dict create kind host id $track]
    return
}
