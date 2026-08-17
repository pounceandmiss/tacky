package provide tackyd 0.1
package require taco

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
# accepted, for every option and not just the debug ones: taco_type takes a
# single dash, so passing the rest through verbatim made --debug-file work and
# --config-dir an error. The rest still reach taco_type, which rejects unknown
# options.
proc tackyd_split_argv {argv} {
    set debug {}
    set rest {}
    foreach {k v} $argv {
        set norm -[string trimleft $k -]
        if {$norm in $::tackyd_debug_flags} {
            lappend debug $norm $v
        } else {
            lappend rest $norm $v
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

# At load, not from tackyd_main: bin/tackyd-embed.tcl requires this package for
# the bgerror alone and brings taco up its own way.
taco_install_bgerror

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
