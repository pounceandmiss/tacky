if 0 {
    participantlegend - read-only dialog explaining MUC roles,
    affiliation prefixes, and presence colors.

    Usage:
        participantlegend show
}

snit::widget participantlegend {
    hulltype ttk::frame

    typemethod show {} {
	set top .participant_legend
	if {[winfo exists $top]} {
	    wm deiconify $top
	    raise $top
	    return
	}
	toplevel $top
	wm title $top "Participant Legend"
	wm resizable $top false false
	pack [participantlegend $top.content] -expand yes -fill both
	bind $top <Escape> [list destroy $top]
    }

    constructor args {
	set t [rotext $win.t -wrap word -cursor arrow -relief flat \
	    -borderwidth 0 -width 52 -height 22 -padx 12 -pady 8]
	pack $t -expand yes -fill both

	# -- Text tags --
	set boldfont TkTextFont_bold
	if {$boldfont ni [font names]} {
	    font create $boldfont {*}[font configure TkTextFont] -weight bold
	}
	$t tag configure heading -font TkHeadingFont -spacing1 10 -spacing3 4
	$t tag configure bold -font $boldfont
	$t tag configure dim -foreground gray50 -font TkSmallCaptionFont
	$t tag configure indent -lmargin1 14 -lmargin2 14
	foreach {tag color} {
	    available green4 away goldenrod3 xa darkorange3
	    dnd red3 offline gray50
	} {
	    $t tag configure pres_$tag -foreground $color -font $boldfont
	}

	# -- Roles --
	$t ins end "Roles (temporary, per session)\n" heading
	foreach {name desc} {
	    Moderators  "Can kick, mute, and manage the room"
	    Participants "Regular speakers \u2014 can send messages"
	    Visitors    "Listen only \u2014 cannot speak in moderated rooms"
	} {
	    $t ins end "  $name  " {indent bold}
	    $t ins end "$desc\n" {indent dim}
	}

	# -- Affiliation prefixes --
	$t ins end "Affiliation Prefixes (persistent)\n" heading
	foreach {prefix name desc} {
	    *   Owner   "Full control over the room"
	    &   Admin   "Can ban users and grant membership"
	    +   Member  "Recognized member of the room"
	    {}  (none)  "No special affiliation"
	} {
	    if {$prefix eq ""} {
		$t ins end "     $name  " {indent bold}
	    } else {
		$t ins end "  $prefix  $name  " {indent bold}
	    }
	    $t ins end "$desc\n" {indent dim}
	}

	# -- Presence colors --
	$t ins end "Presence Colors\n" heading
	foreach {tag lbl desc} {
	    available  Available        "Online and available"
	    away       Away             "Temporarily away"
	    xa         "Extended Away"  "Away for a longer period"
	    dnd        "Do Not Disturb" "Does not want to be disturbed"
	    offline    Offline          "Not connected"
	} {
	    $t ins end "  $lbl  " [list indent pres_$tag]
	    $t ins end "$desc\n" {indent dim}
	}

	ttk::button $win.close -text "Close" \
	    -command [list destroy [winfo toplevel $win]]
	pack $win.close -pady {4 8}
    }
}
