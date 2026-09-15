# One scripted tacky::media conversation, run against any backend.
#
# This is what mock_rtc.tcl used to be, moved up a level: instead of recording
# what taco_calls does to the three extensions, it drives the API itself
# through a whole call - caller and callee, audio and video, devices, teardown
# - and checks the contract in lib/media/media.tcl holds. Every backend has to
# pass it: rtc today, webrtc and host later.
#
#   mediaconform::run <backend> -drive <cmdprefix> ?-open {args}?
#
# -> a list of failures, one string each. Empty means the backend conforms.
#
# A backend cannot be made to invent a peer, so the caller supplies a driver
# that makes it produce one event at a time. It is invoked as
#
#   {*}$drive localDescription <pc> <sdp> offer|answer
#   {*}$drive iceCandidate     <pc> <candidate> <mid>
#   {*}$drive connectionState  <pc> <state>
#   {*}$drive gatheringState   <pc> <state>
#   {*}$drive remoteTrack      <pc> audio|video   -> the track handle reported
#
# Checks are capability-gated: a backend that does not declare `cameras` is
# not asked to enumerate any, but one that does must answer in the documented
# shape. Nothing here assumes the backend answers synchronously, except where
# the driver is what makes the event happen - then it must have arrived by the
# time the driver returns, since that is the only ordering the API promises.
package provide tacky::mediaconformance 0.1

package require tacky::media

namespace eval mediaconform {
    variable Failures {}
    variable Events {}
    variable Driver {}
    variable Answer {}   ;# where an enumeration callback lands
    variable Seen {}     ;# which pc saw what, for Isolation

    variable CAPABILITIES {
        audioDevices audioVolume cameras videoDevice videoChannel
        autoAnswer sdpSanitize trickleIce
    }
    variable PC_STATES {new connecting connected disconnected failed closed}
    variable OFFER_SDP "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:abc\r\na=ice-pwd:xyzxyzxyzxyz\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"
}

proc mediaconform::run {backend args} {
    variable Failures
    variable Driver
    set opts [dict merge {-drive "" -open {}} $args]
    if {[dict get $opts -drive] eq ""} {
        error "mediaconform::run: -drive required"
    }
    set Failures {}
    set Driver [dict get $opts -drive]

    if {$backend ni [::tacky::media available]} {
        return [list "backend $backend is not registered"]
    }
    # A run takes the process-global backend over, so put back whatever was
    # open: in a full suite a taco elsewhere has one, and it must survive.
    set was [::tacky::media backend]
    if {[catch {::tacky::media open $backend {*}[dict get $opts -open]} err]} {
        Restore $was
        return [list "open $backend failed: $err"]
    }

    Lifecycle $backend
    Caller
    Callee
    Devices
    Isolation

    ::tacky::media close
    Restore $was
    return $Failures
}

proc mediaconform::Restore {was} {
    if {$was eq "" || $was eq [::tacky::media backend]} return
    catch {::tacky::media open $was}
}

# ==========================================================================
# Assertions
# ==========================================================================

proc mediaconform::fail {msg} {
    variable Failures
    lappend Failures $msg
}

proc mediaconform::ok {what script} {
    if {[catch {uplevel 1 $script} err]} {
        fail "$what threw: $err"
        return 0
    }
    return 1
}

proc mediaconform::expect {what cond detail} {
    if {$cond} { return 1 }
    fail "$what: $detail"
    return 0
}

# Events seen since the last Collect, in arrival order.
proc mediaconform::Sink {ev} {
    variable Events
    lappend Events $ev
}

proc mediaconform::Collect {} {
    variable Events
    set out $Events
    set Events {}
    return $out
}

# The first event of a type since the last Collect; "" if it never came.
proc mediaconform::Take {events type} {
    foreach ev $events {
        if {[dict exists $ev type] && [dict get $ev type] eq $type} {
            return $ev
        }
    }
    return ""
}

proc mediaconform::Drive {args} {
    variable Driver
    return [uplevel #0 [list {*}$Driver {*}$args]]
}

proc mediaconform::Keys {what ev keys} {
    foreach k $keys {
        if {![dict exists $ev $k]} {
            fail "$what event is missing key $k: $ev"
            return 0
        }
    }
    return 1
}

# ==========================================================================
# Lifecycle, capabilities and codecs
# ==========================================================================

proc mediaconform::Lifecycle {backend} {
    variable CAPABILITIES
    expect "backend" [string equal [::tacky::media backend] $backend] \
        "open $backend but `backend` says [::tacky::media backend]"

    set caps [::tacky::media capabilities]
    expect "capabilities" \
        [string equal [lsort [dict keys $caps]] [lsort $CAPABILITIES]] \
        "expected exactly [lsort $CAPABILITIES], got [lsort [dict keys $caps]]"
    dict for {flag value} $caps {
        expect "capability $flag" [expr {$value in {0 1}}] \
            "must be 0 or 1, got $value"
    }

    set codecs [::tacky::media codecs]
    foreach kind {audio video} {
        expect "codecs" [dict exists $codecs $kind] "no $kind key in $codecs"
    }
}

# ==========================================================================
# The caller half: our own tracks, our own offer, trickle, connect, teardown
# ==========================================================================

proc mediaconform::Caller {} {
    variable OFFER_SDP
    variable PC_STATES
    set pc conform-out

    Collect
    if {![ok createPeer {
        ::tacky::media createPeer $pc \
            -command [list ::mediaconform::Sink] \
            -ice-servers {stun:stun.example.com:3478}
    }]} return

    ok "addTrack audio" {::tacky::media addTrack $pc audio -kind audio}
    ok attachAudio {
        ::tacky::media attachAudio $pc audio -input "" -output "" \
            -input-volume 1.0 -output-volume 1.0
    }
    if {[::tacky::media capability videoChannel]} {
        ok "addTrack video" {::tacky::media addTrack $pc video -kind video}
        Collect
        ok attachVideoSender {
            ::tacky::media attachVideoSender $pc video -device-id ""
        }
        VideoChannel [Collect] preview video
        ok attachVideoReceiver {::tacky::media attachVideoReceiver $pc video}
        VideoChannel [Collect] incoming video
    }

    # A device or gain the backend cannot honour is reported, never thrown.
    if {[::tacky::media capability audioDevices]} {
        ok setAudioDevice {
            ::tacky::media setAudioDevice $pc -kind capture -id no-such-device
        }
    }
    if {[::tacky::media capability audioVolume]} {
        ok setAudioVolume {
            ::tacky::media setAudioVolume $pc -kind playback -volume 0.5
        }
    }
    if {[::tacky::media capability videoDevice]} {
        ok setVideoDevice {::tacky::media setVideoDevice $pc -id no-such-camera}
        ok setVideoEnabled {::tacky::media setVideoEnabled $pc -on 0}
    }

    Collect
    ok setLocalDescription {::tacky::media setLocalDescription $pc}
    Drive localDescription $pc $OFFER_SDP offer
    set ev [Take [Collect] localDescription]
    if {[expect localDescription [expr {$ev ne ""}] "never arrived"]} {
        if {[Keys localDescription $ev {pc type sdp sdpType}]} {
            expect localDescription [string equal [dict get $ev pc] $pc] \
                "routed to pc [dict get $ev pc], expected $pc"
            expect localDescription \
                [expr {[dict get $ev sdpType] in {offer answer}}] \
                "sdpType is [dict get $ev sdpType]"
        }
    }

    if {[::tacky::media capability trickleIce]} {
        Collect
        Drive iceCandidate $pc \
            "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host" ""
        set ev [Take [Collect] iceCandidate]
        if {[expect iceCandidate [expr {$ev ne ""}] "never arrived"]
                && [Keys iceCandidate $ev {pc type candidate mid}]} {
            # An empty mid is the backend's to fill in: a caller has to name
            # a Jingle content with it.
            expect iceCandidate [expr {[dict get $ev mid] ne ""}] \
                "mid came back empty; the backend owes its own default"
        }
    }

    ok setRemoteDescription {
        ::tacky::media setRemoteDescription $pc -sdp $OFFER_SDP -type answer
    }

    Collect
    Drive connectionState $pc connected
    set ev [Take [Collect] connectionState]
    if {[expect connectionState [expr {$ev ne ""}] "never arrived"]
            && [Keys connectionState $ev {pc type state}]} {
        expect connectionState [expr {[dict get $ev state] in $PC_STATES}] \
            "state [dict get $ev state] is not one of $PC_STATES"
    }

    Drive gatheringState $pc complete

    # Closing must silence the pc: a backend with events already queued has
    # to drop them rather than deliver to a caller that has moved on.
    ok closePeer {::tacky::media closePeer $pc}
    Collect
    catch {Drive connectionState $pc closed}
    expect closePeer [expr {[llength [Collect]] == 0}] \
        "an event was delivered after closePeer"
    ok "closePeer twice" {::tacky::media closePeer $pc}
}

proc mediaconform::VideoChannel {events direction track} {
    set ev [Take $events videoChannel]
    if {![expect "videoChannel $direction" [expr {$ev ne ""}] "never arrived"]} {
        return
    }
    if {![Keys "videoChannel $direction" $ev {pc type track direction mid channel}]} {
        return
    }
    expect "videoChannel $direction" \
        [string equal [dict get $ev direction] $direction] \
        "direction is [dict get $ev direction]"
    expect "videoChannel $direction" [string equal [dict get $ev track] $track] \
        "track is [dict get $ev track], expected $track"
    set ch [dict get $ev channel]
    if {![expect "videoChannel $direction" [dict exists $ch kind] \
            "descriptor has no kind: $ch"]} {
        return
    }
    # The shm form is the one a frontend maps by name; a host-rendered
    # channel only owes an id.
    switch -- [dict get $ch kind] {
        shm {
            foreach k {name channel slots slotBytes maxWidth maxHeight format} {
                expect "videoChannel $direction" [dict exists $ch $k] \
                    "shm descriptor has no $k: $ch"
            }
        }
        host {
            expect "videoChannel $direction" [dict exists $ch id] \
                "host descriptor has no id: $ch"
        }
        default {
            fail "videoChannel $direction: unknown descriptor kind\
                [dict get $ch kind]"
        }
    }
}

# ==========================================================================
# The callee half: the peer's offer, the peer's tracks
# ==========================================================================

proc mediaconform::Callee {} {
    variable OFFER_SDP
    set pc conform-in

    Collect
    if {![ok createPeer {
        ::tacky::media createPeer $pc -command [list ::mediaconform::Sink]
    }]} return

    ok "setRemoteDescription offer" {
        ::tacky::media setRemoteDescription $pc -sdp $OFFER_SDP -type offer
    }
    # A backend that does not auto-answer must take an explicit one without
    # complaint; one that does has already applied its own.
    if {![::tacky::media capability autoAnswer]} {
        ok "setLocalDescription answer" {
            ::tacky::media setLocalDescription $pc -type answer
        }
    }

    ok addRemoteCandidate {
        ::tacky::media addRemoteCandidate $pc \
            -candidate "candidate:7 1 udp 2122260223 192.0.2.7 7777 typ host" \
            -mid audio
    }

    foreach kind {audio video} {
        if {$kind eq "video" && ![::tacky::media capability videoChannel]} continue
        Collect
        set tr [Drive remoteTrack $pc $kind]
        set ev [Take [Collect] track]
        if {![expect "track $kind" [expr {$ev ne ""}] "never arrived"]} continue
        if {![Keys "track $kind" $ev {pc type track kind mid}]} continue
        expect "track $kind" [string equal [dict get $ev kind] $kind] \
            "reported kind [dict get $ev kind]"
        expect "track $kind" [string equal [dict get $ev track] $tr] \
            "reported handle [dict get $ev track], driver said $tr"
        # The handle the backend just named has to be one it accepts back.
        if {$kind eq "audio"} {
            ok "attachAudio on a peer track" {
                ::tacky::media attachAudio $pc $tr
            }
        } else {
            Collect
            ok "attachVideoReceiver on a peer track" {
                ::tacky::media attachVideoReceiver $pc $tr
            }
            VideoChannel [Collect] incoming $tr
        }
    }

    ::tacky::media closePeer $pc
}

# ==========================================================================
# Enumeration
# ==========================================================================

proc mediaconform::Devices {} {
    variable Answer
    if {[::tacky::media capability audioDevices]} {
        set Answer _none_
        ok enumerateAudioDevices {
            ::tacky::media enumerateAudioDevices \
                -command [list ::mediaconform::Capture]
        }
        if {$Answer eq "_none_"} {
            fail "enumerateAudioDevices: -command was never invoked"
        } else {
            foreach kind {capture playback} {
                if {![expect enumerateAudioDevices [dict exists $Answer $kind] \
                        "no $kind key in $Answer"]} continue
                foreach dev [dict get $Answer $kind] {
                    Keys "audio device" $dev {name id default}
                }
            }
        }
    }
    if {[::tacky::media capability cameras]} {
        set Answer _none_
        ok enumerateCameras {
            ::tacky::media enumerateCameras \
                -command [list ::mediaconform::Capture]
        }
        if {$Answer eq "_none_"} {
            fail "enumerateCameras: -command was never invoked"
        } else {
            foreach cam $Answer {
                Keys camera $cam {name id facing}
            }
        }
    }
}

# The backend invokes this at global level, so the answer lands in a
# namespace variable rather than a caller's frame. Only a backend that
# answers in the same frame is checked here; an asynchronous one needs an
# event loop turn, which this script deliberately does not take.
proc mediaconform::Capture {value} {
    variable Answer
    set Answer $value
}

# ==========================================================================
# Two peer connections at once
# ==========================================================================

proc mediaconform::Isolation {} {
    variable Seen
    set Seen {}
    ::tacky::media createPeer iso-a -command [list ::mediaconform::IsoSink a]
    ::tacky::media createPeer iso-b -command [list ::mediaconform::IsoSink b]
    Drive connectionState iso-a connected
    Drive connectionState iso-b failed
    expect isolation [string equal $Seen {a connected b failed}] \
        "two pcs crossed their events: $Seen"
    ::tacky::media closePeer iso-a
    ::tacky::media closePeer iso-b
}

proc mediaconform::IsoSink {which ev} {
    variable Seen
    if {[dict get $ev type] ne "connectionState"} return
    lappend Seen $which [dict get $ev state]
}
