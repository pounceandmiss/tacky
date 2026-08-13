package provide tackyd 0.1

# Boilerplate shared by the stdio daemon entry points (bin/tackyd.tcl and
# bin/tackyd-json.tcl), which differ only in the wire codec: each defines its
# own `tacky` emit sink and lenpipe reader, then calls tackyd_main.

# jlog configureDebug's options; anything else on the command line is a
# taco_type option. lib/libtacky/tacky.tcl carries its own copy for the GUI
# side of the wire, which cannot reach this package.
variable tackyd_debug_flags {
    -debug-level -debug-file
    -libdatachannel-debug-level -rtcma-debug-level
}

# Split an argv into {debugFlags tacoArgs}. Both -foo and --foo spellings are
# accepted; the rest pass through to taco_type, which rejects unknown options.
proc tackyd_split_argv {argv} {
    set debug {}
    set rest {}
    foreach {k v} $argv {
        set norm -[string trimleft $k -]
        if {$norm in $::tackyd_debug_flags} {
            lappend debug $norm $v
        } else {
            lappend rest $k $v
        }
    }
    return [list $debug $rest]
}

proc pipesend {msg} {
    set bytes [encoding convertto utf-8 $msg]
    puts stdout [string length $bytes]
    puts -nonewline stdout $bytes
    flush stdout
}

proc bgerror {message} {
    set info $::errorInfo
    if {[catch {jlog error $info -obj bgerror}]} {
        puts stderr $info
    }
}

# Bring up the backend and run the event loop. The caller must already have
# defined `tacky` and its reader: the taco constructor emits for existing
# accounts.
proc tackyd_main {argv} {
    # stdout is the wire; jlog configureDebug routes logs to stderr or the
    # --debug-file, never stdout.
    chan configure stdout -translation binary -buffering full
    lassign [tackyd_split_argv $argv] debug tacoArgs
    jlog configureDebug {*}$debug
    taco_type create taco {*}$tacoArgs
    vwait forever
}
