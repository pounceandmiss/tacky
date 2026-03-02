snit::widget pages {
    # Like notebook but without tabs
    hulltype ttk::frame

    method add {w} {
	grid $w -row 0 -column 0 -sticky news
	grid rowconfigure $win 0 -weight 1
	grid columnconfigure $win 0 -weight 1
    }
    
    method raise {w} {
	raise $w
    }
}
