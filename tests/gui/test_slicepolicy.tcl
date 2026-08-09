# slicepolicy has no Tk in it, so a fake host answers its four questions and
# records what it was told to do. No widget, no geometry, no pixel mocking.

# Rows are just keys here; the policy never looks inside one.
proc sp_host {above below {height 100} {rows {a b c}}} {
    set ::sp_above $above
    set ::sp_below $below
    set ::sp_height $height
    set ::sp_rows $rows
    set ::sp_thirsty {}
    set ::sp_culled {}
    catch {sp destroy}
    slicepolicy sp \
        -measure-command {apply {{what} {set ::sp_$what}}} \
        -rowcount-command {apply {{} {llength $::sp_rows}}} \
        -drop-command {apply {{dir} {
            set ::sp_rows [lreplace $::sp_rows \
                {*}[expr {$dir eq "old" ? {0 0} : {end end}}]]
        }}} \
        -edgekey-command {apply {{dir} {
            lindex $::sp_rows [expr {$dir eq "old" ? 0 : "end"}]
        }}} \
        -thirst-command {apply {{dir key} {lappend ::sp_thirsty [list $dir $key]}}} \
        -cull-command {apply {{dirs} {lappend ::sp_culled $dirs}}}
    return sp
}

proc sp_cleanup {} {
    catch {sp destroy}
    unset -nocomplain ::sp_above ::sp_below ::sp_height ::sp_rows \
        ::sp_thirsty ::sp_culled
}

test slicepolicy-thirsty-fires-per-direction {each direction below the load threshold fires once with its edge key} \
    -body {
        sp_host 100 100
        sp run
        set ::sp_thirsty
    } -cleanup sp_cleanup -result {{old a} {new c}}

test slicepolicy-thirst-only-where-thin {a direction with buffer to spare stays quiet} \
    -body {
        # 3000 sits above the load threshold and below the clean one, so the
        # "new" direction neither fetches nor culls.
        sp_host 100 3000
        sp run
        set ::sp_thirsty
    } -cleanup sp_cleanup -result {{old a}}

test slicepolicy-culls-past-the-clean-threshold {content past the clean threshold is dropped at that edge} \
    -body {
        # 9999 exceeds the clean threshold and never falls, so the drop loop
        # runs until the display is empty.
        sp_host 9999 0
        sp run
        list $::sp_culled $::sp_rows
    } -cleanup sp_cleanup -result {old {}}

test slicepolicy-drops-from-the-named-edge {each edge drops its own end of the list} \
    -body {
        # Reports the buffer back under the target after a single drop, so the
        # loop stops there and the surviving rows show which end went.
        set oneShot {apply {{dir} {
            set ::sp_rows [lreplace $::sp_rows \
                {*}[expr {$dir eq "old" ? {0 0} : {end end}}]]
            set ::sp_above 0
            set ::sp_below 0
        }}}
        sp_host 9999 0
        sp configure -drop-command $oneShot
        sp run
        set afterOld $::sp_rows
        sp_host 0 9999
        sp configure -drop-command $oneShot
        sp run
        list $afterOld $::sp_rows
    } -cleanup sp_cleanup -result {{b c} {a b}}

test slicepolicy-no-thirst-for-a-just-culled-direction {a direction culled this pass does not also fire thirst} \
    -body {
        sp_host 9999 0
        sp run
        set hasOld 0
        foreach call $::sp_thirsty {
            if {[lindex $call 0] eq "old"} { set hasOld 1 }
        }
        list culled=$::sp_culled hasOldThirst=$hasOld
    } -cleanup sp_cleanup -result {culled=old hasOldThirst=0}

test slicepolicy-empty-display-is-not-thirsty {with nothing displayed there is no edge to fetch from} \
    -body {
        sp_host 0 0 100 {}
        sp run
        set ::sp_thirsty
    } -cleanup sp_cleanup -result {}

test slicepolicy-empty-display-reports-no-cull {a pass that dropped nothing does not claim it culled} \
    -body {
        # An over-threshold buffer with nothing left to drop: the host must not
        # be told to invalidate loads it will need.
        sp_host 9999 9999 100 {}
        sp run
        set ::sp_culled
    } -cleanup sp_cleanup -result {}

test slicepolicy-factor-scales-with-viewport {the factor beats the pixel floor once the viewport is tall enough} \
    -body {
        # Default load factor 2, floor 500. At vh=100 the floor wins, so 600
        # pixels of buffer is not thirsty; at vh=1000 the threshold is 2000.
        sp_host 600 9000 100
        sp run
        set short $::sp_thirsty
        sp_host 600 9000 1000
        sp run
        list $short $::sp_thirsty
    } -cleanup sp_cleanup -result {{} {{old a}}}

test slicepolicy-schedule-coalesces {repeated schedules before the idle handler run the pass once} \
    -body {
        sp_host 100 100
        sp schedule
        sp schedule
        sp schedule
        update
        set ::sp_thirsty
    } -cleanup sp_cleanup -result {{old a} {new c}}

test slicepolicy-cancel-drops-a-pending-pass {a cancelled schedule never runs} \
    -body {
        sp_host 100 100
        sp schedule
        sp cancel
        update
        set ::sp_thirsty
    } -cleanup sp_cleanup -result {}
