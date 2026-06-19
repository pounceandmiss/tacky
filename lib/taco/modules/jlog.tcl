package require snit

snit::type jlog_type {
    variable levels
    option -logproc
    option -defaultlevel warning

    # Shared with the native loggers (libdatachannel / rtc-ma); ordered least
    # to most severe, with "none" last as a silence-everything threshold.
    typevariable LEVELS {verbose debug info warning error fatal none}
    
    constructor args {
        array set levels {}
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
                puts "Log $opts(-obj): \[$opts(-level)\] $opts(-text)"
                if {[info exists opts(-stanza)]} {
                    puts [jwrite -pretty $opts(-stanza)]
                }
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
        if {[info exists levels($obj)]} {
            return $levels($obj) 
        }
        
        if {[regexp {(.*)\.([^.]+)$} $obj -> parent tail]} {
            set levels($obj) [$self getLevel $parent]
        } else {
            set levels($obj) $options(-defaultlevel)
        }
        
        set levels($obj)
    }
    
    method setLevel {obj level {recursive no}} {
        set obj [$self NormalizeObj $obj]
        set levels($obj) $level
        set mask [expr {$recursive ? "$obj*": $obj}]
        foreach key [array names levels $mask] {
            set levels($key) $level
        }
    }

    method NormalizeObj {obj} {
        # If it's already fully qualified, return as-is
        if {[string match ::* $obj]} {
            return $obj
        }
        # Otherwise, prepend ::
        return ::$obj
    }

    # -logproc target: one timestamped line per record on stderr.
    method stderrWriter {opts_list} {
        array set opts {-obj "" -level debug -text ""}
        array set opts $opts_list
        set ts [clock format [clock seconds] -format %H:%M:%S]
        puts stderr "\[$ts $opts(-level)\] $opts(-obj): $opts(-text)"
        if {[info exists opts(-stanza)]} {
            puts stderr [jwrite -pretty $opts(-stanza)]
        }
    }

    # -logproc target: one file for every account plus native (libdatachannel /
    # rtc-ma) lines. Open/append/close per line so it survives a crash.
    method fileWriter {file opts_list} {
        array set opts {-obj "" -level debug -text ""}
        array set opts $opts_list
        set fd [open $file a]
        set ts [clock format [clock seconds] -format %H:%M:%S]
        puts $fd "\[$ts $opts(-level)\] $opts(-obj): $opts(-text)"
        if {[info exists opts(-stanza)]} {
            puts $fd [jwrite -pretty $opts(-stanza)]
        }
        close $fd
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
