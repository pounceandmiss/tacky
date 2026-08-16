package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# -- level resolution ------------------------------------------------------
#
# On a private instance: these move levels around, and the singleton is what
# the rest of the suite logs through.

proc jlog_probe {} {
    jlog_type create jprobe -defaultlevel warning \
        -logproc {apply {{opts} {lappend ::jlog_seen $opts}}}
    set ::jlog_seen {}
}

set probe {
    -setup {jlog_probe}
    -cleanup {jprobe destroy; unset -nocomplain ::jlog_seen}
}

test jlog-inherit-after-child-logged {a parent level reaches a child that already logged} \
    {*}$probe -body {
        # Resolve the child before the parent moves.
        jprobe getLevel ::a.b
        jprobe setLevel ::a debug
        jprobe getLevel ::a.b
    } -result debug

test jlog-explicit-child-wins {an explicit child level survives a parent change} \
    {*}$probe -body {
        jprobe setLevel ::a.b error
        jprobe setLevel ::a debug
        jprobe getLevel ::a.b
    } -result error

test jlog-normalizes-both-ways {setLevel on a bare name reaches a bare child} \
    {*}$probe -body {
        jprobe setLevel gui verbose
        list [jprobe getLevel gui.chatarea] [jprobe getLevel ::gui.chatarea]
    } -result {verbose verbose}

test jlog-defaultlevel-applies-late {changing -defaultlevel reaches objects that already logged} \
    {*}$probe -body {
        jprobe getLevel ::a.b
        jprobe configure -defaultlevel verbose
        jprobe getLevel ::a.b
    } -result verbose

# -- write -----------------------------------------------------------------

test jlog-write-rejects-unknown-level {write rejects a level outside the vocabulary} \
    {*}$probe -body {
        jprobe write -level chatty -text hi
    } -returnCodes error -match glob -result {unknown log level "chatty"*}

test jlog-write-none-is-silent {write drops a record at the silence threshold} \
    {*}$probe -body {
        jprobe setLevel frontend verbose
        jprobe write -level none -text hi
        llength $::jlog_seen
    } -result 0

test jlog-write-defaults-obj {write without -obj does not guess from the calling frame} \
    {*}$probe -body {
        jprobe setLevel frontend debug
        jprobe write -level debug -text hi
        dict get [lindex $::jlog_seen 0] -obj
    } -result frontend

# -- line format -----------------------------------------------------------

test jlog-format-timestamp-and-acc {a line carries date, milliseconds and the account} \
    {*}$probe -body {
        jprobe FormatLine {-level error -text boom -obj ::c -acc user@example.com}
    } -match regexp \
      -result {^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} error\] user@example\.com ::c: boom$}

test jlog-format-omits-empty-acc {an accountless line has no stray separator} \
    {*}$probe -body {
        string match {*] ::c: boom} [jprobe FormatLine {-level error -text boom -obj ::c}]
    } -result 1

# -- writer robustness -----------------------------------------------------

test jlog-file-failure-does-not-throw {an unwritable log file never throws into the caller} \
    {*}$probe -body {
        # A path under a plain file cannot be opened, on any platform.
        set blocker [makeFile {} jlog-blocker]
        jprobe fileWriter [file join $blocker nested.log] {-level error -text boom -obj ::c}
        return reached
    } -cleanup {
        removeFile jlog-blocker
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result reached

# -- the log module over each transport ------------------------------------

tacky_test log-getlevel-default {getlevel with no -obj reports the default level} \
    -body {
        tacky_await tacky log getlevel
    } -result warning

tacky_test log-setlevel-roundtrip {a level set for an object reads back for its children} \
    -body {
        tacky log setlevel -obj ::probe -level verbose
        list [tacky_await tacky log getlevel -obj ::probe] \
             [tacky_await tacky log getlevel -obj ::probe.child]
    } -result {verbose verbose}

tacky_test log-setlevel-rejects-unknown {a bad level reaches -onerror across the wire} \
    -body {
        tacky_await_error tacky log setlevel -obj ::probe -level chatty
    } -match glob -result {unknown log level "chatty"*}

tacky_test log-write-sugar {the level-first sugar reaches write across the wire} \
    -body {
        # Silenced first, so the record never reaches the suite's own output.
        tacky log setlevel -obj gui.testcase -level none
        tacky log warning "quiet please" -obj gui.testcase
        return reached
    } -result reached

# getlevel hands out "none" and setlevel takes it, so a caller piping a
# configured level into write will sooner or later pass it one.
tacky_test log-write-takes-a-level-from-getlevel {writing at a level the API returned does not throw} \
    -body {
        tacky log setlevel -obj gui.testcase -level none
        tacky log [tacky_await tacky log getlevel -obj gui.testcase] \
            "goes nowhere" -obj gui.testcase
        return reached
    } -result reached
