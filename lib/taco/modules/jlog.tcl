package require snit

snit::type jlog_type {
    # Levels set through setLevel; everything else inherits, resolved per call.
    # Caching a resolved level here would freeze descendants that had already
    # logged when their ancestor moved.
    variable explicit
    variable nativelevel
    variable filewarned 0
    variable logfile ""
    option -logproc
    option -defaultlevel -default warning -configuremethod SetDefaultLevel
    # Past this the log rotates to <path>.1; 0 disables rotation.
    option -maxlogbytes 4194304

    # Shared with the native loggers (libdatachannel / rtc-ma); ordered least
    # to most severe, with "none" last as a silence-everything threshold.
    typevariable LEVELS {verbose debug info warning error fatal none}

    typevariable NATIVE {
        libdatachannel ::rtc::set-log-level
        rtcma          ::rtcma::set-log-level
    }

    constructor args {
        array set explicit {}
        foreach src [dict keys $NATIVE] {
            set nativelevel($src) none
        }
        $self configurelist $args
    }

    method log {level text args} {
        $self Log -level $level -text $text {*}$args
    }

    method Log {args} {
        array set opts {-obj "" -level debug}
        array set opts $args
        $self CheckLevel $opts(-level)
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
                # Never stdout: that is the daemon's wire.
                $self stderrWriter [array get opts]
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
        $self CheckLevel $level
        set explicit([$self NormalizeObj $obj]) $level
    }

    # An unvalidated threshold loses every comparison in Log, so a typo would
    # log everything rather than nothing.
    method SetDefaultLevel {opt level} {
        $self CheckLevel $level
        set options($opt) $level
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

    # An empty path sends records back to stderr. The writer holds the file
    # open only for the length of a record, so rotation needs no coordination
    # and a host may truncate underneath us; the next record recreates it.
    method setfile {args} {
        array set opts {-path ""}
        array set opts $args
        set logfile $opts(-path)
        if {$logfile eq ""} {
            $self configure -logproc [list $self stderrWriter]
            return
        }
        # Create the parent dir; the per-line writer fails otherwise.
        file mkdir [file dirname $logfile]
        $self MakePrivate $logfile
        # A new file earns a fresh complaint if it turns out to be unwritable.
        set filewarned 0
        $self configure -logproc [list $self fileWriter $logfile]
        return
    }

    # setfile by boolean. The directory is ours here, so it can be restricted.
    method setenabled {args} {
        array set opts {-enabled 0 -dir ""}
        array set opts $args
        if {![string is boolean -strict $opts(-enabled)]} {
            error "invalid -enabled \"$opts(-enabled)\": must be a boolean"
        }
        if {[string is true $opts(-enabled)]} {
            if {$opts(-dir) eq ""} {
                error "cannot write a log file: no directory configured"
            }
            appdirs_mkprivate $opts(-dir)
            return [$self setfile -path [file join $opts(-dir) tacky.log]]
        }
        return [$self setfile -path ""]
    }

    method getfile {args} {
        return $logfile
    }

    # Omitting -source drives every native logger.
    method setnativelevel {args} {
        array set opts {-source "" -level none}
        array set opts $args
        $self CheckLevel $opts(-level)
        foreach src [$self NativeSources $opts(-source)] {
            set cmd [dict get $NATIVE $src]
            if {[info commands $cmd] eq ""} continue
            # Native verbosity is the library's job; don't let jlog re-filter.
            $self setLevel $src verbose
            if {$opts(-level) eq "none"} {
                # Dropping only the callback leaves the library on its own
                # stderr sink, so the level has to say none too.
                {*}$cmd none
            } else {
                {*}$cmd $opts(-level) [list $self nativeLog $src]
            }
            set nativelevel($src) $opts(-level)
        }
        return
    }

    method getnativelevel {args} {
        array set opts {-source ""}
        array set opts $args
        if {$opts(-source) eq ""} {
            error "-source is required: one of [join [dict keys $NATIVE] {, }]"
        }
        $self NativeSources $opts(-source)
        return $nativelevel($opts(-source))
    }

    method NativeSources {source} {
        if {$source eq ""} {
            return [dict keys $NATIVE]
        }
        if {![dict exists $NATIVE $source]} {
            error "unknown native log source \"$source\": must be one of\
                [join [dict keys $NATIVE] {, }]"
        }
        return [list $source]
    }

    # Only the file: setfile's directory may be anywhere the caller named, and
    # 0700 on a shared /tmp would be vandalism.
    method MakePrivate {file} {
        catch {
            if {![file exists $file]} {
                close [open $file a]
            }
            if {$::tcl_platform(platform) eq "unix"} {
                file attributes $file -permissions 0600
            }
        }
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
            # Absent reads as -1, which is also what rotating leaves behind:
            # either way open remakes the file with the umask's mode, not ours.
            set size [expr {[catch {file size $file} n] ? -1 : $n}]
            if {$size >= 0 && $options(-maxlogbytes) > 0
                    && $size >= $options(-maxlogbytes)} {
                # Losing a rotation is survivable; throwing at the caller is not.
                catch {file rename -force $file $file.1}
                set size -1
            }
            set fd [open $file a]
            try {
                puts $fd $line
            } finally {
                close $fd
            }
            if {$size < 0} {
                $self MakePrivate $file
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
    # (id unused). jlog shares the native level vocabulary, so a known level
    # passes through unchanged.
    method nativeLog {source id level message} {
        # Never throw back into C, and never lose the record: a library that
        # grew a level gets logged loudly instead.
        if {$level ni $LEVELS} {
            set message "\[$level\] $message"
            set level error
        }
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
        # Absent flag, not "go to stderr": leave the installed sink alone.
        if {$o(-debug-file) ne ""} {
            $self setfile -path $o(-debug-file)
        }
        foreach {opt src} {
            -libdatachannel-debug-level libdatachannel
            -rtcma-debug-level          rtcma
        } {
            if {$o($opt) ne ""} {
                $self setnativelevel -source $src -level $o($opt)
            }
        }
    }
}

if {[info commands jlog] eq ""} {
    jlog_type jlog
}

# The `log` module: the singleton above reached through the tacky API, so a
# frontend writes into the same file as the backend.
snit::type taco_log {
    # taco's own cache dir, so an embedded host's sandbox and -transient's temp
    # root each get the log instead of the real user's.
    option -cache-dir -default "" -readonly yes

    tackymethod write {args} { jlog write {*}$args }
    tackymethod setlevel {args} { jlog setlevel {*}$args }
    tackymethod getlevel {args} { jlog getlevel {*}$args }
    tackymethod setnativelevel {args} { jlog setnativelevel {*}$args }
    tackymethod getnativelevel {args} { jlog getnativelevel {*}$args }
    tackymethod setfile {args} { jlog setfile {*}$args }
    # Ours last: the directory is not the caller's to name.
    tackymethod setenabled {args} {
        jlog setenabled {*}$args -dir $options(-cache-dir)
    }
    tackymethod getfile {args} { jlog getfile {*}$args }
}
