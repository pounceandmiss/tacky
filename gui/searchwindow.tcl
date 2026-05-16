# searchwindow — toplevel window for full text search via MAM.
#
# Displays search results in a chatarea. Clicking a result navigates
# the main chatview to that message via -goto-command.
#
# Usage:
#   searchwindow $w -acc $acc -jid $jid -goto-command {apply {{ts} {...}}}

snit::widget searchwindow {
    hulltype toplevel

    option -acc -readonly yes
    option -jid -readonly yes
    option -goto-command -default ""

    variable query ""
    variable field "default"
    variable lastCursor ""
    variable isComplete 0
    variable searchTag
    variable ca
    variable Names

    constructor args {
	$self configurelist $args
	set searchTag $win/search
	set Names [dict create]
	wm title $win "Search — [jid bare $options(-jid)]"

	# Top frame: entry + buttons
	set top [ttk::frame $win.top]
	ttk::entry $top.entry -textvariable [myvar query]
	ttk::combobox $top.field -textvariable [myvar field] -width 16 \
	    -values [list default withtext {{urn:xmpp:fulltext:0}fulltext}]
	ttk::button $top.search -text "Search" -command [mymethod DoSearch]
	pack $top.entry -side left -expand yes -fill x -padx {4 2} -pady 4
	pack $top.field -side left -padx {2 2} -pady 4
	pack $top.search -side left -padx {2 4} -pady 4
	pack $top -fill x

	bind $top.entry <Return> [mymethod DoSearch]

	# Chat area for results
	set ca [chatarea $win.ca]
	pack $ca -expand yes -fill both

	# Bottom frame: load more + status
	set bot [ttk::frame $win.bot]
	ttk::button $bot.more -text "Load more" \
	    -command [mymethod LoadMore]
	ttk::label $bot.status -text ""
	pack $bot.more -side left -padx 4 -pady 4
	pack $bot.status -side left -padx 4 -pady 4
	pack $bot -fill x
	$bot.more configure -state disabled
	grid remove $bot.more

	# Click binding on the text widget
	bind $win.ca.text <Button-1> [mymethod OnClick %x %y]

	# Highlight tag
	$win.ca.text tag configure search_match -background yellow \
	    -font "Helvetica 13 bold"

	::tacky listen -tag $searchTag/author author <Changed> \
	    -acc $options(-acc) -chat $options(-jid) [mymethod OnAuthorChanged]
	::tacky author get -acc $options(-acc) -chat $options(-jid) \
	    -command [mymethod OnAuthorSeed]

	focus $top.entry
    }

    destructor {
	catch {::tacky message cancel -acc $options(-acc) -tag $searchTag}
	catch {::tacky unlisten $searchTag/author}
    }

    method OnAuthorSeed {names} {
	set Names $names
	dict for {fromJid name} $names {
	    $ca author update $fromJid $name
	}
    }

    method OnAuthorChanged {ev} {
	set fromJid [dict get $ev -from]
	set name [dict get $ev -name]
	dict set Names $fromJid $name
	$ca author update $fromJid $name
    }

    method DoSearch {} {
	if {$query eq ""} return
	::tacky message cancel -acc $options(-acc) -tag $searchTag
	$ca clear
	set lastCursor ""
	set isComplete 0
	$win.bot.status configure -text "Searching\u2026"
	$win.bot.more configure -state disabled
	pack forget $win.bot.more
	set searchArgs [list -acc $options(-acc) \
			    -chat $options(-jid) -query $query \
			    -tag $searchTag -command [mymethod OnResults]]
	if {$field ne "default" && $field ne ""} {
	    lappend searchArgs -field $field
	}
	::tacky message search {*}$searchArgs
    }

    method LoadMore {} {
	$win.bot.status configure -text "Searching\u2026"
	$win.bot.more configure -state disabled
	set searchArgs [list -acc $options(-acc) \
			    -chat $options(-jid) -query $query \
			    -before $lastCursor -tag $searchTag \
			    -command [mymethod OnResults]]
	if {$field ne "default" && $field ne ""} {
	    lappend searchArgs -field $field
	}
	::tacky message search {*}$searchArgs
    }

    method OnResults {result} {
	if {![winfo exists $win]} return
	$win.bot.status configure -text ""

	if {[dict exists $result error] && [dict get $result error]} {
	    $win.bot.status configure -text "Search failed."
	    return
	}

	set lastCursor [dict get $result last]
	set isComplete [dict get $result complete]

	if {$isComplete} {
	    $win.bot.more configure -state disabled
	    pack forget $win.bot.more
	} else {
	    pack $win.bot.more -side left -padx 4 -pady 4 -before $win.bot.status
	    $win.bot.more configure -state normal
	}

	set messages [dict get $result messages]
	if {[llength $messages] == 0} {
	    $win.bot.status configure -text "No results."
	    return
	}

	# Enrich and stitch prev pointers sequentially
	set existing [$ca messages ids]
	set lastId [lindex $existing end]
	set enriched {}
	foreach msg $messages {
	    set emsg [$self EnrichMessage $msg $lastId]
	    lappend enriched $emsg
	    set lastId [dict get $emsg id]
	}

	set inserted [$ca apply $enriched]

	# Highlight search terms in newly inserted messages
	set text $win.ca.text
	foreach id $inserted {
	    set first item.$id.body.first
	    set last item.$id.body.last
	    if {[catch {$text index $first}]} continue
	    set pos $first
	    while 1 {
		set pos [$text search -nocase -count n -- $query $pos $last]
		if {$pos eq ""} break
		$text tag add search_match $pos "$pos + ${n} chars"
		set pos "$pos + ${n} chars"
	    }
	}
    }

    method EnrichMessage {storeDict prevId} {
	set d [enrich_store_message $storeDict $Names]
	dict set d prev $prevId
	return $d
    }

    method OnClick {x y} {
	set tags [$win.ca.text tag names @$x,$y]
	foreach tag $tags {
	    if {[string match "item.*" $tag] && ![string match "item.*.*" $tag]} {
		set messageId [string range $tag 5 end]
		if {$options(-goto-command) ne ""} {
		    {*}$options(-goto-command) $messageId
		}
		return
	    }
	}
    }
}
