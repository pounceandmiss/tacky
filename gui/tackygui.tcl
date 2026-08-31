package provide tackygui 0.1

package require Tk
package require snit
package require libtacky

# Source every GUI file, foundations first.
#
# A plain alphabetical glob used to do this, and held only by luck: a few files
# run code at source time (icons.tcl creates the images, palette.tcl defines
# the colour lookup), and anything that reads them while its own definition is
# being compiled - a snit typevariable default or typeconstructor, say - has to
# come after. Alphabetical order happened to satisfy that until it didn't.
#
# Everything else is a snit type or widget. Those resolve each other at
# construction time, long after all of this has run, so their order is free and
# they stay globbed - a new widget needs no edit here.
#
# Eager, like lib/taco with its modules: the cost is a few ms per snit type
# spread evenly, with no hotspot worth deferring.
apply {{} {
    set guidir [file dirname [file normalize [info script]]]

    # Must be in place before the widgets are compiled.
    set foundations {
        palette.tcl
        icons.tcl
        presencecolors.tcl
        timefmt.tcl
        pathsafe.tcl
        raiseexisting.tcl
        clickoutside.tcl
        compensate.tcl
        inputdialog.tcl
    }
    # Not widgets: this file and the package index.
    set skip [list tackygui.tcl pkgIndex.tcl {*}$foundations]

    foreach name $foundations {
        uplevel #0 [list source [file join $guidir $name]]
    }
    foreach path [lsort [glob [file join $guidir *.tcl]]] {
        if {[file tail $path] in $skip} continue
        uplevel #0 [list source $path]
    }
}}
