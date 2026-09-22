# Conformance against libtacky_webrtc.so when it is built ($TACKY_WEBRTC_LIB,
# default dist/), on the fake camera and dummy audio device.
package require tcltest
namespace import ::tcltest::*
package require tacky::media
package require tacky::mediaconformance

set webrtcLib [expr {[info exists ::env(TACKY_WEBRTC_LIB)] ? $::env(TACKY_WEBRTC_LIB)
    : [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] \
        dist libtacky_webrtc.so]}]

testConstraint webrtcBackend 0
if {[file exists $webrtcLib]} {
    set ::env(TACKY_WEBRTC_FAKE_CAMERA) 1
    set ::env(TACKY_WEBRTC_DUMMY_AUDIO) 1
    if {![catch {load $webrtcLib Tackywebrtc}]
            && "webrtc" in [::tacky::media available]} {
        testConstraint webrtcBackend 1
    }
}

# test-drive plays the peer, as mock_rtc.tcl does for rtc.
proc conform_drive_webrtc {what pc args} {
    return [::tacky::media::webrtc::Op test-drive $pc $what {*}$args]
}

test media-conformance-webrtc {the webrtc backend conforms to tacky::media} \
        -constraints webrtcBackend -body {
    mediaconform::run webrtc -drive conform_drive_webrtc
} -result {}

test media-webrtc-capabilities {the webrtc backend owns devices and video} \
        -constraints webrtcBackend -setup {
    ::tacky::media open webrtc
} -cleanup {
    ::tacky::media close
} -body {
    set caps [::tacky::media capabilities]
    list [dict get $caps audioDevices] [dict get $caps videoChannel] \
        [dict get $caps autoAnswer] [dict get $caps sdpSanitize]
} -result {1 1 0 0}

# One camera for the process: every sender and the preview hold the same one,
# and the self-view keeps publishing once the pcs are gone.
proc webrtc_camera {} {
    return [::tacky::media::webrtc::Op test-camera]
}

proc webrtc_video_pc {pc} {
    ::tacky::media createPeer $pc -command {apply {ev {}}}
    ::tacky::media addTrack $pc video -kind video
    ::tacky::media attachVideoSender $pc video
}

proc webrtc_preview_grows {} {
    set before [dict get [webrtc_camera] preview]
    after 300
    expr {[dict get [webrtc_camera] preview] > $before}
}

test media-webrtc-one-camera {two senders and a preview open the camera once} \
        -constraints webrtcBackend -setup {
    ::tacky::media open webrtc
} -cleanup {
    ::tacky::media close
} -body {
    set opens [dict get [webrtc_camera] opens]
    webrtc_video_pc a
    webrtc_video_pc b
    ::tacky::media openPreview pv -command {apply {ev {}}}
    set cam [webrtc_camera]
    list [expr {[dict get $cam opens] - $opens}] [dict get $cam users] \
        [dict get $cam open] [webrtc_preview_grows]
} -result {1 3 1 1}

test media-webrtc-preview-outlives-senders {the self-view keeps going once every pc closes} \
        -constraints webrtcBackend -setup {
    ::tacky::media open webrtc
} -cleanup {
    ::tacky::media close
} -body {
    webrtc_video_pc a
    ::tacky::media openPreview pv -command {apply {ev {}}}
    ::tacky::media closePeer a
    set alone [list [dict get [webrtc_camera] users] [webrtc_preview_grows]]
    ::tacky::media closePreview pv
    list {*}$alone [dict get [webrtc_camera] open]
} -result {1 1 0}

test media-webrtc-preview-then-sender {a sender joining a live preview shares its stream} \
        -constraints webrtcBackend -setup {
    ::tacky::media open webrtc
    set ::wEvents {}
} -cleanup {
    ::tacky::media close
    unset -nocomplain ::wEvents
} -body {
    ::tacky::media openPreview pv -command {apply {ev {lappend ::wEvents $ev}}}
    ::tacky::media createPeer a -command {apply {ev {lappend ::wEvents $ev}}}
    ::tacky::media addTrack a video -kind video
    ::tacky::media attachVideoSender a video
    set names [lmap ev $::wEvents {
        if {[dict get $ev type] ne "videoChannel"} continue
        dict get $ev channel name
    }]
    list [llength $names] [llength [lsort -unique $names]]
} -result {2 1}

test media-webrtc-close-drops-camera {closing the backend closes a camera still held} \
        -constraints webrtcBackend -body {
    ::tacky::media open webrtc
    ::tacky::media openPreview pv -command {apply {ev {}}}
    webrtc_video_pc a
    ::tacky::media close
    ::tacky::media open webrtc
    set cam [webrtc_camera]
    ::tacky::media close
    list [dict get $cam open] [dict get $cam users]
} -result {0 0}
