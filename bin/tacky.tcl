#!/usr/bin/env tclsh9.0

if {"-h" in $argv || "--help" in $argv || "-help" in $argv} {
    puts "Usage: tacky \[options\]

Options:
  --backend MODE      Backend mode: direct (default), thread, process
  --tackyd PATH       Path to the tackyd backend binary (process mode only)
  --transient yes     Keep every database in RAM; don't touch stored data
  --console 1|0       Print background errors to stderr instead of a dialog
  --debug-level LVL   jlog verbosity (default: warning)
  --debug-file PATH   Write all logs to PATH instead of stderr
  --libdatachannel-debug-level LVL
                      libdatachannel native log level (default: none)
  --rtcma-debug-level LVL
                      rtc-ma native log level (default: none)
  -h, --help          Display this help text and exit

Log levels: verbose, debug, info, warning, error, fatal, none"
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

# --console is handled here, not by the snit object; strip its pair from argv
set consoleErrors 0
set idx [lsearch -exact $argv -console]
if {$idx >= 0} {
    set consoleErrors [lindex $argv $idx+1]
    set argv [lreplace $argv $idx $idx+1]
}

package require Tk
ttk::style theme use clam
package require snit
package require tkwuffs
package require tkdnd

proc bgerror {message} {
    # Snapshot first: the catch below overwrites ::errorInfo, which would
    # report the wrong trace.
    set info $::errorInfo
    # Through the API, not a local jlog: in process mode the backend owns the
    # log file and this process has no sink at all. A failed call means tacky
    # is gone or its pipe is dead, and the dialog carries the message without
    # the trace, so stderr is the only place left for it.
    set logged [expr {![catch {::tacky log error $info -obj gui.bgerror}]}]
    if {$::consoleErrors || !$logged} {
        puts stderr $info
    }
    if {$::consoleErrors} {
        return
    }
    set ::errorInfo $info
    # tailcall: the dialog answers "Skip Messages" with -code break, which dies
    # as "invoked break outside of a loop" if it unwinds through this proc.
    tailcall ::tk::dialog::error::bgerror $message
}

set dir [file normalize [file join [file dirname [info script]] ..]]
lappend auto_path [file join $dir lib]
package require libtacky

foreach script [lsort [glob [file join $dir gui *.tcl]]] {
    source $script
}

app_type app {*}$argv
