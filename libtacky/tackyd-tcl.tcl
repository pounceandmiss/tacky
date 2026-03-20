#!/usr/bin/env tclsh9.0
# Child process entry point for tacky_process_type.
# Runs a full taco_type backend, communicating with the GUI over
# stdin/stdout using length-prefixed messages (lenpipe).
#
# Incoming (stdin):  <module> <method> <kwarg>...
# Outgoing (stdout): event <module> <event> <args>

proc pipesend {msg} {
    set bytes [encoding convertto utf-8 $msg]
    puts stdout [string length $bytes]
    puts -nonewline stdout $bytes
    flush stdout
}

# Define "tacky" command before creating taco_type,
# because taco constructor calls `tacky emit` for existing accounts.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} { pipesend [list event $module $event $args] }
}

# Configure stdout for writing
chan configure stdout -translation binary -buffering full

source [file join [file dirname [info script]] taco taco.tcl]

# Read commands from stdin via lenpipe
lenpipe create _pipe stdin \
    -onmessage {apply {{msg} {
        taco [lindex $msg 0] [lindex $msg 1] {*}[lrange $msg 2 end]
    }}} \
    -oneof {apply {{} {
        taco destroy
        exit 0
    }}}

taco_type create taco {*}$::argv
vwait forever
