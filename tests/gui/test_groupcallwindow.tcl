# groupcallwindow: drawn from groupcall <State>, a tile per participant.

set ::gcw_acc user@test.example.com
set ::gcw_room room@muc.example.com

proc gcw_up {} {
    mock_backend_up
    tacky muc join -acc $::gcw_acc -jid $::gcw_room -nick me
    $::_client.conn feed [j presence -from $::gcw_room/me {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -role participant -affiliation member -jid $::gcw_acc/res1
            j status -code 110
        }
    }]
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

# A participant in a <State>: nick, then leg and any field to override.
proc gcw_p {nick {leg expected} args} {
    return [dict merge [dict create nick $nick jid $nick@example.com joined 1 \
        video 0 leg $leg reason "" warning "" stream ""] $args]
}

# The room's call as groupcall <State> has it.
proc gcw_state {args} {
    array set opts [list -phase live -count 1 -participants {} -preview {} \
        -warning "" -reason "" -jid $::gcw_room]
    array set opts $args
    tacky emit groupcall <State> -acc $::gcw_acc -jid $opts(-jid) -chat $opts(-jid) \
        -hosted 0 -phase $opts(-phase) -reason $opts(-reason) -warning $opts(-warning) \
        -since 0 -video 0 -camera 0 -preview $opts(-preview) -count $opts(-count) \
        -participants $opts(-participants)
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

test groupcallwindow-legs {a participant's tile follows their leg} \
    -setup {gcw_up} -body {
    set out {}
    foreach leg {expected connecting active} {
        gcw_state -count 2 -participants [list [gcw_p bob $leg]]
        lappend out [gcw_tiles]
    }
    list {*}$out [$::_gcw.head.count cget -text]
} -cleanup {gcw_down} -result {{{bob Waiting...}} {{bob Connecting...}} {{bob Connected}} {2 in call}}

test groupcallwindow-preparing-shows-joining {someone still preparing shows as joining} \
    -setup {gcw_up} -body {
    gcw_state -count 1 -participants [list [gcw_p carol expected joined 0]]
    gcw_tiles
} -cleanup {gcw_down} -result {{carol Joining...}}

test groupcallwindow-other-room-ignored {another room's state is not this window's} \
    -setup {gcw_up} -body {
    gcw_state -jid other@muc.example.com -participants [list [gcw_p bob active]]
    gcw_tiles
} -cleanup {gcw_down} -result {}

test groupcallwindow-gone-removes-tile {someone no longer in the state loses their tile} \
    -setup {gcw_up} -body {
    gcw_state -count 3 -participants [list [gcw_p bob active] [gcw_p carol]]
    gcw_state -count 2 -participants [list [gcw_p carol]]
    gcw_tiles
} -cleanup {gcw_down} -result {{carol Waiting...}}

test groupcallwindow-rename-relabels-tile {a rename relabels the same tile} \
    -setup {gcw_up} -body {
    gcw_state -participants [list [gcw_p bob active]]
    set t [gcw_tile bob]
    gcw_state -participants [list [gcw_p bob active nick robert]]
    list [gcw_tiles] [expr {[gcw_tile robert] eq $t}]
} -cleanup {gcw_down} -result {{{robert Connected}} 1}

test groupcallwindow-leg-over-keeps-tile {a leg that ended or failed keeps the tile, saying so} \
    -setup {gcw_up} -body {
    gcw_state -participants [list [gcw_p bob ended] \
        [gcw_p zed failed jid "" reason "the room hides their address"]]
    gcw_tiles
} -cleanup {gcw_down} -result {{bob Ended} {zed {Failed: the room hides their address}}}

test groupcallwindow-leg-warning {an active leg's trouble is its caption} \
    -setup {gcw_up} -body {
    gcw_state -participants [list [gcw_p bob active warning "media path interrupted"]]
    gcw_tiles
} -cleanup {gcw_down} -result {{bob {media path interrupted}}}

test groupcallwindow-video-follows-stream {a leg's stream shows on the tile, the avatar without one} \
    -setup {gcw_up} -body {
    gcw_state -participants [list [gcw_p bob active stream [dict get $::gcw_stream name]]]
    ::rtcmv::stream::publish [dict get $::gcw_stream handle] 64 48
    set shown [gcw_reaches [gcw_tile bob] 64 48]
    gcw_state -participants [list [gcw_p bob active]]
    set tile [gcw_tile bob]
    list $shown [expr {[$tile.image cget -image] eq [$tile cget -avatar]}]
} -cleanup {gcw_down} -result {1 1}

test groupcallwindow-preview-tile {the call's preview is the self-view tile} \
    -setup {gcw_up} -body {
    gcw_state -participants [list [gcw_p bob active]] \
        -preview [dict create name [dict get $::gcw_stream name]]
    ::rtcmv::stream::publish [dict get $::gcw_stream handle] 32 24
    list [gcw_reaches [gcw_tile You] 32 24] [lsort [lmap t [gcw_tiles] {lindex $t 0}]]
} -cleanup {gcw_down} -result {1 {You bob}}

test groupcallwindow-ended-closes {an ended state closes the window} \
    -setup {gcw_up} -body {
    gcw_state -phase ended -count 0
    after 800 {set ::gcw_flag 1}
    vwait ::gcw_flag
    winfo exists $::_gcw
} -cleanup {gcw_down} -result 0
