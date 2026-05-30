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

# Keep the test window above others and mapped. Tests measure real geometry
# (bbox, count -ypixels, winfo height); if the toplevel is obscured or not
# fully mapped those return stale/zero values, which makes layout-sensitive
# tests (history pagination, viewport stability) flaky.
wm attributes . -topmost 1
raise .
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
