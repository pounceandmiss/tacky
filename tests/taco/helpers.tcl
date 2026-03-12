# Shared test helpers for tacky dual-mode (direct + threaded) testing

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

# Run a tacky command that should error, wait for the MethodError event.
proc tacky_await_error {args} {
    set ::_await_err_done 0
    set ::_await_err {}
    set tag [tacky listen error <MethodError> {apply {{ev} {
        set ::_await_err [dict get $ev -message]
        set ::_await_err_done 1
    }}}]
    {*}$args -command {apply {{result} {}}}
    if {!$::_await_err_done} {
        vwait ::_await_err_done
    }
    tacky unlisten $tag
    return $::_await_err
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
