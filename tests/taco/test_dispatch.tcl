package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# A throwing frontend callback must cost only itself, and still be reported.

proc _dspSetup {} {
    if {[info commands bgerror] ne ""} {
        rename bgerror _dspSavedBgerror
    }
    proc bgerror {msg} {
        lappend ::_dspBg $msg
        set ::_dspBgDone 1
    }
    set ::_dspBg {}
    set ::_dspBgDone 0
    set ::_dspRan {}
}

proc _dspCleanup {} {
    rename bgerror {}
    if {[info commands _dspSavedBgerror] ne ""} {
        rename _dspSavedBgerror bgerror
    }
}

# The report lands in an idle handler. Bounded, so a regression fails the test
# instead of hanging the suite.
proc _dspWaitBg {} {
    if {$::_dspBgDone} return
    set timer [after 2000 {set ::_dspBgDone timeout}]
    vwait ::_dspBgDone
    after cancel $timer
}

tacky_test dispatch-listener-error-isolated \
    {a throwing listener costs itself, not the listeners behind it} \
    -setup _dspSetup -cleanup _dspCleanup -body {
        tacky listen account <Added> {apply {{eargs} {error "listener blew up"}}}
        tacky listen account <Added> {apply {{eargs} {lappend ::_dspRan second}}}
        tacky account add -acc user@example.com
        _dspWaitBg
        list $::_dspRan [llength $::_dspBg]
    } -result {second 1}

tacky_test dispatch-callback-error-not-a-method-error \
    {a throwing -command is not reported back as the method failing} \
    -setup _dspSetup -cleanup _dspCleanup -body {
        tacky account list \
            -command {apply {{result} {error "callback blew up"}}} \
            -onerror {apply {{msg} {lappend ::_dspRan onerror}}}
        _dspWaitBg
        list $::_dspRan [llength $::_dspBg]
    } -result {{} 1}
