#!/usr/bin/env wish9.0
# GUI tests — requires a display (Tk event loop).
# Usage: wish9.0 test_gui.tcl
proc bgerror {message} {
    puts stderr $::errorInfo
}
package require tcltest
namespace import ::tcltest::*

set dir [file dirname [info script]]
lappend auto_path \
    [file join $dir lib] \
    [file join $dir tests taco]

# Match production load order from bin/tacky.tcl so gui/*.tcl can be sourced.
package require Tk
ttk::style theme use clam
package require snit
package require libtacky
package require taco

foreach script [lsort [glob [file join $dir gui *.tcl]]] {
    source $script
}

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
