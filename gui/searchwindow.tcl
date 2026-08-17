# searchwindow - toplevel window for full text search.
#
# Searches the local store; ticking "Also search server" adds a MAM pass whose
# hits land in that same store, so the result list is local either way. The
# box is enabled only for archives advertising a fulltext field.
#
# With no -jid it searches every chat in the account instead. That is local
# only - MAM queries one archive - so the server box never appears, rows label
# their chat, and -goto-command receives a {chat timestamp} pair rather than a
# bare timestamp.
#
# Displays search results in a chatarea. Clicking a result navigates
# to that message via -goto-command.
#
# Usage:
#   searchwindow $w -acc $acc -jid $jid -goto-command {apply {{ts} {...}}}
#   searchwindow $w -acc $acc -goto-command {apply {{pair} {...}}}

snit::widget searchwindow {
    hulltype toplevel

    option -acc -readonly yes
    option -jid -default "" -readonly yes
    option -goto-command -default ""

    variable query ""
    variable alsoRemote 0
    variable lastCursor ""
    variable isComplete 0
    variable searchTag
    variable ca
    variable wholeAccount 0
    # Account-wide only: chat JID -> authornames, built as chats turn up in
    # results. A name cache is per chat, so one window needs several.
    variable authorsByChat
    variable authorSeq 0

    constructor args {
        $self configurelist $args
        set searchTag $win/search
        set wholeAccount [expr {$options(-jid) eq ""}]
        set authorsByChat [dict create]
        if {$wholeAccount} {
            wm title $win "Search - $options(-acc)"
        } else {
            wm title $win "Search - [jid bare $options(-jid)]"
        }

        # Top frame: entry + buttons
        set top [ttk::frame $win.top]
        ttk::entry $top.entry -textvariable [myvar query]
        ttk::checkbutton $top.remote -text "Also search server" \
            -variable [myvar alsoRemote] -command [mymethod OnRemoteToggle]
        ttk::button $top.search -text "Search" -command [mymethod DoSearch]
        pack $top.entry -side left -expand yes -fill x -padx {4 2} -pady 4
        if {!$wholeAccount} {
            pack $top.remote -side left -padx {2 2} -pady 4
            # Stays off until the archive says it can run the search.
            $top.remote configure -state disabled
        }
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
        pack forget $bot.more

        bind $ca <<MessageClick>> [mymethod OnClick %d]

        if {!$wholeAccount} {
            $self Authors $options(-jid)
            ::tacky mam fulltextSupported -acc $options(-acc) \
                -chat $options(-jid) -command [mymethod OnRemoteCapability]
        }

        focus $top.entry
    }

    destructor {
        catch {::tacky message cancel -acc $options(-acc) -tag $searchTag}
        dict for {chat obj} $authorsByChat { catch {$obj destroy} }
    }

    # The name cache for one chat, built on first sight of it in a result. Its
    # seed announces every name it has, and does so from inside the
    # constructor, so nothing reached from -changed-command may come back
    # through here - the object is not registered yet.
    method Authors {chat} {
        if {[dict exists $authorsByChat $chat]} {
            return [dict get $authorsByChat $chat]
        }
        set n [incr authorSeq]
        set obj [authornames ${selfns}::authors$n \
            -acc $options(-acc) -chat $chat \
            -tag $searchTag/author/$n \
            -changed-command [mymethod OnAuthorChanged $chat]]
        dict set authorsByChat $chat $obj
        return $obj
    }

    # authornames hands over the resolved name, so this decorates it rather
    # than asking the cache again.
    method OnAuthorChanged {chat jid name} {
        $ca author update [$self Author $chat $jid] [$self Decorate $chat $jid $name]
    }

    # Who chatarea considers the author of a row. It repaints by this value,
    # so account-wide it has to be per chat: our own bare JID authors messages
    # in every 1:1, and each of those rows wants its own chat's label.
    method Author {chat jid} {
        if {!$wholeAccount} { return $jid }
        return [list $chat $jid]
    }

    method Label {chat jid} {
        $self Decorate $chat $jid [[$self Authors $chat] label $jid]
    }

    # Account-wide, the label is where a row says which chat it came from.
    # Only an incoming 1:1 goes unprefixed, where the author is the chat; the
    # comparison is against the chat JID rather than the room, since a room
    # occupant's bare JID is the room itself.
    method Decorate {chat jid name} {
        if {!$wholeAccount} { return $name }
        if {$chat eq [jid bare $jid]} { return $name }
        return "[regsub {\?join$} $chat {}] - $name"
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
            {*}[$self ChatArgs] -query $query \
            -source [expr {$alsoRemote ? "both" : "local"}] \
            -tag $searchTag -command [mymethod OnResults]
    }

    # Paging stays local so lastCursor stays a store cursor, never an RSM id.
    method LoadMore {} {
        $win.bot.status configure -text "Searching\u2026"
        $win.bot.more configure -state disabled
        ::tacky message search -acc $options(-acc) \
            {*}[$self ChatArgs] -query $query -source local \
            -before $lastCursor -tag $searchTag \
            -command [mymethod OnResults]
    }

    method ChatArgs {} {
        if {$wholeAccount} { return {} }
        return [list -chat $options(-jid)]
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
            $self Enrich $msg
        }]
        $ca apply $enriched
        # Where the backend matched. A row `apply` didn't draw is a no-op.
        foreach msg $enriched {
            if {[dict exists $msg matches]} {
                $ca highlight matches [dict get $msg key] [dict get $msg matches]
            }
        }
    }

    # A timestamp only identifies a message within its own chat, so an
    # account-wide row is keyed by the pair. `sort` stays the timestamp, and
    # rowlist's tiebreak on the key orders equal stamps by chat, as the store
    # already did. avatar_jid keeps the real JID either way - avatars are per
    # person, not per chat.
    method Enrich {msg} {
        set chat [dict get $msg chat_jid]
        set d [enrich_store_message $msg [mymethod Label $chat]]
        if {$wholeAccount} {
            dict set d key [list $chat [dict get $msg timestamp]]
            dict set d from_jid [$self Author $chat [dict get $msg from_jid]]
        }
        return $d
    }

    method OnClick {key} {
        if {$options(-goto-command) ne ""} {
            {*}$options(-goto-command) $key
        }
    }
}
