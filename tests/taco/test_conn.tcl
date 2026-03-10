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

    method socket {} {
        return ""
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
            j mechanism #body PLAIN
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
            j jid #body $jid
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

proc make_sm_enabled {id} {
    j enabled -ns urn:xmpp:sm:3 -id $id
}

proc make_sm_resumed {previd h} {
    j resumed -ns urn:xmpp:sm:3 -previd $previd -h $h
}

proc make_sm_failed {} {
    j failed -ns urn:xmpp:sm:3
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
    } -result {{SASL authentication failed} disconnected}

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
        c.base inject [make_bind_result "user@test.example.com/r"]
        c.base inject [make_sm_resumed "sm-456" 0]
        set _tready_resumed
    } -result {1}

# -- Write buffering -------------------------------------------------------

test conn-write-before-ready-buffers {stanzas before ready are buffered} \
    {*}$common \
    -body {
        c connect
        set msg [j message -to "friend@example.com" {j body #body "hello"}]
        c write $msg
        llength [c.base get_written]
    } -result 0

test conn-write-after-ready-sends {stanzas after ready go through SM} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-789"
        c.base clear
        set msg [j message -to "friend@example.com" {j body #body "hello"}]
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

test conn-emit-ready-event {-emit receives Ready event with resumed flag} \
    {*}$common \
    -body {
        c connect
        drive_to_ready "user@test.example.com/r" "sm-emit2"
        extract_emitted "<Ready>" -resumed
    } -result {0}

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
    } -result {{SASL authentication failed}}

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
        set msg [j message -to "friend@example.com" {j body #body "queued"}]
        c write $msg
        c.base clear
        # SM failed -> falls back to passthrough and flushes queue
        c.base inject [make_sm_failed]
        dict get [lindex [c.base get_written] 0] tag
    } -result {message}

test conn-write-buffer-flushed-after-ready {write buffer flushed when conn reaches ready} \
    {*}$common \
    -body {
        c connect
        set msg [j message -to "friend@example.com" {j body #body "early"}]
        c write $msg
        c.base clear
        drive_to_ready "user@test.example.com/r" "sm-flush1"
        dict get [lindex [c.base get_written] end] tag
    } -result {message}

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
            if {[catch {c write [j message -to "friend@example.com" {j body #body "msg$i"}]} e]} {
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
            c write [j message -to "friend@example.com" {j body #body "buf$i"}]
        }
        # Drive to ready — FlushWriteBuffer will overflow at stanza 4
        drive_to_bind "user@test.example.com/r"
        c.base inject [make_sm_enabled "sm-flush-overflow"]
        # Should NOT have fired onready (overflow interrupted it)
        # and conn should be in waiting state (autoreconnect)
        list $_tready_resumed [c state]
    } -result {{} waiting}
