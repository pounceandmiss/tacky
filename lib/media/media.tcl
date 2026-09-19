# The backend-neutral media API: the one boundary taco_calls, taco_audio and
# taco_video talk to. `rtc` (libdatachannel + rtc-ma + rtc-mv, in process) is
# the backend that ships today; `webrtc` (libtacky_webrtc.so) and `host`
# (media owned by the embedding app) plug in the same way.
#
# Shape is RTCPeerConnection's: peer connections, tracks, local/remote
# descriptions, candidates, state. Every command is asynchronous - none
# returns a value the caller needs. The caller names the peer connections it
# creates and the tracks it adds; the backend names the tracks the peer adds.
# Only strings and dicts cross the boundary, so the same conversation carries
# over JSON, JNI, JS and Objective-C.
#
# Events for a pc go to the -command it was created with, one dict each. Every
# dict carries `pc` and `type`:
#
#   localDescription  sdp <s> sdpType offer|answer
#   iceCandidate      candidate <c> mid <m>
#   gatheringState    state new|gathering|complete
#   connectionState   state new|connecting|connected|disconnected|failed|closed
#   track             track <handle> kind audio|video mid <m>
#   videoChannel      track <h> direction incoming|preview mid <m> channel <desc>
#   deviceFallback    kind capture|playback|camera id <requested> reason <t>
#   error             op <command> reason <text> fatal 0|1
#
# An event may be delivered before the command that caused it returns, so
# re-check your own state after every call. `error` with fatal 1 means the pc
# is unusable; fatal 0 is advisory and the call goes on.
#
# A video channel descriptor is opaque to the caller and always carries a
# `kind`: {kind shm name <n> channel <c> ...} for a backend writing an rtc-mv
# ring, {kind host id <i>} for one rendering in the embedding app.
#
# Device ids are opaque strings from enumerate*, and a stored preference
# outlives the backend that produced it. A backend asked for an id it does
# not know opens its default instead and reports `deviceFallback`; it never
# fails a call over a stale preference.
#
# Capabilities (`tacky::media capabilities` -> flag -> 0|1) let callers skip
# what a backend cannot do:
#
#   audioDevices  enumerate and select capture / playback devices
#   audioVolume   per-kind gain
#   cameras       enumerate cameras
#   videoDevice   select and hot-swap the camera
#   videoChannel  video arrives as a channel descriptor
#   autoAnswer    setRemoteDescription(offer) also generates the answer, so
#                 the callee must not call setLocalDescription itself
#   sdpSanitize   local SDP needs extmap / transport-cc stripped before it
#                 goes on the wire
#   trickleIce    candidates arrive one at a time as iceCandidate events
#
# Commands:
#
#   tacky::media register <name> <cmdprefix>   ;# a backend offers itself
#   tacky::media available                     -> list of registered names
#   tacky::media open <name> ?-opt val ...?    ;# throws if it will not start
#   tacky::media backend                       -> open backend's name, "" if none
#   tacky::media capabilities                  -> dict of flag -> 0|1
#   tacky::media capability <flag>             -> 0|1
#   tacky::media codecs                        -> {audio {...} video {...}}
#   tacky::media close                         ;# drop everything
#
#   tacky::media createPeer <pc> -command <cb> ?-ice-servers <list>? ?-sid <sid>?
#   tacky::media closePeer  <pc>
#   tacky::media addTrack   <pc> <track> -kind audio|video ?-direction <d>?
#   tacky::media setLocalDescription  <pc> ?-sdp <s>? ?-type offer|answer?
#   tacky::media setRemoteDescription <pc> -sdp <s> -type offer|answer
#   tacky::media addRemoteCandidate   <pc> -candidate <c> ?-mid <m>?
#
#   tacky::media attachAudio <pc> <track> ?-input <id>? ?-output <id>?
#                                         ?-input-volume <v>? ?-output-volume <v>?
#   tacky::media setAudioDevice <pc> -kind capture|playback -id <id>
#   tacky::media setAudioVolume <pc> -kind capture|playback -volume <v>
#   tacky::media attachVideoSender   <pc> <track> ?-device-id <id>?
#   tacky::media attachVideoReceiver <pc> <track>
#   tacky::media setVideoEnabled <pc> -on 0|1
#   tacky::media setVideoDevice  <pc> -id <id>
#
#   tacky::media enumerateAudioDevices -command <cb>  ;# {capture {...} playback {...}}
#   tacky::media enumerateCameras      -command <cb>  ;# list of {name id facing}
#
# Backends implement the same verbs, capitalised, behind their command prefix
# (Open, CreatePeer, AddTrack, ...) and push events with ::tacky::media::emit.

package provide tacky::media 0.1

namespace eval ::tacky::media {
    variable Backends {}   ;# name -> command prefix
    variable Active ""     ;# name of the open backend, "" when none
    variable ActiveCmd ""
    variable Caps {}
    variable PcCb          ;# pc -> event callback
    array set PcCb {}

    # Every flag any backend may declare. An omitted one is 0; an unknown one
    # is a typo and throws at open time.
    variable CAPABILITIES {
        audioDevices audioVolume cameras videoDevice videoChannel
        autoAnswer sdpSanitize trickleIce
    }

    namespace export register available open backend capabilities capability \
        codecs close createPeer closePeer addTrack setLocalDescription \
        setRemoteDescription addRemoteCandidate attachAudio setAudioDevice \
        setAudioVolume attachVideoSender attachVideoReceiver setVideoEnabled \
        setVideoDevice enumerateAudioDevices enumerateCameras
    namespace ensemble create -command ::tacky::media
}

# ==========================================================================
# Backend registry
# ==========================================================================

proc ::tacky::media::register {name cmdprefix} {
    variable Backends
    dict set Backends $name $cmdprefix
    return
}

proc ::tacky::media::available {} {
    variable Backends
    return [lsort [dict keys $Backends]]
}

proc ::tacky::media::backend {} {
    variable Active
    return $Active
}

# Throws if $name was never registered or its Open refuses; the caller decides
# whether that is fatal or worth falling back from.
proc ::tacky::media::open {name args} {
    variable Backends
    variable Active
    variable ActiveCmd
    variable Caps
    variable CAPABILITIES
    if {![dict exists $Backends $name]} {
        error "no such media backend: $name"
    }
    if {$Active ne ""} { close }
    set cmd [dict get $Backends $name]
    {*}$cmd Open {*}$args
    set declared [{*}$cmd Capabilities]
    foreach flag [dict keys $declared] {
        if {$flag ni $CAPABILITIES} {
            catch {{*}$cmd Close}
            error "media backend $name declares unknown capability: $flag"
        }
    }
    set Caps {}
    foreach flag $CAPABILITIES {
        dict set Caps $flag [expr {
            [dict exists $declared $flag] && [dict get $declared $flag] ? 1 : 0}]
    }
    set Active $name
    set ActiveCmd $cmd
    return
}

proc ::tacky::media::close {} {
    variable Active
    variable ActiveCmd
    variable Caps
    variable PcCb
    if {$Active eq ""} return
    catch {{*}$ActiveCmd Close}
    array unset PcCb
    set Active ""
    set ActiveCmd ""
    set Caps {}
    return
}

proc ::tacky::media::capabilities {} {
    variable Caps
    return $Caps
}

# Codec names a backend can actually decode, per media kind. An empty list
# means "no opinion" - don't filter. Callers use it to keep a negotiation
# honest: a codec offered but not decodable arrives as noise.
proc ::tacky::media::codecs {} {
    return [Dispatch Codecs]
}

proc ::tacky::media::capability {flag} {
    variable Caps
    variable CAPABILITIES
    if {$flag ni $CAPABILITIES} { error "no such media capability: $flag" }
    if {![dict exists $Caps $flag]} { return 0 }
    return [dict get $Caps $flag]
}

# ==========================================================================
# Dispatch
# ==========================================================================

proc ::tacky::media::Dispatch {op args} {
    variable ActiveCmd
    if {$ActiveCmd eq ""} { error "no media backend is open" }
    return [{*}$ActiveCmd $op {*}$args]
}

# Backends call this; it routes to the pc's own callback. A pc that has
# already been closed swallows its late events rather than throwing on a dead
# callback - the backend's queue can outlive closePeer.
proc ::tacky::media::emit {pc type args} {
    variable PcCb
    if {![info exists PcCb($pc)]} return
    uplevel #0 [list {*}$PcCb($pc) [dict create pc $pc type $type {*}$args]]
}

# ==========================================================================
# Peer connections
# ==========================================================================

# -sid: the call the pc serves, for a host backend whose app renders per call.
proc ::tacky::media::createPeer {pc args} {
    variable PcCb
    set opts [dict merge {-command "" -ice-servers {} -sid ""} $args]
    if {[dict get $opts -command] eq ""} {
        error "createPeer: -command required"
    }
    set PcCb($pc) [dict get $opts -command]
    if {[catch {Dispatch CreatePeer $pc \
            -ice-servers [dict get $opts -ice-servers] \
            -sid [dict get $opts -sid]} err]} {
        unset -nocomplain PcCb($pc)
        error $err
    }
    return
}

proc ::tacky::media::closePeer {pc} {
    variable PcCb
    catch {Dispatch ClosePeer $pc}
    unset -nocomplain PcCb($pc)
    return
}

proc ::tacky::media::addTrack {pc track args} {
    Dispatch AddTrack $pc $track \
        {*}[dict merge {-kind audio -direction sendrecv} $args]
    return
}

# No caller-supplied type by default: the backend infers offer or answer from
# its own signaling state, the way setLocalDescription() does.
proc ::tacky::media::setLocalDescription {pc args} {
    Dispatch SetLocalDescription $pc {*}[dict merge {-sdp "" -type ""} $args]
    return
}

proc ::tacky::media::setRemoteDescription {pc args} {
    Dispatch SetRemoteDescription $pc {*}[dict merge {-sdp "" -type ""} $args]
    return
}

proc ::tacky::media::addRemoteCandidate {pc args} {
    Dispatch AddRemoteCandidate $pc {*}[dict merge {-candidate "" -mid ""} $args]
    return
}

# ==========================================================================
# Media attachment
# ==========================================================================

proc ::tacky::media::attachAudio {pc track args} {
    Dispatch AttachAudio $pc $track {*}[dict merge \
        {-input "" -output "" -input-volume 1.0 -output-volume 1.0} $args]
    return
}

proc ::tacky::media::setAudioDevice {pc args} {
    Dispatch SetAudioDevice $pc {*}[dict merge {-kind "" -id ""} $args]
    return
}

proc ::tacky::media::setAudioVolume {pc args} {
    Dispatch SetAudioVolume $pc {*}[dict merge {-kind "" -volume 1.0} $args]
    return
}

proc ::tacky::media::attachVideoSender {pc track args} {
    Dispatch AttachVideoSender $pc $track {*}[dict merge {-device-id ""} $args]
    return
}

proc ::tacky::media::attachVideoReceiver {pc track args} {
    Dispatch AttachVideoReceiver $pc $track {*}$args
    return
}

proc ::tacky::media::setVideoEnabled {pc args} {
    Dispatch SetVideoEnabled $pc {*}[dict merge {-on 1} $args]
    return
}

proc ::tacky::media::setVideoDevice {pc args} {
    Dispatch SetVideoDevice $pc {*}[dict merge {-id ""} $args]
    return
}

# ==========================================================================
# Device enumeration (process-global, not tied to a pc)
# ==========================================================================

proc ::tacky::media::enumerateAudioDevices {args} {
    set opts [dict merge {-command ""} $args]
    if {[dict get $opts -command] eq ""} {
        error "enumerateAudioDevices: -command required"
    }
    Dispatch EnumerateAudioDevices {*}$opts
    return
}

proc ::tacky::media::enumerateCameras {args} {
    set opts [dict merge {-command ""} $args]
    if {[dict get $opts -command] eq ""} {
        error "enumerateCameras: -command required"
    }
    Dispatch EnumerateCameras {*}$opts
    return
}
