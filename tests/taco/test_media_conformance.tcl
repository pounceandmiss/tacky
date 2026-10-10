# The tacky::media conformance script (tests/taco/media_conformance.tcl) run
# against every backend this build has: the mock, and rtc driven through
# mock_rtc.tcl. A new backend earns its place here by passing the same run.
#
# These take the backend over for the duration, so they do not use tacky_env -
# there is no taco here to have opened one.
package require tcltest
namespace import ::tcltest::*

# rtc is the libdatachannel backend, and half of what this conformance run
# covers. A build without it - the browser's, where WebRTC belongs to the
# page and reaches tacky through the host backend - has nothing here to run.
# No tacky fixture here, so the build constraint is set locally; see
# tests/taco/helpers.tcl for what it stands for.
::tcltest::testConstraint wasm [expr {$::tcl_platform(os) eq "Emscripten"}]
if {[::tcltest::testConstraint wasm]} {
    puts "skipping [file tail [info script]]: no rtc in this build"
    return
}

package require tacky::media
package require tacky::media::rtc
package require tacky::media::host
package require tacky::mockmedia
package require tacky::mockrtc
package require tacky::mediaconformance

# -- Drivers: make a backend produce one event, per media_conformance.tcl --

proc conform_drive_mock {what pc args} {
    return [mockmedia::drive $what $pc {*}$args]
}

# rtc has no events of its own without a peer, so mock_rtc.tcl plays one.
# The libdatachannel pc is looked up from the handle the backend was given.
proc conform_drive_rtc {what pc args} {
    set id [::tacky::media::rtc::pc-id $pc]
    switch -- $what {
        localDescription {
            lassign $args sdp type
            mockrtc::fire $id local-description $sdp $type
        }
        iceCandidate {
            lassign $args cand mid
            mockrtc::fire $id local-candidate $cand $mid
        }
        connectionState { mockrtc::fire $id state-change [lindex $args 0] }
        gatheringState  { mockrtc::fire $id gathering-state-change [lindex $args 0] }
        remoteTrack {
            set kind [lindex $args 0]
            # A peer's own numbered mid, not the "audio"/"video" labels the
            # backend writes on tracks we add.
            set tr [mockrtc::remoteTrack 7 \
                "m=$kind 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\n"]
            mockrtc::fire $id track $tr
            return $tr
        }
        default { error "conform_drive_rtc: cannot drive $what" }
    }
    return
}

# The host backend's driver is the embedding app: every event it produces is
# one the app sends back through the same entry point taco's `media hostEvent`
# uses.
proc conform_drive_host {what pc args} {
    switch -- $what {
        localDescription {
            lassign $args sdp type
            conform_host_send $pc localDescription sdp $sdp sdpType $type
        }
        iceCandidate {
            lassign $args cand mid
            conform_host_send $pc iceCandidate candidate $cand mid $mid
        }
        connectionState { conform_host_send $pc connectionState state [lindex $args 0] }
        gatheringState  { conform_host_send $pc gatheringState state [lindex $args 0] }
        remoteTrack {
            set kind [lindex $args 0]
            set tr ht[incr ::conform_host_seq]
            conform_host_send $pc track track $tr kind $kind \
                mid [incr ::conform_host_seq]
            return $tr
        }
        default { error "conform_drive_host: cannot drive $what" }
    }
    return
}

proc conform_host_send {pc type args} {
    ::tacky::media::host::event [dict create pc $pc type $type {*}$args]
}

# Where the commands for the app go. Nothing reads them here; the conformance
# script checks the events coming back, not the ones going out.
proc conform_host_sink {args} {}

set ::conform_host_seq 0

test media-conformance-mock {the mock backend conforms to tacky::media} -setup {
    mockmedia::reset
} -body {
    mediaconform::run mock -drive conform_drive_mock
} -result {}

test media-conformance-rtc {the rtc backend conforms to tacky::media} -setup {
    mockrtc::install
} -cleanup {
    mockrtc::uninstall
} -body {
    mediaconform::run rtc -drive conform_drive_rtc
} -result {}

# A device streams to one opener at a time, so every sender and the preview
# ride one rtc-mv capture, closed only when the last of them goes.
proc rtc_video_pc {pc} {
    ::tacky::media createPeer $pc -command {apply {ev {}}}
    ::tacky::media addTrack $pc video -kind video
    ::tacky::media attachVideoSender $pc video
}

test media-rtc-one-camera {two senders and a preview share one capture} -setup {
    mockrtc::install
    ::tacky::media open rtc
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
} -body {
    rtc_video_pc a
    rtc_video_pc b
    ::tacky::media openPreview pv -command {apply {ev {}}}
    set senders {}
    foreach call [mockrtc::calls ::rtcmv::sender::new] {
        lappend senders [dict get $call -capture]
    }
    list [llength [mockrtc::calls ::rtcmv::capture::new]] \
        [llength $senders] [llength [lsort -unique $senders]]
} -result {1 2 1}

test media-rtc-camera-outlives-senders {the preview keeps the camera once the pcs close} -setup {
    mockrtc::install
    ::tacky::media open rtc
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
} -body {
    rtc_video_pc a
    ::tacky::media openPreview pv -command {apply {ev {}}}
    ::tacky::media closePeer a
    set afterPc [llength [mockrtc::calls ::rtcmv::capture::destroy]]
    ::tacky::media closePreview pv
    list $afterPc [llength [mockrtc::calls ::rtcmv::capture::destroy]]
} -result {0 1}

# The capture goes only after the sender on it: rtc-mv requires it.
test media-rtc-sender-before-camera {closing the last pc destroys its sender, then the camera} -setup {
    mockrtc::install
    ::tacky::media open rtc
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
} -body {
    rtc_video_pc a
    ::tacky::media closePeer a
    expr {[mockrtc::first ::rtcmv::sender::destroy]
        < [mockrtc::first ::rtcmv::capture::destroy]}
} -result 1

test media-rtc-senders-share-a-switch {a camera switch moves the one capture} -setup {
    mockrtc::install
    ::tacky::media open rtc
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
} -body {
    rtc_video_pc a
    rtc_video_pc b
    ::tacky::media setVideoDevice a -id cam2
    list [llength [mockrtc::calls ::rtcmv::capture::reopen]] \
        [llength [mockrtc::calls ::rtcmv::sender::reopen]] \
        [lrange [lindex [mockrtc::calls ::rtcmv::capture::reopen] 0] 1 end]
} -result {1 0 {-device-id cam2}}

test media-rtc-preview-switch {a preview with no sender still switches the camera} -setup {
    mockrtc::install
    ::tacky::media open rtc
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
} -body {
    ::tacky::media openPreview pv -command {apply {ev {}}}
    ::tacky::media setVideoDevice pv -id cam2
    ::tacky::media setVideoDevice nobody -id cam3
    lmap c [mockrtc::calls ::rtcmv::capture::reopen] { lrange $c 1 end }
} -result {{-device-id cam2}}

test media-rtc-preview-no-camera {a preview with no camera is a fatal error to it alone} -setup {
    mockrtc::install
    ::tacky::media open rtc
    set ::pvEvents {}
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
    unset -nocomplain ::pvEvents
} -body {
    mockrtc::fail ::rtcmv::capture::new "no device"
    ::tacky::media openPreview pv -command {apply {ev {lappend ::pvEvents $ev}}}
    set ev [lindex $::pvEvents 0]
    list [dict get $ev type] [dict get $ev op] [dict get $ev fatal]
} -result {error openPreview 1}

test media-rtc-preview-falls-back {a camera that will not open falls back to the default} -setup {
    mockrtc::install
    ::tacky::media open rtc
    set ::pvEvents {}
} -cleanup {
    ::tacky::media close
    mockrtc::uninstall
    unset -nocomplain ::pvEvents
} -body {
    mockrtc::fail ::rtcmv::capture::new "gone" "*-device-id cam9*"
    ::tacky::media openPreview pv -command {apply {ev {lappend ::pvEvents $ev}}} \
        -device-id cam9
    lmap ev $::pvEvents {dict get $ev type}
} -result {deviceFallback videoChannel}

# The app keeps the camera, so a preview is a command to it and a channel
# named after the preview; its own error comes back on the preview.
test media-preview-refuses-a-live-pc-name {openPreview under a live pc's name throws, and closePreview of it leaves the pc alone} -setup {
    mockmedia::reset
    ::tacky::media open mock
    set ::pvEvents {}
    set ::pcEvents {}
} -cleanup {
    ::tacky::media close
    unset -nocomplain ::pvEvents ::pcEvents
} -body {
    ::tacky::media createPeer pc1 -command {apply {ev {lappend ::pcEvents $ev}}}
    set r [list [catch {::tacky::media openPreview pc1 \
        -command {apply {ev {lappend ::pvEvents $ev}}}} err] $err \
        [llength [mockmedia::calls OpenPreview]]]
    ::tacky::media closePreview pc1
    ::tacky::media::emit pc1 error op x reason y fatal 0
    lappend r [llength [mockmedia::calls ClosePreview]] \
        [llength $::pvEvents] [llength $::pcEvents]
} -result {1 {openPreview: pc1 is in use} 0 0 0 1}

test media-host-preview {openPreview and closePreview go to the app; the channel is the preview's name} -setup {
    set ::hostCmds {}
    set ::pvEvents {}
    ::tacky::media open host -emit {apply {args {lappend ::hostCmds $args}}}
} -cleanup {
    ::tacky::media close
    unset -nocomplain ::hostCmds ::pvEvents
} -body {
    ::tacky::media openPreview gc:room -command {apply {ev {lappend ::pvEvents $ev}}} \
        -device-id cam1
    set channel [dict get [lindex $::pvEvents 0] channel]
    conform_host_send gc:room error op openPreview reason NotAllowedError fatal 1
    ::tacky::media closePreview gc:room
    list [lrange $::hostCmds 0 1] $channel [dict get [lindex $::pvEvents 1] reason]
} -result {{{-op openPreview -pc gc:room -deviceId cam1} {-op closePreview -pc gc:room}} {kind host id gc:room} NotAllowedError}

test media-conformance-host {the host backend conforms to tacky::media} -body {
    mediaconform::run host -drive conform_drive_host \
        -open {-emit conform_host_sink}
} -result {}

# A backend that owns less than rtc does must still conform: the script asks
# only for what the capabilities claim. This is the shape a host backend
# takes, where the embedding app owns the devices and the rendering.
test media-conformance-minimal {a backend declaring no device control conforms} -setup {
    mockmedia::reset
    mockmedia::capabilities {
        audioDevices 0 audioVolume 0 cameras 0 videoDevice 0 videoChannel 0
        autoAnswer 0 sdpSanitize 0 trickleIce 0
    }
} -cleanup {
    mockmedia::reset
} -body {
    mediaconform::run mock -drive conform_drive_mock
} -result {}

# The script has to actually fail a backend that breaks the contract, or its
# passing above means nothing.
test media-conformance-catches-bad-capability {an unknown capability is refused} -setup {
    mockmedia::reset
    mockmedia::capabilities {audioDevices 1 telepathy 1}
} -cleanup {
    mockmedia::reset
} -body {
    set failures [mediaconform::run mock -drive conform_drive_mock]
    expr {[llength $failures] == 1
        && [string match "*unknown capability: telepathy*" $failures]}
} -result 1

test media-conformance-catches-missed-event {a dropped event is caught} -setup {
    mockmedia::reset
} -cleanup {
    mockmedia::reset
} -body {
    # A driver that never fires anything: every event check must complain.
    set failures [mediaconform::run mock -drive {apply {{what pc args} {}}}]
    expr {[llength $failures] > 0}
} -result 1

