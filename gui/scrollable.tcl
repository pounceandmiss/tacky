snit::widget scrollable {
    hulltype ttk::frame
    component canvas
    component vsb

    # The child widget path set by setwidget
    variable child ""
    variable cwin ""

    constructor args {
	install canvas using canvas $win.canvas -highlightthickness 0
	install vsb using ttk::scrollbar $win.vsb -orient vertical \
	    -command [list $canvas yview]
	$canvas configure -yscrollcommand [list $vsb set]

	pack $vsb -side right -fill y
	pack $canvas -side left -fill both -expand yes

	bind $canvas <Configure> [mymethod OnCanvasConfigure]
	# Linux mousewheel
	bind $canvas <Button-4> {%W yview scroll -5 units}
	bind $canvas <Button-5> {%W yview scroll 5 units}
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
