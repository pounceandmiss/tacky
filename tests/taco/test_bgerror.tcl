package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# taco_bg::report is what the daemon and the backend thread install as bgerror.
# Drive it directly: provoking a real background error would need a real bug.

proc _bgLogCapture {record} {
    lappend ::_bgLog $record
}

# Reporting from inside the log sink is the reentrant case.
proc _bgLogReenter {record} {
    lappend ::_bgLog $record
    set ::errorInfo reenter-trace
    ::taco_bg::report reenter
}

set bgenv [tacky_env -capture-emit 1 -extra-setup {
    set ::_bgLog {}
    set ::_bgSavedLogproc [jlog cget -logproc]
    jlog configure -logproc _bgLogCapture
    set ::taco_bg::lastEmit {}
    set ::taco_bg::reporting 0
} -extra-cleanup {
    jlog configure -logproc $::_bgSavedLogproc
    set ::taco_bg::lastEmit {}
    unset -nocomplain ::_bgLog ::_bgSavedLogproc
}]

test bgerror-logs-and-emits {a background error is logged and handed to the frontend} \
    {*}$bgenv -body {
        set ::errorInfo "boom\n    while executing"
        ::taco_bg::report boom
        set emit [lindex $::_emitted 0]
        set eargs [lrange $emit 2 end]
        list [llength $::_bgLog] [llength $::_emitted] \
            [lrange $emit 0 1] [dict get $eargs -message] \
            [string match "boom*while executing" [dict get $eargs -errorinfo]]
    } -result {1 1 {error <Background>} boom 1}

test bgerror-suppresses-a-repeat {a repeat is logged but not emitted twice} \
    {*}$bgenv -body {
        set ::errorInfo boom
        ::taco_bg::report boom
        ::taco_bg::report boom
        ::taco_bg::report other
        list [llength $::_bgLog] [llength $::_emitted]
    } -result {3 2}

test bgerror-does-not-recurse {a report raised while reporting is not re-entered} \
    {*}$bgenv -body {
        jlog configure -logproc _bgLogReenter
        set ::errorInfo boom
        ::taco_bg::report boom
        list [llength $::_bgLog] [llength $::_emitted]
    } -result {1 1}
