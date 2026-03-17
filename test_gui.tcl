#!/usr/bin/env wish9.0
# GUI tests — requires a display (Tk event loop).
# Usage: wish9.0 test_gui.tcl
proc bgerror {message} {
    puts stderr $::errorInfo
}
package require tcltest
package require control
package require snit
source tacky.tcl
source taco/jid.tcl
source taco/xsearch.tcl

foreach script [lsort [glob [file join ./ gui *.tcl]]] {
    source $script
}

# Bootstrap: create and destroy tacky so conn type is loaded
tacky_type create _bootstrap
_bootstrap destroy

source tests/taco/mock_conn.tcl

namespace import ::tcltest::*

# Helper: let the event loop run for $ms milliseconds.
proc wait {{ms 300}} {
    set ::_wait_done 0
    after $ms {set ::_wait_done 1}
    vwait ::_wait_done
}

foreach script [lsort [glob [file join ./ tests gui *.tcl]]] {
    source $script
}

cleanupTests
exit
