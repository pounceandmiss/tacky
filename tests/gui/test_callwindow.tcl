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

# Direct mode emits <Ended> inside `calls hangup`, before Hangup returns; the
# window must still close on <Ended>'s beat, not on a slower fallback.
test callwindow-hangup-closes-promptly {hanging up closes the window within a beat} \
    -setup {mock_backend_up} -body {
    set sid [::tacky calls start -acc $::cw_acc -to bob@test.example.com]
    callwindow show -acc $::cw_acc -sid $sid -peer bob@test.example.com
    update
    .callwindow Hangup
    after 800 {set ::cw_flag 1}
    vwait ::cw_flag
    winfo exists .callwindow
} -cleanup {
    catch {destroy .callwindow}
    mock_backend_down
} -result 0

# -- Verification: the security row follows calls <Verified> --

set cw_key "05ab12cd 33445566 778899aa bbccddee ff001122 33445566 778899aa bbccddee"

proc cw_verify_setup {} {
    mock_backend_up
    callwindow show -acc $::cw_acc -sid s2 -peer bob@test.example.com/phone
    update
}

proc cw_verify_cleanup {} {
    catch {destroy .callwindow}
    catch {destroy .omemokeys_[path_safe $::cw_acc]}
    mock_backend_down
}

# {shown state-text has-lock key-text} of the security row.
proc cw_security {} {
    set w .callwindow.body.security
    list [expr {[winfo manager $w] ne ""}] \
        [$w.state cget -text] [expr {[$w.state cget -image] ne ""}] \
        [string map {\n |} [$w.key cget -text]]
}

test callwindow-verified-shows-lock-and-key \
    {a verified call shows the lock and the key that vouched for it} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid s2 -verified 1 -fingerprint $::cw_key
    update
    cw_security
} -result {1 Verified 1 {05ab12cd 33445566 778899aa bbccddee|ff001122 33445566 778899aa bbccddee}}

test callwindow-unverified-key-shown-without-lock \
    {a key not yet trusted is shown, without the lock} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid s2 -verified 0 -fingerprint $::cw_key
    update
    lrange [cw_security] 0 2
} -result {1 {Key not verified} 0}

test callwindow-no-key-no-row {a call no OMEMO key took part in shows no security row} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid s2 -verified 0 -fingerprint ""
    update
    lindex [cw_security] 0
} -result 0

test callwindow-verified-later-adds-lock \
    {trusting the key mid-call turns the row verified} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid s2 -verified 0 -fingerprint $::cw_key
    update
    $::_client emit calls <Verified> -sid s2 -verified 1 -fingerprint $::cw_key
    update
    lrange [cw_security] 0 2
} -result {1 Verified 1}

test callwindow-other-call-ignored {another call's <Verified> leaves the row alone} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid other -verified 1 -fingerprint $::cw_key
    update
    lindex [cw_security] 0
} -result 0

test callwindow-key-opens-keys-window \
    {clicking the key opens the contact's keys with that one highlighted} \
    -setup cw_verify_setup -cleanup cw_verify_cleanup -body {
    $::_client emit calls <Verified> -sid s2 -verified 0 -fingerprint $::cw_key
    update
    .callwindow ShowKey
    update
    set w .omemokeys_[path_safe $::cw_acc]
    list [winfo exists $w] [$w cget -jid] \
        [expr {[$w cget -highlight] eq $::cw_key}] [$w cget -highlightnote]
} -result {1 bob@test.example.com 1 {this call's key}}
