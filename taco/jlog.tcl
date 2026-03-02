package require snit

snit::type jlog_type {
    variable levels
    option -logproc
    option -defaultlevel warn
    
    typevariable LEVELS {debug error info warn}
    
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

if {[info commands jlog] eq ""} {
    jlog_type jlog
}
