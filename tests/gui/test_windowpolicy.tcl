# windowpolicy has no Tk in it, so a fake host answers its four questions and
# records what it was told to do. No widget, no geometry, no pixel mocking.

# Rows are just keys here; the policy never looks inside one.
proc wp_host {above below {height 100} {rows {a b c}}} {
    set ::wp_above $above
    set ::wp_below $below
    set ::wp_height $height
    set ::wp_rows $rows
    set ::wp_thirsty {}
    set ::wp_culled {}
    catch {wp destroy}
    windowpolicy wp \
        -measure-command {apply {{what} {set ::wp_$what}}} \
        -rowcount-command {apply {{} {llength $::wp_rows}}} \
        -drop-command {apply {{dir} {
            set ::wp_rows [lreplace $::wp_rows \
                {*}[expr {$dir eq "old" ? {0 0} : {end end}}]]
        }}} \
        -edgekey-command {apply {{dir} {
            lindex $::wp_rows [expr {$dir eq "old" ? 0 : "end"}]
        }}} \
        -thirst-command {apply {{dir key} {lappend ::wp_thirsty [list $dir $key]}}} \
        -cull-command {apply {{dirs} {lappend ::wp_culled $dirs}}}
    return wp
}

proc wp_cleanup {} {
    catch {wp destroy}
    unset -nocomplain ::wp_above ::wp_below ::wp_height ::wp_rows \
        ::wp_thirsty ::wp_culled
}

test windowpolicy-thirsty-fires-per-direction {each direction below the load threshold fires once with its edge key} \
    -body {
        wp_host 100 100
        wp run
        set ::wp_thirsty
    } -cleanup wp_cleanup -result {{old a} {new c}}

test windowpolicy-thirst-only-where-thin {a direction with buffer to spare stays quiet} \
    -body {
        # 3000 sits above the load threshold and below the clean one, so the
        # "new" direction neither fetches nor culls.
        wp_host 100 3000
        wp run
        set ::wp_thirsty
    } -cleanup wp_cleanup -result {{old a}}

test windowpolicy-culls-past-the-clean-threshold {content past the clean threshold is dropped at that edge} \
    -body {
        # 9999 exceeds the clean threshold and never falls, so the drop loop
        # runs until the display is empty.
        wp_host 9999 0
        wp run
        list $::wp_culled $::wp_rows
    } -cleanup wp_cleanup -result {old {}}

test windowpolicy-drops-from-the-named-edge {each edge drops its own end of the list} \
    -body {
        # Reports the buffer back under the target after a single drop, so the
        # loop stops there and the surviving rows show which end went.
        set oneShot {apply {{dir} {
            set ::wp_rows [lreplace $::wp_rows \
                {*}[expr {$dir eq "old" ? {0 0} : {end end}}]]
            set ::wp_above 0
            set ::wp_below 0
        }}}
        wp_host 9999 0
        wp configure -drop-command $oneShot
        wp run
        set afterOld $::wp_rows
        wp_host 0 9999
        wp configure -drop-command $oneShot
        wp run
        list $afterOld $::wp_rows
    } -cleanup wp_cleanup -result {{b c} {a b}}

test windowpolicy-no-thirst-for-a-just-culled-direction {a direction culled this pass does not also fire thirst} \
    -body {
        wp_host 9999 0
        wp run
        set hasOld 0
        foreach call $::wp_thirsty {
            if {[lindex $call 0] eq "old"} { set hasOld 1 }
        }
        list culled=$::wp_culled hasOldThirst=$hasOld
    } -cleanup wp_cleanup -result {culled=old hasOldThirst=0}

test windowpolicy-empty-display-is-not-thirsty {with nothing displayed there is no edge to fetch from} \
    -body {
        wp_host 0 0 100 {}
        wp run
        set ::wp_thirsty
    } -cleanup wp_cleanup -result {}

test windowpolicy-empty-display-reports-no-cull {a pass that dropped nothing does not claim it culled} \
    -body {
        # An over-threshold buffer with nothing left to drop: the host must not
        # be told to invalidate loads it will need.
        wp_host 9999 9999 100 {}
        wp run
        set ::wp_culled
    } -cleanup wp_cleanup -result {}

test windowpolicy-factor-scales-with-viewport {the factor beats the pixel floor once the viewport is tall enough} \
    -body {
        # Default load factor 2, floor 500. At vh=100 the floor wins, so 600
        # pixels of buffer is not thirsty; at vh=1000 the threshold is 2000.
        wp_host 600 9000 100
        wp run
        set short $::wp_thirsty
        wp_host 600 9000 1000
        wp run
        list $short $::wp_thirsty
    } -cleanup wp_cleanup -result {{} {{old a}}}

test windowpolicy-schedule-coalesces {repeated schedules before the idle handler run the pass once} \
    -body {
        wp_host 100 100
        wp schedule
        wp schedule
        wp schedule
        update
        set ::wp_thirsty
    } -cleanup wp_cleanup -result {{old a} {new c}}

test windowpolicy-cancel-drops-a-pending-pass {a cancelled schedule never runs} \
    -body {
        wp_host 100 100
        wp schedule
        wp cancel
        update
        set ::wp_thirsty
    } -cleanup wp_cleanup -result {}
