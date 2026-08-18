# Unit tests for the media half of taco_calls: the ::rtc callbacks, the SDP
# that goes out on them, and teardown. Runs against tacky::mockrtc, so no
# peer connection or audio device is involved.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers
package require tacky::mockrtc

set media_env [tacky_env -mock conn -capture-emit 1 -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky
} -bound-jid user@test.example.com/res -extra-setup {mockrtc::reset}]

set MEDIA_PEER peer@example.com/phone

# libdatachannel hands us an offer carrying header extensions and
# transport-cc feedback that rtc-ma does not honour on the wire.
set MEDIA_OFFER_SDP "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=extmap:1 urn:ietf:params:rtp-hdrext:sdes:mid\r\na=extmap-allow-mixed\r\na=rtcp-fb:111 transport-cc\r\na=ice-ufrag:abc\r\na=ice-pwd:xyzxyzxyzxyz\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"

mockrtc::install

# -- Helpers --

proc media_pc {sid} {
    return [dict get [dict get [calls_state] $sid] pc]
}

proc media_session_initiate {sid from} {
    j iq -type set -from $from -to user@test.example.com -id si1 {
        j jingle -ns urn:xmpp:jingle:1 -action session-initiate -sid $sid {
            j content -creator initiator -name audio -senders both {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                    j payload-type -id 0 -name PCMU -clockrate 8000
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

proc media_transport_info {sid from} {
    j iq -type set -from $from -to user@test.example.com -id ti1 {
        j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
            j content -creator initiator -name audio {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 {
                    j candidate -foundation 7 -component 1 -protocol udp \
                        -priority 2122260223 -ip 192.0.2.7 -port 7777 -type host
                }
            }
        }
    }
}

# Answer the XEP-0215 request the module makes before standing up a pc.
proc media_answer_extdisco {} {
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

# Caller with a live pc: propose, peer proceeds, ICE servers come back.
proc media_caller {} {
    set sid [c.calls start -to peer@example.com]
    c.conn feed [calls_jmi_in proceed $sid $::MEDIA_PEER]
    media_answer_extdisco
    c.conn clear
    return $sid
}

# Callee with a live pc: peer proposes, we accept, their offer lands.
proc media_callee {sid} {
    c.conn feed [calls_jmi_in propose $sid $::MEDIA_PEER]
    c.calls accept -sid $sid
    c.conn feed [media_session_initiate $sid $::MEDIA_PEER]
    media_answer_extdisco
    c.conn clear
}

proc media_jingle_sent {} {
    return [xsearch [calls_last_written] jingle -ns urn:xmpp:jingle:1 -get node]
}

# -- Offer and answer --

test media-offer-becomes-session-initiate {a local offer ships as session-initiate} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] local-description $::MEDIA_OFFER_SDP offer
        set jingle [media_jingle_sent]
        string map [list $sid SID] [list \
            [xsearch $jingle -get @action] \
            [xsearch $jingle -get @sid] \
            [xsearch $jingle -get @initiator] \
            [xsearch $jingle content description \
                -ns urn:xmpp:jingle:apps:rtp:1 -get @media]]
    } -result {session-initiate SID user@test.example.com/res audio}

test media-offer-strips-unhonoured-attrs {extmap and transport-cc never reach the peer} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] local-description $::MEDIA_OFFER_SDP offer
        set desc [xsearch [media_jingle_sent] content description \
            -ns urn:xmpp:jingle:apps:rtp:1 -get node]
        list \
            [llength [xsearch $desc rtp-hdrext -gather node]] \
            [llength [xsearch $desc rtcp-fb -gather node]] \
            [llength [xsearch $desc payload-type -gather node]]
    } -result {0 0 1}

test media-answer-becomes-session-accept {a local answer ships as session-accept} \
    {*}$media_env -body {
        media_callee tk-m1
        mockrtc::fire [media_pc tk-m1] local-description $::MEDIA_OFFER_SDP answer
        set jingle [media_jingle_sent]
        list \
            [xsearch $jingle -get @action] \
            [xsearch $jingle -get @sid] \
            [xsearch $jingle -get @responder] \
            [xsearch $jingle -get @initiator]
    } -result {session-accept tk-m1 user@test.example.com/res {}}

# -- Trickled candidates --

test media-candidate-trickles-as-transport-info {a local candidate goes out as transport-info} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] local-candidate \
            "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host" ""
        set jingle [media_jingle_sent]
        set cand [xsearch $jingle content transport candidate -get node]
        string map [list $sid SID] [list \
            [xsearch $jingle -get @action] \
            [xsearch $jingle -get @sid] \
            [xsearch $jingle -get @initiator] \
            [xsearch $jingle content -get @name] \
            [xsearch $cand -get @ip] \
            [xsearch $cand -get @port] \
            [xsearch $cand -get @type]]
    } -result {transport-info SID user@test.example.com/res audio 192.0.2.1 54321 host}

test media-candidate-uses-responder-attr {the callee stamps responder, not initiator} \
    {*}$media_env -body {
        media_callee tk-m2
        mockrtc::fire [media_pc tk-m2] local-candidate \
            "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host" audio
        set jingle [media_jingle_sent]
        list \
            [xsearch $jingle -get @responder] \
            [xsearch $jingle -get @initiator]
    } -result {user@test.example.com/res {}}

test media-candidate-unusable-is-not-sent {a candidate we cannot parse is dropped} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] local-candidate "candidate:1 1 udp" ""
        c.conn get_written
    } -result {}

# -- Connection state --

test media-connected-emits-active {a connected pc surfaces as <Active>} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] state-change connected
        string map [list $sid SID] [list \
            [lindex [calls_events] end] \
            [dict get [dict get [calls_state] $sid] state]]
    } -result {{<Active> -sid SID} active}

test media-list-active {a connected call is the one live state only media can reach} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] state-change connected
        dict get [lindex [c.calls list] 0] state
    } -result active

test media-list-peer-stays-bare {the full JID proceed latched does not leak into the list} \
    {*}$media_env -body {
        set sid [media_caller]
        list [dict get [dict get [calls_state] $sid] peer] \
            [dict get [lindex [c.calls list] 0] peer]
    } -result {peer@example.com/phone peer@example.com}

test media-failed-emits-failed {a failed pc surfaces as <Failed> and forgets the call} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] state-change failed
        string map [list $sid SID] [list \
            [lindex [calls_events] end] \
            [dict exists [calls_state] $sid]]
    } -result {{<Failed> -sid SID -reason {media path failed (ICE/DTLS)}} 0}

test media-closed-ends-call {a closed pc surfaces as <Ended> and forgets the call} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fire [media_pc $sid] state-change closed
        string map [list $sid SID] [list \
            [lindex [calls_events] end] \
            [dict exists [calls_state] $sid]]
    } -result {{<Ended> -sid SID} 0}

# -- Teardown --

test media-teardown-frees-rtcma-before-pc {audio handles are destroyed before the pc} \
    {*}$media_env -body {
        set sid [media_caller]
        c.calls hangup -sid $sid
        set capturer [mockrtc::first ::rtcma::capturer::destroy]
        set player   [mockrtc::first ::rtcma::player::destroy]
        set close    [mockrtc::first ::rtc::pc::close]
        set delete   [mockrtc::first ::rtc::pc::delete]
        list \
            [expr {$capturer >= 0 && $capturer < $close}] \
            [expr {$player   >= 0 && $player   < $close}] \
            [expr {$close < $delete}]
    } -result {1 1 1}

test media-teardown-clears-callbacks-first {queued callbacks are unhooked before close} \
    {*}$media_env -body {
        set sid [media_caller]
        set pc [media_pc $sid]
        c.calls hangup -sid $sid
        set cleared {}
        foreach entry [mockrtc::log] {
            if {[string match ::rtc::pc::on-* [lindex $entry 0]]
                    && [lindex $entry 2] eq ""} {
                lappend cleared [lindex $entry 0]
            }
        }
        list [llength $cleared] \
            [expr {[lsearch -exact $cleared ::rtc::pc::on-state-change] >= 0}] \
            [expr {[mockrtc::first ::rtc::pc::close] > 0}]
    } -result {5 1 1}

# -- Track attachment --

test media-track-attaches-once {a second on-track does not attach a second time} \
    {*}$media_env -body {
        media_callee tk-m3
        set pc [media_pc tk-m3]
        mockrtc::fire $pc track 555
        set afterFirst [llength [mockrtc::calls ::rtcma::capturer::new]]
        mockrtc::fire $pc track 556
        list $afterFirst [llength [mockrtc::calls ::rtcma::capturer::new]] \
            [dict get [dict get [calls_state] tk-m3] track]
    } -result {1 1 555}

test media-input-device-falls-back {an unusable mic warns and falls back to the default} \
    {*}$media_env -body {
        mockrtc::fail ::rtcma::capturer::new "device gone" "-device-id *"
        set sid [media_caller]
        string map [list $sid SID] [list \
            [llength [mockrtc::calls ::rtcma::capturer::new]] \
            [lindex [calls_events] end]]
    } -result {2 {<Warning> -sid SID -reason {input device unavailable, using default}}}

# -- Buffered candidates --

test media-pending-candidates-drain {candidates buffered before the pc are applied in order} \
    {*}$media_env -body {
        c.conn feed [calls_jmi_in propose tk-m4 $::MEDIA_PEER]
        c.calls accept -sid tk-m4
        c.conn feed [media_transport_info tk-m4 $::MEDIA_PEER]
        set buffered [llength [dict get [dict get [calls_state] tk-m4] \
            pending_remote_candidates]]
        c.conn feed [media_session_initiate tk-m4 $::MEDIA_PEER]
        media_answer_extdisco
        list $buffered \
            [mockrtc::calls ::rtc::pc::add-remote-candidate] \
            [dict exists [calls_state] tk-m4 pending_remote_candidates]
    } -result {1 {{101 {candidate:7 1 udp 2122260223 192.0.2.7 7777 typ host} audio}} 0}

# -- Device switching --

test media-setdevices-warns-on-failure {a mic that will not reopen warns and keeps the call} \
    {*}$media_env -body {
        set sid [media_caller]
        mockrtc::fail ::rtcma::capturer::reopen "busy"
        c.calls setDevices -sid $sid -input other
        string map [list $sid SID] [list \
            [lindex [calls_events] end] \
            [dict exists [calls_state] $sid]]
    } -result {{<Warning> -sid SID -reason {input device unavailable: busy}} 1}

mockrtc::uninstall
