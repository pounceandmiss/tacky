if 0 {
    profilebar - compact identity bar showing avatar + display name.

    Sits above the contact list. Clicking fires -command.

    Usage:
        profilebar .bar -acc romeo@montague.lit
        .bar configure -command [list puts "clicked"]
}

# Shared fallback avatar
if {[catch {
    image create photo profilebar::defaultAvatar \
	-file /usr/share/icons/mate/32x32/status/avatar-default.png
}]} {
    image create photo profilebar::defaultAvatar -width 32 -height 32
}

snit::widget profilebar {
    hulltype ttk::frame

    option -acc -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -command -default ""

    variable currentAvatar ""

    constructor args {
	$self configurelist $args

	if {$options(-acc) eq ""} {
	    error "profilebar requires -acc"
	}

	set acc $options(-acc)
	set t $options(-tacky)

	# Avatar label (32x32)
	ttk::label $win.avatar -image profilebar::defaultAvatar -padding 2
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
	    -command [mymethod OnDefaultNick]

	# Own avatar
	$t avatar visible -acc $acc -jid $acc
	$t avatar thumb -acc $acc -jid $acc \
	    -command [mymethod OnAvatarThumb]
	$t listen -tag $win avatar <Update> -acc $acc -jid $acc \
	    [mymethod OnAvatarUpdate]
    }

    destructor {
	catch {$options(-tacky) unlisten $win}
	if {$currentAvatar ne ""} {
	    catch {$options(-tacky) avatar invisible \
		-acc $options(-acc) -jid $options(-acc)}
	    catch {image delete $currentAvatar}
	}
    }

    # --- Event handlers ---

    method OnDefaultNick {name} {
	if {$name ne ""} {
	    $win.name configure -text $name
	}
    }

    method OnAvatarThumb {data} {
	if {$data eq ""} return
	if {$currentAvatar ne ""} {
	    image delete $currentAvatar
	}
	set currentAvatar [image create photo -data $data]
	$win.avatar configure -image $currentAvatar
    }

    method OnAvatarUpdate {ev} {
	if {$currentAvatar ne ""} {
	    image delete $currentAvatar
	    set currentAvatar ""
	    $win.avatar configure -image profilebar::defaultAvatar
	}
	$options(-tacky) avatar thumb \
	    -acc $options(-acc) -jid $options(-acc) \
	    -command [mymethod OnAvatarThumb]
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
