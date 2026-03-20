#!/usr/bin/env wish9.0
# GUI tests — requires a display (Tk event loop).
# Usage: wish9.0 test_gui.tcl
proc bgerror {message} {
    puts stderr $::errorInfo
}
package require tcltest
package require control
package require snit
set dir [file dirname [info script]]
lappend auto_path [file join $dir libtacky]
package require libtacky

foreach script [lsort [glob [file join $dir gui *.tcl]]] {
    source $script
}

# Bootstrap: create and destroy tacky so conn type is loaded
tacky_type create _bootstrap
_bootstrap destroy

source [file join $dir tests taco mock_conn.tcl]

namespace import ::tcltest::*

# Helper: let the event loop run for $ms milliseconds.
proc wait {{ms 300}} {
    set ::_wait_done 0
    after $ms {set ::_wait_done 1}
    vwait ::_wait_done
}

foreach script [lsort [glob [file join $dir tests gui *.tcl]]] {
    source $script
}

cleanupTests
exit
