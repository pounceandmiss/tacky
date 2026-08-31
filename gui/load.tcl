# Source every GUI file, foundations first.
#
# A plain alphabetical glob used to do this, and held only by luck: a few files
# run code at source time (icons.tcl creates the images, palette.tcl defines
# the colour lookup), and anything that reads them while its own definition is
# being compiled - a snit typevariable default, say - has to come after.
# Alphabetical order happened to satisfy that until it didn't.
#
# Everything else is a snit type or widget. Those resolve each other at
# construction time, long after all of this has run, so their order is free and
# they stay globbed - a new widget needs no edit here.

# Files that must be in place before the widgets are compiled.
set ::gui_foundations {
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

proc load_gui {guidir} {
    foreach name $::gui_foundations {
        uplevel #0 [list source [file join $guidir $name]]
    }
    foreach path [lsort [glob [file join $guidir *.tcl]]] {
        set name [file tail $path]
        if {$name eq "load.tcl" || $name in $::gui_foundations} continue
        uplevel #0 [list source $path]
    }
}
