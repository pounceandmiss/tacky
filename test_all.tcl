#!/usr/bin/env tclsh9.0
# Usage: tclsh9.0 test_all.tcl
#   NO_THREADED=1  - skip threaded (tacky_threaded_type) tests
#   NO_PROCESS=1   - skip process (tacky_process_type) tests
#   XMPP_SERVER=x  - run integration tests (natively also requires SPOOF_SSL_CERT)
#   TACKY_TEST_DIRS            - directories under tests/ to run (default: taco
#                                and tackyd-json, after taco_integration with
#                                a server)
#   TACKY_TEST_FILE, TACKY_TEST_MATCH - only these files, tests (glob)
#   TACKY_TEST_TACO_ARGS, TACKY_TEST_ACCOUNT_ARGS, TACKY_TEST_HTTP_BASE -
#                                see tests/taco/helpers.tcl
#
# The browser runs this too, in the interpreter `make wasm-tcltest` builds
# (wasm/test/tcl-suite.js). There it returns 1 if anything failed; natively
# that is the exit code.
package require tcltest
namespace import ::tcltest::*

set dir [file dirname [file normalize [info script]]]
lappend auto_path \
    [file join $dir lib] \
    [file join $dir tests taco] \
    [file join $dir tests taco_integration]

proc envOr {name default} {
    expr {[info exists ::env($name)] ? $::env($name) : $default}
}
set wasm [expr {$::tcl_platform(os) eq "Emscripten"}]
set server [envOr XMPP_SERVER ""]

if {$server ne "" && !$wasm && ![info exists ::env(SPOOF_SSL_CERT)]} {
    error "XMPP_SERVER is set but SPOOF_SSL_CERT is not. Both are required for server tests."
}
testConstraint withServer [expr {$server ne ""}]
foreach {c name} {notProsody prosody notMongoose mongoose notEjabberd ejabberd} {
    testConstraint $c [expr {$server ne $name}]
}
foreach {var name} {
    tacky_test_taco_args    TACKY_TEST_TACO_ARGS
    tacky_test_account_args TACKY_TEST_ACCOUNT_ARGS
    tacky_test_http_base    TACKY_TEST_HTTP_BASE
} {
    if {[info exists ::env($name)]} { set ::$var $::env($name) }
}

set options {}
if {$wasm} {
    # Emscripten's stdout translates to CRLF.
    fconfigure stdout -translation lf
    fconfigure stderr -translation lf
    # The bundle is read-only. And a test that makes a directory and then
    # names a file in it relatively looks in the working directory.
    file mkdir /tmp/tcltest
    cd /tmp/tcltest
    set options {-tmpdir /tmp/tcltest -verbose {body error}}
}

# runAllTests sources the test files in its caller's frame, which here is
# the global one, where they expect to be and where they cannot reach the
# loop's variables.
proc runDirs {root dirs options} {
    set failed 0
    foreach d $dirs {
        configure -testdir [file join $root tests $d] -singleproc 1 \
            -file [envOr TACKY_TEST_FILE test_*.tcl] \
            -match [envOr TACKY_TEST_MATCH *] {*}$options
        if {[uplevel #0 runAllTests]} { set failed 1 }
    }
    return $failed
}
set failed [runDirs $dir [envOr TACKY_TEST_DIRS \
    [concat [expr {$server ne "" ? "taco_integration" : ""}] taco tackyd-json]] \
    $options]

if {$wasm} { return $failed }
exit $failed
