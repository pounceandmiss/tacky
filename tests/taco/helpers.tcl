# The tacky test fixture: the three interchangeable front ends, and the
# layered environment (mock conn, client, avatarcache) a test runs against.
# Ways of blocking on the event loop live in wait.tcl.
package provide tacky::testhelpers 0.1
package require tcltest
package require libtacky
package require taco
package require tacky::mockconn
package require tacky::testwait

::tcltest::testConstraint hasThread [expr {
    ![catch {package require Thread}]
    && !([info exists ::env(NO_THREADED)] && $::env(NO_THREADED))
}]

::tcltest::testConstraint hasProcess [expr {
    !([info exists ::env(NO_PROCESS)] && $::env(NO_PROCESS))
}]

# The three interchangeable tacky front ends: the type that creates one, and
# the constraint gating it. tacky_env builds a single mode; tacky_test fans a
# test out over all of them.
proc tacky_modes {} {
    return {
        direct   {tacky_type          {}}
        threaded {tacky_threaded_type hasThread}
        process  {tacky_process_type  hasProcess}
    }
}

# Emit one test per mode, each constrained to its front end.
#
# Takes tacky_env's options plus -modes, and builds each test's environment
# with tacky_env, so the two fixtures no longer each create `tacky` their own
# way. A test can now fan out over the front ends and take a captured emit
# stream, or narrow itself to one front end with -modes.
#
# -mock and -account stay direct-only, and tacky_env says so: the threaded and
# process front ends hold the client in another interpreter. Pair them with
# -modes direct.
#
# The caller's -setup/-cleanup become the env's extra layers: setup runs after
# every layer is up, cleanup before any is torn down. Same order as before.
proc tacky_test {name desc args} {
    set modes [dict keys [tacky_modes]]
    set user_setup {}
    set user_cleanup {}
    set user_constraints {}
    set env_opts {}
    set rest {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set opt [lindex $args $i]
        switch -- $opt {
            -modes       { set modes [lindex $args [incr i]] }
            -setup       { set user_setup [lindex $args [incr i]] }
            -cleanup     { set user_cleanup [lindex $args [incr i]] }
            -constraints { set user_constraints [lindex $args [incr i]] }
            -extra-setup - -extra-cleanup {
                error "tacky_test: use -setup/-cleanup, not $opt"
            }
            -mock - -stub-emit - -capture-emit - -account - -taco-client -
            -bound-jid - -avatarcache {
                lappend env_opts $opt [lindex $args [incr i]]
            }
            default { lappend rest $opt }
        }
    }
    foreach mode $modes {
        if {![dict exists [tacky_modes] $mode]} {
            error "tacky_test -modes: unknown mode \"$mode\",\
                expected one of [dict keys [tacky_modes]]"
        }
        lassign [dict get [tacky_modes] $mode] _type constraint
        test $mode/$name $desc \
            -constraints [concat $user_constraints $constraint] \
            {*}[tacky_env -mode $mode {*}$env_opts \
                -extra-setup $user_setup -extra-cleanup $user_cleanup] \
            {*}$rest
    }
}

# tacky_env — returns {-setup body -cleanup body} for a tcltest test.
#
# Layers are applied bottom-up. Each layer's undo is pushed onto
# ::_tacky_env_stack only after its do succeeds, so a partial setup
# failure leaves only the completed layers' undos on the stack.
# Cleanup walks the stack in reverse with `catch` around each step, so one
# failing undo cannot strand the rest (a mock left installed would follow the
# test into every later one in the file). Anything caught is re-raised at the
# end, as one error, once the stack is unwound.
#
# Layer order (bottom to top):
#   1. tacky          <mode's type> create ::tacky                       (always)
#   2. emit override  stub or capture tacky.emit             (-stub-emit/-capture-emit)
#   3. mock factory   swap mock_conn into place                          (-mock)
#   4. client         either via -account or -taco-client
#   5. bound-jid      configure bound-jid + fire_ready on the client     (-bound-jid)
#   6. avatarcache    instantiate avatarcache from given class           (-avatarcache)
#   7. extra-setup    user script appended after all layers (no auto-undo)
#
# Options:
#   -mode {direct|threaded|process}  Which tacky front end. Default: direct.
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
        -mode          direct
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
    if {![dict exists [tacky_modes] $opts(-mode)]} {
        error "tacky_env -mode: expected one of [dict keys [tacky_modes]],\
            got $opts(-mode)"
    }
    # The threaded and process front ends keep the client in another
    # interpreter: there `tacky client` returns nothing, and a conn swapped in
    # this one is never consulted. Both layers would come up quietly and then
    # fail somewhere less obvious, so refuse the combination here.
    if {$opts(-mode) ne "direct"} {
        foreach {opt val unset_val} [list \
            -mock    $opts(-mock)    none \
            -account $opts(-account) ""] {
            if {$val eq $unset_val} continue
            error "tacky_env: $opt needs -mode direct, got $opts(-mode) — the\
                $opts(-mode) front end keeps the client in another\
                interpreter, where an in-process client or conn swap is\
                invisible. From tacky_test, add -modes direct."
        }
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
    lassign [dict get [tacky_modes] $opts(-mode)] modeType
    lappend layers [list [list $modeType create ::tacky] {tacky destroy}]

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
            lappend layers [list {mockconn::install} {mockconn::uninstall}]
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

    # -extra-cleanup is caught for the same reason the undos are: raising here
    # would return before the layer stack unwound, and a mock left installed
    # follows the test into every later one in the file. Errors from either are
    # collected and re-raised together once everything is down.
    set cleanupBody "set _errs {}\n"
    if {$opts(-extra-cleanup) ne ""} {
        append cleanupBody "if {\[catch {\n" $opts(-extra-cleanup) \
            "\n} _e]} { lappend _errs \$_e }\n"
    }
    append cleanupBody {
        if {[info exists ::_tacky_env_stack]} {
            try {
                foreach _u [lreverse $::_tacky_env_stack] {
                    if {[catch {eval $_u} _e]} { lappend _errs $_e }
                }
            } finally {
                unset ::_tacky_env_stack
                unset -nocomplain _u _e
            }
        }
        if {[llength $_errs]} {
            set _msg "tacky_env cleanup: [join $_errs {; }]"
            unset _errs
            error $_msg
        }
        unset _errs
    }

    return [list -setup $setupBody -cleanup $cleanupBody]
}
