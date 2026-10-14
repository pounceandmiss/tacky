# disclosure - a section that folds to its header line.
#
#   ▸ Title  detail                                   summary
#
# The ▸/▾ button, the title and the detail open and close it. Closed, only
# the header shows, so the summary should say what the hidden part holds.
# The body is a frame to put the section's content in: content made as a
# child of the body, or of any ancestor of it, packed or gridded -in it.
#
# Tk has no widget for this; omemoroomkeys and the account's connection
# settings use this one.
#
#   disclosure .d -title "Proxy" ?-detail text? ?-summary text?
#       ?-summaryforeground color? ?-titlefont font? ?-open 0|1?
#       ?-command cmd?
#   .d body            -> the body frame
#   .d toggle          open or close it as a click does
#
# -command runs on a click, with the new state appended (1 open, 0 closed);
# configuring -open does not run it.

package require snit

snit::widget disclosure {
    hulltype ttk::frame

    option -title -default "" -configuremethod SetLabel
    option -detail -default "" -configuremethod SetLabel
    option -summary -default "" -configuremethod SetLabel
    option -summaryforeground -default gray40 -configuremethod SetLabel
    option -titlefont -default TkDefaultFont -configuremethod SetLabel
    option -open -default 0 -configuremethod SetOpen
    option -command -default ""

    constructor args {
        set head [ttk::frame $win.head]
        ttk::button $head.fold -style Toolbutton -width 2 -text "▸" \
            -takefocus 1 -command [mymethod toggle]
        ttk::label $head.title
        ttk::label $head.detail -foreground gray40
        ttk::label $head.summary
        pack $head.fold $head.title $head.detail -side left -padx {0 4}
        pack $head.summary -side right -padx 4
        foreach w [list $head.title $head.detail] {
            bind $w <Button-1> [mymethod toggle]
        }
        pack $head -fill x
        ttk::frame $win.body
        $self configurelist $args
        $self SetLabel -title $options(-title)
        $self SetOpen -open $options(-open)
    }

    method body {} {
        return $win.body
    }

    method toggle {} {
        $self configure -open [expr {!$options(-open)}]
        if {$options(-command) ne ""} {
            uplevel #0 [linsert $options(-command) end $options(-open)]
        }
    }

    method SetLabel {option value} {
        set options($option) $value
        set head $win.head
        $head.title configure -text $options(-title) -font $options(-titlefont)
        $head.detail configure -text $options(-detail)
        $head.summary configure -text $options(-summary) \
            -foreground $options(-summaryforeground)
    }

    method SetOpen {option value} {
        set options($option) [expr {$value ? 1 : 0}]
        $win.head.fold configure -text [expr {$options(-open) ? "▾" : "▸"}]
        if {$options(-open)} {
            pack $win.body -fill x
        } else {
            pack forget $win.body
        }
    }
}
