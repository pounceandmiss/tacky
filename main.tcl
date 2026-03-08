#!/usr/bin/env tclsh9.0
package require Tk
package require snit

proc bgerror {message} {
    puts stderr $::errorInfo
}

source tacky.tcl

foreach script [lsort [glob [file join ./ gui *.tcl]]] {
    source $script
}

app_type app {*}$argv
