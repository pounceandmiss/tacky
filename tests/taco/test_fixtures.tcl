# Tests for the test fixtures themselves — the parts that carry logic of their
# own rather than just wiring: the wait timeouts, the mode guard, the mock
# install pair, and tacky_env's layer teardown.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::testwait

# -- wait_var ---------------------------------------------------------------

test wait-var-already-truthy {a truthy variable returns without entering the loop} -body {
    set ::wv_done 1
    wait_var ::wv_done
} -cleanup {unset ::wv_done} -result {}

test wait-var-waits {a variable set from the event loop ends the wait} -setup {
    set ::wv_done 0
    after 20 {set ::wv_done 1}
} -body {
    wait_var ::wv_done 2000
    set ::wv_done
} -cleanup {unset ::wv_done} -result 1

# The old waitVar returned on the first write of any value, so a variable that
# went 0 -> 1 through an intermediate 0 could let a test run on early.
test wait-var-ignores-falsy-write {a falsy write does not end the wait} -setup {
    set ::wv_done 0
    after 10 {set ::wv_done 0}
    after 30 {set ::wv_done ready}
} -body {
    wait_var ::wv_done 2000
    set ::wv_done
} -cleanup {unset ::wv_done} -result ready

test wait-var-timeout-names-the-variable {a timeout says what it waited for} -setup {
    set ::wv_done 0
} -body {
    wait_var ::wv_done 50
} -cleanup {unset ::wv_done} -returnCodes error \
  -result {timeout after 50ms waiting for ::wv_done}

# -- wait_value -------------------------------------------------------------

test wait-value-already-equal {an equal variable returns immediately} -body {
    set ::wv_state connected
    wait_value ::wv_state connected
} -cleanup {unset ::wv_state} -result {}

test wait-value-waits-for-the-value {intermediate values are passed over} -setup {
    set ::wv_state disconnected
    after 10 {set ::wv_state connecting}
    after 30 {set ::wv_state connected}
} -body {
    wait_value ::wv_state connected 2000
    set ::wv_state
} -cleanup {unset ::wv_state} -result connected

test wait-value-timeout-names-the-value {a timeout quotes the value wanted} -setup {
    set ::wv_state disconnected
} -body {
    wait_value ::wv_state connected 50
} -cleanup {unset ::wv_state} -returnCodes error \
  -result {timeout after 50ms waiting for ::wv_state to become "connected"}

test wait-value-removes-its-trace {the write trace does not outlive the wait} -setup {
    set ::wv_state disconnected
    after 10 {set ::wv_state connected}
} -body {
    wait_value ::wv_state connected 2000
    trace info variable ::wv_state
} -cleanup {unset ::wv_state} -result {}

# Nested waits used to share one done flag, so the inner one satisfied the
# outer. Each wait now takes a flag of its own.
test wait-nested-do-not-share-a-flag {an inner wait does not release the outer} -setup {
    set ::wv_outer 0
    set ::wv_inner 0
    after 10 {set ::wv_inner 1}
    after 40 {set ::wv_outer 1}
} -body {
    wait_var ::wv_inner 2000
    wait_var ::wv_outer 2000
    list inner $::wv_inner outer $::wv_outer
} -cleanup {unset ::wv_outer ::wv_inner} -result {inner 1 outer 1}

# -- wait_events ------------------------------------------------------------

test wait-events-empty-returns {no specs is not a 10s stall} -body {
    wait_events {}
} -result {}

tacky_test wait-events-counts-each-spec {one arrival per spec ends the wait} \
    -modes direct -body {
        after 10 {tacky account add -acc a@example.com}
        wait_events {{account <Added>}} 2000
        wait_call tacky account list
    } -result a@example.com

tacky_test wait-events-unlistens-its-tag {the wait leaves no listener behind} \
    -modes direct -body {
        after 10 {tacky account add -acc a@example.com}
        wait_events {{account <Added>}} 2000
        # A second add must not re-enter a stale callback.
        tacky account add -acc b@example.com
        lsort [wait_call tacky account list]
    } -result {a@example.com b@example.com}

# -- tacky_env mode guard ---------------------------------------------------

test env-rejects-unknown-mode {an unknown front end is refused} -body {
    tacky_env -mode bogus
} -returnCodes error -match glob -result {tacky_env -mode: expected one of *}

test env-mock-needs-direct {a conn swap is refused for an out-of-process tacky} -body {
    tacky_env -mode threaded -mock conn
} -returnCodes error -match glob \
  -result {tacky_env: -mock needs -mode direct*another interpreter*}

test env-account-needs-direct {so is an in-process client} -body {
    tacky_env -mode process -account u@example.com
} -returnCodes error -match glob -result {tacky_env: -account needs -mode direct*}

test test-rejects-unknown-mode {tacky_test validates -modes} -body {
    tacky_test x {} -modes bogus -body {}
} -returnCodes error -match glob -result {tacky_test -modes: unknown mode "bogus"*}

test test-redirects-extra-setup {-extra-setup is spelled -setup here} -body {
    tacky_test x {} -extra-setup {} -body {}
} -returnCodes error -result {tacky_test: use -setup/-cleanup, not -extra-setup}

# -- mockconn install/uninstall --------------------------------------------

test mockconn-install-swaps-and-restores {install/uninstall are a matched pair} -body {
    set before [info commands ::conn]
    mockconn::install
    set swapped [list mocked [expr {[info commands ::conn__real] ne ""}] \
                      gone [expr {[info commands ::mock_conn] eq ""}]]
    mockconn::uninstall
    lappend swapped restored [expr {[info commands ::conn] eq $before}] \
                    real-gone [expr {[info commands ::conn__real] eq ""}]
} -result {mocked 1 gone 1 restored 1 real-gone 1}

# The unqualified rename dance this replaced errored on the second install.
test mockconn-install-is-idempotent {a nested install is a no-op, not an error} -body {
    mockconn::install
    mockconn::install
    mockconn::uninstall
    expr {[info commands ::conn__real] eq "" && [info commands ::mock_conn] ne ""}
} -cleanup {mockconn::uninstall} -result 1

test mockconn-uninstall-without-install {uninstalling twice is harmless} -body {
    mockconn::uninstall
    mockconn::uninstall
} -result {}

# -- tacky_env teardown -----------------------------------------------------

test env-teardown-unwinds-every-layer {a mock does not outlive its test} -body {
    set spec [tacky_env -mock conn -account u@example.com]
    eval [dict get $spec -setup]
    set inside [expr {[info commands ::conn__real] ne ""}]
    eval [dict get $spec -cleanup]
    list inside $inside \
         after [expr {[info commands ::conn__real] eq ""}] \
         tacky [expr {[info commands ::tacky] eq ""}]
} -result {inside 1 after 1 tacky 1}

# A failing undo used to abandon the rest of the stack, leaving the mock
# installed for every later test in the file.
test env-teardown-continues-past-a-failure {one bad undo does not strand the rest} -body {
    set spec [tacky_env -mock conn -extra-cleanup {error "boom"}]
    eval [dict get $spec -setup]
    set err [catch {eval [dict get $spec -cleanup]} msg]
    list raised $err \
         mock-gone [expr {[info commands ::conn__real] eq ""}] \
         tacky-gone [expr {[info commands ::tacky] eq ""}]
} -result {raised 1 mock-gone 1 tacky-gone 1}

test env-teardown-reports-what-failed {the swallowed error is re-raised} -body {
    set spec [tacky_env -extra-cleanup {error "boom"}]
    eval [dict get $spec -setup]
    catch {eval [dict get $spec -cleanup]} msg
    set msg
} -match glob -result {*boom*}
