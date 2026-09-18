# The tacky::media conformance script (tests/taco/media_conformance.tcl) run
# against every backend this build has: the mock, and rtc driven through
# mock_rtc.tcl. A new backend earns its place here by passing the same run.
#
# These take the backend over for the duration, so they do not use tacky_env -
# there is no taco here to have opened one.
package require tcltest
namespace import ::tcltest::*
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

