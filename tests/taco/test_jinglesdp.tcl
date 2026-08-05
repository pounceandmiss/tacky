# Tests for jinglesdp module (Jingle <-> SDP conversion).
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

namespace eval jinglesdp_test {}

# Reset the candidate id counter so test results stay deterministic.
proc jinglesdp_test::reset {} {
    set ::jinglesdp::_candidateCounter 0
}

set NS_JINGLE       urn:xmpp:jingle:1
set NS_RTP          urn:xmpp:jingle:apps:rtp:1
set NS_DTLS         urn:xmpp:jingle:apps:dtls:0
set NS_GROUPING     urn:xmpp:jingle:apps:grouping:0
set NS_ICE_UDP      urn:xmpp:jingle:transports:ice-udp:1
set NS_RTP_HDREXT   urn:xmpp:jingle:apps:rtp:rtp-hdrext:0
set NS_RTP_FEEDBACK urn:xmpp:jingle:apps:rtp:rtcp-fb:0
set NS_RTP_SSMA     urn:xmpp:jingle:apps:rtp:ssma:0

proc jinglesdp_test::lines {s} {
    set out {}
    foreach line [split $s "\n"] {
        set line [string trimright $line "\r"]
        if {$line ne ""} { lappend out $line }
    }
    return $out
}

# --- to_sdp tests ---------------------------------------------------------

test jinglesdp-to_sdp-minimal-audio "minimal audio: payload-types + ICE + fingerprint -> SDP" -body {
    jinglesdp_test::reset
    set jingle [j jingle -ns $NS_JINGLE {
        j content -ns $NS_JINGLE -creator initiator -name audio -senders both {
            j description -ns $NS_RTP -media audio {
                j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                j payload-type -id 0 -name PCMU -clockrate 8000
            }
            j transport -ns $NS_ICE_UDP -ufrag abc -pwd xyz {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup actpass #body AA:BB:CC
            }
        }
    }]
    set sdp [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp]
    list \
        [lindex $ls 0] \
        [expr {"a=msid-semantic: WMS my-media-stream" in $ls}] \
        [expr {"m=audio 9 UDP/TLS/RTP/SAVPF 111 0" in $ls}] \
        [expr {"c=IN IP4 0.0.0.0" in $ls}] \
        [expr {"a=rtpmap:111 opus/48000/2" in $ls}] \
        [expr {"a=rtpmap:0 PCMU/8000" in $ls}] \
        [expr {"a=ice-ufrag:abc" in $ls}] \
        [expr {"a=ice-pwd:xyz" in $ls}] \
        [expr {"a=fingerprint:sha-256 AA:BB:CC" in $ls}] \
        [expr {"a=setup:actpass" in $ls}] \
        [expr {"a=mid:audio" in $ls}] \
        [expr {"a=sendrecv" in $ls}]
} -result {v=0 1 1 1 1 1 1 1 1 1 1 1}

test jinglesdp-to_sdp-fmtp-and-rtcp-fb "payload parameters and rtcp-fb attach to right payload" -body {
    jinglesdp_test::reset
    set jingle [j jingle -ns $NS_JINGLE {
        j content -ns $NS_JINGLE -creator initiator -name video {
            j description -ns $NS_RTP -media video {
                j payload-type -id 96 -name VP8 -clockrate 90000 {
                    j parameter -ns $NS_RTP -name max-fr -value 60
                    j rtcp-fb -ns $NS_RTP_FEEDBACK -type nack
                    j rtcp-fb -ns $NS_RTP_FEEDBACK -type nack -subtype pli
                }
                j payload-type -id 97 -name rtx -clockrate 90000 {
                    j parameter -ns $NS_RTP -name apt -value 96
                    j parameter -ns $NS_RTP -name rtx-time -value 3000
                }
                j rtcp-fb -ns $NS_RTP_FEEDBACK -type goog-remb
            }
            j transport -ns $NS_ICE_UDP -ufrag abc -pwd xyz {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup actpass #body AA
            }
        }
    }]
    set sdp [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp]
    list \
        [expr {"a=fmtp:96 max-fr=60" in $ls}] \
        [expr {"a=fmtp:97 apt=96;rtx-time=3000" in $ls}] \
        [expr {"a=rtcp-fb:96 nack" in $ls}] \
        [expr {"a=rtcp-fb:96 nack pli" in $ls}] \
        [expr {"a=rtcp-fb:* goog-remb" in $ls}]
} -result {1 1 1 1 1}

test jinglesdp-to_sdp-candidates "ICE candidates -> a=candidate" -body {
    jinglesdp_test::reset
    set jingle [j jingle -ns $NS_JINGLE {
        j content -ns $NS_JINGLE -creator initiator -name audio {
            j description -ns $NS_RTP -media audio {
                j payload-type -id 0 -name PCMU -clockrate 8000
            }
            j transport -ns $NS_ICE_UDP -ufrag abc -pwd xyz {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup actpass #body AA
                j candidate -foundation 1 -component 1 -protocol udp \
                    -priority 2122260223 -ip 192.0.2.1 -port 54321 -type host -generation 0
                j candidate -foundation 2 -component 1 -protocol udp \
                    -priority 1686052607 -ip 198.51.100.1 -port 56789 \
                    -type srflx -rel-addr 10.0.0.1 -rel-port 54321 -generation 0
            }
        }
    }]
    set sdp [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp]
    list \
        [expr {"a=candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host generation 0" in $ls}] \
        [expr {"a=candidate:2 1 udp 1686052607 198.51.100.1 56789 typ srflx raddr 10.0.0.1 rport 54321 generation 0" in $ls}]
} -result {1 1}

test jinglesdp-to_sdp-bundle-and-extmap "BUNDLE group and extmap" -body {
    jinglesdp_test::reset
    set jingle [j jingle -ns $NS_JINGLE {
        j group -ns $NS_GROUPING -semantics BUNDLE {
            j content -ns $NS_GROUPING -name audio
            j content -ns $NS_GROUPING -name video
        }
        j content -ns $NS_JINGLE -creator initiator -name audio {
            j description -ns $NS_RTP -media audio {
                j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                j rtp-hdrext -ns $NS_RTP_HDREXT -id 1 -uri urn:ietf:params:rtp-hdrext:ssrc-audio-level
                j extmap-allow-mixed -ns $NS_RTP_HDREXT
                j rtcp-mux -ns $NS_RTP
            }
            j transport -ns $NS_ICE_UDP -ufrag a -pwd b {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup actpass #body AA
            }
        }
    }]
    set sdp [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp]
    list \
        [expr {"a=group:BUNDLE audio video" in $ls}] \
        [expr {"a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level" in $ls}] \
        [expr {"a=extmap-allow-mixed" in $ls}] \
        [expr {"a=rtcp-mux" in $ls}]
} -result {1 1 1 1}

test jinglesdp-to_sdp-sources "ssrc and ssrc-group" -body {
    jinglesdp_test::reset
    set jingle [j jingle -ns $NS_JINGLE {
        j content -ns $NS_JINGLE -creator initiator -name video {
            j description -ns $NS_RTP -media video {
                j payload-type -id 96 -name VP8 -clockrate 90000
                j ssrc-group -ns $NS_RTP_SSMA -semantics FID {
                    j source -ns $NS_RTP_SSMA -ssrc 1111
                    j source -ns $NS_RTP_SSMA -ssrc 2222
                }
                j source -ns $NS_RTP_SSMA -ssrc 1111 {
                    j parameter -name cname -value alice
                    j parameter -name msid -value "stream-id track-id"
                }
            }
            j transport -ns $NS_ICE_UDP -ufrag a -pwd b {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup actpass #body AA
            }
        }
    }]
    set sdp [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp]
    list \
        [expr {"a=ssrc-group:FID 1111 2222" in $ls}] \
        [expr {"a=ssrc:1111 cname:alice" in $ls}] \
        [expr {"a=ssrc:1111 msid:stream-id track-id" in $ls}]
} -result {1 1 1}

test jinglesdp-to_sdp-senders "senders mapping respects initiator flag" -body {
    jinglesdp_test::reset
    set buildJingle [list apply {{senders} {
        j jingle -ns urn:xmpp:jingle:1 {
            j content -ns urn:xmpp:jingle:1 -creator initiator -name audio -senders $senders {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 0 -name PCMU -clockrate 8000
                }
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 -ufrag a -pwd b {
                    j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 -hash sha-256 -setup actpass #body AA
                }
            }
        }
    }}]
    set tests {}
    foreach {senders init expected} {
        both       1 sendrecv
        none       1 inactive
        initiator  1 sendonly
        initiator  0 recvonly
        responder  1 recvonly
        responder  0 sendonly
    } {
        set s [{*}$buildJingle $senders]
        set sdp [jinglesdp::to_sdp $s -initiator $init]
        lappend tests [expr {"a=$expected" in [jinglesdp_test::lines $sdp]}]
    }
    set tests
} -result {1 1 1 1 1 1}

# --- from_sdp tests ------------------------------------------------------

test jinglesdp-from_sdp-minimal "parses SDP into jingle with content/description/transport" -body {
    jinglesdp_test::reset
    set sdp "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=rtpmap:0 PCMU/8000\r\na=ice-ufrag:abc\r\na=ice-pwd:xyz\r\na=fingerprint:sha-256 AA:BB:CC\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\na=rtcp-mux\r\n"
    set jingle [jinglesdp::from_sdp $sdp]
    set content [xsearch $jingle content -get node]
    set description [xsearch $content description -ns $::NS_RTP -get node]
    set transport [xsearch $content transport -ns $::NS_ICE_UDP -get node]
    set pt0 [lindex [xsearch $description payload-type -gather node] 0]
    set fp [xsearch $transport fingerprint -ns $::NS_DTLS -get node]
    list \
        [dict get $jingle ns] \
        [xsearch $content -get @name] \
        [xsearch $content -get @creator] \
        [xsearch $pt0 -get @id] \
        [xsearch $pt0 -get @name] \
        [xsearch $pt0 -get @clockrate] \
        [xsearch $pt0 -get @channels] \
        [xsearch $transport -get @ufrag] \
        [xsearch $transport -get @pwd] \
        [xsearch $fp -get @hash] \
        [xsearch $fp -get @setup] \
        [xsearch $fp -get body] \
        [expr {[llength [xsearch $description rtcp-mux -ns $::NS_RTP]] > 0}]
} -result [list $NS_JINGLE audio initiator 111 opus 48000 2 abc xyz sha-256 actpass AA:BB:CC 1]

test jinglesdp-from_sdp-bundle "BUNDLE -> group element" -body {
    jinglesdp_test::reset
    set sdp "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio video\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\na=fingerprint:sha-256 AA\r\na=setup:actpass\r\na=mid:audio\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:96 VP8/90000\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\na=fingerprint:sha-256 AA\r\na=setup:actpass\r\na=mid:video\r\n"
    set jingle [jinglesdp::from_sdp $sdp]
    set group [xsearch $jingle group -ns $::NS_GROUPING -get node]
    set groupContents [xsearch $group content -gather @name]
    set jcontents [xsearch $jingle content -gather @name]
    list \
        [xsearch $group -get @semantics] \
        [llength $groupContents] \
        [lindex $groupContents 0] \
        [lindex $groupContents 1] \
        [llength $jcontents] \
        [lindex $jcontents 0] \
        [lindex $jcontents 1]
} -result {BUNDLE 2 audio video 2 audio video}

test jinglesdp-from_sdp-candidate "parses candidate line into <candidate> child" -body {
    jinglesdp_test::reset
    set sdp "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:0 PCMU/8000\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\na=fingerprint:sha-256 AA\r\na=setup:actpass\r\na=mid:audio\r\na=candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host generation 0\r\na=candidate:2 1 udp 1686052607 198.51.100.1 56789 typ srflx raddr 10.0.0.1 rport 54321 generation 0\r\n"
    set jingle [jinglesdp::from_sdp $sdp]
    set transport [xsearch $jingle content transport -ns $::NS_ICE_UDP -get node]
    set cands [xsearch $transport candidate -gather node]
    set c0 [lindex $cands 0]
    set c1 [lindex $cands 1]
    list \
        [llength $cands] \
        [xsearch $c0 -get @foundation] \
        [xsearch $c0 -get @protocol] \
        [xsearch $c0 -get @ip] \
        [xsearch $c0 -get @type] \
        [xsearch $c1 -get @type] \
        [xsearch $c1 -get @rel-addr] \
        [xsearch $c1 -get @rel-port]
} -result {2 1 udp 192.0.2.1 host srflx 10.0.0.1 54321}

test jinglesdp-from_sdp-fmtp-and-fb "fmtp + rtcp-fb attach to right payload-type" -body {
    jinglesdp_test::reset
    set sdp "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:96 VP8/90000\r\na=rtpmap:97 rtx/90000\r\na=fmtp:96 max-fr=60\r\na=fmtp:97 apt=96;rtx-time=3000\r\na=rtcp-fb:96 nack\r\na=rtcp-fb:96 nack pli\r\na=rtcp-fb:* goog-remb\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\na=fingerprint:sha-256 AA\r\na=setup:actpass\r\na=mid:video\r\n"
    set jingle [jinglesdp::from_sdp $sdp]
    set description [xsearch $jingle content description -ns $::NS_RTP -get node]
    set pts [xsearch $description payload-type -gather node]
    set descFbs [xsearch $description rtcp-fb -gather node]
    set pt96 [lindex $pts 0]
    set pt96Fbs [xsearch $pt96 rtcp-fb -gather node]
    set pt96Params [xsearch $pt96 parameter -gather node]
    set pt97 [lindex $pts 1]
    set pt97Params [xsearch $pt97 parameter -gather node]
    list \
        [llength $pts] \
        [llength $descFbs] \
        [xsearch [lindex $descFbs 0] -get @type] \
        [llength $pt96Fbs] \
        [xsearch [lindex $pt96Fbs 0] -get @type] \
        [xsearch [lindex $pt96Fbs 1] -get @subtype] \
        [llength $pt96Params] \
        [xsearch [lindex $pt96Params 0] -get @name] \
        [xsearch [lindex $pt96Params 0] -get @value] \
        [llength $pt97Params] \
        [xsearch [lindex $pt97Params 0] -get @name] \
        [xsearch [lindex $pt97Params 0] -get @value] \
        [xsearch [lindex $pt97Params 1] -get @name] \
        [xsearch [lindex $pt97Params 1] -get @value]
} -result {2 1 goog-remb 2 nack pli 1 max-fr 60 2 apt 96 rtx-time 3000}

test jinglesdp-from_sdp-senders "SDP direction -> content senders attr" -body {
    jinglesdp_test::reset
    set make [list apply {{direction} {
        return "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:0 PCMU/8000\r\na=ice-ufrag:a\r\na=ice-pwd:b\r\na=fingerprint:sha-256 AA\r\na=setup:actpass\r\na=mid:audio\r\na=$direction\r\n"
    }}]
    set results {}
    foreach {direction init expected} {
        sendrecv 1 ""
        inactive 1 none
        sendonly 1 initiator
        sendonly 0 responder
        recvonly 1 responder
        recvonly 0 initiator
    } {
        set sdp [{*}$make $direction]
        set jingle [jinglesdp::from_sdp $sdp -initiator $init]
        set content [xsearch $jingle content -get node]
        lappend results [xsearch $content -get @senders]
    }
    set results
} -result {{} none initiator responder responder initiator}

test jinglesdp-from_sdp-garbage "input with no media sections yields an empty jingle" -body {
    set jingle [jinglesdp::from_sdp "not an sdp at all\r\nrandom junk\r\n"]
    list [dict get $jingle tag] [llength [xsearch $jingle content -gather node]]
} -result {jingle 0}

# --- candidate helpers ---------------------------------------------------

test jinglesdp-BuildCandidate-incomplete "candidate value with fewer than six fields yields empty" -body {
    list \
        [jinglesdp::BuildCandidate ""] \
        [jinglesdp::BuildCandidate "1 1 udp 2122260223 192.0.2.1"]
} -result {{} {}}

test jinglesdp-CandidateToSdp-non-udp "non-udp candidate is rejected" -body {
    jinglesdp::CandidateToSdp [j candidate -foundation 1 -component 1 \
        -protocol tcp -priority 2122260223 -ip 192.0.2.1 -port 9 -type host]
} -returnCodes error -result {'tcp' is not a supported protocol}

test jinglesdp-CandidateToSdp-missing-field "candidate without a port is rejected" -body {
    jinglesdp::CandidateToSdp [j candidate -foundation 1 -component 1 \
        -protocol udp -priority 2122260223 -ip 192.0.2.1 -type host]
} -returnCodes error -result {candidate missing port}

# --- roundtrip -----------------------------------------------------------

test jinglesdp-roundtrip-audio "from_sdp -> to_sdp preserves key audio attributes" -body {
    jinglesdp_test::reset
    set sdp "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=rtpmap:0 PCMU/8000\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=rtcp-fb:111 transport-cc\r\na=ice-ufrag:abc\r\na=ice-pwd:xyz\r\na=fingerprint:sha-256 AA:BB:CC\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\na=rtcp-mux\r\na=candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host generation 0\r\n"
    set jingle [jinglesdp::from_sdp $sdp]
    set sdp2 [jinglesdp::to_sdp $jingle]
    set ls [jinglesdp_test::lines $sdp2]
    list \
        [expr {"v=0" in $ls}] \
        [expr {"m=audio 9 UDP/TLS/RTP/SAVPF 111 0" in $ls}] \
        [expr {"a=group:BUNDLE audio" in $ls}] \
        [expr {"a=rtpmap:111 opus/48000/2" in $ls}] \
        [expr {"a=rtpmap:0 PCMU/8000" in $ls}] \
        [expr {"a=fmtp:111 minptime=10;useinbandfec=1" in $ls}] \
        [expr {"a=rtcp-fb:111 transport-cc" in $ls}] \
        [expr {"a=ice-ufrag:abc" in $ls}] \
        [expr {"a=ice-pwd:xyz" in $ls}] \
        [expr {"a=fingerprint:sha-256 AA:BB:CC" in $ls}] \
        [expr {"a=setup:actpass" in $ls}] \
        [expr {"a=mid:audio" in $ls}] \
        [expr {"a=sendrecv" in $ls}] \
        [expr {"a=rtcp-mux" in $ls}] \
        [expr {"a=candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host generation 0" in $ls}]
} -result {1 1 1 1 1 1 1 1 1 1 1 1 1 1 1}

test jinglesdp-roundtrip-candidate "BuildCandidate -> CandidateToSdp preserves a trickled candidate" -body {
    jinglesdp_test::reset
    set value "1 1 udp 1686052607 198.51.100.1 56789 typ srflx raddr 10.0.0.1 rport 54321 generation 0"
    jinglesdp::CandidateToSdp [jinglesdp::BuildCandidate $value]
} -result {1 1 udp 1686052607 198.51.100.1 56789 typ srflx raddr 10.0.0.1 rport 54321 generation 0}
