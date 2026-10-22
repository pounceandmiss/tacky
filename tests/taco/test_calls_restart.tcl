# Unit tests for a call's ICE restart (see "ICE restart" in
# lib/taco/modules/call.tcl): ours, the peer's, both at once, and every way
# one can fail - under each capability profile a backend can have:
#
#   none    neither follows nor starts (rtc, today)
#   follow  follows the peer's restart, cannot start one
#   full    follows, starts, rolls back (webrtc, host)
#
# The wire is checked against the shape Conversations sends and expects.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::callshelpers
package require tacky::mockmedia
package require tacky::callsmachine

set CR_PROFILES {
    none   {iceRestart 0 restartIce 0 rollback 0}
    follow {iceRestart 1 restartIce 0 rollback 0}
    full   {iceRestart 1 restartIce 1 rollback 1}
}

# An environment whose mock backend has the capabilities of $profile, and
# timers short enough to run out within a test.
proc cr_env {profile} {
    set caps [dict merge $::mockmedia::DEFAULT_CAPS [dict get $::CR_PROFILES $profile]]
    tacky_env -mock conn -capture-emit 1 -taco-client {
        -domain test.example.com -port 5222
        -username user -password pass -resource res
        -taco ::tacky
    } -bound-jid user@test.example.com/res -extra-setup [string map [list @CAPS@ $caps] {
        mockmedia::reset
        mockmedia::capabilities {@CAPS@}
        ::tacky::media open mock
        c.iq live 1
        set ::taco_calls::call::DISCONNECT_GRACE_MS 10
        set ::taco_calls::call::RESTART_AFTER_MS 20
        set ::taco_calls::call::RESTART_WAIT_MS 40
        set ::taco_calls::call::MEDIA_LOSS_MAX_MS 5000
    }] -extra-cleanup {
        set ::taco_calls::call::DISCONNECT_GRACE_MS 2000
        set ::taco_calls::call::RESTART_AFTER_MS 3000
        set ::taco_calls::call::RESTART_WAIT_MS 15000
        set ::taco_calls::call::MEDIA_LOSS_MAX_MS 60000
        set ::taco_calls::call::MAX_RESTART_ATTEMPTS 3
        set ::taco_calls::call::MAX_RESTARTS 8
    }
}
set none_env   [cr_env none]
set follow_env [cr_env follow]
set full_env   [cr_env full]

# -- Helpers --

# The peer's transport-info under new credentials: an offer with no
# candidates (Conversations' restart), or with $cands (its answer).
proc cr_restart_in {sid ufrag {cands {}} {id rs1}} {
    j iq -type set -from $::CM_PEER -to $::CM_ME -id $id {
        j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
            j content -creator initiator -name audio {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                    -ufrag $ufrag -pwd ${ufrag}pwdpwdpwdpwdpwdpw {
                    foreach port $cands {
                        j candidate -foundation 1 -component 1 -protocol udp \
                            -priority 2122260223 -ip 192.0.2.9 -port $port \
                            -type host -id c$port -generation 0
                    }
                }
            }
        }
    }
}

# A candidate trickled under $ufrag, no pwd, as a peer sends after its
# credentials went out.
proc cr_candidate_in {sid ufrag port {id ci1}} {
    j iq -type set -from $::CM_PEER -to $::CM_ME -id $id {
        j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
            j content -creator initiator -name audio {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 -ufrag $ufrag {
                    j candidate -foundation 1 -component 1 -protocol udp \
                        -priority 2122260223 -ip 192.0.2.9 -port $port \
                        -type host -id c$port -generation 0
                }
            }
        }
    }
}

# The transport-infos we sent: {ufrag pwd candidate-count} each.
proc cr_ti_sent {} {
    set out {}
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn eq "" || [xsearch $jn -get @action] ne "transport-info"} continue
        set t [xsearch $jn content transport -get node]
        lappend out [list [xsearch $t -get @ufrag] [xsearch $t -get @pwd] \
            [llength [xsearch $t candidate -gather node]]]
    }
    return $out
}

# The id of the last transport-info we sent, to answer it.
proc cr_last_ti_id {} {
    set id ""
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $jn -get @action] eq "transport-info"} {
            set id [xsearch $w -get @id]
        }
    }
    return $id
}

proc cr_ack {id} {
    c.conn feed [j iq -type result -from $::CM_PEER -to $::CM_ME -id $id]
}

proc cr_tie_break {id} {
    c.conn feed [j iq -type error -from $::CM_PEER -to $::CM_ME -id $id {
        j error -type cancel {
            j conflict -ns urn:ietf:params:xml:ns:xmpp-stanzas
            j tie-break -ns urn:xmpp:jingle:errors:1
        }
    }]
}

# What our backend was asked: SetLocalDescription / SetRemoteDescription
# arguments, without the pc.
proc cr_backend {op} {
    lmap c [mockmedia::calls $op] { lrange $c 1 end }
}

# The remote descriptions set: {type ufrag setup} each.
proc cr_remote_set {} {
    lmap c [cr_backend SetRemoteDescription] {
        set sdp [dict get $c -sdp]
        regexp -line {^a=ice-ufrag:(\S+)} $sdp -> u
        regexp -line {^a=setup:(\S+)} $sdp -> st
        list [dict get $c -type] $u $st
    }
}

proc cr_candidates_added {} {
    lmap c [cr_backend AddRemoteCandidate] {
        lindex [dict get $c -candidate] 5
    }
}

# A call up with media flowing; the backend log and the wire cleared.
proc cr_live {{role caller}} {
    set sid [cm_transport connected $role]
    mockmedia::reset_log
    return $sid
}

proc cr_drive {sid args} {
    mockmedia::drive {*}[linsert $args 1 [cm_pc $sid]]
}

proc cr_wait {ms} { cm_wait $ms }

proc cr_conn_events {} {
    lmap e [lsearch -all -inline [calls_events] <Connection>*] { lindex $e end }
}

# -- Starting one --

test calls-restart-ours-on-failed {full: a failed path is restarted: an offer under new credentials, sent alone} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        set asked [cr_backend SetLocalDescription]
        cr_drive $sid localDescription [cm_sdp new1] offer
        list $asked [cr_ti_sent] [cm_field $sid transport] [cm_field $sid restart] \
            [cm_events] [cr_conn_events]
    } -result {{{-sdp {} -type offer -ice-restart 1}} {{new1 xyzxyzxyzxyzxyzxyzxyzx 0}} restarting awaiting <Connection> reconnecting}

test calls-restart-ours-wire-shape {full: our restart offer is Conversations' shape: one content, its transport with ufrag and pwd and nothing in it} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        set w [lindex [c.conn get_written] end]
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        list [xsearch $w -get {@type @to}] [xsearch $jn -get {@action @sid @initiator}] \
            [xsearch $jn content -get {@creator @name}] \
            [dict get [xsearch $jn content transport -get node] children]
    } -result [list {set peer@example.com/phone} {transport-info tk-* user@test.example.com/res} {initiator audio} {}] \
    -match glob

test calls-restart-ours-candidates-wait-for-ack {full: our new candidates go out only once the peer took the credentials} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        set id [cr_last_ti_id]
        cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
        set before [llength [cr_ti_sent]]
        cr_ack $id
        list $before [cr_ti_sent]
    } -result {1 {{new1 xyzxyzxyzxyzxyzxyzxyzx 0} {new1 xyzxyzxyzxyzxyzxyzxyzx 1}}}

test calls-restart-ours-answer-applied {full: the peer's credentials with candidates answer our offer, keeping its DTLS role, its candidates in the description} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_ack [cr_last_ti_id]
        c.conn feed [cr_restart_in $sid pa2 {6001}]
        set sdp [dict get [lindex [cr_backend SetRemoteDescription] 0] -sdp]
        list [cm_reply_word rs1] [cr_remote_set] \
            [regexp -line {^a=candidate:.* 6001 typ host} $sdp] [cm_field $sid restart]
    } -result {result {{answer pa2 active}} 1 answered}

test calls-restart-ours-connects {full: connected again ends the restart: <Active> with the first stamp, <Connection connected>, nothing failed} \
    {*}$full_env -body {
        set sid [cr_live]
        set since [cm_field $sid active_since]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_ack [cr_last_ti_id]
        c.conn feed [cr_restart_in $sid pa2 {6001}]
        cr_drive $sid connectionState connected
        list [cm_field $sid transport] [expr {[cm_field $sid restart] ne ""}] \
            [dict exists [calls_state] $sid restart_timer] \
            [expr {[dict get [lrange [lindex [calls_events] 1] 1 end] -since] == $since}] \
            [cm_events] [cr_conn_events] [cm_field $sid restart_attempts] [cm_field $sid restarts]
    } -result {connected 0 0 1 {<Connection> <Active> <Connection>} {reconnecting connected} 0 1}

test calls-restart-ours-from-callee-keeps-role {full: the callee's restart answer is applied with the caller's real DTLS role, not the actpass of our own restart offer} \
    {*}$full_env -body {
        set sid [cm_in pending callee]
        # Our answer took active, so the caller is passive.
        set answer [string map {a=setup:actpass a=setup:active} [cm_sdp ans0]]
        mockmedia::drive localDescription [cm_pc $sid] $answer answer
        mockmedia::drive connectionState [cm_pc $sid] connected
        mockmedia::reset_log
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_ack [cr_last_ti_id]
        c.conn feed [cr_restart_in $sid pa2 {6001}]
        cr_remote_set
    } -result {{answer pa2 passive}}

test calls-restart-ours-from-callee {full: the responder restarts too, the spec letting either side} \
    {*}$full_env -body {
        set sid [cr_live callee]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        set w [lindex [c.conn get_written] end]
        list [cr_backend SetLocalDescription] \
            [xsearch [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node] -get @responder]
    } -result {{{-sdp {} -type offer -ice-restart 1}} user@test.example.com/res}

test calls-restart-ours-after-interruption {full: a path interrupted past RESTART_AFTER_MS is restarted} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState disconnected
        cr_wait 80
        list [cr_backend SetLocalDescription] [cr_conn_events]
    } -result {{{-sdp {} -type offer -ice-restart 1}} {interrupted reconnecting}}

test calls-restart-ours-on-resume {full: the stream coming back while the path is down restarts at once} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_AFTER_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState disconnected
        c.conn fire_ready 1
        cr_backend SetLocalDescription
    } -result {{-sdp {} -type offer -ice-restart 1}}

test calls-restart-blip-not-restarted {full: a path back within RESTART_AFTER_MS is not restarted} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState disconnected
        cr_drive $sid connectionState connected
        cr_wait 80
        list [cr_backend SetLocalDescription] [cm_field $sid transport]
    } -result {{} connected}

# -- Following the peer's --

foreach profile {follow full} {
    test calls-restart-follow-$profile "$profile: the peer's credentials with no candidates are its offer: applied as one, actpass, and acked" \
        {*}[set ${profile}_env] -body {
            set sid [cr_live]
            c.conn feed [cr_restart_in $sid pn1]
            list [cm_reply_word rs1] [cr_remote_set] [cm_field $sid transport] \
                [cm_field $sid restart] [cr_conn_events]
        } -result {result {{offer pn1 actpass}} restarting answering reconnecting}
}

test calls-restart-follow-answer-on-candidates {follow: our answer's credentials go out on our candidates, at once, and never as session-accept} \
    {*}$follow_env -body {
        set ::taco_calls::call::RESTART_AFTER_MS 100000
        set sid [cr_live callee]
        cr_drive $sid connectionState disconnected
        c.conn feed [cr_restart_in $sid pn1]
        cr_drive $sid localDescription [cm_sdp ans1] answer
        cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
        list [cr_ti_sent] [lsearch -all -inline [cm_wire] session-*] [cm_field $sid restart]
    } -result {{{ans1 xyzxyzxyzxyzxyzxyzxyzx 1}} {} answered}

test calls-restart-follow-candidates-wait-for-answer {follow: candidates the backend reports before our answer wait for it, and go out under its credentials} \
    {*}$follow_env -body {
        set ::taco_calls::call::RESTART_AFTER_MS 100000
        set sid [cr_live callee]
        cr_drive $sid connectionState disconnected
        c.conn feed [cr_restart_in $sid pn1]
        cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
        set before [cr_ti_sent]
        cr_drive $sid localDescription [cm_sdp ans1] answer
        list $before [cr_ti_sent]
    } -result {{} {{ans1 xyzxyzxyzxyzxyzxyzxyzx 1}}}

test calls-restart-follow-explicit-answer {follow, no autoAnswer: the answer is asked for after the offer} \
    {*}$follow_env -body {
        mockmedia::capabilities [dict merge [mockmedia::caps] {autoAnswer 0}]
        ::tacky::media open mock
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1]
        cr_backend SetLocalDescription
    } -result {{-sdp {} -type answer}}

test calls-restart-follow-new-generation {follow: candidates of the new credentials are applied, the replaced generation's dropped} \
    {*}$follow_env -body {
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1 {} rs1]
        c.conn feed [cr_candidate_in $sid pn1 6100 ci1]
        c.conn feed [cr_candidate_in $sid def 6200 ci2]
        c.conn feed [cr_candidate_in $sid zzz 6300 ci3]
        list [cr_candidates_added] [cm_reply_word ci2] [cm_reply_word ci3]
    } -result {6100 result result}

test calls-restart-follow-over-working-path {follow: a peer's restart over a path that never broke here ends once answered, the backend saying nothing more} \
    {*}$follow_env -body {
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1]
        cr_drive $sid localDescription [cm_sdp ans1] answer
        list [cm_field $sid transport] [dict exists [calls_state] $sid restart_timer] \
            [cr_conn_events] [cm_events]
    } -result {connected 0 {reconnecting connected} {<Connection> <Active> <Connection>}}

test calls-restart-ours-over-working-path {full: our restart's answer applied on a backend that stayed connected ends it} \
    {*}$full_env -body {
        set sid [cr_live]
        [call_of $sid] StartRestart "a test"
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_ack [cr_last_ti_id]
        c.conn feed [cr_restart_in $sid pa2 {6001}]
        list [cm_field $sid transport] [cr_conn_events]
    } -result {connected {reconnecting connected}}

test calls-restart-wait-out-on-working-path {full: a restart whose wait runs out while the backend says connected ends, not fails} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        [call_of $sid] StartRestart "a test"
        [call_of $sid] Fire restart
        list [dict exists [calls_state] $sid] [cm_field $sid transport]
    } -result {1 connected}

test calls-restart-follow-connects {follow: the followed restart connecting is <Active> and <Connection connected>} \
    {*}$follow_env -body {
        set ::taco_calls::call::RESTART_AFTER_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState disconnected
        c.conn feed [cr_restart_in $sid pn1]
        cr_drive $sid localDescription [cm_sdp ans1] answer
        cr_drive $sid connectionState connected
        list [cm_field $sid transport] [cr_conn_events] [cm_events]
    } -result {connected {reconnecting connected} {<Connection> <Active> <Connection>}}

test calls-restart-follow-only-waits-for-peer {follow: a failed path we cannot restart waits for the peer's restart} \
    {*}$follow_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState failed
        list [dict exists [calls_state] $sid] [cm_field $sid transport] \
            [cr_backend SetLocalDescription] [cr_conn_events]
    } -result {1 interrupted {} interrupted}

test calls-restart-follow-only-gives-up {follow: the peer never restarting fails the call once the wait runs out, as many times as allowed} \
    {*}$follow_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_wait 200
        list [dict exists [calls_state] $sid] [lindex [calls_events] end] \
            [xsearch [cm_terminate] reason * -get tag]
    } -result {0 {<Failed> -sid * -reason {media path failed (ICE/DTLS)}} connectivity-error} -match glob

# -- A backend that can do neither --

test calls-restart-none-fails-at-once {none: a failed path fails the call, as before} \
    {*}$none_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        list [dict exists [calls_state] $sid] [cm_events] [cr_backend SetLocalDescription]
    } -result {0 <Failed> {}}

test calls-restart-none-cannot-follow {none: the peer's restart is acked, warned of, and its generation's candidates never reach the old agent} \
    {*}$none_env -body {
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1 {6001}]
        c.conn feed [cr_candidate_in $sid pn1 6100 ci1]
        c.conn feed [cr_candidate_in $sid def 6200 ci2]
        list [cm_reply_word rs1] [cr_remote_set] [cr_candidates_added] \
            [lindex [calls_events] end 0] [cm_field $sid transport]
    } -result {result {} 6200 <Warning> connected}

test calls-restart-none-interrupted-unrestarted {none: an interruption is said, and nothing is restarted} \
    {*}$none_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState disconnected
        cr_wait 80
        list [dict exists [calls_state] $sid] [cr_conn_events] [cr_backend SetLocalDescription]
    } -result {1 interrupted {}}

# -- Both at once --

test calls-restart-glare-initiator-wins {full, initiator: the responder's offer crossing ours is refused with tie-break} \
    {*}$full_env -body {
        set sid [cr_live caller]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        c.conn feed [cr_restart_in $sid pn1]
        set reply [cm_reply rs1]
        list [xsearch $reply -get @type] \
            [xsearch $reply error tie-break -ns urn:xmpp:jingle:errors:1 -get tag] \
            [cr_remote_set] [cm_field $sid restart]
    } -result {error tie-break {} awaiting}

test calls-restart-glare-responder-yields {full, responder: the initiator's offer crossing ours wins: ours rolled back, theirs followed} \
    {*}$full_env -body {
        set sid [cr_live callee]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        c.conn feed [cr_restart_in $sid pn1]
        list [cm_reply_word rs1] [cr_backend SetLocalDescription] [cr_remote_set] \
            [cm_field $sid restart]
    } -result {result {{-sdp {} -type offer -ice-restart 1} {-sdp {} -type rollback}} {{offer pn1 actpass}} answering}

test calls-restart-glare-responder-before-own-offer {full, responder: the initiator's offer before ours exists: ours, once made, is rolled back and never sent} \
    {*}$full_env -body {
        set sid [cr_live callee]
        cr_drive $sid connectionState failed
        c.conn feed [cr_restart_in $sid pn1]
        c.conn feed [cr_candidate_in $sid pn1 6100 ci1]
        cr_drive $sid localDescription [cm_sdp new1] offer
        list [cr_ti_sent] [cr_backend SetLocalDescription] [cr_remote_set] \
            [cr_candidates_added] [cm_field $sid restart]
    } -result {{} {{-sdp {} -type offer -ice-restart 1} {-sdp {} -type rollback}} {{offer pn1 actpass}} 6100 answering}

test calls-restart-glare-tie-break-waits {full, responder: our offer turned down with tie-break waits for the initiator's, failing nothing} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live callee]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_tie_break [cr_last_ti_id]
        list [cm_field $sid restart] [cm_events] [llength [cr_backend SetLocalDescription]]
    } -result {awaiting <Connection> 1}

test calls-restart-glare-no-rollback-responder-never-starts {a responder whose backend cannot roll back only follows} \
    {*}$full_env -body {
        mockmedia::capabilities [dict merge [mockmedia::caps] {rollback 0}]
        ::tacky::media open mock
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live callee]
        cr_drive $sid connectionState failed
        list [cr_backend SetLocalDescription] [cm_field $sid transport]
    } -result {{} interrupted}

# -- When it does not work --

test calls-restart-times-out-and-retries {full: a restart that does not connect is followed by another, up to MAX_RESTART_ATTEMPTS, then the call fails} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState failed
        set out {}
        foreach n {1 2 3} {
            cr_drive $sid localDescription [cm_sdp new$n] offer
            lappend out [llength [cr_backend SetLocalDescription]]
            [call_of $sid] Fire restart
        }
        list $out [dict exists [calls_state] $sid] [lindex [calls_events] end 0] \
            [xsearch [cm_terminate] reason * -get tag]
    } -result {{1 2 3} 0 <Failed> connectivity-error}

test calls-restart-wait-paused-while-offline {full: a restart's wait running out while the stream is down starts over instead} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState failed
        c.iq live 0
        [call_of $sid] Fire restart
        set offline [list [dict exists [calls_state] $sid restart_timer] \
            [llength [cr_backend SetLocalDescription]]]
        c.iq live 1
        [call_of $sid] Fire restart
        list $offline [llength [cr_backend SetLocalDescription]]
    } -result {{1 1} 2}

test calls-restart-media-loss-ceiling {full: however restarts go, a call with no media for MEDIA_LOSS_MAX_MS is over} \
    {*}$full_env -body {
        set ::taco_calls::call::MEDIA_LOSS_MAX_MS 50
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_wait 90
        list [dict exists [calls_state] $sid] [lindex [calls_events] end]
    } -result {0 {<Failed> -sid * -reason {no media for 0 s}}} -match glob

test calls-restart-cap-per-call {full: a path that keeps failing and coming back stops being restarted after MAX_RESTARTS} \
    {*}$full_env -body {
        set ::taco_calls::call::MAX_RESTARTS 2
        set sid [cr_live]
        foreach n {1 2 3} {
            cr_drive $sid connectionState failed
            cr_drive $sid localDescription [cm_sdp new$n] offer
            cr_drive $sid connectionState connected
        }
        list [llength [cr_backend SetLocalDescription]] [dict exists [calls_state] $sid]
    } -result {2 1}

test calls-restart-cap-ends-call {full: past MAX_RESTARTS a failed path is left to the peer's restart, and then fails} \
    {*}$full_env -body {
        set ::taco_calls::call::MAX_RESTARTS 1
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        cr_drive $sid connectionState connected
        cr_drive $sid connectionState failed
        set waiting [list [cm_field $sid transport] [llength [cr_backend SetLocalDescription]]]
        foreach n {1 2 3} {
            if {[dict exists [calls_state] $sid]} { [call_of $sid] Fire restart }
        }
        list $waiting [dict exists [calls_state] $sid] [lindex [calls_events] end 0]
    } -result {{interrupted 1} 0 <Failed>}

test calls-restart-refused-tries-again {full: the peer refusing our restart offer is a failed attempt} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        cr_drive $sid localDescription [cm_sdp new1] offer
        c.conn feed [j iq -type error -from $::CM_PEER -to $::CM_ME -id [cr_last_ti_id] {
            j error -type cancel {
                j feature-not-implemented -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        llength [cr_backend SetLocalDescription]
    } -result 2

test calls-restart-peer-forgot-session {full: the peer answering our transport-info with unknown-session ends the call} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
        c.conn feed [j iq -type error -from $::CM_PEER -to $::CM_ME -id [cr_last_ti_id] {
            j error -type cancel {
                j item-not-found -ns urn:ietf:params:xml:ns:xmpp-stanzas
                j unknown-session -ns urn:xmpp:jingle:errors:1
            }
        }]
        list [dict exists [calls_state] $sid] [lindex [calls_events] end]
    } -result {0 {<Failed> -sid * -reason {the peer no longer has the session}}} -match glob

test calls-restart-peer-offline-ends {full: the peer's resource gone (service-unavailable) ends the call, restart or not} \
    {*}$full_env -body {
        set out {}
        foreach restarting {0 1} {
            set sid [cr_live]
            if {$restarting} {
                cr_drive $sid connectionState failed
                cr_drive $sid localDescription [cm_sdp new1] offer
            } else {
                cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
            }
            c.conn feed [j iq -type error -from $::CM_PEER -to $::CM_ME -id [cr_last_ti_id] {
                j error -type cancel {
                    j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas
                }
            }]
            lappend out [dict exists [calls_state] $sid] [lindex [calls_events] end]
        }
        set out
    } -result {0 {<Failed> -sid * -reason {the peer went offline}} 0 {<Failed> -sid * -reason {the peer went offline}}} -match glob

test calls-restart-other-error-keeps-call {full: any other error on a transport-info leaves the call to its media path} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid iceCandidate "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host" audio
        c.conn feed [j iq -type error -from $::CM_PEER -to $::CM_ME -id [cr_last_ti_id] {
            j error -type wait {
                j resource-constraint -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        dict exists [calls_state] $sid
    } -result 1

# -- What a restart may not change --

test calls-restart-fingerprint-change-fails {a transport-info carrying another DTLS fingerprint fails the call with security-error} \
    {*}$full_env -body {
        set sid [cr_live]
        c.conn feed [j iq -type set -from $::CM_PEER -to $::CM_ME -id fp1 {
            j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
                j content -creator initiator -name audio {
                    j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                        -ufrag pn1 -pwd pn1pwdpwdpwdpwdpwdpw {
                        j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 \
                            -hash sha-256 -setup actpass -body EE:FF
                    }
                }
            }
        }]
        list [dict exists [calls_state] $sid] [lindex [calls_events] end] \
            [xsearch [cm_terminate] reason * -get tag] [cr_remote_set]
    } -result {0 {<Failed> -sid * -reason {the peer's DTLS fingerprint changed mid-call}} security-error {}} \
    -match glob

test calls-restart-same-fingerprint-fine {a transport-info repeating the session's fingerprint is no change} \
    {*}$full_env -body {
        set sid [cr_live]
        c.conn feed [j iq -type set -from $::CM_PEER -to $::CM_ME -id fp1 {
            j jingle -ns urn:xmpp:jingle:1 -action transport-info -sid $sid {
                j content -creator initiator -name audio {
                    j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                        -ufrag pn1 -pwd pn1pwdpwdpwdpwdpwdpw {
                        j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 \
                            -hash sha-256 -setup actpass -body cc:dd
                    }
                }
            }
        }]
        list [dict exists [calls_state] $sid] [cr_remote_set]
    } -result {1 {{offer pn1 actpass}}}

test calls-restart-before-session-up {credentials arriving before the session is up are no restart} \
    {*}$full_env -body {
        set sid [cm_in pending caller]
        c.conn feed [cr_restart_in $sid pn1]
        list [cm_reply_word rs1] [cr_remote_set] [cm_field $sid transport]
    } -result {result {} idle}

test calls-restart-ufrag-without-pwd {candidates naming an unknown ufrag without a pwd are dropped, not taken for a restart} \
    {*}$full_env -body {
        set sid [cr_live]
        c.conn feed [cr_candidate_in $sid zzz 6300 ci1]
        list [cm_reply_word ci1] [cr_remote_set] [cr_candidates_added]
    } -result {result {} {}}

test calls-restart-current-ufrag-is-candidates {a transport naming the current credentials is only candidates} \
    {*}$full_env -body {
        set sid [cr_live]
        c.conn feed [cr_candidate_in $sid def 6400 ci1]
        list [cr_remote_set] [cr_candidates_added]
    } -result {{} 6400}

# -- Ending in the middle --

test calls-restart-hangup-midway {hanging up during a restart ends the call and leaves no timer} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        set timers [list [cm_field $sid restart_timer] [cm_field $sid loss_timer]]
        c.calls hangup -sid $sid
        list [dict exists [calls_state] $sid] [lmap t $timers {expr {$t in [after info]}}] \
            [lindex [calls_events] end 0]
    } -result {0 {0 0} <Ended>}

test calls-restart-terminate-midway {the peer's terminate during a restart ends the call} \
    {*}$full_env -body {
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1]
        c.conn feed [cm_jingle session-terminate $sid]
        list [dict exists [calls_state] $sid] [lindex [calls_events] end 0]
    } -result {0 <Ended>}

test calls-restart-late-failed-ignored {the old path failing during a restart does not end the call} \
    {*}$full_env -body {
        set ::taco_calls::call::RESTART_WAIT_MS 100000
        set sid [cr_live]
        c.conn feed [cr_restart_in $sid pn1]
        cr_drive $sid connectionState failed
        cr_drive $sid connectionState disconnected
        list [dict exists [calls_state] $sid] [cm_field $sid transport]
    } -result {1 restarting}

test calls-restart-list-reconnecting {list shows a restart as reconnecting} \
    {*}$full_env -body {
        set sid [cr_live]
        cr_drive $sid connectionState failed
        set row [lindex [c.calls list] 0]
        list [dict get $row state] [dict get $row connection]
    } -result {connecting reconnecting}

test calls-restart-no-illegal-moves {no restart moved a machine its table forbids} \
    {*}$full_env -body {
        set ::taco_calls::call::IllegalMoves
    } -result {}
