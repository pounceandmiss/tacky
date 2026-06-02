#!/usr/bin/env tclsh9.0

if {"-h" in $argv || "--help" in $argv || "-help" in $argv} {
    puts "Usage: tacky \[options\]

Options:
  --debug-dir DIR   Write per-account debug logs to DIR
  --backend MODE    Backend mode: direct (default), thread, process
  --transient yes   Work purely in RAM - don't read/write settings/cache
  --console 1|0     Print background errors to stderr instead of a dialog
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
    if {[info commands jlog] ne "" && [jlog cget -logproc] ne ""} {
        catch {jlog error $::errorInfo -obj bgerror}
    }
    if {$::consoleErrors} {
        puts stderr $::errorInfo
    } else {
        ::tk::dialog::error::bgerror $message
    }
}

set dir [file normalize [file join [file dirname [info script]] ..]]
lappend auto_path [file join $dir lib]
package require libtacky

foreach script [lsort [glob [file join $dir gui *.tcl]]] {
    source $script
}

app_type app {*}$argv
