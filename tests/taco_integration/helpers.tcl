package provide tacky::testhelpers::integration 0.1

# The wait helpers this file used to carry now live with every other way a
# test blocks, in tests/taco/wait.tcl (wait_var / wait_value / wait_events).
package require tacky::testwait
package require libtacky

# The integration tests build their environment with tacky_init rather than
# with tacky_env, so the extra taco_type options the fixture carries have to
# reach it here too. The wasm suite sets them to
# `-transport websocket -ws-url ...`, because a page has no socket and that is
# the only way it reaches a server; natively they are empty and this changes
# nothing.
if {![info exists ::tacky_test_taco_args]} {
    set ::tacky_test_taco_args {}
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
