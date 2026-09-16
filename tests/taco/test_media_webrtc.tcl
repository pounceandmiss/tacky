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
