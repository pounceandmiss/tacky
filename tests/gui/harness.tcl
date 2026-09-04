# Shared by the GUI tests that need a real backend behind the thing under
# test: an in-process account whose connection is the mock, so stanzas can be
# fed in and written ones inspected.
#
# The layering is tacky_env's (tests/taco/helpers.tcl). This file only
# evaluates the setup/cleanup bodies it generates, because the GUI tests
# compose the backend with widget construction inside their own -setup rather
# than splatting a {-setup ... -cleanup ...} pair into the test.
#
# Sourced before the test_*.tcl files (the runner globs *.tcl in sorted order),
# so every file below can call these.
package require tacky::mockconn
package require tacky::testhelpers

# Evaluate a tacky_env pair imperatively. Cleanups stack, so a nested up/down
# unwinds in the right order.
proc backend_up {env} {
    uplevel #0 [dict get $env -setup]
    lappend ::_backend_cleanups [dict get $env -cleanup]
}

proc backend_down {} {
    if {![info exists ::_backend_cleanups] || ![llength $::_backend_cleanups]} {
        return
    }
    set cleanup [lindex $::_backend_cleanups end]
    set ::_backend_cleanups [lrange $::_backend_cleanups 0 end-1]
    uplevel #0 $cleanup
}

# One account, bound and ready, with an avatarcache. The account's own
# bind/ready traffic is cleared, so a test's first get_written is the stanza it
# provoked.
proc mock_backend_up {{acc user@test.example.com}} {
    backend_up [tacky_env -mock conn \
        -account $acc \
        -bound-jid $acc/res1 \
        -avatarcache tk_avatarcache \
        -extra-setup {$::_client.conn clear}]
}

proc mock_backend_down {} {
    backend_down
}
