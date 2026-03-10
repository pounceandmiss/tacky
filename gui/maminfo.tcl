if 0 {
    maminfo - dialog to query and display MAM archive metadata and supported
    form fields from the server.

    Usage:
        maminfo open romeo@montague.lit
}

snit::widget maminfo {
    hulltype ttk::frame

    option -acc -readonly yes

    variable version_text ""
    variable version_error ""
    variable metadata_dict {}
    variable metadata_error ""
    variable fields_list {}
    variable pending 0

    typemethod open {account} {
	set top .maminfo_[string map {@ _ . _} $account]
	if {[winfo exists $top]} {
	    wm deiconify $top
	    raise $top
	    return
	}
	toplevel $top
	wm title $top "MAM Archive Info"
	wm resizable $top 1 0
	pack [maminfo $top.mi -acc $account] \
	    -expand yes -fill both -padx 10 -pady 10
    }

    constructor args {
	$self configurelist $args

	if {$options(-acc) eq ""} {
	    error "maminfo requires -acc"
	}

	# --- Target row ---
	ttk::label $win.targetlbl -text "Target"
	ttk::entry $win.target -width 40
	ttk::button $win.query -text "Query" \
	    -command [mymethod Query]

	grid $win.targetlbl -row 0 -column 0 -sticky w  -padx 4 -pady 4
	grid $win.target    -row 0 -column 1 -sticky ew  -padx 4 -pady 4
	grid $win.query     -row 0 -column 2 -sticky e   -padx 4 -pady 4

	ttk::separator $win.sep0 -orient horizontal
	grid $win.sep0 -row 1 -column 0 -columnspan 3 -sticky ew -pady 6

	# --- Text display ---
	set t [rotext $win.t -wrap word -cursor arrow -relief flat \
	    -borderwidth 0 -width 52 -height 18 -padx 12 -pady 8]
	grid $t -row 2 -column 0 -columnspan 3 -sticky nsew

	grid columnconfigure $win 1 -weight 1
	grid rowconfigure $win 2 -weight 1

	# -- Text tags --
	set boldfont TkTextFont_bold
	if {$boldfont ni [font names]} {
	    font create $boldfont {*}[font configure TkTextFont] -weight bold
	}
	$t tag configure heading -font TkHeadingFont -spacing1 10 -spacing3 4
	$t tag configure bold -font $boldfont
	$t tag configure label -font $boldfont -lmargin1 14 -lmargin2 14
	$t tag configure value -lmargin1 0 -lmargin2 14
	$t tag configure dim -foreground gray50
	$t tag configure error -foreground red
	$t tag configure indent -lmargin1 14 -lmargin2 14

	$win.target insert 0 [jid domain $options(-acc)]
    }

    destructor {}

    method Query {} {
	set version_text ""
	set version_error ""
	set metadata_dict {}
	set metadata_error ""
	set fields_list {}
	set pending 3
	$self Render

	set target [string trim [$win.target get]]

	# Version query — target entity, or own server if empty
	set versionTo [expr {$target ne "" ? $target
	    : [jid domain $options(-acc)]}]
	::tacky caps softwareVersion -acc $options(-acc) \
	    -to $versionTo -command [mymethod OnVersion]

	# Metadata and form fields
	set mamArgs [list -acc $options(-acc)]
	if {$target ne ""} {
	    lappend mamArgs -to $target
	}
	::tacky mam metadata {*}$mamArgs \
	    -command [mymethod OnMetadata]
	::tacky mam formfields {*}$mamArgs \
	    -command [mymethod OnFields]
    }

    # --- Callbacks ---

    method OnVersion {d} {
	if {![winfo exists $win]} return
	incr pending -1
	if {[dict exists $d error] && [dict get $d error]} {
	    set version_text ""
	    set version_error [dict getdef $d error_text "Version query failed"]
	} else {
	    set parts {}
	    foreach key {name version os} {
		set v [dict get $d $key]
		if {$v ne ""} { lappend parts $v }
	    }
	    set version_text [join $parts " "]
	    set version_error ""
	}
	$self Render
    }

    method OnMetadata {d} {
	if {![winfo exists $win]} return
	incr pending -1
	if {[dict exists $d error] && [dict get $d error]} {
	    set metadata_error "Not supported"
	    set metadata_dict {}
	} else {
	    set metadata_dict $d
	    set metadata_error ""
	}
	$self Render
    }

    method OnFields {fields} {
	if {![winfo exists $win]} return
	incr pending -1
	set fields_list $fields
	$self Render
    }

    method Render {} {
	set t $win.t
	$t del 1.0 end

	# -- Server --
	$t ins end "Server\n" heading
	if {$version_text ne ""} {
	    $t ins end "  $version_text\n" indent
	} elseif {$version_error ne ""} {
	    $t ins end "  $version_error\n" {indent error}
	} elseif {$pending > 0} {
	    $t ins end "  ...\n" indent
	} else {
	    $t ins end "  —\n" indent
	}

	# -- Metadata --
	$t ins end "Metadata\n" heading
	if {[dict size $metadata_dict] > 0} {
	    foreach {key label} {
		start_timestamp "Oldest message"
		start_id        "Oldest ID"
		end_timestamp   "Newest message"
		end_id          "Newest ID"
	    } {
		set val [dict get $metadata_dict $key]
		$t ins end "  $label  " label
		if {[string match *_timestamp $key] && $val ne ""} {
		    $t ins end "[FormatTimestamp $val]\n" value
		} elseif {$val ne ""} {
		    $t ins end "$val\n" {value dim}
		} else {
		    $t ins end "—\n" {value dim}
		}
	    }
	} elseif {$metadata_error ne ""} {
	    $t ins end "  $metadata_error\n" {indent error}
	} elseif {$pending > 0} {
	    $t ins end "  ...\n" indent
	} else {
	    $t ins end "  —\n" indent
	}

	# -- Fields --
	$t ins end "Supported Fields\n" heading
	if {[llength $fields_list] > 0} {
	    foreach f $fields_list {
		$t ins end "  $f\n" indent
	    }
	} elseif {$pending > 0} {
	    $t ins end "  ...\n" indent
	} else {
	    $t ins end "  (none)\n" {indent dim}
	}
    }
}

proc FormatTimestamp {us} {
    if {$us eq ""} { return "(empty)" }
    set secs [expr {$us / 1000000}]
    return [clock format $secs -format "%Y-%m-%d %H:%M:%S" -gmt 0]
}
