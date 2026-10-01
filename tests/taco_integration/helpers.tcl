package provide tacky::testhelpers::integration 0.1

# The wait helpers this file used to carry now live with every other way a
# test blocks, in tests/taco/wait.tcl (wait_var / wait_value / wait_events).
package require tacky::testwait
package require libtacky

# tacky_init doesn't go through tacky_env, so the fixture's extra taco
# options are applied here, and every `tacky account add` passes the extra
# account fields. Both are set by the wasm suite and empty natively.
if {![info exists ::tacky_test_taco_args]} {
    set ::tacky_test_taco_args {}
}
if {![info exists ::tacky_test_account_args]} {
    set ::tacky_test_account_args {}
}

# The build, as tcltest states a platform: see tests/taco/helpers.tcl. Set
# here too, because an integration test need not load that fixture.
::tcltest::testConstraint wasm [expr {$::tcl_platform(os) eq "Emscripten"}]

# The dockerized OMEMO peer. bot@example.local is registered by
# tests/servers/omemo-bot/with_bot.sh rather than by the harness USERS list,
# so a plain with_prosody.sh run has a server but no one to talk OMEMO to.
::tcltest::testConstraint omemoBot \
    [expr {[info exists ::env(OMEMO_BOT_JID)] && $::env(OMEMO_BOT_JID) ne ""}]
if {[llength [info commands ::tacky_init_plain]] == 0} {
    rename ::tacky_init ::tacky_init_plain
    proc ::tacky_init {args} {
        ::tacky_init_plain {*}$args {*}$::tacky_test_taco_args
    }
}

namespace eval ::test::helpers {}

# Displayed text of a derived message dict: the text body or a media caption.
# "" for a retracted tombstone, which carries no content.
proc ::test::helpers::msgText {msg} {
    if {![dict exists $msg content]} { return "" }
    set content [dict get $msg content]
    switch -- [dict get $content type] {
        media { return [dict get $content caption] }
        text  { return [dict get $content body] }
    }
    return ""
}
