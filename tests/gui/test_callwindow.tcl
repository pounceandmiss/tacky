# callwindow - video: the photo follows the frame stream a calls event names,
# as frames arrive and at whatever size they come.

set cw_acc user@test.example.com

proc cw_setup {} {
    mock_backend_up
    set ::cw_dir [file tempdir tacky-callwindow]
    set ::cw_stream [::rtcmv::stream::create -dir $::cw_dir]
    callwindow show -acc $::cw_acc -sid s1 -peer bob@test.example.com
}

proc cw_cleanup {} {
    catch {destroy .callwindow}
    catch {::rtcmv::stream::close [dict get $::cw_stream handle]}
    file delete -force $::cw_dir
    mock_backend_down
}

# Whether the remote video photo reaches w x h within two seconds.
proc cw_reaches {w h} {
    for {set i 0} {$i < 400} {incr i} {
        update
        set img [.callwindow.body.video cget -image]
        if {$img ne "" && [image width $img] == $w && [image height $img] == $h} {
            return 1
        }
        after 5
    }
    return 0
}

test callwindow-video-follows-stream \
    {<VideoTrack> connects the named stream, and every frame size shows} \
    -setup cw_setup -cleanup cw_cleanup -body {
    set h [dict get $::cw_stream handle]
    $::_client emit calls <VideoTrack> -sid s1 -mid video \
        -direction incoming -name [dict get $::cw_stream name]
    ::rtcmv::stream::publish $h 64 48
    set small [cw_reaches 64 48]
    ::rtcmv::stream::publish $h 2560 1440
    list $small [cw_reaches 2560 1440]
} -result {1 1}
