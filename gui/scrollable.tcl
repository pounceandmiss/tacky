snit::widget scrollable {
    hulltype ttk::frame
    component canvas
    component vsb

    # The child widget path set by setwidget
    variable child ""
    variable cwin ""

    constructor args {
        install canvas using canvas $win.canvas -highlightthickness 0
        # Match the ttk theme so the canvas doesn't show its classic-Tk
        # (white) background around the content frame.
        set bg [ttk::style lookup TFrame -background]
        if {$bg ne ""} { $canvas configure -background $bg }
        install vsb using ttk::scrollbar $win.vsb -orient vertical \
            -command [list $canvas yview]
        $canvas configure -yscrollcommand [list $vsb set]

        pack $vsb -side right -fill y
        pack $canvas -side left -fill both -expand yes

        bind $canvas <Configure> [mymethod OnCanvasConfigure]
        # Wheel scrolling: X11 sends Button-4/5; Tk 9 / other platforms
        # send <MouseWheel> with %D.
        bind $canvas <Button-4> {%W yview scroll -5 units}
        bind $canvas <Button-5> {%W yview scroll 5 units}
        bind $canvas <MouseWheel> \
            {%W yview scroll [expr {%D > 0 ? -5 : 5}] units}
    }

    method setwidget {w} {
        set child $w
        set cwin [$canvas create window 0 0 -anchor nw -window $w]
        bind $w <Configure> [mymethod OnChildConfigure]
    }

    method OnCanvasConfigure {} {
        if {$cwin ne ""} {
            $canvas itemconfigure $cwin -width [winfo width $canvas]
        }
    }

    method OnChildConfigure {} {
        $canvas configure -scrollregion \
            [list 0 0 0 [winfo reqheight $child]]
    }
}
