#!/usr/bin/env tclsh9.0
# Child process entry point for tacky_process_type.
# Speaks length-prefixed Tcl lists over stdin/stdout (lenpipe).
#
# Incoming (stdin):  [module method args]              fire-and-forget
#                    [module method args token wants]  request/response
# Outgoing (stdout): [event module <Event> args]       broadcast
#                    [result token data]               success reply
#                    [error  token message]            error reply
#
# `wants` is a subset of {cmd err}: only those callbacks are wired, so a
# -command with no -onerror still reaches the macro's <MethodError> branch.

lappend auto_path [file normalize [file join [file dirname [info script]] .. lib]]
package require taco
package require lenpipe

proc pipesend {msg} {
    set bytes [encoding convertto utf-8 $msg]
    puts stdout [string length $bytes]
    puts -nonewline stdout $bytes
    flush stdout
}

# Define "tacky" before creating taco_type — taco's constructor calls
# `tacky emit` for existing accounts.  Module=callback (used by the
# token wiring below) becomes a result/error reply; everything else is
# a broadcast event.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} {
        if {$module eq "callback" && [dict exists $args -token]} {
            set token [dict get $args -token]
            set data  [dict get $args -result]
            if {$event eq "<Error>"} {
                pipesend [list error $token $data]
            } else {
                pipesend [list result $token $data]
            }
            return
        }
        pipesend [list event $module $event $args]
    }
}

chan configure stdout -translation binary -buffering full

lenpipe create _pipe stdin \
    -onmessage {apply {{msg} {
        lassign $msg module method args
        if {[llength $msg] > 3} {
            set token [lindex $msg 3]
            set wants [lindex $msg 4]
            if {"cmd" in $wants} {
                dict set args -command \
                    [list tacky emit callback <Result> -token $token -result]
            }
            if {"err" in $wants} {
                dict set args -onerror \
                    [list tacky emit callback <Error> -token $token -result]
            }
        }
        taco $module $method {*}$args
    }}} \
    -oneof {apply {{} {
        taco destroy
        exit 0
    }}}

proc bgerror {message} {
    if {[catch {jlog error $::errorInfo -obj bgerror}]} {
        puts stderr $::errorInfo
    }
}

set _debug {}
set _taco_args {}
foreach {_k _v} $::argv {
    switch -- $_k {
        -debug-level - --debug-level { lappend _debug -debug-level $_v }
        -debug-file  - --debug-file  { lappend _debug -debug-file $_v }
        -libdatachannel-debug-level - --libdatachannel-debug-level {
            lappend _debug -libdatachannel-debug-level $_v
        }
        -rtcma-debug-level - --rtcma-debug-level {
            lappend _debug -rtcma-debug-level $_v
        }
        default { lappend _taco_args $_k $_v }
    }
}
# stdout is the lenpipe wire; jlog configureDebug routes logs to stderr or
# the --debug-file, never stdout.
jlog configureDebug {*}$_debug

taco_type create taco {*}$_taco_args
vwait forever
