package require control
package require snit

# slicepolicy - decides when the displayed slice of a conversation should grow
# or shrink. No Tk: it asks its host for measurements and tells it what to drop,
# so the rule can be reasoned about (and tested) on its own.
#
# The host holds only a slice of the conversation, not the full history. As the
# user scrolls toward an edge the next batch is loaded on demand, and content
# far from the viewport is culled to bound memory. Two numbers drive that: the
# pixels of content above the viewport and the pixels below it.
#
# Three thresholds, each computed as max(<name>-threshold, vh * <name>-factor).
# The factor scales with viewport height and is the primary tuning knob; the
# threshold is a pixel floor that only matters on windows too small for the
# factor to mean anything.
#
#   load          below this in one direction, the host is asked to fetch more
#   clean         above this in one direction, content at that edge is dropped
#   clean target  where dropping stops. Sits between the other two, so a clean
#                 pass leaves the buffer well clear of the load threshold and
#                 the two don't chase each other.
snit::type slicepolicy {
    option -clean-factor    -default 10
    option -clean-threshold -default 5000

    option -load-factor    -default 2
    option -load-threshold -default 500

    option -clean-target-factor    -default 5
    option -clean-target-threshold -default 2500

    # What the host must answer. `measure` is called as {*}$cmd above|below|
    # height and returns pixels; `rowcount` returns how many rows are drawn;
    # `drop` is called as {*}$cmd old|new and removes the row at that edge;
    # `edgekey` is called as {*}$cmd old|new and returns that row's key.
    option -measure-command  -default ""
    option -rowcount-command -default ""
    option -drop-command     -default ""
    option -edgekey-command  -default ""

    # Fires when the buffer in $direction ("old"/"new") fell below the load
    # threshold. Called as: {*}$cmd $direction $edgeKey - the cursor the host
    # should fetch from. Fires once per thirsty direction per pass. Not fired
    # if nothing is displayed (no edge to fetch from), nor for a direction that
    # was just culled in the same pass, which would loop load-clean-load.
    option -thirst-command -default control::no-op

    # Fires after rows were culled from one or both edges. Called as:
    # {*}$cmd $directions, a list containing "old" and/or "new". The host
    # should invalidate any in-flight loads for those directions; their cursors
    # no longer connect to displayed content. Fires once per pass that culled.
    option -cull-command -default control::no-op

    variable Above 0
    variable Below 0
    variable Scheduled 0

    destructor { $self cancel }

    # Ask for a pass at idle. Scrolling fires far more often than the decision
    # needs making, so repeated calls before the idle handler runs coalesce.
    method schedule {} {
        if {$Scheduled} return
        set Scheduled 1
        after idle [mymethod run]
    }

    method cancel {} {
        set Scheduled 0
        after cancel [mymethod run]
    }

    method run {} {
        set Scheduled 0
        set Above [$self Measure above]
        set Below [$self Measure below]
        set vh [$self Measure height]

        set loadTh      [$self Threshold load $vh]
        set cleanTh     [$self Threshold clean $vh]
        set cleanTarget [$self Threshold clean-target $vh]

        # Only a direction that actually gave something up counts as culled:
        # with nothing displayed the buffer stays over the threshold forever,
        # and reporting that would have the host cancel loads for no reason.
        set cleaned {}
        if {$Above > $cleanTh && [$self Drain old Above $cleanTarget]} {
            lappend cleaned old
        }
        if {$Below > $cleanTh && [$self Drain new Below $cleanTarget]} {
            lappend cleaned new
        }

        # Invalidate in-flight loads whose cursors may now be stale.
        if {[llength $cleaned] > 0} {
            {*}$options(-cull-command) $cleaned
        }

        # Need an edge to fetch from; if the display ended up empty there is
        # nothing to be thirsty about. The first load comes through a different
        # path, so the host's dedupe guard would not catch this.
        if {[$self Rowcount] == 0} return

        if {$Above < $loadTh && "old" ni $cleaned} { $self Thirst old }
        if {$Below < $loadTh && "new" ni $cleaned} { $self Thirst new }
    }

    # Drop rows at one edge until its buffer is back to the target, remeasuring
    # after each. Stops on an empty display even if the target is unreachable,
    # which is what a host reporting a constant measurement would do. Returns
    # whether anything was dropped.
    method Drain {direction pixelsVar target} {
        upvar 0 [myvar $pixelsVar] pixels
        set what [expr {$direction eq "old" ? "above" : "below"}]
        set dropped 0
        while {$pixels > $target && [$self Rowcount] > 0} {
            {*}$options(-drop-command) $direction
            set pixels [$self Measure $what]
            incr dropped
        }
        return $dropped
    }

    method Thirst {direction} {
        {*}$options(-thirst-command) $direction \
            [{*}$options(-edgekey-command) $direction]
    }

    method Threshold {name vh} {
        expr {max($options(-$name-threshold), $vh * $options(-$name-factor))}
    }

    method Measure {what} { {*}$options(-measure-command) $what }
    method Rowcount {} { {*}$options(-rowcount-command) }
}
