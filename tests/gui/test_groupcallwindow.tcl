# groupcallwindow: one tile per participant, driven by the events the
# backend emits for a room's call.

set ::gcw_acc user@test.example.com
set ::gcw_room room@muc.example.com

proc gcw_up {} {
    mock_backend_up
    set ::gcw_dir [file tempdir tacky-groupcall]
    set ::gcw_stream [::rtcmv::stream::create -dir $::gcw_dir]
    set ::_gcw [groupcallwindow show -acc $::gcw_acc -jid $::gcw_room]
    update
    return $::_gcw
}

proc gcw_down {} {
    catch {destroy $::_gcw}
    unset -nocomplain ::_gcw
    catch {::rtcmv::stream::close [dict get $::gcw_stream handle]}
    file delete -force $::gcw_dir
    mock_backend_down
}

# Whether $tile's photo reaches w x h within two seconds.
proc gcw_reaches {tile w h} {
    for {set i 0} {$i < 400} {incr i} {
        update
        set img [$tile.image cget -image]
        if {$img ne "" && [image width $img] == $w && [image height $img] == $h} {
            return 1
        }
        after 5
    }
    return 0
}

proc gcw_tile {nick} {
    foreach w [winfo children $::_gcw.grid] {
        if {[$w cget -name] eq $nick} { return $w }
    }
    return ""
}

proc gcw_tiles {} {
    set out {}
    foreach w [winfo children $::_gcw.grid] {
        if {[winfo manager $w] eq ""} continue
        lappend out [list [$w cget -name] [$w cget -status]]
    }
    return [lsort $out]
}

test groupcallwindow-show-is-singleton {show reuses the window open for a room} \
    -setup {gcw_up} -body {
    set again [groupcallwindow show -acc $::gcw_acc -jid $::gcw_room]
    list [expr {$again eq $::_gcw}] [winfo exists $::_gcw]
} -cleanup {gcw_down} -result {1 1}

test groupcallwindow-peer-joined-adds-tile {<PeerJoined> adds a tile, <Active> on its leg marks it connected} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -video 0
    update
    set before [gcw_tiles]
    tacky emit calls <Active> -acc $::gcw_acc -sid s1
    update
    list $before [gcw_tiles]
} -cleanup {gcw_down} -result {{{bob Connecting...}} {{bob Connected}}}

test groupcallwindow-other-room-ignored {a call in another room does not land here} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid other@muc.example.com \
        -nick bob -peer bob@example.com/desk -sid s9 -video 0
    update
    gcw_tiles
} -cleanup {gcw_down} -result {}

test groupcallwindow-peer-left-removes-tile {a peer leaving the call takes its tile down} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -video 0
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick carol -peer carol@example.com/phone -sid s2 -video 0
    tacky emit groupcall <PeerLeft> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -reason "left the call"
    update
    gcw_tiles
} -cleanup {gcw_down} -result {{carol Connecting...}}

test groupcallwindow-leg-ended-keeps-tile {a leg ending while the peer stays in the call keeps the tile} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -video 0
    tacky emit groupcall <PeerLeft> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -reason "session ended"
    update
    gcw_tiles
} -cleanup {gcw_down} -result {{bob {session ended}}}

test groupcallwindow-video-follows-stream {a leg's <VideoTrack> puts its stream on the peer's tile} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -video 1
    update
    tacky emit calls <VideoTrack> -acc $::gcw_acc -sid s1 -mid video \
        -direction incoming -name [dict get $::gcw_stream name]
    ::rtcmv::stream::publish [dict get $::gcw_stream handle] 64 48
    set shown [gcw_reaches [gcw_tile bob] 64 48]
    tacky emit calls <VideoEnded> -acc $::gcw_acc -sid s1 -mid video
    update
    set tile [gcw_tile bob]
    list $shown [expr {[$tile.image cget -image] eq [$tile cget -avatar]}]
} -cleanup {gcw_down} -result {1 1}

test groupcallwindow-preview-tile {a leg's <VideoPreview> adds the self-view tile} \
    -setup {gcw_up} -body {
    tacky emit groupcall <PeerJoined> -acc $::gcw_acc -jid $::gcw_room \
        -nick bob -peer bob@example.com/desk -sid s1 -video 1
    tacky emit calls <VideoPreview> -acc $::gcw_acc -sid s1 \
        -direction preview -name [dict get $::gcw_stream name]
    ::rtcmv::stream::publish [dict get $::gcw_stream handle] 32 24
    list [gcw_reaches [gcw_tile You] 32 24] [lsort [lmap t [gcw_tiles] {lindex $t 0}]]
} -cleanup {gcw_down} -result {1 {You bob}}

test groupcallwindow-left-closes {<Left> closes the window} \
    -setup {gcw_up} -body {
    tacky emit groupcall <Left> -acc $::gcw_acc -jid $::gcw_room -reason left
    update
    after 800 {set ::gcw_flag 1}
    vwait ::gcw_flag
    winfo exists $::_gcw
} -cleanup {gcw_down} -result 0

test groupcallwindow-leave-asks-backend {the leave button leaves the room's call} \
    -setup {gcw_up} -body {
    $::_gcw.controls.leave invoke
    update
    set written [$::_client.conn get_written]
    set out {}
    foreach w $written {
        if {[dict get $w tag] eq "presence"} { lappend out presence }
    }
    # Not in the room: leaving is a no-op on the wire, and the window
    # stays up for its own timer rather than failing.
    list $out [winfo exists $::_gcw]
} -cleanup {gcw_down} -result {{} 1}

# A call the backend has no record of sends no <Left>; leaving still closes
# on <Left>'s beat rather than waiting on one.
test groupcallwindow-leave-closes-promptly {leaving closes the window within a beat} \
    -setup {gcw_up} -body {
    $::_gcw.controls.leave invoke
    after 800 {set ::gcw_flag 1}
    vwait ::gcw_flag
    winfo exists $::_gcw
} -cleanup {gcw_down} -result 0
