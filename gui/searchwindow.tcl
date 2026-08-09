# searchwindow - toplevel window for full text search over one chat.
#
# Searches the local store; ticking "Also search server" adds a MAM pass whose
# hits land in that same store, so the result list is local either way. The
# box is enabled only for archives advertising a fulltext field.
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
    variable alsoRemote 0
    variable lastCursor ""
    variable isComplete 0
    variable searchTag
    variable ca
    component authors

    constructor args {
        $self configurelist $args
        set searchTag $win/search
        wm title $win "Search — [jid bare $options(-jid)]"

        # Top frame: entry + buttons
        set top [ttk::frame $win.top]
        ttk::entry $top.entry -textvariable [myvar query]
        ttk::checkbutton $top.remote -text "Also search server" \
            -variable [myvar alsoRemote] -command [mymethod OnRemoteToggle]
        ttk::button $top.search -text "Search" -command [mymethod DoSearch]
        pack $top.entry -side left -expand yes -fill x -padx {4 2} -pady 4
        pack $top.remote -side left -padx {2 2} -pady 4
        pack $top.search -side left -padx {2 4} -pady 4
        pack $top -fill x

        # Stays off until the archive says it can run the search.
        $top.remote configure -state disabled

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

        bind $ca <<MessageClick>> [mymethod OnClick %d]

        # Highlight tag
        [$ca textwidget] tag configure search_match -background yellow \
            -font "Helvetica 13 bold"

        install authors using authornames ${selfns}::authors \
            -acc $options(-acc) -chat $options(-jid) \
            -tag $searchTag/author \
            -changed-command [list $ca author update]
        ::tacky mam fulltextSupported -acc $options(-acc) \
            -chat $options(-jid) -command [mymethod OnRemoteCapability]

        focus $top.entry
    }

    destructor {
        catch {::tacky message cancel -acc $options(-acc) -tag $searchTag}
    }

    method OnRemoteCapability {supported} {
        if {![winfo exists $win]} return
        if {$supported} {
            $win.top.remote configure -state normal
            return
        }
        # The status label is transient, so the box states its own reason.
        $win.top.remote configure -text "Server can't search"
    }

    method OnRemoteToggle {} {
        if {$query eq ""} return
        $self DoSearch
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
        ::tacky message search -acc $options(-acc) \
            -chat $options(-jid) -query $query \
            -source [expr {$alsoRemote ? "both" : "local"}] \
            -tag $searchTag -command [mymethod OnResults]
    }

    # Paging stays local so lastCursor stays a timestamp, never an RSM id.
    method LoadMore {} {
        $win.bot.status configure -text "Searching\u2026"
        $win.bot.more configure -state disabled
        ::tacky message search -acc $options(-acc) \
            -chat $options(-jid) -query $query -source local \
            -before $lastCursor -tag $searchTag \
            -command [mymethod OnResults]
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

        set enriched [lmap msg $messages {
            enrich_store_message $msg [list $authors label]
        }]
        set inserted [$ca apply $enriched]

        # Highlight search terms in newly inserted messages
        set text [$ca textwidget]
        foreach key $inserted {
            set range [$ca messages body-range $key]
            if {$range eq ""} continue
            lassign $range pos last
            while 1 {
                set pos [$text search -nocase -count n -- $query $pos $last]
                if {$pos eq ""} break
                $text tag add search_match $pos "$pos + ${n} chars"
                set pos "$pos + ${n} chars"
            }
        }
    }

    method OnClick {key} {
        if {$options(-goto-command) ne ""} {
            {*}$options(-goto-command) $key
        }
    }
}
