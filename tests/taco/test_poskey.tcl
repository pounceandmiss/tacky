# Unit tests for poskey, the order keys chat messages sort by.
package require tcltest
namespace import ::tcltest::*
package require taco

namespace eval ::test::poskey {

    # Keys from rocicorp/fractional-indexing's own tests: the scheme is
    # theirs, so it should agree with them key for key.
    test poskey-between-known {between agrees with the reference implementation} -body {
        lmap {a b} {
            "" ""
            "" a0
            "" a0V
            "" b999
            "" Y00
            a0 ""
            bzz ""
            a0 a1
            a1 a2
            a0V a1
            Zz a0
            Zz a1
            Zz a01
            a0 a0V
            a0 a0G
            b125 b129
            a0 a1V
            "" A000000000000000000000000001
            zzzzzzzzzzzzzzzzzzzzzzzzzzy ""
            zzzzzzzzzzzzzzzzzzzzzzzzzzz ""
        } { poskey between $a $b }
    } -result {a0 Zz a0 b99 Xzzz a1 c000 a0V a1V a0l ZzV a0 a0 a0G a08 b127 a1 A000000000000000000000000000V zzzzzzzzzzzzzzzzzzzzzzzzzzz zzzzzzzzzzzzzzzzzzzzzzzzzzzV}

    test poskey-between-refuses {malformed keys, and bounds the wrong way round, are refused} -body {
        lmap {a b} {
            "" A00000000000000000000000000
            a00 ""
            a00 a1
            0 1
            a1 a0
            a1 a1
            a0 a0-
        } { catch {poskey between $a $b} }
    } -result {1 1 1 1 1 1 1}

    test poskey-nth-counts-like-appends {nth gives the run that appending one key after another gives} -body {
        set k ""
        set bad {}
        for {set i 0} {$i < 4000} {incr i} {
            set k [poskey between $k ""]
            if {[poskey nth $i] ne $k} { lappend bad $i }
        }
        list $bad [poskey nth 0] [poskey nth 61] [poskey nth 62] [poskey nth 3905] [poskey nth 3906]
    } -result {{} a0 az b00 bzz c000}

    # Strictly ascending and every key well formed.
    proc ordered {keys} {
        foreach k $keys {
            if {![poskey valid $k]} { return "invalid $k" }
        }
        for {set i 1} {$i < [llength $keys]} {incr i} {
            if {[string compare [lindex $keys $i-1] [lindex $keys $i]] >= 0} {
                return "out of order at $i: [lindex $keys $i-1] [lindex $keys $i]"
            }
        }
        return ok
    }

    proc maxlen {keys} {
        tcl::mathfunc::max {*}[lmap k $keys {string length $k}]
    }

    test poskey-random-inserts-stay-ordered {keys put anywhere among others, singly or a page at a time, keep the list in order} -body {
        expr {srand(7)}
        set keys {}
        for {set i 0} {$i < 3000} {incr i} {
            set at [expr {int(rand() * ([llength $keys] + 1))}]
            set a [expr {$at == 0 ? "" : [lindex $keys $at-1]}]
            set b [expr {$at == [llength $keys] ? "" : [lindex $keys $at]}]
            set n [expr {rand() < 0.2 ? 1 + int(rand() * 60) : 1}]
            switch [expr {int(rand() * 3)}] {
                0 { set new [poskey nBetween $a $b $n] }
                1 { set new [poskey page $a $b $n up] }
                2 { set new [poskey page $a $b $n down] }
            }
            set keys [linsert $keys $at {*}$new]
        }
        list [ordered $keys] [llength $keys]
    } -match regexp -result {^ok \d+$}

    test poskey-appends-stay-short {a long run of appends, or of prepends, keeps keys short} -body {
        set up {}
        set k ""
        for {set i 0} {$i < 100000} {incr i} {
            set k [poskey between $k ""]
            lappend up $k
        }
        set down {}
        set k ""
        for {set i 0} {$i < 100000} {incr i} {
            set k [poskey between "" $k]
            lappend down $k
        }
        list [ordered $up] [ordered [lreverse $down]] [maxlen $up] [maxlen $down]
    } -result {ok ok 4 4}

    # One gap, filled page after page from one side: a forward fill
    # going up from the row below, or a walk back going down from the row
    # above. 200 pages of 50 is the most one fill takes.
    proc fill {dir pages per} {
        set lo a1
        set hi a2
        set all {}
        for {set p 0} {$p < $pages} {incr p} {
            set keys [poskey page $lo $hi $per $dir]
            if {$dir eq "up"} {
                lappend all {*}$keys
                set lo [lindex $keys end]
            } else {
                set all [concat $keys $all]
                set hi [lindex $keys 0]
            }
        }
        list [ordered [list a1 {*}$all a2]] [maxlen $all]
    }

    test poskey-pages-up {a forward fill of 200 pages keeps keys short} -body {
        lassign [fill up 200 50] ok len
        list $ok [expr {$len <= 48}]
    } -result {ok 1}

    test poskey-pages-down {a walk back of 200 pages keeps keys short} -body {
        lassign [fill down 200 50] ok len
        list $ok [expr {$len <= 48}]
    } -result {ok 1}

    test poskey-page-open-ends {a page with no bound on its far side counts on} -body {
        list [poskey page a5 "" 3 up] [poskey page "" a5 3 down]
    } -result {{a6 a7 a8} {a2 a3 a4}}
}

cleanupTests
