# groupcallwindow: a tile per room occupant in the call; calls events for
# each session drive its tile.

set ::gcw_acc user@test.example.com
set ::gcw_room room@muc.example.com

proc gcw_up {} {
    mock_backend_up
    tacky muc join -acc $::gcw_acc -jid $::gcw_room -nick me
    $::_client.conn feed [gcw_presence me -self 1 -jid $::gcw_acc/res1]
    $::_client.conn clear
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

# An occupant's presence in the room: -call announced|preparing|"" (none),
# -type unavailable for leaving.
proc gcw_presence {nick args} {
    array set opts {-self 0 -call "" -jid "" -type ""}
    array set opts $args
    set itemAttrs {-role participant -affiliation member}
    if {$opts(-jid) ne ""} { lappend itemAttrs -jid $opts(-jid) }
    set presAttrs [list -from $::gcw_room/$nick]
    if {$opts(-type) ne ""} { lappend presAttrs -type $opts(-type) }
    return [j presence {*}$presAttrs {
        j x -ns http://jabber.org/protocol/muc#user {
            j item {*}$itemAttrs
            if {$opts(-self)} { j status -code 110 }
        }
        if {$opts(-call) ne ""} {
            j muji -ns urn:xmpp:jingle:muji:0 {
                if {$opts(-call) eq "preparing"} { j preparing }
                j content -ns urn:xmpp:jingle:1 -creator initiator -name audio {
                    j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                        j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                    }
                }
            }
        }
    }]
}

proc gcw_feed {stanza} {
    $::_client.conn feed $stanza
    update
}

# bob in the call, with our session s1 to him.
proc gcw_bob_with_session {{video 0}} {
    gcw_feed [gcw_presence bob -call announced -jid bob@example.com/desk]
    tacky emit groupcall <Session> -acc $::gcw_acc -jid $::gcw_room \
        -peer bob@example.com/desk -sid s1 -video $video
    update
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

test groupcallwindow-occupant-in-call-adds-tile {an announced occupant gets a tile; <Session> then <Active> mark it connecting, then connected} \
    -setup {gcw_up} -body {
    gcw_feed [gcw_presence bob -call announced -jid bob@example.com/desk]
    set waiting [gcw_tiles]
    tacky emit groupcall <Session> -acc $::gcw_acc -jid $::gcw_room \
        -peer bob@example.com/desk -sid s1 -video 0
    update
    set connecting [gcw_tiles]
    tacky emit calls <Active> -acc $::gcw_acc -sid s1
    update
    list $waiting $connecting [gcw_tiles] [$::_gcw.head.count cget -text]
} -cleanup {gcw_down} -result {{{bob Waiting...}} {{bob Connecting...}} {{bob Connected}} {1 in call}}

test groupcallwindow-preparing-shows-joining {an occupant still preparing shows as joining, and is not counted} \
    -setup {gcw_up} -body {
    gcw_feed [gcw_presence carol -call preparing -jid carol@example.com/phone]
    list [gcw_tiles] [$::_gcw.head.count cget -text]
} -cleanup {gcw_down} -result {{{carol Joining...}} {0 in call}}

test groupcallwindow-other-room-ignored {a session in another room is ignored} \
    -setup {gcw_up} -body {
    tacky emit groupcall <Session> -acc $::gcw_acc -jid other@muc.example.com \
        -peer bob@example.com/desk -sid s9 -video 0
    update
    gcw_tiles
} -cleanup {gcw_down} -result {}

test groupcallwindow-leave-removes-tile {an occupant leaving the room takes its tile down} \
    -setup {gcw_up} -body {
    gcw_bob_with_session
    gcw_feed [gcw_presence carol -call announced -jid carol@example.com/phone]
    gcw_feed [gcw_presence bob -jid bob@example.com/desk -type unavailable]
    gcw_tiles
} -cleanup {gcw_down} -result {{carol Waiting...}}

test groupcallwindow-out-of-call-removes-tile {an occupant who leaves the call but stays in the room loses the tile} \
    -setup {gcw_up} -body {
    gcw_bob_with_session
    gcw_feed [gcw_presence bob -jid bob@example.com/desk]
    gcw_tiles
} -cleanup {gcw_down} -result {}

test groupcallwindow-rename-relabels-tile {a rename relabels the tile and keeps its session and status} \
    -setup {gcw_up} -body {
    gcw_bob_with_session
    tacky emit calls <Active> -acc $::gcw_acc -sid s1
    update
    gcw_feed [j presence -from $::gcw_room/bob -type unavailable {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -role participant -affiliation member -jid bob@example.com/desk -nick robert
            j status -code 303
        }
    }]
    gcw_feed [gcw_presence robert -call announced -jid bob@example.com/desk]
    set renamed [gcw_tiles]
    tacky emit calls <Ended> -acc $::gcw_acc -sid s1
    update
    list $renamed [gcw_tiles]
} -cleanup {gcw_down} -result {{{robert Connected}} {{robert Ended}}}

test groupcallwindow-session-ended-keeps-tile {a session ending while the peer stays in the call keeps the tile} \
    -setup {gcw_up} -body {
    gcw_bob_with_session
    tacky emit calls <Ended> -acc $::gcw_acc -sid s1
    update
    gcw_tiles
} -cleanup {gcw_down} -result {{bob Ended}}

test groupcallwindow-video-follows-stream {a session's <VideoTrack> puts its stream on the peer's tile} \
    -setup {gcw_up} -body {
    gcw_bob_with_session 1
    tacky emit calls <VideoTrack> -acc $::gcw_acc -sid s1 -mid video \
        -direction incoming -name [dict get $::gcw_stream name]
    ::rtcmv::stream::publish [dict get $::gcw_stream handle] 64 48
    set shown [gcw_reaches [gcw_tile bob] 64 48]
    tacky emit calls <VideoEnded> -acc $::gcw_acc -sid s1 -mid video
    update
    set tile [gcw_tile bob]
    list $shown [expr {[$tile.image cget -image] eq [$tile cget -avatar]}]
} -cleanup {gcw_down} -result {1 1}

test groupcallwindow-preview-tile {a session's <VideoPreview> adds the self-view tile} \
    -setup {gcw_up} -body {
    gcw_bob_with_session 1
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
    # In the room but not in its call: leaving is a no-op on the wire, and
    # the window stays up for its own timer rather than failing.
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
