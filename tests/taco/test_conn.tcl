package require tcltest
namespace import ::tcltest::*
package require taco

# PBKDF2 comes from mtls; builds without it (wasm) have no SCRAM.
testConstraint mtls [scram::available]

snit::type mockbaseconn {
    variable state
    variable written
    variable writtenRaw

    option -ontransportready -default ""
    option -command -default ""
    option -error-command -default ""
    option -header-command -default ""
    option -footer-command -default ""
    option -starttls -default true
    option -transport -default tcp
    option -ws-url -default ""

    constructor {args} {
        $self configurelist $args
        set state disconnected
        set written {}
        set writtenRaw {}
    }

    method connect {host port} {
        set state connected
        if {$options(-ontransportready) ne ""} {
            {*}$options(-ontransportready)
        }
    }

    method writeStanza {stanza} {
        lappend written $stanza
    }

    method writeNow {data} {
        lappend writtenRaw $data
    }

    method close {} {
        set state disconnected
    }

    method CreateReader {} {}

    method state {} {
        return $state
    }

    variable socket ""
    method socket {} {
        return $socket
    }

    # The channel conn reads TLS state from (see with_tls).
    method set_socket {name} {
        set socket $name
    }

    # -- test helpers --

    method inject {stanza} {
        {*}$options(-command) $stanza
    }

    method inject_error {msg} {
        {*}$options(-error-command) $msg
    }

    method get_written {} {
        return $written
    }

    method get_written_raw {} {
        return $writtenRaw
    }

    method clear {} {
        set written {}
        set writtenRaw {}
    }
}

proc make_features {} {
    j features {
        j mechanisms -ns urn:ietf:params:xml:ns:xmpp-sasl {
            j mechanism -body PLAIN
        }
    }
}

proc make_success {} {
    j success -ns urn:ietf:params:xml:ns:xmpp-sasl
}

proc make_failure {} {
    j failure -ns urn:ietf:params:xml:ns:xmpp-sasl {
        j not-authorized
    }
}

proc make_bind_features {} {
    j features {
        j bind -ns urn:ietf:params:xml:ns:xmpp-bind
    }
}

proc make_bind_features_with_sm {} {
    j features {
        j bind -ns urn:ietf:params:xml:ns:xmpp-bind
        j sm -ns urn:xmpp:sm:3
    }
}

proc make_bind_result {jid} {
    j iq -type result -id bind {
        j bind -ns urn:ietf:params:xml:ns:xmpp-bind {
            j jid -body $jid
        }
    }
}

proc make_bind_error {} {
    j iq -type error -id bind {
        j error -type cancel {
            j not-allowed -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }
    }
}

proc make_bind_conflict {} {
    j iq -type error -id bind {
        j error -type cancel {
            j conflict -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }
    }
}

proc make_sm_enabled {id} {
    j enabled -ns urn:xmpp:sm:3 -id $id
}

proc make_sm_resumed {previd h} {
    j resumed -ns urn:xmpp:sm:3 -previd $previd -h $h
}

# <failed/> optionally reports how far the abandoned stream got.
proc make_sm_failed {{h ""}} {
    if {$h eq ""} {
        return [j failed -ns urn:xmpp:sm:3]
    }
    j failed -ns urn:xmpp:sm:3 -h $h
}

proc make_sm_ack {h} {
    j a -ns urn:xmpp:sm:3 -h $h
}

# Drive conn through SASL + bind.  Leaves it in sm-negotiating (or ready
# if no SM support).  Returns nothing; operates on conn instance "c".
proc drive_to_bind {jid} {
    c.base inject [make_features]
    c.base inject [make_success]
    c.base inject [make_bind_features_with_sm]
    c.base inject [make_bind_result $jid]
}

proc drive_to_bind_no_sm {jid} {
    c.base inject [make_features]
    c.base inject [make_success]
    c.base inject [make_bind_features]
    c.base inject [make_bind_result $jid]
}

proc drive_to_ready {jid smid} {
    drive_to_bind $jid
    c.base inject [make_sm_enabled $smid]
}

# Callbacks are command prefixes ({*}-expanded), so we use apply lambdas
# that write to global variables visible from the test body.
set common {
    -setup {
        rename baseconn _real_baseconn
        rename mockbaseconn baseconn
        set _tready_resumed ""
        set _tauth_err {}
        set _tdisconnect {}
        set _temitted {}
        jlog configure -logproc {apply {{msg} {}}}
        conn c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res \
            -emit         {apply {{args} {lappend ::_temitted $args}}} \
            -onready      {apply {{resumed} {set ::_tready_resumed $resumed}}} \
            -onautherror  {apply {{message} {lappend ::_tauth_err $message}}} \
            -ondisconnect {apply {{message} {lappend ::_tdisconnect $message}}}
    }
    -cleanup {
        catch {c destroy}
        jlog configure -logproc ""
        rename baseconn mockbaseconn
        rename _real_baseconn baseconn
    }
}

# -- Connection flow (happy path) -----------------------------------------

test conn-connect-sets-state {connect transitions through connecting to authenticating} \
    {*}$common \
    -body {
        set s1 [c state]
        c connect
        # With synchronous mock, connect completes instantly through to authenticating
        set s2 [c state]
        list $s1 $s2 [c isReady]
    } -result {disconnected authenticating 0}

test conn-sasl-auth-sends-plain {features stanza triggers SASL PLAIN auth} \
    {*}$common \
    -body {
        c connect
        c.base clear
        c.base inject [make_features]
        set written [c.base get_written]
        set auth [lindex $written 0]
        set tag [dict get $auth tag]
        set ns  [dict get $auth ns]
        set mech [dict get $auth attrs mechanism]
        set body [dict get $auth body]
        set expected [base64::encode "\0user\0pass"]
        list $tag $ns $mech [expr {$body eq $expected}]
    } -result {auth urn:ietf:params:xml:ns:xmpp-sasl PLAIN 1}

test conn-sasl-success-restarts-stream {success stanza restarts XML stream} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base clear
        c.base inject [make_success]
        set raw [c.base get_written_raw]
        expr {[llength $raw] == 1 && [string match "*<stream:stream*" [lindex $raw 0]]}
    } -result 1

test conn-sasl-failure-fires-onautherror {SASL failure fires -onautherror} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_failure]
        list [lindex $_tauth_err 0] [c.base state]
    } -result {{SASL authentication failed: not-authorized} disconnected}

proc make_features_offering {mechs} {
    j features -ns http://etherx.jabber.org/streams {
        j mechanisms -ns urn:ietf:params:xml:ns:xmpp-sasl {
            foreach m $mechs {
                j mechanism -body $m
            }
        }
    }
}

proc make_sasl {tag msg} {
    j $tag -ns urn:ietf:params:xml:ns:xmpp-sasl \
        -body [binary encode base64 $msg]
}

proc sasl_sent {} {
    lmap s [c.base get_written] {
        list [dict get $s tag] [dict getdef $s attrs mechanism ""] \
            [binary decode base64 [dict get $s body]]
    }
}

# RFC 7677 section 3, with its fixed client nonce.
proc with_rfc7677_nonce {script} {
    rename scram::nonce _scram_nonce
    proc scram::nonce {} { return rOprNGfwEbeRWgbNEkqO }
    try {
        uplevel 1 $script
    } finally {
        rename scram::nonce {}
        rename _scram_nonce scram::nonce
    }
}

set rfc7677_server_first {r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096}

test conn-sasl-prefers-scram-sha-256 {SCRAM-SHA-256 is chosen over SCRAM-SHA-1 and PLAIN} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base clear
        with_rfc7677_nonce {
            c.base inject [make_features_offering {PLAIN SCRAM-SHA-1 SCRAM-SHA-256}]
        }
        sasl_sent
    } -result {{auth SCRAM-SHA-256 n,,n=user,r=rOprNGfwEbeRWgbNEkqO}}

test conn-sasl-scram-sha-1-over-plain {SCRAM-SHA-1 is chosen over PLAIN} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base clear
        c.base inject [make_features_offering {PLAIN SCRAM-SHA-1}]
        lindex [sasl_sent] 0 1
    } -result SCRAM-SHA-1

test conn-sasl-no-common-mechanism {no usable mechanism fires -onautherror} \
    {*}$common \
    -body {
        c connect
        c.base clear
        c.base inject [make_features_offering {DIGEST-MD5 EXTERNAL}]
        list $_tauth_err [c.base get_written]
    } -result {{{No supported SASL mechanism (offered: DIGEST-MD5, EXTERNAL)}} {}}

test conn-sasl-scram-exchange {a SCRAM-SHA-256 exchange proves the password and checks the server} \
    {*}$common -constraints mtls \
    -body {
        c configure -password pencil
        c connect
        with_rfc7677_nonce {
            c.base inject [make_features_offering SCRAM-SHA-256]
        }
        c.base clear
        c.base inject [make_sasl challenge $rfc7677_server_first]
        set sent [sasl_sent]
        c.base inject [make_sasl success v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=]
        list $sent $_tauth_err [c state]
    } -result {{{response {} {c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=}}} {} binding}

# Run $script as if on TLS $version with tls-exporter data $cb, stubbing
# ::mtls::status and ::mtls::exporter.
proc with_tls {version cb script} {
    package require mtls
    c.base set_socket tlssock
    rename ::mtls::status _real_mtls_status
    rename ::mtls::exporter _real_mtls_exporter
    proc ::mtls::status {sock} [list return [list version $version]]
    proc ::mtls::exporter {sock label length} [list return $cb]
    try {
        uplevel 1 $script
    } finally {
        rename ::mtls::status {}
        rename ::mtls::exporter {}
        rename _real_mtls_status ::mtls::status
        rename _real_mtls_exporter ::mtls::exporter
    }
}

test conn-sasl-plus-with-binding {on TLS 1.3, SCRAM-SHA-256-PLUS binds to tls-exporter} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base clear
        with_tls TLSv1.3 [string repeat \x01 32] {
            with_rfc7677_nonce {
                c.base inject [make_features_offering {SCRAM-SHA-256 SCRAM-SHA-256-PLUS}]
            }
        }
        sasl_sent
    } -result {{auth SCRAM-SHA-256-PLUS p=tls-exporter,,n=user,r=rOprNGfwEbeRWgbNEkqO}}

test conn-sasl-binding-flags-y-without-plus {binding available but no -PLUS offered: the gs2 flag is y} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base clear
        with_tls TLSv1.3 [string repeat \x01 32] {
            with_rfc7677_nonce {
                c.base inject [make_features_offering SCRAM-SHA-256]
            }
        }
        sasl_sent
    } -result {{auth SCRAM-SHA-256 y,,n=user,r=rOprNGfwEbeRWgbNEkqO}}

test conn-sasl-no-binding-below-tls13 {on TLS 1.2 no -PLUS is chosen, and the flag is n} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base clear
        with_tls TLSv1.2 [string repeat \x01 32] {
            with_rfc7677_nonce {
                c.base inject [make_features_offering {SCRAM-SHA-256 SCRAM-SHA-256-PLUS}]
            }
        }
        sasl_sent
    } -result {{auth SCRAM-SHA-256 n,,n=user,r=rOprNGfwEbeRWgbNEkqO}}

test conn-sasl-plain-without-scram {without SCRAM support, PLAIN is used even when SCRAM is offered} \
    {*}$common \
    -body {
        rename scram::available _real_scram_available
        proc scram::available {} { return 0 }
        try {
            c connect
            c.base clear
            c.base inject [make_features_offering {SCRAM-SHA-256 PLAIN}]
        } finally {
            rename scram::available {}
            rename _real_scram_available scram::available
        }
        sasl_sent
    } -result [list [list auth PLAIN "\0user\0pass"]]

test conn-sasl-plain-only {a server offering only PLAIN gets PLAIN} \
    {*}$common \
    -body {
        c connect
        c.base clear
        c.base inject [make_features_offering PLAIN]
        sasl_sent
    } -result [list [list auth PLAIN "\0user\0pass"]]

test conn-sasl-unexpected-challenge {a challenge outside a SCRAM exchange is an auth error} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features_offering PLAIN]
        c.base inject [make_sasl challenge whatever]
        list $_tauth_err [c state]
    } -result {{{SASL: unexpected challenge}} disconnected}

test conn-sasl-bad-server-first {a server-first without a salt is an auth error} \
    {*}$common -constraints mtls \
    -body {
        c connect
        with_rfc7677_nonce {
            c.base inject [make_features_offering SCRAM-SHA-256]
        }
        c.base inject [make_sasl challenge r=rOprNGfwEbeRWgbNEkqOxyz,i=4096]
        list $_tauth_err [c state]
    } -result {{{SASL: server-first-message lacks s=}} disconnected}

test conn-sasl-server-final-as-challenge {a server-final sent as a challenge is checked and acknowledged} \
    {*}$common -constraints mtls \
    -body {
        c configure -password pencil
        c connect
        with_rfc7677_nonce {
            c.base inject [make_features_offering SCRAM-SHA-256]
        }
        c.base inject [make_sasl challenge $rfc7677_server_first]
        c.base clear
        c.base inject [make_sasl challenge v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=]
        set ack [sasl_sent]
        c.base inject [make_success]
        list $ack $_tauth_err [c state]
    } -result {{{response {} {}}} {} binding}

test conn-sasl-scram-bad-server-signature {a wrong server signature in success is an auth error} \
    {*}$common -constraints mtls \
    -body {
        c configure -password pencil
        c connect
        with_rfc7677_nonce {
            c.base inject [make_features_offering SCRAM-SHA-256]
        }
        c.base inject [make_sasl challenge $rfc7677_server_first]
        c.base inject [make_sasl success v=[binary encode base64 [string repeat x 32]]]
        list $_tauth_err [c state]
    } -result {{{SASL: server signature mismatch}} disconnected}

test conn-sasl-scram-success-without-final {success before the client proof is an auth error} \
    {*}$common -constraints mtls \
    -body {
        c connect
        c.base inject [make_features_offering SCRAM-SHA-1]
        c.base inject [make_success]
        list $_tauth_err [c state]
    } -result {{{SASL: success before the exchange completed}} disconnected}

test conn-bind-sends-request {second features triggers bind iq} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base clear
        c.base inject [make_bind_features_with_sm]
        set written [c.base get_written]
        set iq [lindex $written 0]
        set tag [dict get $iq tag]
        set type [dict get $iq attrs type]
        set id [dict get $iq attrs id]
        list $tag $type $id
    } -result {iq set bind}

test conn-bind-result-stores-jid {bind result stores bound JID} \
    {*}$common \
    -body {
        c connect
        drive_to_bind "user@test.example.com/res1"
        c cget -bound-jid
    } -result {user@test.example.com/res1}

test conn-bind-error-fires-onautherror {bind error fires -onautherror} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_bind_error]
        list [lindex $_tauth_err 0] [c.base state]
    } -result {{Resource binding failed} disconnected}

test conn-bind-conflict-fires-onresourceconflict {bind <conflict/> fires -onresourceconflict, not -onautherror} \
    {*}$common \
    -body {
        set ::_tconflict 0
        c configure -onresourceconflict {apply {{} {incr ::_tconflict}}}
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_bind_conflict]
        list $::_tconflict [llength $_tauth_err] [c.base state]
    } -result {1 0 disconnected}

test conn-bind-rejects-foreign-jid {bind result for another account tears down the session} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_bind_result "victim@other.example.com/r"]
        list [lindex $_tauth_err 0] [c cget -bound-jid] [c.base state]
    } -result {{Server bound an unexpected JID} {} disconnected}

test conn-bind-accepts-case-difference {server may canonicalize case in the bare JID} \
    {*}$common \
    -body {
        c connect
        drive_to_bind "User@Test.Example.COM/r"
        list [llength $_tauth_err] [c cget -bound-jid]
    } -result {0 User@Test.Example.COM/r}

test conn-bind-rejects-empty-jid {bind result with no JID tears down the session} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_bind_result ""]
        list [lindex $_tauth_err 0] [c cget -bound-jid] [c.base state]
    } -result {{Server bound an unexpected JID} {} disconnected}

# -- SM negotiation --------------------------------------------------------

test conn-sm-enabled-fires-ready {SM enabled fires -onready with resumed=0} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-123"
        list $_tready_resumed [c isReady]
    } -result {0 1}

test conn-sm-no-support-fires-ready {no SM support fires -onready with resumed=0} \
    {*}$common \
    -body {
        c connect
        drive_to_bind_no_sm "user@test.example.com/r"
        list $_tready_resumed [c isReady]
    } -result {0 1}

test conn-sm-resumed-fires-onready-with-1 {SM resumed fires -onready with resumed=1} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-456"
        set _tready_resumed ""
        c.base inject_error "connection lost"
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_sm_resumed "sm-456" 0]
        set _tready_resumed
    } -result {1}

# -- Write buffering -------------------------------------------------------

test conn-write-before-ready-buffers {stanzas before ready are buffered} \
    {*}$common \
    -body {
        c connect
        set msg [j message -to "friend@example.com" {j body -body "hello"}]
        c write $msg
        llength [c.base get_written]
    } -result 0

test conn-write-after-ready-sends {stanzas after ready go through SM} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-789"
        c.base clear
        set msg [j message -to "friend@example.com" {j body -body "hello"}]
        c write $msg
        dict get [lindex [c.base get_written] 0] tag
    } -result {message}

# -- Close -----------------------------------------------------------------

test conn-close-resets-state {close resets state} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-abc"
        c close
        list [c state] [c isReady]
    } -result {disconnected 0}

test conn-close-ends-sm-session {after a close the next stream enables SM afresh and replays nothing} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-abc"
        c write [j message -to "friend@example.com" {j body -body "unacked"}]
        # Buffered while waiting to reconnect.
        c configure -autoreconnect 1
        c.base inject_error "connection lost"
        c write [j presence]
        c close
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base clear
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_bind_result "user@test.example.com/r"]
        set tags [lmap s [c.base get_written] {dict get $s tag}]
        c.base clear
        c.base inject [make_sm_enabled "sm-def"]
        list $tags [lmap s [c.base get_written] {dict get $s tag}]
    } -result {{iq enable} {}}

test conn-close-while-disconnected-noop {close on disconnected is a no-op} \
    {*}$common \
    -body {
        c close
        c state
    } -result {disconnected}

# -- Transport error -------------------------------------------------------

test conn-transport-error-fires-ondisconnect {transport error fires -ondisconnect and sets disconnected} \
    {*}$common \
    -body {
        c connect
        c.base inject_error "read failed"
        list [lindex $_tdisconnect 0] [c state]
    } -result {{read failed} disconnected}

test conn-transport-error-with-autoreconnect {autoreconnect sets state to waiting, no callback} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-xyz"
        c.base inject_error "read failed"
        list [c state] $_tdisconnect
    } -result {waiting {}}

# -- Logging ---------------------------------------------------------------
#
# Records go through the singleton, which $common otherwise silences; these
# start listening mid-body so only the step under test is captured.

proc conn_capture_log {} {
    set ::_tlog {}
    # Only c: the default threshold is warning, and the routine lines sit
    # below it, which is the whole point of their level.
    jlog setLevel ::c verbose
    jlog configure -logproc {apply {{rec} {lappend ::_tlog $rec}}}
}

proc conn_logged {level} {
    set out {}
    foreach rec $::_tlog {
        if {[dict get $rec -level] eq $level} {
            lappend out [dict get $rec -text]
        }
    }
    return $out
}

test conn-connect-logs-endpoint {connect records what it dialled} \
    {*}$common \
    -body {
        conn_capture_log
        c connect
        conn_logged info
    } -result {{connecting to test.example.com:5222}}

test conn-transport-error-logs {a transport error names the endpoint and the reason} \
    {*}$common \
    -body {
        c connect
        conn_capture_log
        c.base inject_error "Connect failed: connection refused"
        conn_logged warning
    } -result {{test.example.com:5222: Connect failed: connection refused}}

test conn-reconnect-logs-backoff {a scheduled reconnect records its delay} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        conn_capture_log
        c.base inject_error "read failed"
        conn_logged info
    } -result {{reconnect attempt 1 in 1000ms}}

test conn-backoff-climbs-through-short-sessions {a session dropped soon after login does not reset the backoff} \
    {*}$common \
    -body {
        c configure -autoreconnect 1 -stable-after 1000
        c connect
        conn_capture_log
        foreach smid {s1 s2 s3} {
            drive_to_ready "user@test.example.com/r" $smid
            c.base inject_error "read failed"
            c DoReconnect
        }
        conn_logged info
    } -match glob -result {*attempt 1 in 1000ms* *attempt 2 in 2000ms* *attempt 3 in 5000ms*}

test conn-backoff-resets-after-stable-session {a session that stays up resets the backoff} \
    {*}$common \
    -body {
        c configure -autoreconnect 1 -stable-after 20
        c connect
        drive_to_ready "user@test.example.com/r" s1
        c.base inject_error "read failed"
        c DoReconnect
        drive_to_ready "user@test.example.com/r" s2
        after 60 {set ::_stable_waited 1}
        vwait ::_stable_waited
        conn_capture_log
        c.base inject_error "read failed"
        lsearch -all -inline [conn_logged info] "reconnect*"
    } -result {{reconnect attempt 1 in 1000ms}}

test conn-auth-error-logs {an auth failure logs at error level} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        conn_capture_log
        c.base inject [make_failure]
        conn_logged error
    } -result {{SASL authentication failed: not-authorized}}

# -- Auth error (no reconnect) ---------------------------------------------

test conn-auth-error-no-reconnect {SASL failure does not trigger reconnect} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        c.base inject [make_features]
        c.base inject [make_failure]
        c state
    } -result {disconnected}

# -- Stream errors -----------------------------------------------------------

proc make_stream_error {cond {text ""}} {
    j error -ns http://etherx.jabber.org/streams {
        j $cond -ns urn:ietf:params:xml:ns:xmpp-streams
        if {$text ne ""} {
            j text -ns urn:ietf:params:xml:ns:xmpp-streams -body $text
        }
    }
}

test conn-stream-conflict-stops {a stream taken over by another client ends without reconnecting} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-x"
        c.base inject [make_stream_error conflict "Replaced by new connection"]
        list [c state] $_tdisconnect [c.base state]
    } -result {disconnected {{Stream error: conflict (Replaced by new connection)}} disconnected}

test conn-stream-not-authorized-is-auth-error {a not-authorized stream error is an auth error} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-x"
        c.base inject [make_stream_error not-authorized]
        list [c state] $_tauth_err
    } -result {disconnected {{Stream error: not-authorized}}}

test conn-stream-shutdown-reconnects-at-once {a server shutting down is asked again on the first backoff step} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-x"
        conn_capture_log
        c.base inject [make_stream_error system-shutdown]
        list [c state] [conn_logged info]
    } -result {waiting {{reconnect attempt 1 in 1000ms}}}

test conn-stream-other-error-backs-off {any other stream error reconnects further along the backoff} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-x"
        conn_capture_log
        c.base inject [make_stream_error policy-violation]
        list [c state] [conn_logged info]
    } -result {waiting {{reconnect attempt 4 in 15000ms}}}

# -- State emission -----------------------------------------------------------

proc extract_emitted {event key} {
    set found {}
    foreach ev $::_temitted {
        if {[lindex $ev 1] eq $event} {
            set idx [lsearch -exact $ev $key]
            lappend found [lindex $ev [expr {$idx + 1}]]
        }
    }
    return $found
}

test conn-emit-state-sequence {-emit receives State events through full connect} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-emit"
        extract_emitted "<State>" -state
    } -result {connecting authenticating binding connected}

test conn-emit-disconnected-event {-emit receives Disconnected event} \
    {*}$common \
    -body {
        c connect
        c.base inject_error "read failed"
        extract_emitted "<Disconnected>" -message
    } -result {{read failed}}

test conn-emit-autherror-event {-emit receives AuthError event} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        c.base inject [make_failure]
        extract_emitted "<AuthError>" -message
    } -result {{SASL authentication failed: not-authorized}}

# -- pull ---------------------------------------------------------------------

test conn-pull-state {pull -event <State> re-emits the state as it stands} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pull"
        set ::_temitted {}
        c pull -event <State>
        set ::_temitted
    } -result {{conn <State> -state connected}}

test conn-pull-connerror {pull -event <ConnError> re-emits the standing error} \
    {*}$common \
    -body {
        c connect
        c.base inject_error "read failed"
        set ::_temitted {}
        c pull -event <ConnError>
        set ::_temitted
    } -result {{conn <ConnError> -message {read failed}}}

# An edge event has no standing value to re-emit, so pull refuses it.
test conn-pull-rejects-autherror {pull -event <AuthError> errors} \
    {*}$common \
    -body {
        catch {c pull -event <AuthError>} err
        set err
    } -result {conn pull: event <AuthError> is not pullable}

# -- Bug fix: connect() state guard ----------------------------------------

test conn-connect-while-connected-tears-down {connect while connected tears down and restarts} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-guard1"
        # Call connect again while fully connected
        c connect
        # Mock fires -ontransportready synchronously, so conn reaches authenticating
        list [c state] [c.base state]
    } -result {authenticating connected}

test conn-connect-while-authenticating-restarts {connect while authenticating restarts cleanly} \
    {*}$common \
    -body {
        c connect
        c.base inject [make_features]
        # Now in authenticating state
        c connect
        # Should restart and reach authenticating again
        c state
    } -result {authenticating}

# -- Untested edge cases ---------------------------------------------------

test conn-transport-error-during-negotiation-with-autoreconnect {transport error during negotiation with autoreconnect sets waiting} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        # Now binding; inject transport error
        c.base inject_error "connection reset"
        list [c state] $_tdisconnect
    } -result {waiting {}}

test conn-close-during-waiting-cancels-reconnect {close during waiting cancels reconnect} \
    {*}$common \
    -body {
        c configure -autoreconnect 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-wait1"
        c.base inject_error "connection lost"
        # Now in waiting state
        c close
        c state
    } -result {disconnected}

test conn-sm-failed-falls-back-to-passthrough {SM failed falls back to passthrough, conn reaches ready} \
    {*}$common \
    -body {
        c connect
        drive_to_bind "user@test.example.com/r"
        c.base inject [make_sm_failed]
        list $_tready_resumed [c isReady]
    } -result {0 1}

test conn-sm-failed-resends-queued-stanzas {SM failed resends queued stanzas via passthrough} \
    {*}$common \
    -body {
        c connect
        drive_to_bind "user@test.example.com/r"
        # In sm-negotiating; write a stanza (goes to SM queue)
        set msg [j message -to "friend@example.com" {j body -body "queued"}]
        c write $msg
        c.base clear
        # SM failed -> falls back to passthrough and flushes queue
        c.base inject [make_sm_failed]
        dict get [lindex [c.base get_written] 0] tag
    } -result {message}

test conn-sm-resume-failed-retries-enable {resume failed sends enable instead of passthrough} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-retry1"
        set _tready_resumed ""
        c.base inject_error "connection lost"
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base clear
        # Resume fails: nothing is bound yet, so bind, then <enable/>
        c.base inject [make_sm_failed]
        set bind [lindex [c.base get_written] end]
        c.base inject [make_bind_result "user@test.example.com/r"]
        set enableStanza [lindex [c.base get_written] end]
        list [dict get $bind tag] [dict get $enableStanza tag] \
            [dict get $enableStanza ns] [c isReady]
    } -result {iq enable urn:xmpp:sm:3 0}

test conn-sm-resume-failed-enable-reaches-ready {resume fail -> enable -> enabled reaches ready} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-retry2"
        set _tready_resumed ""
        c.base inject_error "connection lost"
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_sm_failed]
        c.base inject [make_bind_result "user@test.example.com/r"]
        c.base inject [make_sm_enabled "sm-retry2-new"]
        list $_tready_resumed [c isReady]
    } -result {0 1}

test conn-sm-resume-failed-without-h-drops-queue {resume fail without h replays nothing: what arrived is unknown} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-retry4"
        c write [j message -to "friend@example.com" {j body -body "unacked"}]
        c.base inject_error "connection lost"
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_sm_failed]
        c.base inject [make_bind_result "user@test.example.com/r"]
        c.base clear
        c.base inject [make_sm_enabled "sm-retry4-new"]
        # Message sends are retried by RetryPending against the archive.
        set hasMessage 0
        foreach s [c.base get_written] {
            if {[dict get $s tag] eq "message"} { set hasMessage 1; break }
        }
        list [c isReady] $hasMessage
    } -result {1 0}

test conn-sm-resume-failed-replays-queue {resume fail with h -> enable replays the unacked stanzas past it} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-retry3"
        # Send a stanza that won't be acked
        c write [j message -to "friend@example.com" {j body -body "unacked"}]
        set _tready_resumed ""
        c.base inject_error "connection lost"
        c connect
        c.base inject [make_features]
        c.base inject [make_success]
        c.base inject [make_bind_features_with_sm]
        c.base inject [make_sm_failed 0]
        c.base inject [make_bind_result "user@test.example.com/r"]
        c.base clear
        c.base inject [make_sm_enabled "sm-retry3-new"]
        # The unacked message should have been replayed
        set written [c.base get_written]
        set hasMessage 0
        foreach s $written {
            if {[dict get $s tag] eq "message"} { set hasMessage 1; break }
        }
        list [c isReady] $hasMessage
    } -result {1 1}

# -- SM delivery confirmation across a broken stream -------------------------

# Reconnect after a drop and drive as far as the resume request, which takes
# the place of binding: conn is left in sm-negotiating, waiting for the
# server's <resumed/> or <failed/>. After a <failed/> it binds; answer that
# with bind_after_failed.
proc drive_to_resume_attempt {jid} {
    c.base inject_error "connection lost"
    c connect
    c.base inject [make_features]
    c.base inject [make_success]
    c.base inject [make_bind_features_with_sm]
}

proc bind_after_failed {jid} {
    c.base inject [make_bind_result $jid]
}

# The ids of the stanzas the connection has reported as delivered so far.
proc sm_acked_ids {} {
    set ids {}
    foreach e $::_temitted {
        if {[lrange $e 0 1] ne {sm <Ack>}} continue
        foreach stanza [dict get [lrange $e 2 end] -stanzas] {
            lappend ids [dict get $stanza attrs id]
        }
    }
    return $ids
}

# The ids of the <message/>s written to the transport since the last clear.
proc sent_message_ids {} {
    set ids {}
    foreach stanza [c.base get_written] {
        if {[dict get $stanza tag] eq "message"} {
            lappend ids [dict get $stanza attrs id]
        }
    }
    return $ids
}

# The h on <failed/> is the server's last word on the abandoned stream: those
# stanzas arrived, so they must be confirmed rather than just dropped.
test conn-sm-resume-failed-confirms-what-arrived {<failed h=N/> acks the stanzas the server did receive} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-failed-h"
        c write [j message -to "friend@example.com" -id m1 {j body -body "arrived"}]
        c write [j message -to "friend@example.com" -id m2 {j body -body "did not"}]
        drive_to_resume_attempt "user@test.example.com/r"
        set ::_temitted {}
        c.base clear
        c.base inject [make_sm_failed 1]
        bind_after_failed "user@test.example.com/r"
        c.base inject [make_sm_enabled "sm-failed-h-new"]
        # m1 confirmed, only m2 replayed onto the fresh stream
        list [sm_acked_ids] [sent_message_ids] [c isReady]
    } -result {m1 m2 1}

# A <resumed/> naming someone else's stream falls back to a fresh one rather
# than parking in 'disconnected' with the queue thrown away.
test conn-sm-resumed-previd-mismatch-enables-fresh {a <resumed/> for another stream negotiates a fresh one} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-mismatch"
        drive_to_resume_attempt "user@test.example.com/r"
        c.base clear
        c.base inject [make_sm_resumed "someone-elses-stream" 0]
        bind_after_failed "user@test.example.com/r"
        set enable [lindex [c.base get_written] end]
        list [dict get $enable tag] [dict get $enable ns] [c isReady]
    } -result {enable urn:xmpp:sm:3 0}

test conn-sm-resumed-previd-mismatch-keeps-queue {a mismatched <resumed/> keeps unacked stanzas for the fresh stream} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-mismatch2"
        c write [j message -to "friend@example.com" -id m1 {j body -body "unacked"}]
        drive_to_resume_attempt "user@test.example.com/r"
        c.base inject [make_sm_resumed "someone-elses-stream" 0]
        bind_after_failed "user@test.example.com/r"
        c.base clear
        c.base inject [make_sm_enabled "sm-mismatch2-new"]
        list [c isReady] [sent_message_ids]
    } -result {1 m1}

# <failed/> to the fresh <enable/> must drop to passthrough and flush the
# queue rather than strand it.
test conn-sm-resumed-previd-mismatch-then-refused {mismatch then a refused enable falls through to passthrough} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-mismatch3"
        c write [j message -to "friend@example.com" -id m1 {j body -body "unacked"}]
        drive_to_resume_attempt "user@test.example.com/r"
        c.base inject [make_sm_resumed "someone-elses-stream" 0]
        bind_after_failed "user@test.example.com/r"
        c.base clear
        c.base inject [make_sm_failed]
        list [c isReady] [sent_message_ids]
    } -result {1 m1}

# <failed/>, <resumed/> and <a/> share one confirm path; an ordinary ack must
# still name exactly the prefix the server counted.
test conn-sm-ack-confirms-a-prefix {<a h=N/> confirms the first N stanzas and no more} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-ack"
        c write [j message -to "friend@example.com" -id m1 {j body -body "one"}]
        c write [j message -to "friend@example.com" -id m2 {j body -body "two"}]
        set ::_temitted {}
        c.base inject [make_sm_ack 1]
        set first [sm_acked_ids]
        c.base inject [make_sm_ack 2]
        list $first [sm_acked_ids]
    } -result {m1 {m1 m2}}

test conn-sm-resumed-confirms-what-arrived {<resumed h=N/> acks the stanzas the old stream delivered} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-resumed-h"
        c write [j message -to "friend@example.com" -id m1 {j body -body "arrived"}]
        c write [j message -to "friend@example.com" -id m2 {j body -body "did not"}]
        drive_to_resume_attempt "user@test.example.com/r"
        set ::_temitted {}
        c.base clear
        c.base inject [make_sm_resumed "sm-resumed-h" 1]
        # m1 confirmed, m2 resent on the resumed stream
        list [sm_acked_ids] [sent_message_ids] $_tready_resumed
    } -result {m1 m2 1}

test conn-write-buffer-flushed-after-ready {write buffer flushed when conn reaches ready} \
    {*}$common \
    -body {
        c connect
        set msg [j message -to "friend@example.com" {j body -body "early"}]
        c write $msg
        c.base clear
        drive_to_ready "user@test.example.com/r" "sm-flush1"
        dict get [lindex [c.base get_written] end] tag
    } -result {message}

# -- SM ack requests ---------------------------------------------------------

# How many <r/>s the connection has asked for so far.
proc sm_ack_requests {} {
    set n 0
    foreach s [c.base get_written] {
        if {[dict get $s tag] eq "r" && [dict get $s ns] eq "urn:xmpp:sm:3"} {
            incr n
        }
    }
    return $n
}

# A stanza with no traffic behind it must still get an <r/>, or nothing ever
# confirms it.
test conn-sm-lone-stanza-asks-for-an-ack {a single stanza is acked-for after the delay} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-lone"
        c.sm configure -ack-delay 20
        c.base clear
        c write [j message -to "friend@example.com" {j body -body "alone"}]
        set immediate [sm_ack_requests]
        after 60 {set ::_sm_waited 1}
        vwait ::_sm_waited
        list $immediate [sm_ack_requests]
    } -result {0 1}

# Asking on the threshold cancels the delayed ask instead of asking twice.
test conn-sm-burst-asks-once {a full burst asks on the threshold and not again} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-burst"
        c.sm configure -ack-delay 20
        c.base clear
        for {set i 0} {$i < 5} {incr i} {
            c write [j message -to "friend@example.com" {j body -body "m$i"}]
        }
        set immediate [sm_ack_requests]
        after 60 {set ::_sm_waited 1}
        vwait ::_sm_waited
        list $immediate [sm_ack_requests]
    } -result {1 1}

# -- SM queue overflow -------------------------------------------------------

test conn-sm-queue-overflow-triggers-reconnect {SM queue overflow triggers disconnect/reconnect} \
    -setup {
        rename baseconn _real_baseconn
        rename mockbaseconn baseconn
        set _tready_resumed ""
        set _tauth_err {}
        set _tdisconnect {}
        set _temitted {}
        jlog configure -logproc {apply {{msg} {}}}
        conn c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res \
            -autoreconnect 1 \
            -emit         {apply {{args} {lappend ::_temitted $args}}} \
            -onready      {apply {{resumed} {set ::_tready_resumed $resumed}}} \
            -onautherror  {apply {{message} {lappend ::_tauth_err $message}}} \
            -ondisconnect {apply {{message} {lappend ::_tdisconnect $message}}}
        c.sm configure -max-queue-size 5
    } \
    -cleanup {
        catch {c destroy}
        jlog configure -logproc ""
        rename baseconn mockbaseconn
        rename _real_baseconn baseconn
    } \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-overflow"
        # Send stanzas without any server ACKs until queue overflows
        set err ""
        for {set i 0} {$i < 6} {incr i} {
            if {[catch {c write [j message -to "friend@example.com" {j body -body "msg$i"}]} e]} {
                set err $e
                break
            }
        }
        # Error raised to caller, and autoreconnect triggers waiting state
        list $err [c state]
    } -result {{SM queue full} waiting}

test conn-sm-queue-overflow-during-flush {SM overflow during FlushWriteBuffer preserves stanzas and skips ready} \
    -setup {
        rename baseconn _real_baseconn
        rename mockbaseconn baseconn
        set _tready_resumed ""
        set _tauth_err {}
        set _tdisconnect {}
        set _temitted {}
        jlog configure -logproc {apply {{msg} {}}}
        conn c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res \
            -autoreconnect 1 \
            -emit         {apply {{args} {lappend ::_temitted $args}}} \
            -onready      {apply {{resumed} {set ::_tready_resumed $resumed}}} \
            -onautherror  {apply {{message} {lappend ::_tauth_err $message}}} \
            -ondisconnect {apply {{message} {lappend ::_tdisconnect $message}}}
        c.sm configure -max-queue-size 3
    } \
    -cleanup {
        catch {c destroy}
        jlog configure -logproc ""
        rename baseconn mockbaseconn
        rename _real_baseconn baseconn
    } \
    -body {
        c connect
        # Buffer 5 stanzas before ready (goes to writeBuffer)
        for {set i 0} {$i < 5} {incr i} {
            c write [j message -to "friend@example.com" {j body -body "buf$i"}]
        }
        # Drive to ready: FlushWriteBuffer will overflow at stanza 4
        drive_to_bind "user@test.example.com/r"
        c.base inject [make_sm_enabled "sm-flush-overflow"]
        # Should NOT have fired onready (overflow interrupted it)
        # and conn should be in waiting state (autoreconnect)
        list $_tready_resumed [c state]
    } -result {{} waiting}

# XEP-0198 5: a resume takes the place of binding. Bound first, a server
# refuses it (Prosody: "Tried to resume after resource binding").
test conn-sm-resume-replaces-bind {a reconnect with a stream to resume sends <resume/>, not a bind} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-order"
        drive_to_resume_attempt "user@test.example.com/r"
        set tags [lmap st [c.base get_written] {dict get $st tag}]
        list [lindex $tags end] [expr {"iq" in [lrange $tags end-1 end]}]
    } -result {resume 0}


# -- liveness -------------------------------------------------------------------

proc conn_wait {ms} {
    after $ms {set ::_conn_waited 1}
    vwait ::_conn_waited
}

test conn-keepalive-drops-a-silent-link {a link that answers nothing after a probe is dropped} \
    {*}$common \
    -body {
        c configure -keepalive 30 -keepalive-timeout 30
        c connect
        drive_to_ready "user@test.example.com/r" "sm-ka1"
        c.base clear
        conn_wait 120
        list [lmap st [c.base get_written] {dict get $st tag}] $_tdisconnect [c isReady]
    } -result {r {{no answer from the server}} 0}

test conn-keepalive-answer-keeps-the-link {an answer to the probe keeps the link up} \
    {*}$common \
    -body {
        c configure -keepalive 30 -keepalive-timeout 60
        c connect
        drive_to_ready "user@test.example.com/r" "sm-ka2"
        conn_wait 45
        c.base inject [make_sm_ack 0]
        conn_wait 40
        list $_tdisconnect [c isReady]
    } -result {{} 1}

test conn-keepalive-pings-without-sm {without stream management the probe is a ping} \
    {*}$common \
    -body {
        c configure -keepalive 30 -keepalive-timeout 1000
        c connect
        drive_to_bind_no_sm "user@test.example.com/r"
        c.base clear
        conn_wait 50
        set st [lindex [c.base get_written] 0]
        list [dict get $st tag] [xsearch $st ping -get ns]
    } -result {iq urn:xmpp:ping}

test conn-probe-drops-a-silent-link {an explicit probe that goes unanswered drops the link} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 0 -probe-timeout 30
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr1"
        conn_wait 40
        c.base clear
        c probe
        conn_wait 60
        list [lmap st [c.base get_written] {dict get $st tag}] $_tdisconnect [c isReady]
    } -result {r {{no answer from the server}} 0}

test conn-probe-skips-a-busy-link {a probe right after traffic sends nothing} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 0 -probe-timeout 1000
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr2"
        c.base clear
        c.base inject [make_sm_ack 0]
        c probe
        c.base get_written
    } -result {}

test conn-probe-opt-out {a disallowed probe sends nothing} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 0 -probe-timeout 30 \
            -probe-allowed-command {expr 0}
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr4"
        conn_wait 40
        c.base clear
        c probe
        c.base get_written
    } -result {}

test conn-wake-jump-probes {a wake tick arriving far too late probes the link} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 20 -probe-timeout 30
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr3"
        c.base clear
        after 150
        conn_wait 40
        lmap st [c.base get_written] {dict get $st tag}
    } -result {r}

test conn-probe-answered-keeps-the-link {an answered probe keeps the link and keepalive goes on} \
    {*}$common \
    -body {
        c configure -keepalive 100 -keepalive-timeout 1000 -wake-check 0 \
            -probe-timeout 30
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr5"
        conn_wait 40
        c probe
        c.base inject [make_sm_ack 0]
        conn_wait 60
        set ready [c isReady]
        c.base clear
        conn_wait 200
        list $_tdisconnect $ready [lmap st [c.base get_written] {dict get $st tag}]
    } -result {{} 1 r}

test conn-probe-once-while-pending {a probe while one is pending sends nothing more} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 0 -probe-timeout 30
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr6"
        conn_wait 40
        c.base clear
        c probe
        c probe
        lmap st [c.base get_written] {dict get $st tag}
    } -result {r}

test conn-wake-on-time-no-probe {wake ticks that arrive on time send nothing} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 20 -probe-timeout 1
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr7"
        c.base clear
        conn_wait 150
        c.base get_written
    } -result {}

test conn-wake-cuts-backoff {a wake while waiting to reconnect reconnects now} \
    {*}$common \
    -body {
        c configure -autoreconnect 1 -keepalive 0 -wake-check 20
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr9"
        c.base inject_error "read failed"
        set before [c state]
        # Simulated sleep, well within the 1 s backoff.
        after 150
        conn_wait 40
        list $before [c state]
    } -result {waiting authenticating}

test conn-wake-backoff-opt-out {with probing disallowed, a wake leaves the backoff alone} \
    {*}$common \
    -body {
        c configure -autoreconnect 1 -keepalive 0 -wake-check 20 \
            -probe-allowed-command {expr 0}
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr10"
        c.base inject_error "read failed"
        after 150
        conn_wait 40
        c state
    } -result {waiting}

test conn-probe-overdue-asks-again {a probe whose timeout fires far too late asks again rather than drop} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 0 -probe-timeout 20 \
            -keepalive-timeout 20
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr11"
        conn_wait 40
        c.base clear
        c probe
        # Block past the probe timeout, then deliver the answer.
        after 150
        conn_wait 5
        c.base inject [make_sm_ack 0]
        conn_wait 40
        list [lmap st [c.base get_written] {dict get $st tag}] $_tdisconnect [c isReady]
    } -result {{r r} {} 1}

test conn-wake-check-stops-when-not-ready {the wake check stops once the link leaves ready} \
    {*}$common \
    -body {
        c configure -keepalive 0 -wake-check 20
        c connect
        drive_to_ready "user@test.example.com/r" "sm-pr8"
        c connect
        conn_wait 60
        llength [lmap id [after info] {
            if {![string match *WakeTick* [lindex [after info $id] 0]]} continue
            set id
        }]
    } -result {0}
