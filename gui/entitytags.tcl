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
    set bounds {}
    foreach {type offset length} $spans {
        lappend bounds $offset [expr {$offset + $length}]
    }
    set bounds [lsort -integer -unique $bounds]

    # For each interval, name it after the styles covering it.
    set runs {}
    set n [llength $bounds]
    for {set b 0} {$b < $n - 1} {incr b} {
        set iStart [lindex $bounds $b]
        set iEnd [lindex $bounds [expr {$b + 1}]]
        set active {}
        foreach {type offset length} $spans {
            if {$offset <= $iStart && $offset + $length >= $iEnd} {
                lappend active $type
            }
        }
        if {[llength $active] > 0} {
            lappend runs [join [lsort -unique $active] .] \
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
