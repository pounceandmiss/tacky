# taco_chatlist - aggregated contact list (roster + bookmarks + recent chats).
#
# Merges data from roster, bookmarks, and chats into a single search
# result with three sections: recent, roster, bookmarks.  Emits a
# unified chatlist <Changed> event when any source changes.

snit::type taco_chatlist {
    option -client -readonly yes

    variable client
    variable db
    variable RecentJids {}

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]

        $client bus subscribe $self roster:<Changed> [mymethod OnDataChanged]
        $client bus subscribe $self bookmarks:<Changed> [mymethod OnDataChanged]
        $client bus subscribe $self chats:<Updated> [mymethod OnChatUpdated]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    method OnDataChanged {args} {
        $client emit chatlist <Changed>
    }

    method OnChatUpdated {args} {
        array set opts {-jid ""}
        array set opts $args
        set jid $opts(-jid)

        set allJids [$client chats latest]
        set newTop20 [lrange $allJids 0 19]

        set name [$self ResolveName $jid]
        set source [$self ResolveSource $jid]
        set ev [list -jid $jid -name $name -source $source]
        set aj [$self ResolveAutojoin $jid]
        if {$aj ne ""} {
            lappend ev -autojoin $aj
        }
        $client emit chatlist <RecentTop> {*}$ev

        # Check if a JID fell off the old top-20
        foreach old $RecentJids {
            if {$old ni $newTop20} {
                $client emit chatlist <RecentDrop> -jid $old
            }
        }

        set RecentJids $newTop20
    }

    method ResolveName {jid} {
        set name [$db onecolumn {
            SELECT name FROM roster_item WHERE jid=$jid
        }]
        if {$name ne ""} { return $name }
        $db onecolumn {
            SELECT name FROM bookmark WHERE jid=$jid
        }
    }

    method ResolveSource {jid} {
        set inRoster [$db onecolumn {
            SELECT count(*) FROM roster_item WHERE jid=$jid
        }]
        set inBookmark [$db onecolumn {
            SELECT count(*) FROM bookmark WHERE jid=$jid
        }]
        if {$inRoster && $inBookmark} { return "both" }
        if {$inRoster} { return "roster" }
        if {$inBookmark} { return "bookmark" }
        return "none"
    }

    method ResolveAutojoin {jid} {
        $db onecolumn {
            SELECT autojoin FROM bookmark WHERE jid=$jid
        }
    }

    tackymethod search {args} {
        array set opts {-query "" -sort name}
        array set opts $args

        set query $opts(-query)
        set sort $opts(-sort)

        # 1. Gather raw data
        set rosterItems [$client roster get]
        set bookmarkItems [$client bookmarks get]
        set chatJids [$client chats latest]

        # 2. Build JID→name map (roster name wins over bookmark name)
        set jidName [dict create]
        foreach item $bookmarkItems {
            set jid [dict get $item -jid]
            set name [dict get $item -name]
            if {$name ne ""} {
                dict set jidName $jid $name
            }
        }
        foreach item $rosterItems {
            set jid [dict get $item -jid]
            set name [dict get $item -name]
            if {$name ne ""} {
                dict set jidName $jid $name
            }
        }

        # 3. Build JID→source map
        set jidSource [dict create]
        foreach item $rosterItems {
            set jid [dict get $item -jid]
            dict set jidSource $jid roster
        }
        foreach item $bookmarkItems {
            set jid [dict get $item -jid]
            if {[dict exists $jidSource $jid]} {
                dict set jidSource $jid both
            } else {
                dict set jidSource $jid bookmark
            }
        }

        # 4. Build bookmark autojoin lookup
        set bmAutojoin [dict create]
        foreach item $bookmarkItems {
            dict set bmAutojoin [dict get $item -jid] [dict get $item -autojoin]
        }

        # 5. Recent section
        set recent {}
        set count 0
        foreach jid $chatJids {
            set name ""
            if {[dict exists $jidName $jid]} {
                set name [dict get $jidName $jid]
            }
            if {![$self MatchesQuery $jid $name $query]} continue

            set source "none"
            if {[dict exists $jidSource $jid]} {
                set source [dict get $jidSource $jid]
            }
            set entry [list -jid $jid -name $name -source $source]
            if {$source in {bookmark both}} {
                lappend entry -autojoin [dict get $bmAutojoin $jid]
            }
            lappend recent $entry
            if {[incr count] >= 20} break
        }

        # Sync RecentJids from unfiltered top-20 for incremental updates
        set RecentJids [lrange $chatJids 0 19]

        # 6. Roster section
        set roster {}
        foreach item $rosterItems {
            set jid [dict get $item -jid]
            set name [dict get $item -name]
            if {![$self MatchesQuery $jid $name $query]} continue
            lappend roster $item
        }
        set roster [$self SortItems $roster $sort]

        # 7. Bookmarks section
        set bookmarks {}
        foreach item $bookmarkItems {
            set jid [dict get $item -jid]
            # Use roster name if available, else bookmark name
            set name [dict get $item -name]
            if {[dict exists $jidName $jid]} {
                set resolvedName [dict get $jidName $jid]
            } else {
                set resolvedName $name
            }
            if {![$self MatchesQuery $jid $resolvedName $query]} continue
            # Replace name with resolved name for display
            set entry $item
            dict set entry -name $resolvedName
            lappend bookmarks $entry
        }
        set bookmarks [$self SortItems $bookmarks $sort]

        return [dict create recent $recent roster $roster bookmarks $bookmarks]
    }

    method MatchesQuery {jid name query} {
        if {$query eq ""} { return 1 }
        set q [string tolower $query]
        if {[string first $q [string tolower $jid]] >= 0} { return 1 }
        if {[string first $q [string tolower $name]] >= 0} { return 1 }
        return 0
    }

    method SortItems {items sort} {
        if {$sort eq "jid"} {
            return [lsort -command [mymethod CmpJid] $items]
        }
        lsort -command [mymethod CmpName] $items
    }

    method CmpName {a b} {
        set na [dict get $a -name]
        set nb [dict get $b -name]
        if {$na eq ""} { set na [dict get $a -jid] }
        if {$nb eq ""} { set nb [dict get $b -jid] }
        string compare -nocase $na $nb
    }

    method CmpJid {a b} {
        string compare -nocase [dict get $a -jid] [dict get $b -jid]
    }
}
