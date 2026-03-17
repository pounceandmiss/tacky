#!/usr/bin/env tclsh9.0

if {"-h" in $argv || "--help" in $argv || "-help" in $argv} {
    puts "Usage: tacky \[options\]

Options:
  --debug-dir DIR   Write per-account debug logs to DIR
  --backend MODE    Backend mode: direct (default), thread, process
  --transient yes   Work purely in RAM - don't read/write settings/cache
  -h, --help        Display this help text and exit"
    exit 0
}

# Normalize --foo to -foo for snit
set argv [lmap arg $argv {
    if {[string match --* $arg]} {
        string range $arg 1 end
    } else {
        set arg
    }
}]

package require Tk
package require snit

proc bgerror {message} {
    puts stderr $::errorInfo
}

source tacky.tcl
source taco/jid.tcl
source taco/xsearch.tcl

foreach script [lsort [glob [file join ./ gui *.tcl]]] {
    source $script
}

app_type app {*}$argv
