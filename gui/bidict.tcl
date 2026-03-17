proc bidict {cmd args} {
    set val [lindex $args 0]
    set args [lrange $args 1 end]
    switch $cmd {
    new - clear {
        return {fwd {} rev {}}
    }
    set {
        lassign $args k v
        # Extract fwd, drop refcount in val
        set fwd [dict get $val fwd]
        dict unset val fwd
        set rev [dict get $val rev]
        dict unset val rev
        # Remove old mappings if key or value already existed
        if {[dict exists $fwd $k]} { dict unset rev [dict get $fwd $k] }
        if {[dict exists $rev $v]} { dict unset fwd [dict get $rev $v] }
        dict set fwd $k $v
        dict set rev $v $k
        dict set val fwd $fwd
        dict set val rev $rev
        return $val
    }
    unset {
        set k [lindex $args 0]
        set fwd [dict get $val fwd]
        dict unset val fwd
        set rev [dict get $val rev]
        dict unset val rev
        if {[dict exists $fwd $k]} {
            dict unset rev [dict get $fwd $k]
            dict unset fwd $k
        }
        dict set val fwd $fwd
        dict set val rev $rev
        return $val
    }
    get     { return [dict get [dict get $val fwd] [lindex $args 0]] }
    rget    { return [dict get [dict get $val rev] [lindex $args 0]] }
    exists  { return [dict exists [dict get $val fwd] [lindex $args 0]] }
    rexists { return [dict exists [dict get $val rev] [lindex $args 0]] }
    }
}
