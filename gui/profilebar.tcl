if 0 {
    profilebar - compact identity bar showing avatar + display name.

    Sits above the contact list. Clicking fires -command.

    Usage:
        profilebar .bar -acc romeo@montague.lit
        .bar configure -command [list puts "clicked"]
}

snit::widget profilebar {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -command -default ""

    constructor args {
	$self configurelist $args

	if {$options(-acc) eq ""} {
	    error "profilebar requires -acc"
	}

	set acc $options(-acc)
	set t $options(-tacky)

	# Avatar label (32x32)
	ttk::label $win.avatar -image [avatarcache default] -padding 2
	avatarcache track \
	    -acc $acc -jid $acc -tag $win \
	    -command [mymethod OnAvatar]
	# Name label — default to JID username until we fetch the nick
	ttk::label $win.name -text [jid username $acc] -padding {4 2}
	# Connection status indicator
	ttk::label $win.status -text "\u25CF" -foreground gray50 -padding {4 2}

	pack $win.avatar -side left
	pack $win.name -side left -fill x -expand yes
	pack $win.status -side right

	# Click binding on the whole bar
	foreach w [list $win $win.avatar $win.name $win.status] {
	    bind $w <Button-1> [mymethod OnClick]
	}

	# Connection state events
	$t listen -tag $win conn <State> -acc $acc [mymethod OnConnState]

	# Fetch display name
	$t bookmarks defaultNick -acc $acc \
	    -tag $win -command [mymethod OnDefaultNick]
    }

    destructor {
	catch {$options(-tacky) unlisten $win}
	catch {avatarcache untrack -tag $win}
    }

    # --- Event handlers ---

    method OnDefaultNick {name} {
	if {$name ne ""} {
	    $win.name configure -text $name
	}
    }

    method OnAvatar {img} {
	$win.avatar configure -image $img
    }

    method OnConnState {ev} {
	set state [dict get $ev -state]
	switch -- $state {
	    connected {
		$win.status configure -text "\u25CF" -foreground green4
	    }
	    connecting - authenticating - binding {
		$win.status configure -text "\u25CF" -foreground goldenrod3
	    }
	    waiting {
		$win.status configure -text "\u25CF" -foreground goldenrod3
	    }
	    disconnected {
		$win.status configure -text "\u25CF" -foreground gray50
	    }
	}
    }

    method OnClick {} {
	if {$options(-command) ne ""} {
	    {*}$options(-command)
	}
    }
}
