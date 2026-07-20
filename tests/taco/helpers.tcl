# Shared test helpers for tacky dual-mode (direct + threaded) testing
package provide tacky::testhelpers 0.1
package require tcltest
package require libtacky
package require taco
package require tacky::mockconn

::tcltest::testConstraint hasThread [expr {
    ![catch {package require Thread}]
    && !([info exists ::env(NO_THREADED)] && $::env(NO_THREADED))
}]

::tcltest::testConstraint hasProcess [expr {
    !([info exists ::env(NO_PROCESS)] && $::env(NO_PROCESS))
}]

# Run a tacky command with -command callback, wait for result.
# Works with both tacky_type (synchronous) and tacky_threaded_type (async).
proc tacky_await {args} {
    set ::_await_done 0
    set ::_await_result {}
    {*}$args -command [list apply {{result} {
        set ::_await_result $result
        set ::_await_done 1
    }}]
    if {!$::_await_done} {
        vwait ::_await_done
    }
    return $::_await_result
}

# Run a tacky command that should error, wait for the -onerror callback.
proc tacky_await_error {args} {
    set ::_await_err_done 0
    set ::_await_err {}
    {*}$args \
        -command {apply {{result} {}}} \
        -onerror {apply {{msg} {
            set ::_await_err $msg
            set ::_await_err_done 1
        }}}
    if {!$::_await_err_done} {
        vwait ::_await_err_done
    }
    return $::_await_err
}

# Wait for the `error <MethodError>` event a failing call emits when it has a
# -command but no -onerror. tacky_await_error can't see this path: it supplies
# -onerror, which takes the error to the callback instead.
proc tacky_await_methoderror {args} {
    set ::_await_me_done 0
    set ::_await_me {}
    set tag [tacky listen error <MethodError> [list apply {{eargs} {
        set ::_await_me $eargs
        set ::_await_me_done 1
    }}]]
    {*}$args -command {apply {{result} {}}}
    if {!$::_await_me_done} {
        vwait ::_await_me_done
    }
    tacky unlisten $tag
    return $::_await_me
}

# Emit two test calls: direct/ and threaded/.
# Wraps caller's -setup/-cleanup with tacky create/destroy.
proc tacky_test {name desc args} {
    set user_setup {}
    set user_cleanup {}
    set rest {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        switch -- [lindex $args $i] {
            -setup   { set user_setup [lindex $args [incr i]] }
            -cleanup { set user_cleanup [lindex $args [incr i]] }
            default  { lappend rest [lindex $args $i] }
        }
    }
    foreach {mode create constraint} {
        direct   {tacky_type create tacky}          {}
        threaded {tacky_threaded_type create tacky}  hasThread
        process  {tacky_process_type create tacky}   hasProcess
    } {
        test $mode/$name $desc \
            -constraints $constraint \
            -setup "$create\n$user_setup" \
            -cleanup "$user_cleanup\ntacky destroy" \
            {*}$rest
    }
}

# tacky_env — returns {-setup body -cleanup body} for a tcltest test.
#
# Layers are applied bottom-up. Each layer's undo is pushed onto
# ::_tacky_env_stack only after its do succeeds, so a partial setup
# failure leaves only the completed layers' undos on the stack.
# Cleanup walks the stack in reverse with `catch` around each step.
#
# Layer order (bottom to top):
#   1. tacky          tacky_type create tacky                            (always)
#   2. emit override  stub or capture tacky.emit             (-stub-emit/-capture-emit)
#   3. mock factory   swap mock_conn into place                          (-mock)
#   4. client         either via -account or -taco-client
#   5. bound-jid      configure bound-jid + fire_ready on the client     (-bound-jid)
#   6. avatarcache    instantiate avatarcache from given class           (-avatarcache)
#   7. extra-setup    user script appended after all layers (no auto-undo)
#
# Options:
#   -mock {none|conn}             Default: none.
#   -stub-emit 0|1                Drop all emits.
#   -capture-emit 0|1             Append emits to ::_emitted (list of {module event args}).
#   -account JID                  `tacky account add -acc JID`; sets ::_client.
#   -taco-client {opts...}        `taco_client c {*}$opts`.
#   -bound-jid JID                After client creation, configure bound-jid + fire_ready.
#   -avatarcache CLASS            `CLASS create avatarcache`; teardown destroys it.
#   -extra-setup SCRIPT           Appended to setup body (no automatic undo).
#   -extra-cleanup SCRIPT         Runs before the layer-stack teardown.
#
# Mutually-exclusive pairs: -account/-taco-client, -stub-emit/-capture-emit.
proc tacky_env {args} {
    array set opts {
        -mock          none
        -stub-emit     0
        -capture-emit  0
        -account       ""
        -taco-client   ""
        -bound-jid     ""
        -avatarcache   ""
        -extra-setup   ""
        -extra-cleanup ""
    }
    array set opts $args

    if {$opts(-account) ne "" && $opts(-taco-client) ne ""} {
        error "tacky_env: -account and -taco-client are mutually exclusive"
    }
    if {$opts(-stub-emit) && $opts(-capture-emit)} {
        error "tacky_env: -stub-emit and -capture-emit are mutually exclusive"
    }
    if {$opts(-mock) ni {none conn}} {
        error "tacky_env -mock: expected {none|conn}, got $opts(-mock)"
    }
    if {$opts(-bound-jid) ne "" && $opts(-account) eq "" && $opts(-taco-client) eq ""} {
        error "tacky_env: -bound-jid requires -account or -taco-client"
    }

    # Each layer is {do undo}. Empty undo = no separate teardown.
    set layers {}

    # Qualify with :: so the instance is always created at global scope.
    # Without this, when tcltest runs the setup body in a test's
    # namespace (e.g. ::test::omemo_int), oo creates the instance there
    # and downstream snit code that hard-references "tacky" fails.
    lappend layers [list {tacky_type create ::tacky} {tacky destroy}]

    if {$opts(-stub-emit)} {
        lappend layers [list \
            {oo::objdefine tacky method emit {module event args} {}} \
            {}]
    } elseif {$opts(-capture-emit)} {
        lappend layers [list {
            set ::_emitted {}
            oo::objdefine tacky method emit {module event args} {
                lappend ::_emitted [list $module $event {*}$args]
            }
        } {unset -nocomplain ::_emitted}]
    }

    switch -- $opts(-mock) {
        conn {
            lappend layers [list {
                rename conn _real_conn
                rename mock_conn conn
            } {
                rename conn mock_conn
                rename _real_conn conn
            }]
        }
    }

    set clientRef ""
    if {$opts(-account) ne ""} {
        set acc $opts(-account)
        set clientRef {$::_client}
        lappend layers [list [subst -nocommands {
            tacky account add -acc $acc
            set ::_client [tacky client $acc]
        }] {unset -nocomplain ::_client}]
    } elseif {$opts(-taco-client) ne ""} {
        set clientRef c
        lappend layers [list \
            [list taco_client c {*}$opts(-taco-client)] \
            {c destroy}]
    }

    if {$opts(-bound-jid) ne ""} {
        set bj $opts(-bound-jid)
        lappend layers [list "$clientRef.conn configure -bound-jid $bj
$clientRef.conn fire_ready 0" {}]
    }

    if {$opts(-avatarcache) ne ""} {
        set ac $opts(-avatarcache)
        lappend layers [list "$ac create avatarcache" {avatarcache destroy}]
    }

    if {$opts(-extra-setup) ne ""} {
        lappend layers [list $opts(-extra-setup) {}]
    }

    set setupBody "set ::_tacky_env_stack {}\n"
    foreach layer $layers {
        lassign $layer do undo
        append setupBody $do \n
        if {$undo ne ""} {
            append setupBody "lappend ::_tacky_env_stack " [list $undo] \n
        }
    }

    set cleanupBody ""
    if {$opts(-extra-cleanup) ne ""} {
        append cleanupBody $opts(-extra-cleanup) \n
    }
    append cleanupBody {
        if {[info exists ::_tacky_env_stack]} {
            try {
                foreach _u [lreverse $::_tacky_env_stack] {
                    eval $_u
                }
            } finally {
                unset ::_tacky_env_stack
            }
        }
    }

    return [list -setup $setupBody -cleanup $cleanupBody]
}
