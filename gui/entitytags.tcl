# entitytags - combine overlapping XEP-0393 font-style spans into the
# non-overlapping compound tag names the chat text widget pre-builds.
#
# Tk text tags don't merge fonts, so a run covered by several font-affecting
# styles needs a single tag naming the whole set. combine takes a flat
# {type offset length ...} list of single-type spans (which may overlap) and
# returns a flat {type offset length ...} list of non-overlapping runs whose
# type is the styles active over that run, sorted alphabetically and joined
# with "." (e.g. bold.italic) - matching the cross-product entity.* tags.

namespace eval entitytags {
    namespace export combine
}

proc entitytags::combine {spans} {
    if {[llength $spans] == 0} { return {} }

    # Every span edge is an interval boundary.
    set edges {}
    foreach {type offset length} $spans {
        dict lappend edges $offset [list $type 1]
        dict lappend edges [expr {$offset + $length}] [list $type -1]
    }
    set bounds [lsort -integer [dict keys $edges]]

    # Sweep left to right, naming each interval after the styles active across
    # it; re-scanning every span per interval is quadratic.
    set runs {}
    set active {}
    set n [llength $bounds]
    for {set b 0} {$b < $n} {incr b} {
        set iStart [lindex $bounds $b]
        foreach edge [dict get $edges $iStart] {
            lassign $edge type delta
            dict incr active $type $delta
            if {[dict get $active $type] <= 0} {
                dict unset active $type
            }
        }
        if {$b + 1 < $n && [dict size $active] > 0} {
            set iEnd [lindex $bounds [expr {$b + 1}]]
            lappend runs [join [lsort [dict keys $active]] .] \
                $iStart [expr {$iEnd - $iStart}]
        }
    }

    # Merge adjacent runs that ended up with the same compound type.
    set merged {}
    set prevType ""
    set prevOffset 0
    set prevLength 0
    foreach {type offset length} $runs {
        if {$type eq $prevType && $offset == $prevOffset + $prevLength} {
            incr prevLength $length
        } else {
            if {$prevType ne ""} {
                lappend merged $prevType $prevOffset $prevLength
            }
            set prevType $type
            set prevOffset $offset
            set prevLength $length
        }
    }
    if {$prevType ne ""} {
        lappend merged $prevType $prevOffset $prevLength
    }
    return $merged
}
