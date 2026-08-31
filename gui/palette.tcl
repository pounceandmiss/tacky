# The colours the app paints itself with, named by what they are for.
# presence_colors covers the per-presence dots; everything else lives here.
#
# These are the light-theme values the widgets used to carry inline. Gathering
# them means a theme has one place to change, and a new widget has one place to
# look rather than a neighbour to copy a hex code from.
namespace eval palette {
    variable Colors {
        accent        #2d6da3
        dim           #888888
        muted         #666666
        inset         #f0f3f6
        error         #b04040
        notify-card   #ffffff
        notify-border #b8b8b8
        notify-accent #4a76c8
        mention       #d08b18
        drop-target   #cfe0ff
        invalid       #ffcccc
        highlight     yellow
        system        gray50
        quote         green
    }
}

# The colour for a role. Unknown roles are an error, not a silent black.
proc palette {role} {
    variable palette::Colors
    if {![dict exists $palette::Colors $role]} {
        error "unknown palette role \"$role\""
    }
    return [dict get $palette::Colors $role]
}
