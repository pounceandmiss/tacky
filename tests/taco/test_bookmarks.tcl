# Tests for taco_bookmarks room join-state tracking
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set bookmarks_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# Helper: insert a bookmark row directly
proc bm_insert {jid args} {
    array set opts {name "" autojoin 0 nick "" password ""}
    array set opts $args
    c db eval {
        INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
        VALUES ($jid, $opts(name), $opts(autojoin), $opts(nick), $opts(password))
    }
}

# Helper: {room_state room_reason} for $jid as reported by bookmarks get
proc bm_state {jid} {
    foreach item [c bookmarks get] {
        if {[dict get $item jid] eq $jid} {
            return [list [dict get $item room_state] \
                [dict get $item room_reason]]
        }
    }
    return missing
}

test bookmarks-get-item-shape {get returns the full item dict incl. derived room state} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room" autojoin 1 nick me password pw
        c bookmarks get
    } -result {{jid room@muc.example.com name Room autojoin 1 nick me password pw room_state idle room_reason {}}}

test bookmarks-jid-input-canonicalized {-jid accepts a chat JID with ?join suffix} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com autojoin 1
        c bookmarks autojoin -jid room@muc.example.com?join
    } -result {1}

test bookmarks-room-state-lifecycle {room state follows the muc join lifecycle, last event wins} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room"
        set states [list [bm_state room@muc.example.com]]
        c bus publish muc:<Joining> -jid room@muc.example.com
        lappend states [bm_state room@muc.example.com]
        c bus publish muc:<Joined> -jid room@muc.example.com -nick me
        lappend states [bm_state room@muc.example.com]
        c bus publish muc:<Error> -jid room@muc.example.com -error not-authorized -stanza {}
        lappend states [bm_state room@muc.example.com]
        c bus publish muc:<Joined> -jid room@muc.example.com -nick me
        lappend states [bm_state room@muc.example.com]
        set states
    } -result {{idle {}} {joining {}} {joined {}} {error not-authorized} {joined {}}}

test bookmarks-room-state-left {a dropped room reads disconnected for members, idle otherwise} \
    {*}$bookmarks_common \
    -body {
        bm_insert member@muc.example.com name "Member" autojoin 1
        bm_insert guest@muc.example.com name "Guest" autojoin 0
        foreach jid {member@muc.example.com guest@muc.example.com} {
            c bus publish muc:<Joined> -jid $jid -nick me
            c bus publish muc:<Left> -jid $jid -nick me
        }
        list [bm_state member@muc.example.com] [bm_state guest@muc.example.com]
    } -result {{disconnected {}} {idle {}}}

test bookmarks-room-state-event {<RoomState> carries jid, state and reason} \
    {*}$bookmarks_common \
    -body {
        set ev {}
        tacky listen bookmarks <RoomState> \
            {apply {{ev} { set ::ev $ev }}}
        c bus publish muc:<Error> -jid room@muc.example.com -error forbidden -stanza {}
        set err [list [dict get $ev -jid] [dict get $ev -state] [dict get $ev -reason]]
        c bus publish muc:<Joined> -jid room@muc.example.com -nick me
        set ok [list [dict get $ev -state] [dict get $ev -reason]]
        list $err $ok
    } -result {{room@muc.example.com error forbidden} {joined {}}}

test bookmarks-room-state-disconnect-resets {disconnect clears tracked room state back to idle} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room" autojoin 1
        c bus publish muc:<Error> -jid room@muc.example.com -error forbidden -stanza {}
        c bus publish <Disconnect>
        bm_state room@muc.example.com
    } -result {idle {}}

test bookmarks-wire-publish {item publishes a XEP-0402 item with whitelist publish-options} \
    {*}$bookmarks_common \
    -body {
        c bookmarks item -jid room@muc.example.com -name "Room" -autojoin 1 -nick me
        set iq [lindex [c.conn get_written] end]
        set item [lindex [xsearch $iq pubsub publish item] 0]
        set conf [lindex [xsearch $item conference -ns urn:xmpp:bookmarks:1] 0]
        set access ""
        foreach f [xsearch $iq pubsub publish-options x field] {
            if {[xsearch $f -get @var] eq "pubsub#access_model"} {
                set access [xsearch $f value -get body]
            }
        }
        list [xsearch $iq -get @type] \
            [xsearch $iq pubsub publish -get @node] \
            [xsearch $item -get @id] \
            [xsearch $conf -get @autojoin] \
            [xsearch $conf -get @name] \
            [xsearch $conf nick -get body] \
            $access
    } -result {set urn:xmpp:bookmarks:1 room@muc.example.com true Room me whitelist}

test bookmarks-wire-retract {remove sends a notifying retract for the item} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room"
        c.conn clear
        c bookmarks remove -jid room@muc.example.com
        set iq [lindex [c.conn get_written] end]
        list [xsearch $iq pubsub retract -get @node] \
            [xsearch $iq pubsub retract -get @notify] \
            [xsearch $iq pubsub retract item -get @id]
    } -result {urn:xmpp:bookmarks:1 true room@muc.example.com}

test bookmarks-wire-result {items result populates the store and triggers autojoin} \
    {*}$bookmarks_common \
    -body {
        c bookmarks request
        set req [lindex [c.conn get_written] end]
        c.conn clear
        c.conn feed [j iq -type result -id [xsearch $req -get @id] {
            j pubsub -ns http://jabber.org/protocol/pubsub {
                j items -node urn:xmpp:bookmarks:1 {
                    j item -id room@muc.example.com {
                        j conference -ns urn:xmpp:bookmarks:1 \
                            -autojoin true -name "Room" {
                            j nick #body me
                        }
                    }
                }
            }
        }]
        set p [lindex [c.conn get_written] end]
        list [bm_state room@muc.example.com] \
            [xsearch $p -get @to] \
            [expr {[xsearch $p x -ns http://jabber.org/protocol/muc] ne ""}]
    } -result {{joining {}} room@muc.example.com/me 1}

test bookmarks-wire-notification {pubsub notifications add and retract bookmarks} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        set actions {}
        tacky listen bookmarks <Changed> \
            {apply {{ev} { lappend ::actions [dict get $ev -action] }}}
        c.conn feed [j message -from user@test.example.com {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node urn:xmpp:bookmarks:1 {
                    j item -id room@muc.example.com {
                        j conference -ns urn:xmpp:bookmarks:1 \
                            -autojoin true -name "Room" {
                            j nick #body me
                        }
                    }
                }
            }
        }]
        set joined [expr {[llength [c.conn get_written]] > 0}]
        set stored [bm_state room@muc.example.com]
        c.conn feed [j message -from user@test.example.com {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node urn:xmpp:bookmarks:1 {
                    j retract -id room@muc.example.com
                }
            }
        }]
        set gone [expr {[bm_state room@muc.example.com] eq "missing"}]
        list $actions $joined $stored $gone
    } -result {{add remove} 1 {joining {}} 1}

test bookmarks-wire-extensions-preserved {republish keeps extensions from the server copy} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        c.conn feed [j message -from user@test.example.com {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node urn:xmpp:bookmarks:1 {
                    j item -id room@muc.example.com {
                        j conference -ns urn:xmpp:bookmarks:1 \
                            -autojoin false -name "Room" {
                            j nick #body me
                            j extensions {
                                j pinned -ns urn:example:pinning
                            }
                        }
                    }
                }
            }
        }]
        c.conn clear
        c bookmarks item -jid room@muc.example.com -name "Renamed"
        set iq [lindex [c.conn get_written] end]
        set conf [lindex [xsearch $iq pubsub publish item conference] 0]
        list [xsearch $conf -get @name] \
            [llength [xsearch $conf extensions pinned -ns urn:example:pinning]]
    } -result {Renamed 1}

test bookmarks-wire-foreign-notification-dropped {bookmark events from other senders are ignored} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        c.conn feed [j message -from attacker@evil.example {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node urn:xmpp:bookmarks:1 {
                    j item -id trap@muc.evil.example {
                        j conference -ns urn:xmpp:bookmarks:1 \
                            -autojoin true -name "Trap" {
                            j nick #body me
                        }
                    }
                }
            }
        }]
        list [bm_state trap@muc.evil.example] [llength [c.conn get_written]]
    } -result {missing 0}
