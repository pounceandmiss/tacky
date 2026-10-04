# Schema migrations. Each database has one ordered sequence of steps, and
# PRAGMA user_version records how many of them it has had:
#
#   accounts     - accounts.db, one per install
#   per-account  - <jid>.db, one per account, all on the same steps
#
# A step is lib/taco/schema/<which>/NNNN-name.sql or NNNN-name.tcl. A .sql
# step goes to `$db eval` whole; a .tcl step is a script run with `db` bound
# to the database handle, for steps that need logic. Steps are never edited
# once released: a change to the schema is a new step.
#
# taco_schema_migrate db which ?-dir path?
#   Runs every step above the database's user_version, each in its own
#   transaction together with the user_version it reaches. -dir replaces
#   lib/taco/schema/<which>, for tests.
#   error: a database newer than the newest step, a step number used twice

namespace eval ::taco_schema {
    variable dir [file join [file dirname [info script]] schema]
    # step dir -> sorted list of {number path}
    variable steps [dict create]
}

proc taco_schema_migrate {db which args} {
    set dir [file join $::taco_schema::dir $which]
    if {[dict exists $args -dir]} {
        set dir [dict get $args -dir]
    }
    set steps [::taco_schema::Steps $dir]
    set have [$db onecolumn {PRAGMA user_version}]
    set newest [lindex $steps end 0]
    if {$newest eq ""} {
        error "no schema steps in $dir"
    }
    if {$have > $newest} {
        error "database is at schema $have, newer than this Tacky's $newest"
    }
    foreach step $steps {
        lassign $step n path
        if {$n <= $have} continue
        set f [open $path]
        fconfigure $f -encoding utf-8
        set body [read $f]
        close $f
        $db transaction {
            if {[file extension $path] eq ".sql"} {
                $db eval $body
            } else {
                apply [list db $body] $db
            }
            # PRAGMA takes no bound variable; $n is a checked integer.
            $db eval "PRAGMA user_version = $n"
        }
    }
}

proc ::taco_schema::Steps {dir} {
    variable steps
    if {[dict exists $steps $dir]} {
        return [dict get $steps $dir]
    }
    set found [dict create]
    foreach path [glob -nocomplain -directory $dir -types f *.sql *.tcl] {
        if {![regexp {^0*(\d+)-} [file tail $path] -> n] || $n < 1} {
            error "schema step without a number from 1 up: $path"
        }
        if {[dict exists $found $n]} {
            error "schema step $n used twice: [dict get $found $n] and $path"
        }
        dict set found $n $path
    }
    set list {}
    foreach n [lsort -integer [dict keys $found]] {
        lappend list [list $n [dict get $found $n]]
    }
    dict set steps $dir $list
    return $list
}
