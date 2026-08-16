package require snit

snit::type jlog_type {
    # Levels set through setLevel; everything else inherits, resolved per call.
    # Caching a resolved level here would freeze descendants that had already
    # logged when their ancestor moved.
    variable explicit
    variable filewarned 0
    option -logproc
    option -defaultlevel warning

    # Shared with the native loggers (libdatachannel / rtc-ma); ordered least
    # to most severe, with "none" last as a silence-everything threshold.
    typevariable LEVELS {verbose debug info warning error fatal none}

    constructor args {
        array set explicit {}
        $self configurelist $args
    }

    method log {level text args} {
        $self Log -level $level -text $text {*}$args
    }

    method Log {args} {
        array set opts {-obj "" -level debug}
        array set opts $args
        # Usually the logger is gonna be invoked from a snit object,
        # which I hope all will have somewhat descriptive names, so
        # it's handy to include that name if available.
        if {$opts(-obj) eq ""} {
            catch {set opts(-obj) [uplevel 2 set self]}
        }
        # Will print if the level of the message is bigger than the
        # level of the object
        set objlevel [$self getLevel $opts(-obj)]
        if {[lsearch $LEVELS $opts(-level)] >= [lsearch $LEVELS $objlevel]} {
            if {$options(-logproc) ne ""} {
                {*}$options(-logproc) [array get opts]
            } else {
                puts [$self FormatLine [array get opts]]
            }
        }
    }
    method warn {text args} {
        $self Log -level warning -text $text {*}$args
    }
    method inform {text args} {
        $self Log -level info -text $text {*}$args
    }

    method debug {text args} {
        $self Log -level debug -text $text {*}$args
    }

    method error {text args} {
        $self Log -level error -text $text {*}$args
    }

    method getLevel obj {
        set obj [$self NormalizeObj $obj]
        while {1} {
            if {[info exists explicit($obj)]} {
                return $explicit($obj)
            }
            if {![regexp {(.*)\.[^.]+$} $obj -> parent]} {
                return $options(-defaultlevel)
            }
            set obj $parent
        }
    }

    method setLevel {obj level} {
        set explicit([$self NormalizeObj $obj]) $level
    }

    method NormalizeObj {obj} {
        # If it's already fully qualified, return as-is
        if {[string match ::* $obj]} {
            return $obj
        }
        # Otherwise, prepend ::
        return ::$obj
    }

    # -- named-arg surface, driven by the `log` module ----------------------
    # The positional methods above stay for the in-process callers; these take
    # the option lists a transport can carry.

    method write {args} {
        array set opts {-obj "" -level "" -text "" -acc ""}
        array set opts $args
        $self CheckLevel $opts(-level)
        # getlevel and --debug-level both hand out "none", so a caller piping a
        # configured level through lands here asking for no output.
        if {$opts(-level) eq "none"} {
            return
        }
        # Name it here, or the -obj guess in Log grabs the transport's frame.
        if {$opts(-obj) eq ""} {
            set opts(-obj) frontend
        }
        $self Log -level $opts(-level) -text $opts(-text) \
            -obj $opts(-obj) -acc $opts(-acc)
    }

    method setlevel {args} {
        array set opts {-obj "" -level ""}
        array set opts $args
        $self CheckLevel $opts(-level)
        if {$opts(-obj) eq ""} {
            $self configure -defaultlevel $opts(-level)
        } else {
            $self setLevel $opts(-obj) $opts(-level)
        }
        return
    }

    method getlevel {args} {
        array set opts {-obj ""}
        array set opts $args
        if {$opts(-obj) eq ""} {
            return $options(-defaultlevel)
        }
        return [$self getLevel $opts(-obj)]
    }

    method CheckLevel {level} {
        if {$level ni $LEVELS} {
            error "unknown log level \"$level\": must be one of [join $LEVELS {, }]"
        }
    }

    # One record, one write, so concurrent appenders can't interleave a line.
    method FormatLine {opts_list} {
        array set opts {-obj "" -level debug -text "" -acc ""}
        array set opts $opts_list
        set now [clock milliseconds]
        set ts [clock format [expr {$now / 1000}] -format {%Y-%m-%d %H:%M:%S}]
        append ts [format .%03d [expr {$now % 1000}]]
        set who $opts(-obj)
        if {$opts(-acc) ne ""} {
            set who "$opts(-acc) $who"
        }
        set line "\[$ts $opts(-level)\] $who: $opts(-text)"
        if {[info exists opts(-stanza)]} {
            append line \n [jwrite -pretty $opts(-stanza)]
        }
        return $line
    }

    # -logproc target: one timestamped line per record on stderr.
    method stderrWriter {opts_list} {
        puts stderr [$self FormatLine $opts_list]
    }

    # -logproc target: one file for every account plus native (libdatachannel /
    # rtc-ma) lines. Open/append/close per line so it survives a crash.
    #
    # A log call must never throw into the handler that made it, so an
    # unwritable file costs that record a stderr line instead. Later records
    # still try the file: the cause may be transient.
    method fileWriter {file opts_list} {
        set line [$self FormatLine $opts_list]
        if {[catch {
            set fd [open $file a]
            try {
                puts $fd $line
            } finally {
                close $fd
            }
        } err]} {
            if {!$filewarned} {
                set filewarned 1
                catch {puts stderr "jlog: cannot write $file: $err"}
            }
            catch {puts stderr $line}
        }
    }

    # Native log callback sink, invoked as `jlog nativeLog source id level msg`
    # (id unused). jlog shares the native level vocabulary, so level passes
    # through unchanged.
    method nativeLog {source id level message} {
        $self log $level $message -obj ::$source
    }

    # Apply resolved debug settings in this process. Native loggers are wired
    # only where rtc / rtc-ma are loaded, so they're skipped in the process-mode
    # GUI; there the daemon (tackyd / tackyd-json) calls configureDebug on its
    # own side and captures the native logs.
    method configureDebug {args} {
        array set o {
            -debug-level "" -debug-file ""
            -libdatachannel-debug-level "" -rtcma-debug-level ""
        }
        array set o $args
        if {$o(-debug-level) ne ""} {
            $self configure -defaultlevel $o(-debug-level)
        }
        if {$o(-debug-file) ne ""} {
            # Create the parent dir; the per-line writer fails otherwise.
            file mkdir [file dirname $o(-debug-file)]
            $self configure -logproc [list $self fileWriter $o(-debug-file)]
        } else {
            $self configure -logproc [list $self stderrWriter]
        }
        if {$o(-libdatachannel-debug-level) ne "" \
                && [info commands ::rtc::set-log-level] ne ""} {
            # Native verbosity is the library's job; don't let jlog re-filter.
            $self setLevel libdatachannel verbose
            ::rtc::set-log-level $o(-libdatachannel-debug-level) \
                [list $self nativeLog libdatachannel]
        }
        if {$o(-rtcma-debug-level) ne "" \
                && [info commands ::rtcma::set-log-level] ne ""} {
            $self setLevel rtcma verbose
            ::rtcma::set-log-level $o(-rtcma-debug-level) \
                [list $self nativeLog rtcma]
        }
    }
}

if {[info commands jlog] eq ""} {
    jlog_type jlog
}

# The `log` module: the singleton above reached through the tacky API, so a
# frontend writes into the same file as the backend.
snit::type taco_log {
    tackymethod write {args} { jlog write {*}$args }
    tackymethod setlevel {args} { jlog setlevel {*}$args }
    tackymethod getlevel {args} { jlog getlevel {*}$args }
}
