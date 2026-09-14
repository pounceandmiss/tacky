# Stand-in for the rtc / rtc-ma extensions: install swaps the real commands
# for recorders, so the media half of taco_calls can be driven without a peer
# connection or an audio device. Handles come from separate ranges (pc 101..,
# track 201.., rtcma 301..) so a mixed-up id shows up in a failing result.
package provide tacky::mockrtc 0.1

namespace eval mockrtc {
    variable Log {}
    variable Cb
    variable Fail {}
    variable Seq
    variable TrackMid
    variable Installed 0

    variable COMMANDS {
        ::rtc::pc::new
        ::rtc::pc::add-track
        ::rtc::pc::set-local-description
        ::rtc::pc::set-remote-description
        ::rtc::pc::add-remote-candidate
        ::rtc::pc::close
        ::rtc::pc::delete
        ::rtc::pc::on-local-description
        ::rtc::pc::on-local-candidate
        ::rtc::pc::on-gathering-state-change
        ::rtc::pc::on-state-change
        ::rtc::pc::on-track
        ::rtc::track::get-mid
        ::rtc::track::get-description
        ::rtc::track::request-keyframe
        ::rtcma::capturer::new
        ::rtcma::capturer::attach
        ::rtcma::capturer::start
        ::rtcma::capturer::set-volume
        ::rtcma::capturer::reopen
        ::rtcma::capturer::destroy
        ::rtcma::player::new
        ::rtcma::player::attach
        ::rtcma::player::start
        ::rtcma::player::set-volume
        ::rtcma::player::reopen
        ::rtcma::player::destroy
        ::rtcmv::sender::new
        ::rtcmv::sender::attach
        ::rtcmv::sender::start
        ::rtcmv::sender::reopen
        ::rtcmv::sender::set-enabled
        ::rtcmv::sender::set-bitrate
        ::rtcmv::sender::request-keyframe
        ::rtcmv::sender::preview-shm
        ::rtcmv::sender::detach
        ::rtcmv::sender::destroy
        ::rtcmv::receiver::new
        ::rtcmv::receiver::attach
        ::rtcmv::receiver::start
        ::rtcmv::receiver::shm
        ::rtcmv::receiver::detach
        ::rtcmv::receiver::destroy
    }
}

proc mockrtc::install {} {
    variable COMMANDS
    variable Installed
    if {$Installed} { reset; return }
    foreach cmd $COMMANDS {
        if {[info commands $cmd] ne ""} { rename $cmd ${cmd}__real }
        proc $cmd args [format {return [mockrtc::Dispatch %s {*}$args]} \
            [list $cmd]]
    }
    set Installed 1
    reset
}

proc mockrtc::uninstall {} {
    variable COMMANDS
    variable Installed
    if {!$Installed} return
    foreach cmd $COMMANDS {
        catch {rename $cmd ""}
        catch {rename ${cmd}__real $cmd}
    }
    set Installed 0
    reset
}

proc mockrtc::reset {} {
    variable Log
    variable Cb
    variable Fail
    variable Seq
    variable TrackMid
    variable TrackDesc
    set Log {}
    set Fail {}
    array unset Cb
    array unset TrackMid
    array unset TrackDesc
    array set Seq {pc 100 track 200 handle 300 vhandle 400}
}

# A track id with an arbitrary mid + description, independent of our own
# add-track (which always assigns "audio"/"video" literals) - simulates a
# real peer's own numbered mid scheme.
proc mockrtc::remoteTrack {mid desc} {
    variable Seq
    variable TrackMid
    variable TrackDesc
    set id [incr Seq(track)]
    set TrackMid($id) $mid
    set TrackDesc($id) $desc
    return $id
}

proc mockrtc::log {} {
    variable Log
    return $Log
}

# Calls to one command, as recorded. Handy when the full log is noise.
proc mockrtc::calls {cmd} {
    variable Log
    set out {}
    foreach entry $Log {
        if {[lindex $entry 0] eq $cmd} { lappend out [lrange $entry 1 end] }
    }
    return $out
}

# Index of the first call to $cmd, or -1. Used to assert teardown ordering.
proc mockrtc::first {cmd} {
    variable Log
    return [lsearch -index 0 -exact $Log $cmd]
}

proc mockrtc::fail {cmd msg {pattern *}} {
    variable Fail
    lappend Fail [list $cmd $pattern $msg]
}

proc mockrtc::fire {pc event args} {
    variable Cb
    if {![info exists Cb($pc,$event)]} {
        error "mockrtc: pc $pc has no $event callback"
    }
    uplevel #0 [list {*}$Cb($pc,$event) $pc {*}$args]
}

proc mockrtc::Dispatch {cmd args} {
    variable Log
    variable Cb
    variable Fail
    variable Seq
    variable TrackMid

    lappend Log [linsert $args 0 $cmd]

    foreach rule $Fail {
        lassign $rule failCmd pattern msg
        if {$cmd eq $failCmd && [string match $pattern $args]} {
            error $msg
        }
    }

    # on-<event> $pc $command registers (or with "" clears) a callback.
    if {[regexp {^::rtc::pc::on-(.*)$} $cmd -> event]} {
        lassign $args pc command
        if {$command eq ""} {
            unset -nocomplain Cb($pc,$event)
        } else {
            set Cb($pc,$event) $command
        }
        return
    }

    switch -- $cmd {
        ::rtc::pc::new         { return [incr Seq(pc)] }
        ::rtc::pc::add-track   {
            set id [incr Seq(track)]
            set desc [lindex $args 1]
            set TrackMid($id) [expr {[string match "video *" $desc] ? "video" : "audio"}]
            return $id
        }
        ::rtcma::capturer::new -
        ::rtcma::player::new   { return [incr Seq(handle)] }
        ::rtc::track::get-mid  {
            set id [lindex $args 0]
            return [expr {[info exists TrackMid($id)] ? $TrackMid($id) : ""}]
        }
        ::rtc::track::get-description {
            # Real shape: an m= line first ("m=" is not optional).
            set id [lindex $args 0]
            variable TrackDesc
            if {[info exists TrackDesc($id)]} { return $TrackDesc($id) }
            set m [expr {[info exists TrackMid($id)] ? $TrackMid($id) : "audio"}]
            return "m=$m 9 UDP/TLS/RTP/SAVPF 96"
        }
        ::rtcmv::sender::new -
        ::rtcmv::receiver::new { return [incr Seq(vhandle)] }
        ::rtcmv::sender::preview-shm -
        ::rtcmv::receiver::shm {
            set h [lindex $args 0]
            return [dict create name "/tv-mock$h" channel "vc-mock$h" fd -1 \
                slots 6 slotBytes 1400000 maxWidth 1280 maxHeight 720 format I420]
        }
    }
    return
}
