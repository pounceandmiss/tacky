# Calls verified through OMEMO. We are a taco client with the real omemo
# module on a mock connection; the peer is a plain picomemo store
# (tacky::omemopeer), so both ends use real sessions. Media is
# tacky::mockrtc, so the SDP given to the backend can be checked.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers
package require tacky::omemopeer
if {[::tcltest::testConstraint wasm]} {
    puts "skipping [file tail [info script]]: no rtc in this build"
    return
}
package require tacky::mockrtc

namespace eval ::test::cv {
    variable ME      user@test.example.com
    variable PEER    peer@example.com/phone
    variable BARE    peer@example.com
    variable DEV     4242
    variable NS_JMI  urn:xmpp:jingle-message:0
    variable NS_VERIFY http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification
    variable NS_DTLS urn:xmpp:jingle:apps:dtls:0
    variable NS_AXOLOTL eu.siacs.conversations.axolotl
    # Our offer/answer as the backend writes it: AA:BB is our fingerprint.
    variable SDP "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:abc\r\na=ice-pwd:xyzxyzxyzxyz\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"
}

# We already have a session with the peer's device 4242, built from its
# bundle (as after an earlier chat).
set ::test::cv::env [tacky_env -mock conn -capture-emit 1 -taco-args {-media-backend rtc} -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky -db-path :memory:
} -bound-jid user@test.example.com/res -extra-setup {
    mockrtc::reset
    c omemo OnReady
    omemopeer::create romeo -device $::test::cv::DEV
    c omemo BuildSessionFromBundle $::test::cv::BARE $::test::cv::DEV \
        [omemopeer::bundle romeo]
} -extra-cleanup {
    omemopeer::destroy romeo
}]

# No session yet on either side; the peer starts one from our bundle.
set ::test::cv::fresh_env [tacky_env -mock conn -capture-emit 1 -taco-args {-media-backend rtc} -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
    -taco ::tacky -db-path :memory:
} -bound-jid user@test.example.com/res -extra-setup {
    mockrtc::reset
    c omemo OnReady
    omemopeer::create romeo -device $::test::cv::DEV
    omemopeer::learn romeo $::test::cv::ME [c omemo device_id] \
        [[set [c.omemo info vars store]] bundle]
} -extra-cleanup {
    omemopeer::destroy romeo
}]

mockrtc::install

# -- Helpers --

proc ::test::cv::myDevice {} { c omemo device_id }

proc ::test::cv::pc {sid} {
    ::tacky::media::rtc::pc-id [dict get [dict get [calls_state] $sid] pc]
}

# A JMI message from the peer, announcing its device unless $dev is "".
proc ::test::cv::jmi {action sid {dev 4242}} {
    variable NS_JMI
    variable NS_VERIFY
    j message -from $::test::cv::PEER -to $::test::cv::ME -type chat {
        j $action -ns $NS_JMI -id $sid {
            if {$action eq "propose"} {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio
            }
            if {$dev ne ""} { j device -ns $NS_VERIFY -id $dev }
        }
    }
}

# The device our last JMI $action announced, "" for none.
proc ::test::cv::announced {action} {
    variable NS_JMI
    variable NS_VERIFY
    set out ""
    foreach w [c.conn get_written] {
        set child [xsearch $w $action -ns $NS_JMI -get node]
        if {$child eq ""} continue
        set out [xsearch $child device -ns $NS_VERIFY -get @id]
    }
    return $out
}

# A <transport> whose fingerprint is $fp: {plain BODY}, {encrypted ENC},
# {both BODY ENC} or {none}.
proc ::test::cv::transport {ufrag fp} {
    variable NS_VERIFY
    variable NS_DTLS
    j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
        -ufrag $ufrag -pwd ${ufrag}pwdpwdpwd {
        switch -- [lindex $fp 0] {
            plain {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup active \
                    -body [lindex $fp 1]
            }
            encrypted {
                j fingerprint -ns $NS_VERIFY -hash sha-256 -setup active {
                    j #as-is [lindex $fp 1]
                }
            }
            both {
                j fingerprint -ns $NS_DTLS -hash sha-256 -setup active \
                    -body [lindex $fp 1]
                j fingerprint -ns $NS_VERIFY -hash sha-256 -setup active {
                    j #as-is [lindex $fp 2]
                }
            }
        }
    }
}

# The peer's session-initiate or -accept, one audio content per entry of
# $fps (as ::test::cv::transport takes them).
proc ::test::cv::jingle {action sid fps} {
    set i 0
    j iq -type set -from $::test::cv::PEER -to $::test::cv::ME -id j[incr ::test::cv::iqs] {
        j jingle -ns urn:xmpp:jingle:1 -action $action -sid $sid {
            foreach fp $fps {
                j content -creator initiator -name [expr {$i ? "audio$i" : "audio"}] {
                    j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                        j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                    }
                    j #as-is [::test::cv::transport u$i $fp]
                }
                incr i
            }
        }
    }
}
set ::test::cv::iqs 0

# The peer encrypts fingerprint $text for our device.
proc ::test::cv::peerEncrypts {text} {
    omemopeer::encrypt romeo $::test::cv::ME [myDevice] $text
}

# Answer the XEP-0215 request made before a pc goes up.
proc ::test::cv::answerExtdisco {} {
    foreach w [c.conn get_written] {
        if {[xsearch $w services -ns urn:xmpp:extdisco:2 -get node] ne ""} {
            set id [xsearch $w -get @id]
        }
    }
    c.conn feed [j iq -type result -from test.example.com -to $::test::cv::ME \
        -id $id { j services -ns urn:xmpp:extdisco:2 }]
}

# We call; the peer proceeds (announcing $dev); our pc is up. Returns sid.
proc ::test::cv::caller {{dev 4242}} {
    set sid [c.calls start -to $::test::cv::BARE]
    c.conn feed [jmi proceed $sid $dev]
    answerExtdisco
    return $sid
}

# ... then send our offer and have the peer read it, which also gives it
# a session with us. What it read is left in ::test::cv::ours.
proc ::test::cv::offered {{dev 4242}} {
    set sid [caller $dev]
    c.conn clear
    mockrtc::fire [pc $sid] local-description $::test::cv::SDP offer
    set initiate [sent session-initiate]
    set ::test::cv::ours [expr {$initiate eq "" ? "" : [readFingerprint $initiate]}]
    return $sid
}

# The last <jingle> we sent with $action.
proc ::test::cv::sent {action} {
    set out ""
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $jn -get @action] eq $action} { set out $jn }
    }
    return $out
}

# Our fingerprint as the peer reads it from $jingle: {plain BODY} or
# {encrypted RIDS TEXT}.
proc ::test::cv::readFingerprint {jingle} {
    variable NS_VERIFY
    variable NS_DTLS
    variable NS_AXOLOTL
    set transport [xsearch $jingle content transport -get node]
    set plain [xsearch $transport fingerprint -ns $NS_DTLS -get body]
    set efp [xsearch $transport fingerprint -ns $NS_VERIFY -get node]
    if {$efp eq ""} { return [list plain $plain] }
    set enc [xsearch $efp encrypted -ns $NS_AXOLOTL -get node]
    set rids [xsearch $enc header key -gather @rid]
    list encrypted $rids [omemopeer::open romeo $::test::cv::ME $enc] \
        plain_too [expr {$plain ne ""}]
}

# The fingerprint lines of the SDP last handed to the backend.
proc ::test::cv::remoteFingerprints {} {
    set calls [mockrtc::calls ::rtc::pc::set-remote-description]
    if {![llength $calls]} { return none }
    regexp -all -inline -line {^a=fingerprint:[^\r\n]*} [lindex $calls end 1]
}

proc ::test::cv::events {name} {
    lmap e [calls_events] {
        if {[lindex $e 0] ne $name} continue
        lrange $e 1 end
    }
}

# {last event, terminate reason, call still listed}.
proc ::test::cv::failedInsecure {sid} {
    set term [sent session-terminate]
    list [lindex [calls_events] end 0] \
        [xsearch $term reason * -get tag] \
        [dict exists [calls_state] $sid]
}

# -- Announcing our device --

test calls-verify-propose-announces-device \
    {a call we place announces our OMEMO device in the propose} \
    {*}$::test::cv::env -body {
        c.calls start -to $::test::cv::BARE
        expr {[::test::cv::announced propose] == [::test::cv::myDevice]}
    } -result 1

test calls-verify-proceed-announces-device \
    {accepting a call announces our OMEMO device in the proceed} \
    {*}$::test::cv::env -body {
        c.conn feed [::test::cv::jmi propose tk-v1]
        c.calls accept -sid tk-v1
        expr {[::test::cv::announced proceed] == [::test::cv::myDevice]}
    } -result 1

test calls-verify-nothing-announced-when-off \
    {with OMEMO off for the chat, neither propose nor proceed names a device} \
    {*}$::test::cv::env -body {
        c omemo setEnabled -jid $::test::cv::BARE -value 0
        c.calls hangup -sid [c.calls start -to $::test::cv::BARE]
        c.conn feed [::test::cv::jmi propose tk-v2]
        c.calls accept -sid tk-v2
        list [::test::cv::announced propose] [::test::cv::announced proceed]
    } -result {{} {}}

# -- Our fingerprint going out --

test calls-verify-initiate-encrypted-for-announced-device \
    {our offer's fingerprint goes out encrypted for the peer's announced device alone} \
    {*}$::test::cv::env -body {
        ::test::cv::offered
        set ::test::cv::ours
    } -result {encrypted 4242 AA:BB plain_too 0}

test calls-verify-plain-initiate-when-peer-announced-nothing \
    {a peer that announced no device gets our fingerprint plain} \
    {*}$::test::cv::env -body {
        ::test::cv::offered ""
        set ::test::cv::ours
    } -result {plain AA:BB}

test calls-verify-plain-initiate-when-off \
    {with OMEMO off for the chat our fingerprint goes plain, whatever the peer announced} \
    {*}$::test::cv::env -body {
        c omemo setEnabled -jid $::test::cv::BARE -value 0
        ::test::cv::offered
        set ::test::cv::ours
    } -result {plain AA:BB}

test calls-verify-candidates-wait-for-encrypted-initiate \
    {while our fingerprint waits on the peer's bundle, candidates are held, then follow the initiate} \
    {*}$::test::cv::env -body {
        # No session with device 7777: its bundle fetch starts on the
        # proceed and is still pending when our offer is ready.
        omemopeer::destroy romeo
        omemopeer::create romeo -device 7777
        set sid [::test::cv::caller 7777]
        set fetch ""
        foreach w [c.conn get_written] {
            if {[string match *bundles:7777 [xsearch $w pubsub items -get @node]]} {
                set fetch $w
            }
        }
        c.conn clear
        mockrtc::fire [::test::cv::pc $sid] local-description $::test::cv::SDP offer
        mockrtc::fire [::test::cv::pc $sid] local-candidate \
            "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host" ""
        set before [list [::test::cv::sent session-initiate] [::test::cv::sent transport-info]]
        c.conn feed [omemopeer::bundleReply romeo $fetch]
        set order [lmap w [c.conn get_written] {
            set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
            if {$jn eq ""} continue
            xsearch $jn -get @action
        }]
        list $before $order \
            [lrange [::test::cv::readFingerprint [::test::cv::sent session-initiate]] 0 2]
    } -result {{{} {}} {session-initiate transport-info} {encrypted 7777 AA:BB}}

test calls-verify-initiate-fails-without-session \
    {no session with the announced device in time: the call fails and nothing goes out plain} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::caller 7777]
        c.conn clear
        mockrtc::fire [::test::cv::pc $sid] local-description $::test::cv::SDP offer
        c omemo OnBundleFetchTimeout $::test::cv::BARE 7777
        list [::test::cv::sent session-initiate] [::test::cv::failedInsecure $sid]
    } -result {{} {<Failed> security-error 0}}

test calls-verify-untrusted-device-fails \
    {a peer device marked untrusted fails the call before anything is sent} \
    {*}$::test::cv::env -body {
        c omemo EnsureTrustRow $::test::cv::BARE $::test::cv::DEV \
            [::omemopeer::store_romeo identity_pub]
        c omemo trust -jid $::test::cv::BARE -device $::test::cv::DEV -state untrusted
        set sid [::test::cv::offered]
        list [::test::cv::sent session-initiate] [::test::cv::failedInsecure $sid]
    } -result {{} {<Failed> security-error 0}}

# -- The peer's fingerprint coming in --

test calls-verify-accept-authenticated \
    {an encrypted accept is authenticated by the peer's device: its fingerprint reaches the SDP, and under blind trust its undecided key verifies the call as it would a message} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid \
            [list [list encrypted [::test::cv::peerEncrypts CC:DD]]]]
        set v [lindex [::test::cv::events <Verified>] end]
        list [::test::cv::remoteFingerprints] \
            [dict get $v -verified] \
            [expr {[dict get $v -fingerprint] eq [omemopeer::fingerprint romeo]}] \
            [dict get [lindex [c.calls list] 0] verified]
    } -result {{{a=fingerprint:sha-256 CC:DD}} 1 1 1}

# -verified of the last <Verified>.
proc ::test::cv::lastVerified {} {
    dict get [lindex [events <Verified>] end] -verified
}

# An offered call the peer has answered encrypted.
proc ::test::cv::answered {} {
    set sid [offered]
    c.conn feed [jingle session-accept $sid \
        [list [list encrypted [peerEncrypts CC:DD]]]]
    return $sid
}

test calls-verify-trusted-device-verifies \
    {without blind trust an undecided key does not verify the call; trusting it mid-call does} \
    {*}$::test::cv::env -body {
        c omemo setBlindTrust -value 0
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid \
            [list [list encrypted [::test::cv::peerEncrypts CC:DD]]]]
        set before [dict get [lindex [::test::cv::events <Verified>] end] -verified]
        c omemo trust -jid $::test::cv::BARE -device $::test::cv::DEV -state trusted
        set after [lindex [::test::cv::events <Verified>] end]
        list $before [dict get $after -verified] \
            [expr {[dict get $after -fingerprint] eq [omemopeer::fingerprint romeo]}] \
            [dict get [lindex [c.calls list] 0] verified] \
            [llength [::test::cv::events <Verified>]]
    } -result {0 1 1 1 2}

test calls-verify-blind-trust-off-mid-call \
    {turning blind trust off mid-call unverifies a call its undecided key verified} \
    {*}$::test::cv::env -body {
        ::test::cv::answered
        set before [::test::cv::lastVerified]
        c omemo setBlindTrust -value 0
        list $before [::test::cv::lastVerified] \
            [dict get [lindex [c.calls list] 0] verified]
    } -result {1 0 0}

test calls-verify-other-device-verified-ends-blind-trust \
    {verifying another of the peer's keys mid-call ends blind trust for the one the call came by} \
    {*}$::test::cv::env -body {
        omemopeer::create laptop -device 5555
        c omemo EnsureTrustRow $::test::cv::BARE 5555 \
            [::omemopeer::store_laptop identity_pub]
        omemopeer::destroy laptop
        ::test::cv::answered
        set before [::test::cv::lastVerified]
        c omemo trust -jid $::test::cv::BARE -device 5555 -state trusted
        list $before [::test::cv::lastVerified]
    } -result {1 0}

test calls-verify-accept-plain-after-encrypted-fails \
    {our offer went out encrypted: a plain answer fails the call} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid {{plain CC:DD}}]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure $sid]
    } -result {none {<Failed> security-error 0}}

test calls-verify-accept-without-key-fails \
    {an encrypted fingerprint with our key stripped fails the call} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        set enc [::test::cv::peerEncrypts CC:DD]
        set header [xsearch $enc header -get node]
        dict set header children [xsearch $header iv -gather node]
        set enc [dict replace $enc children \
            [list $header [xsearch $enc payload -get node]]]
        c.conn feed [::test::cv::jingle session-accept $sid [list [list encrypted $enc]]]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure $sid]
    } -result {none {<Failed> security-error 0}}

test calls-verify-accept-partly-encrypted-fails \
    {one transport's fingerprint encrypted and another's plain fails the call} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid [list \
            [list encrypted [::test::cv::peerEncrypts CC:DD]] {plain EE:FF}]]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure $sid]
    } -result {none {<Failed> security-error 0}}

test calls-verify-accept-plain-beside-encrypted-fails \
    {a transport carrying both a plain and an encrypted fingerprint fails the call} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid [list \
            [list both EE:FF [::test::cv::peerEncrypts CC:DD]]]]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure $sid]
    } -result {none {<Failed> security-error 0}}

test calls-verify-accept-not-a-fingerprint-fails \
    {an encrypted text that is no fingerprint fails the call} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered]
        c.conn feed [::test::cv::jingle session-accept $sid [list \
            [list encrypted [::test::cv::peerEncrypts "CC:DD\r\na=x"]]]]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure $sid]
    } -result {none {<Failed> security-error 0}}

test calls-verify-plain-call-unverified \
    {a call with plain fingerprints both ways is unverified, with no key} \
    {*}$::test::cv::env -body {
        set sid [::test::cv::offered ""]
        c.conn feed [::test::cv::jingle session-accept $sid {{plain CC:DD}}]
        list [::test::cv::remoteFingerprints] [::test::cv::events <Verified>]
    } -result {{{a=fingerprint:sha-256 CC:DD}} {{-sid tk-* -verified 0 -fingerprint {}}}} \
    -match glob

# -- Called by the peer --

# The peer calls (announcing its device), we accept, its offer arrives with
# $fps; our pc comes up.
proc ::test::cv::called {sid fps} {
    c.conn feed [jmi propose $sid]
    c.calls accept -sid $sid
    c.conn feed [jingle session-initiate $sid $fps]
    if {[dict exists [calls_state] $sid]} { answerExtdisco }
}

test calls-verify-callee-initiate-authenticated-and-accept-encrypted \
    {the peer's encrypted offer is authenticated, and our answer goes back encrypted for it} \
    {*}$::test::cv::fresh_env -body {
        ::test::cv::called tk-v3 [list [list encrypted [::test::cv::peerEncrypts CC:DD]]]
        set remote [::test::cv::remoteFingerprints]
        set v [lindex [::test::cv::events <Verified>] end]
        mockrtc::fire [::test::cv::pc tk-v3] local-description $::test::cv::SDP answer
        list $remote [dict get $v -verified] \
            [expr {[dict get $v -fingerprint] eq [omemopeer::fingerprint romeo]}] \
            [::test::cv::readFingerprint [::test::cv::sent session-accept]]
    } -result {{{a=fingerprint:sha-256 CC:DD}} 1 1 {encrypted 4242 AA:BB plain_too 0}}

test calls-verify-callee-holding-own-session \
    {an encrypted offer is authenticated though we built a session of our own with the caller's device} \
    {*}$::test::cv::env -body {
        omemopeer::learn romeo $::test::cv::ME [::test::cv::myDevice] \
            [[set [c.omemo info vars store]] bundle]
        ::test::cv::called tk-v7 [list [list encrypted [::test::cv::peerEncrypts CC:DD]]]
        list [::test::cv::remoteFingerprints] [::test::cv::lastVerified] \
            [dict exists [calls_state] tk-v7]
    } -result {{{a=fingerprint:sha-256 CC:DD}} 1 1}

test calls-verify-callee-plain-initiate-accepted \
    {a plain offer is taken even from a peer that announced a device, unverified} \
    {*}$::test::cv::env -body {
        ::test::cv::called tk-v4 {{plain CC:DD}}
        list [::test::cv::remoteFingerprints] \
            [lrange [lindex [::test::cv::events <Verified>] end] 2 end] \
            [dict exists [calls_state] tk-v4]
    } -result {{{a=fingerprint:sha-256 CC:DD}} {-verified 0 -fingerprint {}} 1}

test calls-verify-callee-initiate-that-will-not-open-fails \
    {an encrypted offer that does not authenticate fails the call} \
    {*}$::test::cv::fresh_env -body {
        set enc [::test::cv::peerEncrypts CC:DD]
        set other [::test::cv::peerEncrypts EE:FF]
        set enc [dict replace $enc children [list \
            [xsearch $enc header -get node] [xsearch $other payload -get node]]]
        ::test::cv::called tk-v5 [list [list encrypted $enc]]
        list [::test::cv::remoteFingerprints] [::test::cv::failedInsecure tk-v5]
    } -result {none {<Failed> security-error 0}}

test calls-verify-callee-starts-no-session-while-ringing \
    {a callee fetches no bundle for the caller's device: the caller's offer starts the session} \
    {*}$::test::cv::fresh_env -body {
        c.conn feed [::test::cv::jmi propose tk-v6 7777]
        c.calls accept -sid tk-v6
        llength [lmap w [c.conn get_written] {
            if {![string match *bundles:7777 [xsearch $w pubsub items -get @node]]} continue
            set w
        }]
    } -result 0

test calls-verify-caller-readies-session-on-proceed \
    {the caller fetches the callee's bundle as the proceed names its device} \
    {*}$::test::cv::fresh_env -body {
        set sid [c.calls start -to $::test::cv::BARE]
        c.conn feed [::test::cv::jmi proceed $sid 7777]
        llength [lmap w [c.conn get_written] {
            if {![string match *bundles:7777 [xsearch $w pubsub items -get @node]]} continue
            set w
        }]
    } -result 1

test calls-verify-group-session-stays-plain \
    {a group-call session sends its fingerprint plain} \
    {*}$::test::cv::env -body {
        set sid [c.calls StartGroupSession -room room@conf.example.com \
            -peer $::test::cv::PEER]
        ::test::cv::answerExtdisco
        c.conn clear
        mockrtc::fire [::test::cv::pc $sid] local-description $::test::cv::SDP offer
        ::test::cv::readFingerprint [::test::cv::sent session-initiate]
    } -result {plain AA:BB}

mockrtc::uninstall
