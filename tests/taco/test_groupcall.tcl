# Unit tests for taco_groupcall: the XEP-0272 presence choreography and the
# legs it opens through taco_calls. Runs against the mock media backend, so
# a leg gets as far as its offer, which is where the wire is checked.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers
package require tacky::mockmedia

set groupcall_env [tacky_env -mock conn -capture-emit 1 -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky
} -bound-jid user@test.example.com/res -extra-setup {
    mockmedia::reset
    ::tacky::media open mock
    set ::taco_groupcall::PREPARE_TIMEOUT_MS 5000
    set ::taco_groupcall::ECHO_TIMEOUT_MS 10000
}]

set ROOM room@muc.example.com
set NS_MUJI urn:xmpp:jingle:muji:0
set BOB bob@example.com/desk
set CAROL carol@example.com/phone

# -- Helpers --

# A MUC presence from an occupant. -contents is media -> payload dicts and
# -preparing adds <preparing/>; with neither there is no <muji> at all.
# -jid "" is a room that hides the JID.
proc gc_presence {nick args} {
    array set opts [list -jid "" -self 0 -preparing 0 -contents "" -type "" \
        -room $::ROOM -role participant -affiliation member -codes {}]
    array set opts $args
    set room $opts(-room)
    set ns $::NS_MUJI
    set presAttrs [list -from $room/$nick]
    if {$opts(-type) ne ""} { lappend presAttrs -type $opts(-type) }
    set itemAttrs [list -role $opts(-role) -affiliation $opts(-affiliation)]
    if {$opts(-jid) ne ""} { lappend itemAttrs -jid $opts(-jid) }
    set withMuji [expr {$opts(-preparing) || $opts(-contents) ne ""}]
    return [j presence {*}$presAttrs {
        j x -ns http://jabber.org/protocol/muc#user {
            j item {*}$itemAttrs
            if {$opts(-self)} { j status -code 110 }
            foreach code $opts(-codes) { j status -code $code }
        }
        if {$withMuji} {
            j muji -ns $ns {
                if {$opts(-preparing)} { j preparing }
                dict for {media pts} $opts(-contents) {
                    j content -ns urn:xmpp:jingle:1 -creator initiator -name $media {
                        j description -ns urn:xmpp:jingle:apps:rtp:1 -media $media {
                            foreach pt $pts {
                                j payload-type {*}$pt
                            }
                        }
                    }
                }
            }
        }
    }]
}

set OPUS_111 {-id 111 -name opus -clockrate 48000 -channels 2}
set OPUS_100 {-id 100 -name opus -clockrate 48000 -channels 2}
set PCMU     {-id 0 -name PCMU -clockrate 8000}
set VP8_96   {-id 96 -name VP8 -clockrate 90000}
set VP8_98   {-id 98 -name VP8 -clockrate 90000}

# Join the room as "me" with the given other occupants already in.
proc gc_room {args} {
    c muc join -jid $::ROOM -nick me
    foreach pres $args { c.conn feed $pres }
    c.conn feed [gc_presence me -self 1 -jid user@test.example.com/res]
    c.conn clear
    set ::_emitted {}
}

# The last room join we wrote (a presence carrying the muc namespace): its to.
proc gc_last_join {} {
    foreach w [lreverse [c.conn get_written]] {
        if {[dict get $w tag] ne "presence"} continue
        if {[xsearch $w x -ns http://jabber.org/protocol/muc -get node] ne ""} {
            return [xsearch $w -get @to]
        }
    }
    return ""
}

# Everything we wrote to $jid (bare match), in order.
proc gc_written_to {jid} {
    set out {}
    foreach w [c.conn get_written] {
        set to [xsearch $w -get @to]
        if {$to eq ""} continue
        if {$to eq $jid || [jid bare $to] eq $jid} { lappend out $w }
    }
    return $out
}

# The last muc#owner request we wrote to $room, answered with $payload.
proc gc_owner_reply {room payload} {
    foreach w [lreverse [gc_written_to $room]] {
        if {[xsearch $w query -ns http://jabber.org/protocol/muc#owner -get node] ne ""} {
            c.conn feed [j iq -type result -id [xsearch $w -get @id] -from $room {
                if {$payload ne ""} { j #as-is $payload }
            }]
            return $w
        }
    }
    error "no muc#owner request to $room"
}

proc gc_owner_form {} {
    j query -ns http://jabber.org/protocol/muc#owner {
        j x -ns jabber:x:data -type form {
            j field -var FORM_TYPE -type hidden { j value -body http://jabber.org/protocol/muc#roomconfig }
            j field -var muc#roomconfig_membersonly -type boolean { j value -body 0 }
            j field -var muc#roomconfig_whois -type list-single { j value -body moderators }
        }
    }
}

# Start a hosted call from $ROOM and see its room through creation; returns
# the call room's JID. Our nick there is whatever start chose.
proc gc_start_hosted {} {
    c.groupcall start -chat $::ROOM?join
    set to [gc_last_join]
    set call [jid bare $to]
    c.conn feed [gc_presence [jid resource $to] -room $call -self 1 \
        -jid user@test.example.com/res -role moderator -affiliation owner -codes 201]
    gc_owner_reply $call [gc_owner_form]
    gc_owner_reply $call ""
    return $call
}

# A <tag> in the call-invites namespace we sent to $to: {type id} of the
# message and element, "" if none.
proc gc_invite_sent {to tag} {
    foreach w [lreverse [gc_written_to $to]] {
        if {[dict get $w tag] ne "message"} continue
        set node [xsearch $w $tag -ns urn:xmpp:call-invites:0 -get node]
        if {$node ne ""} {
            return [list [xsearch $w -get @type] [xsearch $node -get @id] $node]
        }
    }
    return ""
}

# The stanza we wrote with the given id, "" if none.
proc gc_written_id {id} {
    foreach w [c.conn get_written] {
        if {[xsearch $w -get @id] eq $id} { return $w }
    }
    return ""
}

proc gc_error_condition {stanza} {
    set node [xsearch $stanza error * \
        -ns urn:ietf:params:xml:ns:xmpp-stanzas -get node]
    if {$node eq ""} { return "" }
    return [dict get $node tag]
}

# Our own preparing echo, as the room rebroadcasts it.
proc gc_echo_preparing {} {
    c.conn feed [gc_presence me -self 1 -jid user@test.example.com/res -preparing 1]
}

# The <muji> node of the last presence we wrote, "" if it had none.
proc gc_muji_written {} {
    foreach w [lreverse [c.conn get_written]] {
        if {[dict get $w tag] ne "presence"} continue
        return [xsearch $w muji -ns $::NS_MUJI -get node]
    }
    error "no presence was written"
}

# media -> {id name ...} of a written <muji>, for comparing announcements.
proc gc_payloads {muji} {
    set out {}
    xsearch $muji content -script content {
        set d [xsearch $content description -get node]
        set pts {}
        xsearch $d payload-type -script pt {
            lappend pts [list [xsearch $pt -get @id] [xsearch $pt -get @name]]
        }
        dict set out [xsearch $d -get @media] $pts
    }
    return $out
}

proc gc_events {} {
    set out {}
    foreach e $::_emitted {
        if {[lindex $e 0] ne "groupcall"} continue
        lappend out [list [lindex $e 1] {*}[dict remove [lrange $e 2 end] -acc]]
    }
    return $out
}

proc gc_event_names {} {
    set out {}
    foreach e [gc_events] { lappend out [lindex $e 0] }
    return $out
}

# Answer the XEP-0215 request a new leg makes, so its pc comes up.
proc gc_answer_extdisco {} {
    set id ""
    foreach w [c.conn get_written] {
        if {[dict get $w tag] ne "iq"} continue
        set child [lindex [dict get $w children] 0]
        if {$child ne "" && [dict get $child tag] eq "services"} {
            set id [xsearch $w -get @id]
        }
    }
    if {$id eq ""} { error "no extdisco request was written" }
    c.conn feed [j iq -type result -from test.example.com \
        -to user@test.example.com -id $id {
        j services -ns urn:xmpp:extdisco:2
    }]
}

proc gc_offer_sdp {} {
    return "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:abc\r\na=ice-pwd:xyzxyzxyzxyz\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"
}

# The jingle node of the last IQ we wrote, "" if none.
proc gc_jingle_written {} {
    foreach w [lreverse [c.conn get_written]] {
        if {[dict get $w tag] ne "iq"} continue
        set jingle [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jingle ne ""} { return [list [xsearch $w -get @to] $jingle] }
    }
    return ""
}

proc gc_session_initiate {sid from {room ""}} {
    j iq -type set -from $from -to user@test.example.com/res -id si1 {
        j jingle -ns urn:xmpp:jingle:1 -action session-initiate -sid $sid \
            -initiator $from {
            if {$room ne ""} { j muji -ns urn:xmpp:jingle:muji:0 -room $room }
            j content -creator initiator -name audio {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                }
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                    -ufrag abc -pwd xyzxyzxyzxyz {
                    j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 \
                        -hash sha-256 -setup actpass -body AA:BB
                }
            }
        }
    }
}

# The sid a <PeerJoined> for $nick carried.
proc gc_sid_of {nick} {
    foreach e [gc_events] {
        if {[lindex $e 0] eq "<PeerJoined>" && [dict get [lrange $e 1 end] -nick] eq $nick} {
            return [dict get [lrange $e 1 end] -sid]
        }
    }
    return ""
}

# The pc handle of a leg, as mock media logged it.
proc gc_pc_of {sid} {
    foreach entry [mockmedia::calls CreatePeer] {
        if {[string match "*/$sid" [lindex $entry 0]]} { return [lindex $entry 0] }
    }
    return ""
}

# -- Joining ------------------------------------------------------------------

test groupcall-join-outside-room-is-hosted {joining a room we are not in enters it as a hosted call's} \
    {*}$groupcall_env -body {
        c.groupcall join -jid call@muc.example.com
        set to [gc_last_join]
        list [jid bare $to] [regexp {^[0-9a-f]{8}$} [jid resource $to]]
    } -result {call@muc.example.com 1}

test groupcall-join-prepares {join announces preparation in the room, with our caps} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        set w [lindex [c.conn get_written] end]
        list [xsearch $w -get @to] \
            [expr {[xsearch $w c -ns http://jabber.org/protocol/caps -get node] ne ""}] \
            [expr {[xsearch [gc_muji_written] preparing -get node] ne ""}] \
            [gc_event_names]
    } -result [list $ROOM/me 1 1 {}]

test groupcall-first-in-announces-own-codecs {alone in the room, the echo announces our payload types and joins} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        list [gc_payloads [gc_muji_written]] [gc_event_names] \
            [c.groupcall status -jid $ROOM]
    } -result [list {audio {{111 opus}} video {{96 VP8}}} \
        {<VideoPreview> <Changed> <Joined> <Changed>} {active 0 joined 1 count 0 mode mesh}]

test groupcall-audio-only-announces-no-video {without -video the announcement has no video content} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        dict keys [gc_payloads [gc_muji_written]]
    } -result audio

test groupcall-joiner-adopts-room-codecs {with someone in, we announce the intersection with their ids} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB \
            -contents [list audio [list $OPUS_100 $PCMU] video [list $VP8_98]]]
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        gc_payloads [gc_muji_written]
    } -result {audio {{100 opus}} video {{98 VP8}}}

test groupcall-joiner-calls-those-in {the joiner initiates to everyone already announced} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set sid [gc_sid_of bob]
        gc_answer_extdisco
        set pc [gc_pc_of $sid]
        mockmedia::drive localDescription $pc [gc_offer_sdp] offer
        lassign [gc_jingle_written] to jingle
        string map [list $sid SID] [list [expr {$sid ne ""}] $to \
            [xsearch $jingle -get @action] \
            [xsearch $jingle muji -ns $NS_MUJI -get @room] \
            [expr {[xsearch $jingle -get @sid] eq $sid}] \
            [lsearch -inline [gc_events] {<PeerJoined>*}]]
    } -result [list 1 $BOB session-initiate $ROOM 1 \
        [list <PeerJoined> -jid $ROOM -nick bob -peer $BOB -sid SID -video 0]]

test groupcall-leg-is-not-a-1to1-call {a leg emits no <Outgoing> and lists its room} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        list [calls_events] [dict get [lindex [c.calls list] 0] group] \
            [c.groupcall list]
    } -result [list {} $ROOM [list [list jid $ROOM chat $ROOM hosted 0 count 1 video 0 mode mesh preview {}]]]

test groupcall-video-only-when-peer-offers {a leg offers video only to a peer announcing it} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]] \
            [gc_presence carol -jid $CAROL \
                -contents [list audio [list $OPUS_111] video [list $VP8_96]]]
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        set out {}
        foreach e [gc_events] {
            if {[lindex $e 0] ne "<PeerJoined>"} continue
            lappend out [dict get [lrange $e 1 end] -nick] [dict get [lrange $e 1 end] -video]
        }
        lsort -stride 2 $out
    } -result {bob 0 carol 1}

test groupcall-hidden-jid-warns {a room hiding a participant's JID gets a warning, not a leg} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        list [gc_event_names] [llength [c.calls list]] \
            [dict get [lindex [c.groupcall participants -jid $ROOM] 0] state]
    } -result {{<Changed> <Joined> <Warning> <Changed>} 0 expected}

# -- Waiting on preparing peers ------------------------------------------------

test groupcall-waits-for-preparing-peer {a peer still preparing holds our announcement} \
    {*}$groupcall_env -body {
        gc_room [gc_presence carol -jid $CAROL -preparing 1]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set before [gc_event_names]
        c.conn feed [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111]]]
        list $before [gc_event_names] [expr {[gc_sid_of carol] ne ""}]
    } -result {<Changed> {<Changed> <Changed> <Joined> <PeerJoined> <Changed>} 1}

test groupcall-preparing-wait-is-bounded {a peer stuck preparing is waited out} \
    {*}$groupcall_env -body {
        set ::taco_groupcall::PREPARE_TIMEOUT_MS 50
        gc_room [gc_presence carol -jid $CAROL -preparing 1]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set flag [testwait::Flag]
        after 200 [list set $flag 1]
        testwait::Block $flag 2000 "prepare timeout"
        list [gc_event_names] [llength [c.calls list]]
    } -result {{<Changed> <Joined> <Changed>} 0}

# -- Peers arriving after us ---------------------------------------------------

test groupcall-late-peer-calls-us {a peer announcing after us is let in when they initiate} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        set before [llength [c.calls list]]
        c.conn feed [gc_session_initiate bob-sid $BOB $ROOM]
        set ack [gc_written_id si1]
        gc_answer_extdisco
        list $before [xsearch $ack -get @type] [xsearch $ack -get @id] \
            [gc_sid_of bob] [dict get [lindex [c.calls list] 0] group] \
            [expr {[gc_pc_of bob-sid] ne ""}]
    } -result [list 0 result si1 bob-sid $ROOM 1]

test groupcall-late-peer-video-follows-ours {an inbound leg sends video only if we joined with it} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        c.conn feed [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_session_initiate bob-sid $BOB $ROOM]
        dict get [lindex [c.calls list] 0] video_local
    } -result 1

test groupcall-unknown-initiator-refused {a muji session-initiate from a stranger is not found} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_session_initiate x-sid $CAROL $ROOM]
        list [gc_error_condition [gc_written_id si1]] \
            [llength [c.calls list]]
    } -result {item-not-found 0}

test groupcall-initiate-for-room-not-joined-refused {a muji session-initiate for a call we are not in is not found} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_session_initiate x-sid $BOB $ROOM]
        gc_error_condition [gc_written_id si1]
    } -result item-not-found

test groupcall-one-leg-per-peer {a second session-initiate from a connected peer is refused} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_session_initiate bob-sid $BOB $ROOM]
        c.conn clear
        c.conn feed [gc_session_initiate bob-sid2 $BOB $ROOM]
        list [gc_error_condition [gc_written_id si1]] \
            [llength [c.calls list]]
    } -result {item-not-found 1}

test groupcall-preparing-peer-cannot-initiate {a peer that has not announced contents is refused} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence bob -jid $BOB -preparing 1]
        c.conn feed [gc_session_initiate bob-sid $BOB $ROOM]
        gc_error_condition [gc_written_id si1]
    } -result item-not-found

# -- Peers leaving --------------------------------------------------------------

test groupcall-peer-drops-muji {a peer clearing <muji> has its leg hung up} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set sid [gc_sid_of bob]
        c.conn clear
        c.conn feed [gc_presence bob -jid $BOB]
        lassign [gc_jingle_written] to jingle
        string map [list $sid SID] [list $to [xsearch $jingle -get @action] \
            [llength [c.calls list]] \
            [lsearch -inline [gc_events] {<PeerLeft>*}] \
            [c.groupcall status -jid $ROOM]]
    } -result [list $BOB session-terminate 0 \
        [list <PeerLeft> -jid $ROOM -nick bob -peer $BOB -sid SID -reason "left the call"] \
        {active 0 joined 1 count 0 mode mesh}]

test groupcall-peer-leaves-room {a peer leaving the room has its leg hung up} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence bob -jid $BOB -type unavailable]
        list [llength [c.calls list]] \
            [llength [lsearch -all -inline [gc_events] {<PeerLeft>*}]]
    } -result {0 1}

test groupcall-leg-ending-reports-peer {a leg the peer terminated is reported left, and the participant stays} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set sid [gc_sid_of bob]
        c.conn feed [j iq -type set -from $BOB -to user@test.example.com/res -id t1 {
            j jingle -ns urn:xmpp:jingle:1 -action session-terminate -sid $sid {
                j reason { j success }
            }
        }]
        string map [list $sid SID] [list [lsearch -inline [gc_events] {<PeerLeft>*}] \
            [dict get [lindex [c.groupcall participants -jid $ROOM] 0] state]]
    } -result [list [list <PeerLeft> -jid $ROOM -nick bob -peer $BOB -sid SID -reason "session ended"] expected]

test groupcall-refused-initiate-warns {a peer refusing our session is reported, with the likely cause} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set sid [gc_sid_of bob]
        gc_answer_extdisco
        mockmedia::drive localDescription [gc_pc_of $sid] [gc_offer_sdp] offer
        set id ""
        foreach w [c.conn get_written] {
            if {[xsearch $w jingle -ns urn:xmpp:jingle:1 -get @action] eq "session-initiate"} {
                set id [xsearch $w -get @id]
            }
        }
        # What a peer that does not see us in the call answers.
        c.conn feed [j iq -type error -from $BOB -to user@test.example.com/res -id $id {
            j error -type cancel {
                j item-not-found -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        string map [list $sid SID] [list \
            [lsearch -inline [gc_events] {<PeerLeft>*}] \
            [lsearch -inline [gc_events] {<Warning>*}] \
            [dict get [c.groupcall status -jid $ROOM] joined]]
    } -result [list \
        [list <PeerLeft> -jid $ROOM -nick bob -peer $BOB -sid SID -reason "session-initiate rejected"] \
        [list <Warning> -jid $ROOM -reason "bob does not see you in the call; is another device of yours in this room as me?"] \
        1]

# -- Leaving ---------------------------------------------------------------------

test groupcall-leave {leave clears our presence before hanging up, and reports it} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn clear
        c.groupcall leave -jid $ROOM
        set tags {}
        foreach w [c.conn get_written] {
            if {[dict get $w tag] eq "presence"} {
                lappend tags [expr {[xsearch $w muji -get node] eq "" ? "presence-clear" : "presence-muji"}]
            } elseif {[xsearch $w jingle -get node] ne ""} {
                lappend tags [xsearch $w jingle -get @action]
            }
        }
        list $tags [lindex [gc_event_names] end] [llength [c.calls list]] \
            [c.groupcall list]
    } -result {{presence-clear session-terminate} <Left> 0 {}}

test groupcall-own-clear-echo-leaves {our muji-less echo from another device of ours ends the call} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence me -self 1 -jid user@test.example.com/res]
        list [lindex [gc_event_names] end-1] [c.groupcall list]
    } -result {<Left> {}}

test groupcall-room-left-ends-call {being put out of the room ends the call} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c.conn feed [gc_presence me -self 1 -jid user@test.example.com/res -type unavailable]
        list [expr {"<Left>" in [gc_event_names]}] [llength [c.calls list]] \
            [c.groupcall status -jid $ROOM]
    } -result {1 0 {active 0 joined 0 count 0 mode mesh}}

test groupcall-backend-failure-leaves {a backend that cannot name its payload types ends the join} \
    {*}$groupcall_env -body {
        gc_room
        mockmedia::fail PayloadTypes "no payload types"
        c.groupcall join -jid $ROOM
        c.conn clear
        gc_echo_preparing
        list [gc_muji_written] [lsearch -inline [gc_events] {<Left>*}] \
            [c.groupcall status -jid $ROOM]
    } -result [list {} \
        [list <Left> -jid $ROOM -reason "media backend failed: no payload types" -chat $ROOM] \
        {active 0 joined 0 count 0 mode mesh}]

test groupcall-shared-nick-gives-up {another session of ours holding the nick ends the join} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        c.conn clear
        # The room shows our other device's presence under the nick.
        c.conn feed [gc_presence me -self 1 -jid user@test.example.com/phone]
        list [gc_muji_written] [lindex [lsearch -inline [gc_events] {<Left>*}] 0] \
            [string match "*user@test.example.com/phone*" \
                [dict get [lrange [lsearch -inline [gc_events] {<Left>*}] 1 end] -reason]] \
            [c.groupcall status -jid $ROOM]
    } -result {{} <Left> 1 {active 0 joined 0 count 0 mode mesh}}

test groupcall-echo-timeout-gives-up {a <preparing/> the room never echoes ends the join} \
    {*}$groupcall_env -body {
        set ::taco_groupcall::ECHO_TIMEOUT_MS 50
        gc_room
        c.groupcall join -jid $ROOM
        after 100 { set ::_waited 1 }
        vwait ::_waited
        list [lsearch -inline [gc_events] {<Left>*}] [c.groupcall status -jid $ROOM]
    } -result [list [list <Left> -jid $ROOM -reason "the room never showed our call presence" -chat $ROOM] \
        {active 0 joined 0 count 0 mode mesh}]

test groupcall-echo-arrives-in-time {the echo timer does not fire once the room has echoed} \
    {*}$groupcall_env -body {
        set ::taco_groupcall::ECHO_TIMEOUT_MS 50
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        after 100 { set ::_waited 1 }
        vwait ::_waited
        list [expr {"<Left>" in [gc_event_names]}] [c.groupcall status -jid $ROOM]
    } -result {0 {active 0 joined 1 count 0 mode mesh}}

test groupcall-fresh-stream-ends-call {a reconnect that could not resume ends the call we were in} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c bus publish <Ready>
        list [lsearch -inline [gc_events] {<Left>*}] [c.groupcall list] \
            [dict get [c.groupcall status -jid $ROOM] joined]
    } -result [list [list <Left> -jid $ROOM -reason disconnected -chat $ROOM] {} 0]

test groupcall-disconnect-while-preparing {losing the stream mid-join reports the join over} \
    {*}$groupcall_env -body {
        gc_room [gc_presence carol -jid $CAROL -preparing 1]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        c bus publish <Disconnect>
        list [lsearch -inline [gc_events] {<Left>*}] [c.groupcall list]
    } -result [list [list <Left> -jid $ROOM -reason disconnected] {}]

# -- Hosted calls: a room of their own ----------------------------------------------

test groupcall-start-hosted {start makes a room of the call's own, lets the chat in, and invites it} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        set call [gc_start_hosted]
        # What was submitted to configure the room.
        set submitted {}
        foreach w [gc_written_to $call] {
            xsearch $w query x -ns jabber:x:data field -script f {
                dict set submitted [xsearch $f -get @var] [xsearch $f value -get body]
            }
        }
        set affil ""
        foreach w [gc_written_to $call] {
            set item [xsearch $w query -ns http://jabber.org/protocol/muc#admin item -get node]
            if {$item ne ""} { lappend affil [xsearch $item -get @jid] [xsearch $item -get @affiliation] }
        }
        lassign [gc_invite_sent $ROOM invite] type id invite
        list [jid domain $call] [c muc isHidden -jid $call] \
            [dict get $submitted muc#roomconfig_membersonly] \
            [dict get $submitted muc#roomconfig_whois] \
            $affil $type [regexp {^[0-9a-f]{32}$} $id] \
            [expr {[xsearch $invite muji -ns $NS_MUJI -get @room] eq $call}] \
            [xsearch $invite -get @multi] \
            [expr {[xsearch [gc_muji_written] preparing -get node] ne ""}] \
            [string map [list $call CALL] [lsearch -inline [gc_events] {<Started>*}]]
    } -result [list muc.example.com 1 1 anyone {bob@example.com owner} groupchat 1 1 true 1 \
        [list <Started> -jid CALL -chat $ROOM]]

test groupcall-start-falls-back-to-own-service {a chat service that will not have us: our server's} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall start -chat $ROOM
        set first [jid bare [gc_last_join]]
        c.conn feed [j presence -type error -from [gc_last_join] {
            j error -type auth { j forbidden -ns urn:ietf:params:xml:ns:xmpp-stanzas }
        }]
        set items [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $items -get @id] -from test.example.com {
            j query -ns http://jabber.org/protocol/disco#items {
                j item -jid conference.test.example.com
            }
        }]
        set info [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $info -get @id] -from conference.test.example.com {
            j query -ns http://jabber.org/protocol/disco#info {
                j identity -category conference -type text
            }
        }]
        list [jid domain $first] [jid domain [gc_last_join]]
    } -result {muc.example.com conference.test.example.com}

test groupcall-start-fails-without-service {no room anywhere: <StartFailed>, nothing left behind} \
    {*}$groupcall_env -body {
        c.groupcall start -chat bob@example.com
        set items [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $items -get @id] -from test.example.com {
            j query -ns http://jabber.org/protocol/disco#items {}
        }]
        list [lsearch -inline [gc_events] {<StartFailed>*}] [c.groupcall list]
    } -result [list [list <StartFailed> -chat bob@example.com \
        -reason "no group chat service to hold the call"] {}]

test groupcall-start-offline {starting a call with no session up fails at once, saying so} \
    {*}$groupcall_env -body {
        c iq live 0
        c.conn clear
        c.groupcall start -chat bob@example.com
        update
        list [lsearch -inline [gc_events] {<StartFailed>*}] [llength [c.conn get_written]]
    } -result [list [list <StartFailed> -chat bob@example.com -reason "not connected"] 0]

test groupcall-hosted-join-offline {joining a hosted call with no session up ends the join, saying so} \
    {*}$groupcall_env -body {
        c iq live 0
        c.groupcall join -jid call@muc.example.com -chat bob@example.com
        update
        list [lsearch -inline [gc_events] {<Left>*}] [c.groupcall list]
    } -result [list [list <Left> -jid call@muc.example.com -reason "not connected" \
        -chat bob@example.com] {}]

test groupcall-hosted-join {joining a hosted call: hidden, a nick of our own, and the chat told} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid call@muc.example.com -chat $ROOM?join -id inv42
        set to [gc_last_join]
        c.conn feed [gc_presence [jid resource $to] -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res]
        lassign [gc_invite_sent $ROOM accept] type id
        list [c muc isHidden -jid call@muc.example.com] $type $id \
            [expr {[xsearch [gc_muji_written] preparing -get node] ne ""}]
    } -result {1 groupchat inv42 1}

test groupcall-hosted-join-not-member {a hosted call we are not let into ends the join, saying why} \
    {*}$groupcall_env -body {
        c.groupcall join -jid call@muc.example.com
        c.conn feed [j presence -type error -from [gc_last_join] {
            j error -type auth { j registration-required -ns urn:ietf:params:xml:ns:xmpp-stanzas }
        }]
        list [lsearch -inline [gc_events] {<Left>*}] [c.groupcall list]
    } -result [list [list <Left> -jid call@muc.example.com \
        -reason "you are not on this call's guest list"] {}]

test groupcall-hosted-join-ended {a call whose room is gone: the fresh room is left, the call has ended} \
    {*}$groupcall_env -body {
        c.groupcall join -jid call@muc.example.com
        set to [gc_last_join]
        c.conn feed [gc_presence [jid resource $to] -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res -role moderator -affiliation owner -codes 201]
        set last [lindex [gc_written_to call@muc.example.com] end]
        list [xsearch $last -get @type] [lsearch -inline [gc_events] {<Left>*}]
    } -result [list unavailable [list <Left> -jid call@muc.example.com -reason "the call has ended"]]

test groupcall-hosted-leave-alone-retracts {leaving a call of ours nobody came to takes the invite back} \
    {*}$groupcall_env -body {
        gc_room
        set call [gc_start_hosted]
        lassign [gc_invite_sent $ROOM invite] - id
        c.groupcall leave -jid $call
        lassign [gc_invite_sent $ROOM retract] type rid
        set last [lindex [gc_written_to $call] end]
        list $type [expr {$rid eq $id}] [xsearch $last -get @type] [c.groupcall list]
    } -result {groupchat 1 unavailable {}}

test groupcall-hosted-leave-after-company {leaving once someone came says left, not retract} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid call@muc.example.com -chat $ROOM -id inv42
        set nick [jid resource [gc_last_join]]
        c.conn feed [gc_presence bob -room call@muc.example.com -jid $BOB \
            -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_presence $nick -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res]
        c.conn feed [gc_presence $nick -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res -preparing 1]
        c.groupcall leave -jid call@muc.example.com
        list [lindex [gc_invite_sent $ROOM left] 1] [gc_invite_sent $ROOM retract]
    } -result {inv42 {}}

test groupcall-hosted-admits-late-arrival {someone entering the chat mid-call is let into its room} \
    {*}$groupcall_env -body {
        gc_room
        set call [gc_start_hosted]
        c.conn feed [gc_presence carol -jid $CAROL]
        set affil ""
        foreach w [gc_written_to $call] {
            set item [xsearch $w query -ns http://jabber.org/protocol/muc#admin item -get node]
            if {$item ne ""} { lappend affil [xsearch $item -get @jid] }
        }
        set affil
    } -result {carol@example.com}

test groupcall-in-room-shared-nick-any-item {a nick shared with another device is caught whichever item comes first} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        # Our own JID listed first, the other device's second.
        c.conn feed [j presence -from $ROOM/me {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role participant -affiliation member -jid user@test.example.com/res
                j item -role participant -affiliation member -jid user@test.example.com/phone
                j status -code 110
            }
        }]
        string match "another device of yours (user@test.example.com/phone)*" \
            [dict get [lrange [lsearch -inline [gc_events] {<Left>*}] 1 end] -reason]
    } -result 1

# -- Watching a call we are not in -----------------------------------------------

test groupcall-tracks-call-in-room {a call in progress is seen from the occupants' presences} \
    {*}$groupcall_env -body {
        gc_room
        c.conn feed [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_presence carol -jid $CAROL -preparing 1]
        list [gc_events] [c.groupcall status -jid $ROOM] \
            [lsort [lmap p [c.groupcall participants -jid $ROOM] {
                list [dict get $p nick] [dict get $p preparing] [dict get $p audio] [dict get $p state]}]]
    } -result [list [list [list <Changed> -jid $ROOM -active 1 -count 1 -joined 0 -chat $ROOM] \
                          [list <Changed> -jid $ROOM -active 1 -count 1 -joined 0 -chat $ROOM]] \
        {active 1 joined 0 count 1 mode mesh} \
        {{bob 0 1 none} {carol 1 0 none}}]

test groupcall-call-ending-in-room {the last participant leaving clears the room's call} \
    {*}$groupcall_env -body {
        gc_room
        c.conn feed [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_presence bob -jid $BOB]
        list [lindex [gc_events] end] [c.groupcall status -jid $ROOM]
    } -result [list [list <Changed> -jid $ROOM -active 0 -count 0 -joined 0 -chat $ROOM] \
        {active 0 joined 0 count 0 mode mesh}]

# -- Invites (XEP-0482) ------------------------------------------------------------

test groupcall-invite-sends {invite writes a call-invites message naming the room, with the id Dino needs} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        c.groupcall invite -jid $ROOM -to $BOB
        set m [lindex [c.conn get_written] end]
        set inv [xsearch $m invite -ns urn:xmpp:call-invites:0 -get node]
        list [xsearch $m -get @to] [xsearch $m -get @type] \
            [regexp {^[0-9a-f]{32}$} [xsearch $inv -get @id]] \
            [xsearch $inv -get @video] [xsearch $inv -get @multi] \
            [xsearch $inv muji -ns $NS_MUJI -get @room]
    } -result [list bob@example.com chat 1 true true $ROOM]

# A call invite (XEP-0482) as a stanza: -type chat from a contact, or
# groupchat from a room occupant; -delay stamps it as history.
proc gc_call_invite {from type args} {
    array set opts [list -room call@muc.example.com -id inv1 -video false -delay ""]
    array set opts $args
    set to user@test.example.com/res
    j message -from $from -to $to -type $type -id m-$opts(-id) {
        j invite -ns urn:xmpp:call-invites:0 -id $opts(-id) -video $opts(-video) -multi true {
            j muji -ns urn:xmpp:jingle:muji:0 -room $opts(-room)
        }
        if {$opts(-delay) ne ""} {
            j delay -ns urn:xmpp:delay -from [gc_delay_from $from $type] -stamp $opts(-delay)
        }
    }
}

# Who stamps a delayed message: the room for its history, our server for
# what it kept while we were offline.
proc gc_delay_from {from type} {
    if {$type eq "groupchat"} { return [jid bare $from] }
    return test.example.com
}

# -delay stamps it, so tests can say which answer happened first.
proc gc_call_answer {from type tag id args} {
    array set opts {-delay ""}
    array set opts $args
    j message -from $from -to user@test.example.com/res -type $type {
        j $tag -ns urn:xmpp:call-invites:0 -id $id
        if {$opts(-delay) ne ""} {
            j delay -ns urn:xmpp:delay -from [gc_delay_from $from $type] -stamp $opts(-delay)
        }
    }
}

# The call rows stored in $chat, oldest first, as {timestamp content}.
proc gc_call_rows {chat} {
    set out {}
    foreach m [dict get [c message messagestore get latest $chat] messages] {
        if {[dict exists $m content] && [dict get $m content type] eq "call"} {
            lappend out [list [dict get $m timestamp] [dict get $m content]]
        }
    }
    return $out
}

proc gc_call_state {chat} {
    dict get [lindex [gc_call_rows $chat] end 1] state
}

test groupcall-invite-stored {a contact's call invite is kept in their chat, pending, and rings} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat -video true]
        lassign [lindex [gc_call_rows bob@example.com] 0] ts content
        set inv [lsearch -inline [gc_events] {<Invited>*}]
        list [dict get $content room] [dict get $content id] [dict get $content inviter] \
            [dict get $content video] [dict get $content state] [dict get $content active] \
            [dict get $content body] \
            [expr {[dict get [lrange $inv 1 end] -timestamp] == $ts}] \
            [dict get [lrange $inv 1 end] -chat] [dict get [lrange $inv 1 end] -jid]
    } -result {call@muc.example.com inv1 bob@example.com 1 pending 0 {Group video call} 1 bob@example.com call@muc.example.com}

test groupcall-invite-own-carbon-no-ring {our own invite, from another device of ours, does not ring} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite user@test.example.com/other chat]
        gc_events
    } -result {}

test groupcall-invite-answers-not-messages {accept, reject, retract and left are not stored as messages} \
    {*}$groupcall_env -body {
        foreach tag {accept reject retract left} {
            c.conn feed [gc_call_answer $BOB chat $tag nosuch]
        }
        list [dict get [c message messagestore get latest bob@example.com] messages] [gc_events]
    } -result {{} {}}

test groupcall-invite-retracted-missed {the inviter taking a pending invite back: a missed call} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat]
        set ::_emitted {}
        c.conn feed [gc_call_answer $BOB chat retract inv1]
        set edited [llength [lsearch -all -index 1 $::_emitted <Edited>]]
        list [gc_call_state bob@example.com] $edited
    } -result {missed 1}

test groupcall-room-invite-dino-shaped {an invite posted to a room: in its chat, with the inviter's real JID} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        lassign [lindex [gc_call_rows $ROOM?join] 0] ts content
        set inv [lrange [lsearch -inline [gc_events] {<Invited>*}] 1 end]
        list [dict get $content inviter] [dict get $content state] \
            [dict get $inv -chat] [dict get $inv -from]
    } -result [list bob@example.com pending $ROOM?join bob@example.com]

test groupcall-room-invite-history-no-ring {an invite the room replays as history is kept but does not ring} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -delay 2026-01-01T10:00:00Z]
        list [llength [gc_call_rows $ROOM?join]] [lsearch -inline [gc_events] {<Invited>*}]
    } -result {1 {}}

test groupcall-room-invite-other-device-accepted {another device of ours accepting in the room: answered elsewhere} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        # Under our nick, from the room: one of ours, not this device.
        c.conn feed [gc_call_answer $ROOM/me groupchat accept inv1]
        gc_call_state $ROOM?join
    } -result elsewhere

test groupcall-join-from-invite {answering the stored invite: its room, the chat told, the row joined} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv9]
        set ts [lindex [gc_call_rows $ROOM?join] 0 0]
        c.groupcall join -chat $ROOM?join -timestamp $ts
        set to [gc_last_join]
        c.conn feed [gc_presence [jid resource $to] -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res]
        # Our <accept> echoing back is no news about our answer.
        c.conn feed [gc_call_answer $ROOM/me groupchat accept inv9]
        list [jid bare $to] [lindex [gc_invite_sent $ROOM accept] 1] [gc_call_state $ROOM?join]
    } -result {call@muc.example.com inv9 joined}

test groupcall-decline-invite {declining the stored invite: the chat hears reject, the row says declined} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat -id inv7]
        set ts [lindex [gc_call_rows bob@example.com] 0 0]
        c.groupcall decline -chat bob@example.com -timestamp $ts
        list [lrange [gc_invite_sent bob@example.com reject] 0 1] [gc_call_state bob@example.com]
    } -result {{chat inv7} declined}

test groupcall-own-invite-echo-joined {our own call's invite, echoed by the room, is a call we are in} \
    {*}$groupcall_env -body {
        gc_room
        set call [gc_start_hosted]
        lassign [gc_invite_sent $ROOM invite] - id
        c.conn feed [gc_call_invite $ROOM/me groupchat -room $call -id $id]
        list [gc_call_state $ROOM?join] [lsearch -inline [gc_events] {<Invited>*}] \
            [expr {[c message messagestore get latest $ROOM?join] ne ""}]
    } -result {joined {} 1}

test groupcall-join-from-invite-ended {answering an invite to a call that is over: the row says ended} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat]
        set ts [lindex [gc_call_rows bob@example.com] 0 0]
        c.groupcall join -chat bob@example.com -timestamp $ts
        c.conn feed [gc_presence [jid resource [gc_last_join]] -room call@muc.example.com \
            -self 1 -jid user@test.example.com/res -role moderator -affiliation owner -codes 201]
        gc_call_state bob@example.com
    } -result ended

test groupcall-call-row-active {a call row reads active while we are in its call} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat -room call@muc.example.com]
        set ts [lindex [gc_call_rows bob@example.com] 0 0]
        c.groupcall join -chat bob@example.com -timestamp $ts
        set nick [jid resource [gc_last_join]]
        c.conn feed [gc_presence $nick -room call@muc.example.com -self 1 -jid user@test.example.com/res]
        c.conn feed [gc_presence $nick -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res -preparing 1]
        set during [dict get [lindex [gc_call_rows bob@example.com] 0 1] active]
        c.groupcall leave -jid call@muc.example.com
        list $during [dict get [lindex [gc_call_rows bob@example.com] 0 1] active]
    } -result {1 0}

# -- Helpers for hosted calls with company -----------------------------------------

# Finish entering the hosted call whose room we just asked to join: the
# occupants already there ($peers, presences), our own presence, the echo
# of our <preparing/>. Returns our nick in the call's room.
proc gc_in_hosted {call {peers {}}} {
    set nick [jid resource [gc_last_join]]
    foreach p $peers { c.conn feed $p }
    c.conn feed [gc_presence $nick -room $call -self 1 -jid user@test.example.com/res]
    c.conn feed [gc_presence $nick -room $call -self 1 \
        -jid user@test.example.com/res -preparing 1]
    return $nick
}

# The echo of our <preparing/> in a call we started (gc_start_hosted).
proc gc_started_echo {call} {
    set nick [jid resource [gc_last_join]]
    c.conn feed [gc_presence $nick -room $call -self 1 \
        -jid user@test.example.com/res -role moderator -affiliation owner -preparing 1]
}

# $nick ($full) arriving in the call's room announcing audio, then calling us.
proc gc_late_peer {call nick full sid} {
    c.conn feed [gc_presence $nick -room $call -jid $full \
        -contents [list audio [list $::OPUS_111]]]
    c.conn feed [gc_session_initiate $sid $full $call]
}

# A leg's peer terminating it, with a Jingle reason.
proc gc_terminate {sid from {reason success}} {
    c.conn feed [j iq -type set -from $from -to user@test.example.com/res -id t-$sid {
        j jingle -ns urn:xmpp:jingle:1 -action session-terminate -sid $sid {
            j reason { j $reason }
        }
    }]
}

proc gc_event_args {name} {
    set out {}
    foreach e [gc_events] {
        if {[lindex $e 0] eq $name} { lappend out [lrange $e 1 end] }
    }
    return $out
}

proc gc_nicks_left {} {
    lmap e [gc_event_args <PeerLeft>] { dict get $e -nick }
}

# -- The self-view ----------------------------------------------------------------

test groupcall-preview-video-join {a video call holds a preview of its own, named in <VideoPreview>} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        set pv [lindex [gc_event_args <VideoPreview>] 0]
        list [llength [mockmedia::calls OpenPreview]] [dict get $pv -jid] \
            [string match /tmp/tv-mock*.sock [dict get $pv -name]] \
            [expr {[dict get [lindex [c.groupcall list] 0] preview] eq [list name [dict get $pv -name]]}]
    } -result [list 1 $ROOM 1 1]

test groupcall-preview-audio-join-none {an audio call opens no camera} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        list [mockmedia::calls OpenPreview] [gc_event_args <VideoPreview>]
    } -result {{} {}}

test groupcall-preview-leave-closes {leaving closes the preview we opened} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        c.groupcall leave -jid $ROOM
        list [expr {[mockmedia::calls ClosePreview] eq [list [lindex [mockmedia::calls OpenPreview] 0 0]]}] \
            [llength [mockmedia::calls ClosePreview]]
    } -result {1 1}

test groupcall-preview-outlives-peers {the preview stays while peers leave, in either order, until we do} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111] video [list $VP8_96]]] \
            [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111] video [list $VP8_96]]]
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        set legs [llength [gc_event_args <PeerJoined>]]
        c.conn feed [gc_presence carol -jid $CAROL -type unavailable]
        set afterCarol [llength [mockmedia::calls ClosePreview]]
        c.conn feed [gc_presence bob -jid $BOB]
        set alone [list [llength [mockmedia::calls ClosePreview]] \
            [dict get [c.groupcall status -jid $ROOM] joined]]
        c.groupcall leave -jid $ROOM
        list $legs $afterCarol $alone [llength [mockmedia::calls ClosePreview]] \
            [llength [mockmedia::calls OpenPreview]] [lsort [gc_nicks_left]]
    } -result {2 0 {0 1} 1 1 {bob carol}}

test groupcall-preview-camera-switch {a new preferred camera reaches the self-view while we are alone} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        c.groupcall applyPreferredCamera -id cam2
        list [expr {[lindex [mockmedia::calls SetVideoDevice] 0 0] eq [lindex [mockmedia::calls OpenPreview] 0 0]}] \
            [lrange [lindex [mockmedia::calls SetVideoDevice] 0] 1 end]
    } -result {1 {-id cam2}}

test groupcall-preview-give-up-closes {a join given up closes its preview} \
    {*}$groupcall_env -body {
        set ::taco_groupcall::ECHO_TIMEOUT_MS 20
        gc_room
        c.groupcall join -jid $ROOM -video 1
        after 60 {set ::gc_wait 1}; vwait ::gc_wait
        list [llength [mockmedia::calls OpenPreview]] [llength [mockmedia::calls ClosePreview]] \
            [llength [gc_event_args <Left>]]
    } -result {1 1 1}

test groupcall-preview-disconnect-closes {losing the stream closes the preview} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        c bus publish <Disconnect>
        list [llength [mockmedia::calls ClosePreview]] [c.groupcall list]
    } -result {1 {}}

test groupcall-preview-without-capability {a backend with no preview leaves the self-view to the legs} \
    {*}$groupcall_env -body {
        ::tacky::media close
        mockmedia::capabilities {
            audioDevices 1 audioVolume 1 cameras 1 videoDevice 1 videoChannel 1
            autoAnswer 1 sdpSanitize 1 trickleIce 1
        }
        ::tacky::media open mock
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        list [mockmedia::calls OpenPreview] [gc_event_args <VideoPreview>] \
            [dict get [c.groupcall status -jid $ROOM] joined]
    } -result {{} {} 1}

test groupcall-preview-no-camera-joins-anyway {a camera that will not open warns, and the call goes on} \
    {*}$groupcall_env -body {
        mockmedia::fail OpenPreview "no camera could be opened"
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        list [gc_event_args <Warning>] [dict get [c.groupcall status -jid $ROOM] joined] \
            [dict get [lindex [c.groupcall list] 0] preview]
    } -result [list [list [list -jid $ROOM -reason "camera: no camera could be opened"]] 1 {}]

test groupcall-preview-lost-mid-call {a preview the backend loses is closed once, and the call goes on} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        gc_echo_preparing
        set name [lindex [mockmedia::calls OpenPreview] 0 0]
        ::tacky::media::emit $name error op openPreview reason "camera unplugged" fatal 1
        set warned [gc_event_args <Warning>]
        c.groupcall leave -jid $ROOM
        list $warned [llength [mockmedia::calls ClosePreview]]
    } -result [list [list [list -jid $ROOM -reason "camera: camera unplugged"]] 1]

test groupcall-preview-fallback-warns {a preferred camera that is gone warns, the preview still comes} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        set name [lindex [mockmedia::calls OpenPreview] 0 0]
        ::tacky::media::emit $name deviceFallback kind camera id cam9 reason gone
        list [gc_event_args <Warning>] [llength [gc_event_args <VideoPreview>]]
    } -result [list [list [list -jid $ROOM -reason "camera device unavailable, using default"]] 1]

test groupcall-preview-per-call {two calls at once hold two previews, each closed with its call} \
    {*}$groupcall_env -body {
        gc_room
        c.groupcall join -jid $ROOM -video 1
        c.groupcall join -jid call@muc.example.com -video 1
        gc_in_hosted call@muc.example.com
        set names [lmap c [mockmedia::calls OpenPreview] {lindex $c 0}]
        c.groupcall leave -jid $ROOM
        set closed [lmap c [mockmedia::calls ClosePreview] {lindex $c 0}]
        list [llength [lsort -unique $names]] [expr {$closed eq [lrange $names 0 0]}]
    } -result {2 1}

# -- Whether a call is still going, as its room says -----------------------------------

# The disco#info requests we wrote to $room, oldest first.
proc gc_disco_asks {room} {
    set out {}
    foreach w [gc_written_to $room] {
        if {[dict get $w tag] ne "iq"} continue
        if {[xsearch $w query -ns http://jabber.org/protocol/disco#info -get node] ne ""} {
            lappend out $w
        }
    }
    return $out
}

# Answer the last disco#info we asked $room: `there`, or an error condition.
proc gc_answer_room {room answer} {
    set ask [lindex [gc_disco_asks $room] end]
    if {$ask eq ""} { error "no disco#info asked of $room" }
    set id [xsearch $ask -get @id]
    if {$answer eq "there"} {
        c.conn feed [j iq -type result -from $room -to user@test.example.com/res -id $id {
            j query -ns http://jabber.org/protocol/disco#info {
                j identity -category conference -type text
                j feature -var http://jabber.org/protocol/muc
            }
        }]
    } else {
        c.conn feed [j iq -type error -from $room -to user@test.example.com/res -id $id {
            j error -type cancel { j $answer -ns urn:ietf:params:xml:ns:xmpp-stanzas }
        }]
    }
}

proc gc_live {chat} {
    set content [lindex [gc_call_rows $chat] end 1]
    expr {[dict exists $content live] ? [dict get $content live] : "?"}
}

test groupcall-live-asks-the-room {a call invite arriving asks its room; until it answers, nobody knows} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        list [gc_live $ROOM?join] [llength [gc_disco_asks call@muc.example.com]]
    } -result {? 1}

test groupcall-live-room-there {the room answering: the call is live, and its row is re-sent once} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_live $ROOM?join
        set ::_emitted {}
        gc_answer_room call@muc.example.com there
        list [gc_live $ROOM?join] [llength [lsearch -all -index 1 $::_emitted <Edited>]] \
            [llength [gc_disco_asks call@muc.example.com]]
    } -result {1 1 1}

test groupcall-live-room-gone {the room gone: the call is over} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_answer_room call@muc.example.com item-not-found
        list [gc_live $ROOM?join] [gc_call_state $ROOM?join]
    } -result {0 pending}

test groupcall-live-room-unsure {an answer that says neither is not kept: the room is asked again} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_answer_room call@muc.example.com remote-server-timeout
        set first [gc_live $ROOM?join]
        list $first [llength [gc_disco_asks call@muc.example.com]]
    } -result {? 2}

test groupcall-live-asked-once {reading the row again while the room has not answered asks once} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_live $ROOM?join
        gc_live $ROOM?join
        gc_answer_room call@muc.example.com there
        gc_live $ROOM?join
        llength [gc_disco_asks call@muc.example.com]
    } -result 1

test groupcall-live-only-newest {only a chat's newest call is asked about; an older one reads as over} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv1 -room one@muc.example.com]
        c.conn feed [gc_call_invite $ROOM/carol groupchat -id inv2 -room two@muc.example.com]
        set before [llength [gc_disco_asks one@muc.example.com]]
        gc_answer_room two@muc.example.com there
        list [lmap callRow [gc_call_rows $ROOM?join] {dict get [lindex $callRow 1] live}] \
            [expr {[llength [gc_disco_asks one@muc.example.com]] == $before}]
    } -result {{0 1} 1}

foreach tag {accept left retract} {
    test groupcall-live-$tag-asks-again "someone's $tag: the room is asked again" \
        {*}$groupcall_env -body [string map [list @TAG@ $tag] {
            gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
            c.conn feed [gc_call_invite $ROOM/bob groupchat]
            gc_answer_room call@muc.example.com there
            c.conn feed [gc_call_answer $ROOM/carol groupchat @TAG@ inv1]
            gc_answer_room call@muc.example.com item-not-found
            list [llength [gc_disco_asks call@muc.example.com]] [gc_live $ROOM?join]
        }] -result {2 0}
}

test groupcall-live-reject-asks-nothing {someone declining is no news about the room} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_answer_room call@muc.example.com there
        c.conn feed [gc_call_answer $ROOM/carol groupchat reject inv1]
        gc_live $ROOM?join
        list [llength [gc_disco_asks call@muc.example.com]] [gc_live $ROOM?join]
    } -result {1 1}

test groupcall-live-while-in {a call we are in is live without asking; leaving asks again} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv5]
        gc_answer_room call@muc.example.com there
        c.groupcall join -chat $ROOM?join -timestamp [lindex [gc_call_rows $ROOM?join] 0 0]
        gc_in_hosted call@muc.example.com
        set asks [llength [gc_disco_asks call@muc.example.com]]
        set during [gc_live $ROOM?join]
        c.groupcall leave -jid call@muc.example.com
        list $during [expr {[llength [gc_disco_asks call@muc.example.com]] - $asks}]
    } -result {1 1}

test groupcall-live-found-gone-joining {a join finding the room gone makes the call over without asking} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_answer_room call@muc.example.com there
        c.groupcall join -chat $ROOM?join -timestamp [lindex [gc_call_rows $ROOM?join] 0 0]
        c.conn feed [gc_presence [jid resource [gc_last_join]] -room call@muc.example.com \
            -self 1 -jid user@test.example.com/res -role moderator -affiliation owner -codes 201]
        list [gc_live $ROOM?join] [gc_call_state $ROOM?join] \
            [llength [gc_disco_asks call@muc.example.com]]
    } -result {0 ended 1}

test groupcall-live-forgotten-on-reconnect {a fresh stream forgets what rooms said} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        gc_answer_room call@muc.example.com there
        c bus publish <Ready>
        list [gc_live $ROOM?join] [llength [gc_disco_asks call@muc.example.com]]
    } -result {? 2}

test groupcall-live-own-call {our own call's invite echoing back: live, since we are in it} \
    {*}$groupcall_env -body {
        gc_room
        set call [gc_start_hosted]
        gc_started_echo $call
        lassign [gc_invite_sent $ROOM invite] - id
        c.conn feed [gc_call_invite $ROOM/me groupchat -room $call -id $id]
        list [gc_live $ROOM?join] [llength [gc_disco_asks $call]]
    } -result {1 0}

# -- Starting a call where one is going: joining it --------------------------------

test groupcall-start-joins-live-call {start with the chat's newest call's room there joins it, no new room} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv3 -room call@muc.example.com]
        c.groupcall start -chat $ROOM?join -video 1
        gc_answer_room call@muc.example.com there
        set to [gc_last_join]
        gc_in_hosted call@muc.example.com [list [gc_presence bob -room call@muc.example.com \
            -jid $BOB -contents [list audio [list $OPUS_111]]]]
        list [jid bare $to] [lindex [gc_invite_sent $ROOM accept] 1] \
            [gc_invite_sent $ROOM invite] [gc_event_args <Started>] \
            [gc_call_state $ROOM?join] [llength [mockmedia::calls OpenPreview]] \
            [dict get [lindex [c.groupcall list] 0] jid]
    } -result {call@muc.example.com inv3 {} {} joined 1 call@muc.example.com}

test groupcall-start-waits-for-the-room {start waits on the room's answer, sharing a question already asked} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -room call@muc.example.com]
        c.groupcall start -chat $ROOM?join
        set waiting [list [gc_last_join] [llength [gc_disco_asks call@muc.example.com]]]
        gc_answer_room call@muc.example.com there
        list {*}$waiting [jid bare [gc_last_join]]
    } -result {{} 1 call@muc.example.com}

test groupcall-start-after-call-over {start with the newest call's room gone makes a new call} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -room old@muc.example.com]
        c.groupcall start -chat $ROOM?join
        gc_answer_room old@muc.example.com item-not-found
        set to [gc_last_join]
        set call [jid bare $to]
        c.conn feed [gc_presence [jid resource $to] -room $call -self 1 \
            -jid user@test.example.com/res -role moderator -affiliation owner -codes 201]
        gc_owner_reply $call [gc_owner_form]
        gc_owner_reply $call ""
        list [expr {$call ne "old@muc.example.com"}] [llength [gc_event_args <Started>]] \
            [lindex [gc_invite_sent $ROOM invite] 0]
    } -result {1 1 groupchat}

test groupcall-start-room-unsure {a room answer that says neither: start makes a new call} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -room old@muc.example.com]
        c.groupcall start -chat $ROOM?join
        gc_answer_room old@muc.example.com service-unavailable
        expr {[jid bare [gc_last_join]] ne "old@muc.example.com"}
    } -result 1

test groupcall-start-no-call-yet {a chat with no call: start makes one without asking anyone} \
    {*}$groupcall_env -body {
        gc_room
        set call [gc_start_hosted]
        list [llength [gc_event_args <Started>]] [llength [gc_disco_asks $call]]
    } -result {1 0}

test groupcall-rejoin-after-leaving {left a call others are still in: start goes back into it} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv4]
        c.groupcall join -chat $ROOM?join -timestamp [lindex [gc_call_rows $ROOM?join] 0 0]
        gc_in_hosted call@muc.example.com
        set nick [jid resource [gc_last_join]]
        c.groupcall leave -jid call@muc.example.com
        c.conn feed [gc_presence $nick -room call@muc.example.com -self 1 \
            -jid user@test.example.com/res -type unavailable]
        # The question asked before we left is stale: the room is asked again.
        gc_answer_room call@muc.example.com there
        gc_answer_room call@muc.example.com there
        set out [list [gc_live $ROOM?join] [c.groupcall list]]
        c.conn clear
        c.groupcall start -chat $ROOM?join
        gc_answer_room call@muc.example.com there
        gc_in_hosted call@muc.example.com
        list {*}$out [jid bare [gc_last_join]] [dict get [lindex [c.groupcall list] 0] jid] \
            [lindex [gc_invite_sent $ROOM accept] 1]
    } -result {1 {} call@muc.example.com call@muc.example.com inv4}

test groupcall-start-live-in-contact-chat {a call going in a 1:1 chat is joined by start too} \
    {*}$groupcall_env -body {
        c.conn feed [gc_call_invite $BOB chat -id inv6 -room call@muc.example.com]
        c.groupcall start -chat bob@example.com
        gc_answer_room call@muc.example.com there
        gc_in_hosted call@muc.example.com
        list [jid bare [gc_last_join]] [lrange [gc_invite_sent bob@example.com accept] 0 1]
    } -result {call@muc.example.com {chat inv6}}

# -- Three in a call: orders, and one of them failing ----------------------------------

set DAVE dave@example.com/laptop

# We start a call; bob and carol arrive in that order and call us.
proc gc_hosted_three {} {
    gc_room [gc_presence bob -jid $::BOB] [gc_presence carol -jid $::CAROL]
    set call [gc_start_hosted]
    gc_started_echo $call
    gc_late_peer $call bob $::BOB sid-bob
    gc_late_peer $call carol $::CAROL sid-carol
    return $call
}

# Answer every XEP-0215 request written so far, each leg its own.
proc gc_answer_every_extdisco {} {
    foreach w [c.conn get_written] {
        if {[dict get $w tag] ne "iq"} continue
        set child [lindex [dict get $w children] 0]
        if {$child eq "" || [dict get $child tag] ne "services"} continue
        c.conn feed [j iq -type result -from test.example.com \
            -to user@test.example.com -id [xsearch $w -get @id] {
            j services -ns urn:xmpp:extdisco:2
        }]
    }
}

proc gc_leg_sids {} {
    lsort [lmap l [c.calls list] {dict get $l sid}]
}

test groupcall-three-late-arrivals {two peers arriving after us each get their leg} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        list [gc_leg_sids] [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}] \
            [dict get [c.groupcall status -jid $call] count]
    } -result {{sid-bob sid-carol} {bob carol} 2}

test groupcall-three-arrive-reversed {the same, carol first: the order of arrival does not matter} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
        set call [gc_start_hosted]
        gc_started_echo $call
        gc_late_peer $call carol $CAROL sid-carol
        gc_late_peer $call bob $BOB sid-bob
        list [gc_leg_sids] [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}]
    } -result {{sid-bob sid-carol} {carol bob}}

test groupcall-three-joiner-calls-both {joining with two already in: we call both, one leg each} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]] \
            [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        list [llength [gc_leg_sids]] [lsort [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}]]
    } -result {2 {bob carol}}

foreach {order first second} {forward bob carol reverse carol bob} {
    test groupcall-three-leave-$order "peers leaving $first then $second: we stay in, alone" \
        {*}$groupcall_env -body [string map [list @1 $first @2 $second] {
            set call [gc_hosted_three]
            set full [dict create bob $BOB carol $CAROL]
            c.conn feed [gc_presence @1 -room $call -jid [dict get $full @1] -type unavailable]
            set one [list [dict get [c.groupcall status -jid $call] count] [gc_leg_sids]]
            c.conn feed [gc_presence @2 -room $call -jid [dict get $full @2] -type unavailable]
            list $one [dict get [c.groupcall status -jid $call] count] [gc_leg_sids] \
                [dict get [c.groupcall status -jid $call] joined] [gc_nicks_left] \
                [llength [mockmedia::calls ClosePreview]]
        }] -result [list [list 1 [list sid-$second]] 0 {} 1 [list $first $second] 0]
}

test groupcall-three-we-leave-first {leaving with two still in hangs both legs up and says left} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        lassign [gc_invite_sent $ROOM invite] - id
        c.conn clear
        c.groupcall leave -jid $call
        set terminated {}
        foreach w [c.conn get_written] {
            if {[xsearch $w jingle -ns urn:xmpp:jingle:1 -get @action] eq "session-terminate"} {
                lappend terminated [xsearch $w -get @to]
            }
        }
        list [lsort $terminated] [expr {[lindex [gc_invite_sent $ROOM left] 1] eq $id}] \
            [gc_invite_sent $ROOM retract] [c.calls list]
    } -result [list [lsort [list $BOB $CAROL]] 1 {} {}]

test groupcall-three-one-leg-fails {one leg failing: that peer is reported gone, the other leg and the call go on} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        gc_terminate sid-bob $BOB connectivity-error
        set left [lindex [gc_event_args <PeerLeft>] 0]
        list [dict get $left -nick] [gc_leg_sids] \
            [dict get [c.groupcall status -jid $call] joined] \
            [lsort [lmap p [c.groupcall participants -jid $call] {
                if {[dict get $p state] eq "none"} continue
                list [dict get $p nick] [dict get $p state]
            }]] \
            [llength [mockmedia::calls ClosePreview]]
    } -result {bob sid-carol 1 {{bob expected} {carol new}} 0}

test groupcall-three-one-refuses {joining two, one refusing our session: the other leg goes on} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]] \
            [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set bobSid [gc_sid_of bob]
        set carolSid [gc_sid_of carol]
        gc_answer_every_extdisco
        foreach sid [list $bobSid $carolSid] {
            mockmedia::drive localDescription [gc_pc_of $sid] [gc_offer_sdp] offer
        }
        foreach w [c.conn get_written] {
            if {[xsearch $w jingle -ns urn:xmpp:jingle:1 -get @action] eq "session-initiate"
                    && [xsearch $w -get @to] eq $BOB} {
                set id [xsearch $w -get @id]
            }
        }
        c.conn feed [j iq -type error -from $BOB -to user@test.example.com/res -id $id {
            j error -type cancel { j item-not-found -ns urn:ietf:params:xml:ns:xmpp-stanzas }
        }]
        list [gc_nicks_left] [expr {[gc_leg_sids] eq [list $carolSid]}] \
            [dict get [c.groupcall status -jid $ROOM] joined]
    } -result {bob 1 1}

test groupcall-three-one-stuck-preparing {one of two stuck preparing: the other is called, the laggard calls us later} \
    {*}$groupcall_env -body {
        set ::taco_groupcall::PREPARE_TIMEOUT_MS 20
        gc_room [gc_presence bob -jid $BOB -contents [list audio [list $OPUS_111]]] \
            [gc_presence carol -jid $CAROL -preparing 1]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        set waiting [expr {"<Joined>" in [gc_event_names]}]
        after 60 {set ::gc_wait 1}; vwait ::gc_wait
        set called [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}]
        c.conn feed [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111]]]
        c.conn feed [gc_session_initiate sid-carol $CAROL $ROOM]
        list $waiting $called [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}]
    } -result {0 bob {bob carol}}

test groupcall-three-one-hidden {one of two hiding their JID: a warning for them, a leg to the other} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -contents [list audio [list $OPUS_111]]] \
            [gc_presence carol -jid $CAROL -contents [list audio [list $OPUS_111]]]
        c.groupcall join -jid $ROOM
        gc_echo_preparing
        list [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}] \
            [llength [gc_event_args <Warning>]] [llength [gc_leg_sids]]
    } -result {carol 1 1}

test groupcall-three-peer-comes-back {a peer leaving and coming back gets a fresh leg} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        c.conn feed [gc_presence bob -room $call -jid $BOB -type unavailable]
        gc_late_peer $call bob $BOB sid-bob2
        list [gc_leg_sids] [lmap e [gc_event_args <PeerJoined>] {dict get $e -nick}]
    } -result {{sid-bob2 sid-carol} {bob carol bob}}

test groupcall-three-fourth-arrives {a fourth arriving while one of three already left} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        c.conn feed [gc_presence carol -room $call -jid $CAROL -type unavailable]
        gc_late_peer $call dave $DAVE sid-dave
        list [gc_leg_sids] [dict get [c.groupcall status -jid $call] count]
    } -result {{sid-bob sid-dave} 2}

test groupcall-three-both-legs-fail {every leg failing leaves us in the call, alone, not out of it} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        gc_terminate sid-bob $BOB connectivity-error
        gc_terminate sid-carol $CAROL failed-transport
        list [lsort [gc_nicks_left]] [gc_leg_sids] \
            [dict get [c.groupcall status -jid $call] joined] [gc_event_args <Left>]
    } -result {{bob carol} {} 1 {}}

test groupcall-three-disconnect-mid-call {losing our stream with two in ends our call and our legs} \
    {*}$groupcall_env -body {
        set call [gc_hosted_three]
        c bus publish <Disconnect>
        list [dict get [lindex [gc_event_args <Left>] 0] -reason] [c.groupcall list] \
            [llength [mockmedia::calls ClosePreview]]
    } -result {disconnected {} 0}

test groupcall-preview-names-chat {a hosted call's self-view names the chat it belongs to} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -id inv8]
        c.groupcall join -chat $ROOM?join -timestamp [lindex [gc_call_rows $ROOM?join] 0 0] -video 1
        gc_in_hosted call@muc.example.com
        set pv [lindex [gc_event_args <VideoPreview>] 0]
        list [dict get $pv -jid] [dict get $pv -chat]
    } -result [list call@muc.example.com $ROOM]

test groupcall-live-stale-answer {an answer to a question asked before someone left is asked again} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB] [gc_presence carol -jid $CAROL]
        c.conn feed [gc_call_invite $ROOM/bob groupchat]
        c.conn feed [gc_call_answer $ROOM/carol groupchat accept inv1]
        c.conn feed [gc_call_answer $ROOM/bob groupchat left inv1]
        # The first question was asked with everyone still in; its answer is old.
        set first [lindex [gc_disco_asks call@muc.example.com] 0]
        c.conn feed [j iq -type result -from call@muc.example.com \
            -to user@test.example.com/res -id [xsearch $first -get @id] {
            j query -ns http://jabber.org/protocol/disco#info
        }]
        set afterStale [gc_live $ROOM?join]
        gc_answer_room call@muc.example.com item-not-found
        list $afterStale [gc_live $ROOM?join]
    } -result {? 0}

test groupcall-start-stale-answer-waits {start waits past a stale answer for the fresh one} \
    {*}$groupcall_env -body {
        gc_room [gc_presence bob -jid $BOB]
        c.conn feed [gc_call_invite $ROOM/bob groupchat -room old@muc.example.com]
        c.groupcall start -chat $ROOM?join
        c.conn feed [gc_call_answer $ROOM/bob groupchat left inv1]
        set first [lindex [gc_disco_asks old@muc.example.com] 0]
        c.conn feed [j iq -type result -from old@muc.example.com \
            -to user@test.example.com/res -id [xsearch $first -get @id] {
            j query -ns http://jabber.org/protocol/disco#info
        }]
        set waiting [gc_last_join]
        gc_answer_room old@muc.example.com item-not-found
        list $waiting [expr {[jid bare [gc_last_join]] ni {"" old@muc.example.com}}]
    } -result {{} 1}
