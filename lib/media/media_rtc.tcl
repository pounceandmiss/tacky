# tacky::media over libdatachannel (::rtc) + rtc-ma (::rtcma) + rtc-mv
# (::rtcmv), all in this process. Everything below the API - the m-line the
# tracks are built from, which codecs we can decode, the rtc-ma/rtc-mv handles
# and the order they have to be freed in - belongs to this backend and to no
# caller.
#
# Handles: the caller names its pcs and the tracks it adds; a track the peer
# adds is reported under its libdatachannel track id. TrackId maps either to
# the id rtc-ma / rtc-mv want.

package provide tacky::media::rtc 0.1

package require rtc
package require rtcma
package require rtcmv
package require tacky::media

namespace eval ::tacky::media::rtc {
    variable Pc          ;# handle -> libdatachannel pc id
    variable PcOf        ;# libdatachannel pc id -> handle
    variable TrackId     ;# handle,track -> libdatachannel track id
    variable Audio       ;# handle -> {capturer <h> player <h>}
    variable Vsend       ;# handle -> rtc-mv sender handle
    variable Vrecv       ;# handle -> rtc-mv receiver handle
    array set Pc {}
    array set PcOf {}
    array set TrackId {}
    array set Audio {}
    array set Vsend {}
    array set Vrecv {}

    # The SDP m-line labels this backend builds its tracks with. They double
    # as the mid a caller sees on its own tracks; a peer's tracks carry the
    # peer's own mids and are dispatched by media type instead.
    variable MID       audio
    variable VIDEO_MID video

    # Opus stereo @ 48 kHz, matching rtc-ma's fixed audio pipeline.
    variable PAYLOAD_TYPE   111
    variable AUDIO_CHANNELS 2

    # VP8 only, 90 kHz. rtx/NACK is deferred - rtc-mv recovers loss with a
    # keyframe request - so no apt/rtx payload is offered.
    variable VIDEO_PT    96
    variable VIDEO_CLOCK 90000
}

::tacky::media register rtc ::tacky::media::rtc::Op

proc ::tacky::media::rtc::Op {op args} {
    return [::tacky::media::rtc::$op {*}$args]
}

namespace eval ::tacky::media::rtc {
    namespace export Open Close Capabilities Codecs CreatePeer ClosePeer \
        AddTrack SetLocalDescription SetRemoteDescription AddRemoteCandidate \
        AttachAudio SetAudioDevice SetAudioVolume AttachVideoSender \
        AttachVideoReceiver SetVideoEnabled SetVideoDevice \
        EnumerateAudioDevices EnumerateCameras
}

# ==========================================================================
# Lifecycle
# ==========================================================================

# The three extensions are linked in, so there is nothing to load or probe:
# reaching this proc at all means `package require rtc` already succeeded.
proc ::tacky::media::rtc::Open {args} {
    return
}

proc ::tacky::media::rtc::Close {} {
    variable Pc
    foreach h [array names Pc] { ClosePeer $h }
    return
}

proc ::tacky::media::rtc::Capabilities {} {
    return {
        audioDevices 1 audioVolume 1 cameras 1 videoDevice 1 videoChannel 1
        autoAnswer 1 sdpSanitize 1 trickleIce 1
    }
}

# rtc-ma decodes opus and rtc-mv VP8; anything else the peer offers would be
# accepted by libdatachannel's auto-generated answer and then arrive as noise.
proc ::tacky::media::rtc::Codecs {} {
    return {audio opus video vp8}
}

# ==========================================================================
# Peer connections
# ==========================================================================

proc ::tacky::media::rtc::CreatePeer {h args} {
    variable Pc
    variable PcOf
    set opts [dict merge {-ice-servers {}} $args]
    set pc [::rtc::pc::new -ice-servers [dict get $opts -ice-servers]]
    set Pc($h) $pc
    set PcOf($pc) $h
    ::rtc::pc::on-local-description      $pc [namespace code [list OnLocalDescription]]
    ::rtc::pc::on-local-candidate        $pc [namespace code [list OnLocalCandidate]]
    ::rtc::pc::on-gathering-state-change $pc [namespace code [list OnGatheringState]]
    ::rtc::pc::on-state-change           $pc [namespace code [list OnPcState]]
    ::rtc::pc::on-track                  $pc [namespace code [list OnTrack]]
    return
}

# Ordering matters: the rtc-ma / rtc-mv handles own the libdatachannel track's
# message callback and user pointer, so they go before pc::delete frees the
# track. The callback scripts are dropped before close+delete so any event
# libdatachannel has already queued becomes a no-op at dispatch time instead
# of reaching a caller that has moved on.
proc ::tacky::media::rtc::ClosePeer {h} {
    variable Pc
    variable PcOf
    variable TrackId
    variable Audio
    variable Vsend
    variable Vrecv
    if {![info exists Pc($h)]} return
    set pc $Pc($h)
    if {[info exists Vsend($h)]} {
        catch {::rtcmv::sender::destroy $Vsend($h)}
        unset Vsend($h)
    }
    if {[info exists Vrecv($h)]} {
        catch {::rtcmv::receiver::destroy $Vrecv($h)}
        unset Vrecv($h)
    }
    if {[info exists Audio($h)]} {
        catch {::rtcma::capturer::destroy [dict get $Audio($h) capturer]}
        catch {::rtcma::player::destroy   [dict get $Audio($h) player]}
        unset Audio($h)
    }
    catch {::rtc::pc::on-local-description      $pc ""}
    catch {::rtc::pc::on-local-candidate        $pc ""}
    catch {::rtc::pc::on-gathering-state-change $pc ""}
    catch {::rtc::pc::on-state-change           $pc ""}
    catch {::rtc::pc::on-track                  $pc ""}
    catch {::rtc::pc::close  $pc}
    catch {::rtc::pc::delete $pc}
    array unset TrackId $h,*
    unset -nocomplain PcOf($pc)
    unset Pc($h)
    return
}

proc ::tacky::media::rtc::AddTrack {h track args} {
    variable Pc
    variable TrackId
    set opts [dict merge {-kind audio -direction sendrecv} $args]
    if {![info exists Pc($h)]} { error "no such peer connection: $h" }
    set kind [dict get $opts -kind]
    set desc [expr {$kind eq "video"
        ? [VideoMediaDesc [dict get $opts -direction]]
        : [AudioMediaDesc [dict get $opts -direction]]}]
    if {[catch {::rtc::pc::add-track $Pc($h) $desc} id]} {
        ::tacky::media::emit $h error op addTrack reason $id fatal 1
        return
    }
    set TrackId($h,$track) $id
    return
}

# libdatachannel media-description fragment for one Opus audio m-line:
# "<media> <port> <proto> <pt>\r\na=...\r\n..." - the bytes after the m=
# prefix. The payload type and channel count are fixed so a responder
# mirroring this via on-track gets matching codec config from the offer.
proc ::tacky::media::rtc::AudioMediaDesc {direction} {
    variable MID
    variable PAYLOAD_TYPE
    variable AUDIO_CHANNELS
    return [join [list \
        "audio 9 UDP/TLS/RTP/SAVPF $PAYLOAD_TYPE" \
        "a=mid:$MID" \
        "a=$direction" \
        "a=rtpmap:$PAYLOAD_TYPE opus/48000/$AUDIO_CHANNELS" \
        "a=fmtp:$PAYLOAD_TYPE minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1"] \
        \r\n]
}

# nack/pli/ccm feedback is advertised so libwebrtc peers send us PLIs, which
# rtc-mv turns into keyframes; rtc-mv needs no negotiated header extensions.
proc ::tacky::media::rtc::VideoMediaDesc {direction} {
    variable VIDEO_MID
    variable VIDEO_PT
    variable VIDEO_CLOCK
    return [join [list \
        "video 9 UDP/TLS/RTP/SAVPF $VIDEO_PT" \
        "a=mid:$VIDEO_MID" \
        "a=$direction" \
        "a=rtpmap:$VIDEO_PT VP8/$VIDEO_CLOCK" \
        "a=rtcp-fb:$VIDEO_PT nack" \
        "a=rtcp-fb:$VIDEO_PT nack pli" \
        "a=rtcp-fb:$VIDEO_PT ccm fir" \
        "a=rtcp-fb:$VIDEO_PT goog-remb"] \
        \r\n]
}

# An empty type lets libdatachannel infer offer or answer from its signaling
# state; the generated SDP comes back on the localDescription event.
proc ::tacky::media::rtc::SetLocalDescription {h args} {
    variable Pc
    set opts [dict merge {-sdp "" -type ""} $args]
    if {![info exists Pc($h)]} return
    if {[catch {::rtc::pc::set-local-description $Pc($h) \
            [dict get $opts -type]} err]} {
        ::tacky::media::emit $h error op setLocalDescription reason $err fatal 1
    }
    return
}

proc ::tacky::media::rtc::SetRemoteDescription {h args} {
    variable Pc
    set opts [dict merge {-sdp "" -type ""} $args]
    if {![info exists Pc($h)]} return
    if {[catch {::rtc::pc::set-remote-description $Pc($h) \
            [dict get $opts -sdp] [dict get $opts -type]} err]} {
        # The type goes back with it: rejecting an offer and rejecting an
        # answer mean very different things to a caller.
        ::tacky::media::emit $h error op setRemoteDescription reason $err \
            fatal 1 sdpType [dict get $opts -type]
    }
    return
}

# A candidate libdatachannel rejects - stale, duplicate, wrong ufrag - is not
# fatal: the others may still connect, so this reports fatal 0.
proc ::tacky::media::rtc::AddRemoteCandidate {h args} {
    variable Pc
    set opts [dict merge {-candidate "" -mid ""} $args]
    if {![info exists Pc($h)]} return
    if {[catch {::rtc::pc::add-remote-candidate $Pc($h) \
            [dict get $opts -candidate] [dict get $opts -mid]} err]} {
        ::tacky::media::emit $h error op addRemoteCandidate reason $err fatal 0
    }
    return
}

# ==========================================================================
# libdatachannel callbacks
# ==========================================================================

proc ::tacky::media::rtc::OnLocalDescription {pc sdp sdpType} {
    variable PcOf
    if {![info exists PcOf($pc)]} return
    ::tacky::media::emit $PcOf($pc) localDescription sdp $sdp sdpType $sdpType
    return
}

# libdatachannel gives the SDP attribute form ("candidate:..."), which is what
# the API carries. An empty mid means the bundle group's audio m-line.
proc ::tacky::media::rtc::OnLocalCandidate {pc cand mid} {
    variable PcOf
    variable MID
    if {![info exists PcOf($pc)]} return
    if {$mid eq ""} { set mid $MID }
    ::tacky::media::emit $PcOf($pc) iceCandidate candidate $cand mid $mid
    return
}

proc ::tacky::media::rtc::OnGatheringState {pc state} {
    variable PcOf
    if {![info exists PcOf($pc)]} return
    ::tacky::media::emit $PcOf($pc) gatheringState state $state
    return
}

proc ::tacky::media::rtc::OnPcState {pc state} {
    variable PcOf
    if {![info exists PcOf($pc)]} return
    ::tacky::media::emit $PcOf($pc) connectionState state $state
    return
}

# Dispatch by media type, not mid: a real peer's own offer uses its own BUNDLE
# mids, not the labels AddTrack writes. The description match needs the "m="
# prefix - get-description returns the whole line.
proc ::tacky::media::rtc::OnTrack {pc tr} {
    variable PcOf
    variable TrackId
    variable VIDEO_MID
    if {![info exists PcOf($pc)]} return
    set h $PcOf($pc)
    set mid ""
    catch {set mid [::rtc::track::get-mid $tr]}
    set isVideo 0
    if {![catch {::rtc::track::get-description $tr} desc]} {
        set isVideo [string match "m=video *" $desc]
    }
    if {!$isVideo} { set isVideo [expr {$mid eq $VIDEO_MID}] }
    set TrackId($h,$tr) $tr
    ::tacky::media::emit $h track track $tr \
        kind [expr {$isVideo ? "video" : "audio"}] mid $mid
    return
}

# ==========================================================================
# Audio
# ==========================================================================

# rtc-ma puts both ends on one track id: the player owns the message-callback
# / RTP recv side, the capturer only ever calls rtcSendMessage. A device id
# this backend cannot open - a preference stored against another backend, a
# mic that went away - falls back to the default rather than failing the call.
proc ::tacky::media::rtc::AttachAudio {h track args} {
    variable TrackId
    variable Audio
    set opts [dict merge \
        {-input "" -output "" -input-volume 1.0 -output-volume 1.0} $args]
    if {![info exists TrackId($h,$track)]} {
        ::tacky::media::emit $h error op attachAudio \
            reason "no such track: $track" fatal 1
        return
    }
    if {[info exists Audio($h)]} return
    set id $TrackId($h,$track)

    set capturer [OpenDevice $h capturer capture [dict get $opts -input]]
    if {[catch {::rtcma::capturer::attach $capturer $id} err]} {
        catch {::rtcma::capturer::destroy $capturer}
        ::tacky::media::emit $h error op attachAudio \
            reason "capturer attach failed: $err" fatal 1
        return
    }
    ::rtcma::capturer::start $capturer
    catch {::rtcma::capturer::set-volume $capturer [dict get $opts -input-volume]}

    set player [OpenDevice $h player playback [dict get $opts -output]]
    if {[catch {::rtcma::player::attach $player $id} err]} {
        catch {::rtcma::player::destroy $player}
        catch {::rtcma::capturer::destroy $capturer}
        ::tacky::media::emit $h error op attachAudio \
            reason "player attach failed: $err" fatal 1
        return
    }
    ::rtcma::player::start $player
    catch {::rtcma::player::set-volume $player [dict get $opts -output-volume]}

    set Audio($h) [dict create capturer $capturer player $player]
    return
}

proc ::tacky::media::rtc::OpenDevice {h which kind id} {
    if {![catch {::rtcma::${which}::new -device-id $id} handle]} {
        return $handle
    }
    ::tacky::media::emit $h deviceFallback kind $kind id $id reason $handle
    return [::rtcma::${which}::new]
}

proc ::tacky::media::rtc::SetAudioDevice {h args} {
    variable Audio
    set opts [dict merge {-kind "" -id ""} $args]
    if {![info exists Audio($h)]} return
    set which [expr {[dict get $opts -kind] eq "capture" ? "capturer" : "player"}]
    if {[catch {::rtcma::${which}::reopen [dict get $Audio($h) $which] \
            -device-id [dict get $opts -id]} err]} {
        ::tacky::media::emit $h error op setAudioDevice \
            reason $err fatal 0 kind [dict get $opts -kind]
    }
    return
}

# rtc-ma applies the change atomically on the mixer factor, with no clicks.
# An out-of-range or NaN value is rejected there and reported as advisory.
proc ::tacky::media::rtc::SetAudioVolume {h args} {
    variable Audio
    set opts [dict merge {-kind "" -volume 1.0} $args]
    if {![info exists Audio($h)]} return
    set which [expr {[dict get $opts -kind] eq "capture" ? "capturer" : "player"}]
    if {[catch {::rtcma::${which}::set-volume [dict get $Audio($h) $which] \
            [dict get $opts -volume]} err]} {
        ::tacky::media::emit $h error op setAudioVolume \
            reason $err fatal 0 kind [dict get $opts -kind]
    }
    return
}

# ==========================================================================
# Video
# ==========================================================================

# Camera -> VP8 -> RTP, with the local camera also going to a preview ring so
# a GUI can show a self-view.
proc ::tacky::media::rtc::AttachVideoSender {h track args} {
    variable TrackId
    variable Vsend
    variable VIDEO_MID
    set opts [dict merge {-device-id ""} $args]
    if {[info exists Vsend($h)]} return
    if {![info exists TrackId($h,$track)]} {
        ::tacky::media::emit $h error op attachVideoSender \
            reason "no such track: $track" fatal 0
        return
    }
    set snd [::rtcmv::sender::new -device-id [dict get $opts -device-id] -preview 1]
    if {[catch {::rtcmv::sender::attach $snd $TrackId($h,$track)} err]} {
        catch {::rtcmv::sender::destroy $snd}
        ::tacky::media::emit $h error op attachVideoSender reason $err fatal 0
        return
    }
    ::rtcmv::sender::start $snd
    set Vsend($h) $snd
    if {![catch {::rtcmv::sender::preview-shm $snd} pv]} {
        ::tacky::media::emit $h videoChannel track $track direction preview \
            mid $VIDEO_MID channel [ShmDescriptor $pv]
    }
    return
}

# RTP -> VP8 -> I420 into a named shm ring the frontend maps.
proc ::tacky::media::rtc::AttachVideoReceiver {h track args} {
    variable TrackId
    variable Vrecv
    variable VIDEO_MID
    if {[info exists Vrecv($h)]} return
    if {![info exists TrackId($h,$track)]} {
        ::tacky::media::emit $h error op attachVideoReceiver \
            reason "no such track: $track" fatal 0
        return
    }
    set rcv [::rtcmv::receiver::new]
    if {[catch {::rtcmv::receiver::attach $rcv $TrackId($h,$track)} err]} {
        catch {::rtcmv::receiver::destroy $rcv}
        ::tacky::media::emit $h error op attachVideoReceiver reason $err fatal 0
        return
    }
    ::rtcmv::receiver::start $rcv
    set Vrecv($h) $rcv
    ::tacky::media::emit $h videoChannel track $track direction incoming \
        mid $VIDEO_MID channel [ShmDescriptor [::rtcmv::receiver::shm $rcv]]
    return
}

# The fd stays out of the descriptor: POSIX frontends open by name, and
# Android takes the fd over JNI rather than off this dict.
proc ::tacky::media::rtc::ShmDescriptor {sh} {
    return [dict create kind shm \
        channel   [dict get $sh channel] \
        name      [dict get $sh name] \
        slots     [dict get $sh slots] \
        slotBytes [dict get $sh slotBytes] \
        maxWidth  [dict get $sh maxWidth] \
        maxHeight [dict get $sh maxHeight] \
        format    [dict get $sh format]]
}

proc ::tacky::media::rtc::SetVideoEnabled {h args} {
    variable Vsend
    set opts [dict merge {-on 1} $args]
    if {![info exists Vsend($h)]} return
    catch {::rtcmv::sender::set-enabled $Vsend($h) \
        [expr {[dict get $opts -on] ? 1 : 0}]}
    return
}

proc ::tacky::media::rtc::SetVideoDevice {h args} {
    variable Vsend
    set opts [dict merge {-id ""} $args]
    if {![info exists Vsend($h)]} return
    if {[catch {::rtcmv::sender::reopen $Vsend($h) \
            -device-id [dict get $opts -id]} err]} {
        ::tacky::media::emit $h deviceFallback \
            kind camera id [dict get $opts -id] reason $err
    }
    return
}

# ==========================================================================
# Enumeration
# ==========================================================================

proc ::tacky::media::rtc::EnumerateAudioDevices {args} {
    set opts [dict merge {-command ""} $args]
    uplevel #0 [list {*}[dict get $opts -command] [::rtcma::enumerate-devices]]
    return
}

proc ::tacky::media::rtc::EnumerateCameras {args} {
    set opts [dict merge {-command ""} $args]
    uplevel #0 [list {*}[dict get $opts -command] [::rtcmv::enumerate-cameras]]
    return
}

# Which libdatachannel pc backs a handle. For tests and for logging - no
# caller outside this file may use the id for anything else.
proc ::tacky::media::rtc::pc-id {h} {
    variable Pc
    if {![info exists Pc($h)]} { return -1 }
    return $Pc($h)
}
