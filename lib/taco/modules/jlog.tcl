package require snit

snit::type jlog_type {
    variable levels
    option -logproc
    option -defaultlevel warn
    
    typevariable LEVELS {debug info warn error}
    
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
        $self Log -level warn -text $text {*}$args
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

}

proc jlog_stderr_writer {opts_list} {
    array set opts {-obj "" -level debug -text ""}
    array set opts $opts_list
    set ts [clock format [clock seconds] -format %H:%M:%S]
    puts stderr "\[$ts $opts(-level)\] $opts(-obj): $opts(-text)"
    if {[info exists opts(-stanza)]} {
        puts stderr [jwrite -pretty $opts(-stanza)]
    }
}

# One file for every account plus native (libdatachannel / rtc-ma) lines.
# Open/append/close per line so it survives a crash.
proc jlog_file_writer_single {file opts_list} {
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

# Sink for native log callbacks, invoked as `native_jlog source id level msg`;
# id is unused. configure_debug pins the source level so this only maps the
# native level to a jlog method (info uses inform).
proc native_jlog {source id level message} {
    set method [dict get {
        none debug fatal error error error warning warn
        info inform debug debug verbose debug
    } $level]
    jlog $method $message -obj ::$source
}

# Apply resolved debug settings in this process. Native loggers are wired only
# where rtc / rtc-ma are loaded, so they're skipped in the process-mode GUI.
proc configure_debug {args} {
    array set o {-level "" -file "" -libdatachannel-level "" -rtcma-level ""}
    array set o $args
    if {$o(-level) ne ""} {
        jlog configure -defaultlevel $o(-level)
    }
    if {$o(-file) ne ""} {
        # Create the parent dir; the per-line writer fails otherwise.
        file mkdir [file dirname $o(-file)]
        jlog configure -logproc [list jlog_file_writer_single $o(-file)]
    } else {
        jlog configure -logproc jlog_stderr_writer
    }
    if {$o(-libdatachannel-level) ne "" \
            && [info commands ::rtc::set-log-level] ne ""} {
        # Native verbosity is the library's job; don't let jlog re-filter.
        jlog setLevel libdatachannel debug
        ::rtc::set-log-level $o(-libdatachannel-level) \
            [list native_jlog libdatachannel]
    }
    if {$o(-rtcma-level) ne "" \
            && [info commands ::rtcma::set-log-level] ne ""} {
        jlog setLevel rtcma debug
        ::rtcma::set-log-level $o(-rtcma-level) [list native_jlog rtcma]
    }
}

if {[info commands jlog] eq ""} {
    jlog_type jlog
}
