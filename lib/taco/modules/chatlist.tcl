# taco_chatlist - aggregated contact list (roster + bookmarks + recent chats).
#
# Merges data from roster, bookmarks, and chats into a single search
# result with three sections: recent, roster, bookmarks.  Single-item
# source changes are forwarded as itemized section patches:
#   chatlist <Item>   -section recent|roster|bookmarks -jid $jid -item $entry
#   chatlist <Remove> -section recent|roster|bookmarks -jid $jid
# A wholesale source replacement (roster/bookmarks -action clear) emits
# chatlist <Changed> instead, meaning: refetch via search.
#
# Every jid in the result is a chat JID, to be opened verbatim:
# bare = 1:1 chat, room@muc?join = group chat, room@muc/nick = MUC PM.
# Recent entries pass the stored chat JID through; bookmarks-section
# entries (and their patches) carry room@muc?join. The ?join suffix is
# the tell for group vs 1:1; `source` only says where the counterpart
# is known from.

snit::type taco_chatlist {
    option -client -readonly yes

    variable client
    variable db
    variable RecentJids {}

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]

        $client bus subscribe $self roster:<Changed> [mymethod OnSourceChanged roster]
        $client bus subscribe $self bookmarks:<Changed> [mymethod OnSourceChanged bookmarks]
        $client bus subscribe $self chats:<Updated> [mymethod OnChatUpdated]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    method OnSourceChanged {source args} {
        array set opts {-action "" -jid ""}
        array set opts $args
        if {$opts(-jid) eq "" || $opts(-action) ni {add update remove}} {
            $client emit chatlist <Changed>
            return
        }
        set jid $opts(-jid)

        # Patch with the jid's current state rather than trusting the
        # action: present -> <Item>, absent -> <Remove>
        if {$source eq "roster"} {
            $self EmitSectionPatch roster $jid [$self RosterEntry $jid]
        } else {
            $self EmitSectionPatch bookmarks $jid?join \
                [$self BookmarkEntry $jid]
        }

        # Recent entries are keyed by chat JID (rooms carry ?join)
        foreach chatJid $RecentJids {
            if {[regsub {\?join$} $chatJid {}] ne $jid} continue
            $client emit chatlist <Item> -section recent -jid $chatJid \
                -item [$self RecentEntry $chatJid]
        }
    }

    method EmitSectionPatch {section jid entry} {
        if {$entry eq ""} {
            $client emit chatlist <Remove> -section $section -jid $jid
        } else {
            $client emit chatlist <Item> -section $section -jid $jid \
                -item $entry
        }
    }

    method RosterEntry {jid} {
        foreach item [$client roster get] {
            if {[dict get $item jid] eq $jid} { return $item }
        }
        return {}
    }

    # Bookmark entry as presented by this module: the bookmark item
    # with jid as the chat JID ($jid?join)
    method BookmarkEntry {jid} {
        foreach item [$client bookmarks get] {
            if {[dict get $item jid] ne $jid} continue
            dict set item jid $jid?join
            return $item
        }
        return {}
    }

    # Union of the counterpart's roster/bookmark section entries plus
    # recent-specific overrides: jid (the chat JID, verbatim), name
    # (resolved: roster wins, else bookmark), source
    method RecentEntry {chatJid} {
        set jid [regsub {\?join$} $chatJid {}]
        set source [$self ResolveSource $jid]
        set entry [dict create]
        if {$source in {bookmark both}} {
            set entry [$self BookmarkEntry $jid]
        }
        if {$source in {roster both}} {
            set entry [dict merge $entry [$self RosterEntry $jid]]
        }
        dict set entry jid $chatJid
        dict set entry name [$self ResolveName $jid]
        dict set entry source $source
        return $entry
    }

    method OnChatUpdated {args} {
        array set opts {-jid ""}
        array set opts $args
        set jid $opts(-jid)

        set allJids [$client chats latest]
        set newTop20 [lrange $allJids 0 19]

        set entry [$self RecentEntry $jid]
        set ev [list -jid $jid -name [dict get $entry name] \
            -source [dict get $entry source]]
        if {[dict exists $entry autojoin]} {
            lappend ev -autojoin [dict get $entry autojoin]
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

    tackymethod search {args} {
        array set opts {-query "" -sort name}
        array set opts $args

        set query $opts(-query)
        set sort $opts(-sort)

        # 1. Gather raw data
        set rosterItems [$client roster get]
        set bookmarkItems [$client bookmarks get]
        set chatJids [$client chats latest]

        # 2. Recent section
        set recent {}
        set count 0
        foreach jid $chatJids {
            set entry [$self RecentEntry $jid]
            if {![$self MatchesQuery $jid [dict get $entry name] $query]} continue
            lappend recent $entry
            if {[incr count] >= 20} break
        }

        # Sync RecentJids from unfiltered top-20 for incremental updates
        set RecentJids [lrange $chatJids 0 19]

        # 3. Roster section
        set roster {}
        foreach item $rosterItems {
            set jid [dict get $item jid]
            set name [dict get $item name]
            if {![$self MatchesQuery $jid $name $query]} continue
            lappend roster $item
        }
        set roster [$self SortItems $roster $sort]

        # 4. Bookmarks section
        set bookmarks {}
        foreach item $bookmarkItems {
            set jid [dict get $item jid]
            if {![$self MatchesQuery $jid?join [dict get $item name] $query]} continue
            # Present the jid as a chat JID (open verbatim)
            set entry $item
            dict set entry jid $jid?join
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
        set na [dict get $a name]
        set nb [dict get $b name]
        if {$na eq ""} { set na [dict get $a jid] }
        if {$nb eq ""} { set nb [dict get $b jid] }
        string compare -nocase $na $nb
    }

    method CmpJid {a b} {
        string compare -nocase [dict get $a jid] [dict get $b jid]
    }
}
