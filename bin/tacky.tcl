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
# Native widgets where available; clam on X11.
switch -- [tk windowingsystem] {
    aqua  { ttk::style theme use aqua }
    win32 { ttk::style theme use vista }
    default { ttk::style theme use clam }
}
package require snit
package require tkwuffs
# Not built on macOS (no Aqua backend), and chatpanel.tcl already guards every
# use, so its absence is only worth a word where it should have been there.
if {[catch {package require tkdnd} err]} {
    if {$::tcl_platform(os) ne "Darwin"} {
        puts stderr "tacky: tkdnd unavailable ($err); drag-and-drop disabled"
    }
}

set dir [file normalize [file join [file dirname [info script]] ..]]
lappend auto_path [file join $dir lib]
lappend auto_path [file join $dir gui]
package require libtacky

package require tackygui

app_type app {*}$argv
