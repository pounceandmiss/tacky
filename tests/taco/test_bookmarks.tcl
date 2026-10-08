# Tests for taco_bookmarks room join-state tracking
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set bookmarks_common [tacky_env -mock conn -taco-client {
    -domain test.example.com -port 5222
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

test bookmarks-item-join-suffix-one-row \
    {item -jid with a ?join suffix updates the bare-keyed row, not a second one} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room" nick me
        c bookmarks item -jid room@muc.example.com?join -autojoin 1
        c db eval {SELECT jid, name, autojoin FROM bookmark ORDER BY jid}
    } -result {room@muc.example.com Room 1}

test bookmarks-item-join-suffix-publishes-bare-jid \
    {the published item id is the bare room JID, not the ?join chat JID} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room" nick me
        c.conn clear
        c bookmarks item -jid room@muc.example.com?join -autojoin 1
        set iq [lindex [c.conn get_written] end]
        xsearch $iq pubsub publish item -get @id
    } -result {room@muc.example.com}

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
    } -result {{idle {}} {joining {}} {joined {}} {error {Password required or incorrect}} {joined {}}}

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
    } -result {{room@muc.example.com error {You are banned from this room}} {joined {}}}

test bookmarks-room-state-disconnect-resets {disconnect clears tracked room state back to idle} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com name "Room" autojoin 1
        c bus publish muc:<Error> -jid room@muc.example.com -error forbidden -stanza {}
        c bus publish <SessionEnd>
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
                            j nick -body me
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

test bookmarks-fetch-timeout-joins-known-rooms {an unanswered fetch still enters the autojoin rooms last listed} \
    {*}$bookmarks_common \
    -body {
        bm_insert room@muc.example.com autojoin 1 nick me
        bm_insert quiet@muc.example.com autojoin 0 nick me
        c.conn fire_state connected
        set joins {}
        foreach cond {item-not-found remote-server-timeout} {
            c bookmarks request
            set req [lindex [c.conn get_written] end]
            c.conn clear
            c.conn feed [j iq -type error -id [xsearch $req -get @id] {
                j error -type wait {
                    j $cond -ns urn:ietf:params:xml:ns:xmpp-stanzas
                }
            }]
            lappend joins [lmap p [c.conn get_written] {xsearch $p -get @to}]
        }
        set joins
    } -result {{} room@muc.example.com/me}

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
                            j nick -body me
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

# -- Changes made on another device ---------------------------------------

# Feed a bookmark notification from our own PEP service, as sent for
# another device's publish or for the echo of ours.
proc bm_push {room autojoin {nick me} {name Room}} {
    c.conn feed [j message -from user@test.example.com {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node urn:xmpp:bookmarks:1 {
                j item -id $room {
                    j conference -ns urn:xmpp:bookmarks:1 \
                        -autojoin $autojoin -name $name {
                        j nick -body $nick
                    }
                }
            }
        }
    }]
}

proc bm_push_retract {room} {
    c.conn feed [j message -from user@test.example.com {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node urn:xmpp:bookmarks:1 {
                j retract -id $room
            }
        }
    }]
}

proc bm_push_purge {} {
    c.conn feed [j message -from user@test.example.com {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j purge -node urn:xmpp:bookmarks:1
        }
    }]
}

# Presences sent: {to type} each, since the last clear.
proc bm_presences {} {
    set out {}
    foreach st [c.conn get_written] {
        if {[dict get $st tag] ne "presence"} continue
        lappend out [list [xsearch $st -get @to] [xsearch $st -get @type]]
    }
    return $out
}

# Join $room as $nick and feed the room's self-presence.
proc bm_in_room {room nick} {
    c muc join -jid $room -nick $nick
    c.conn feed [j presence -from $room/$nick {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -affiliation member -role participant
            j status -code 110
        }
    }]
}

test bookmarks-remote-autojoin-on-joins {autojoin turned on elsewhere joins the room} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_push room@muc.example.com false
        set before [bm_presences]
        c.conn clear
        bm_push room@muc.example.com true
        list $before [bm_presences]
    } -result {{} {{room@muc.example.com/me {}}}}

test bookmarks-remote-autojoin-off-leaves {autojoin turned off elsewhere leaves the room} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_push room@muc.example.com true
        bm_in_room room@muc.example.com me
        c.conn clear
        bm_push room@muc.example.com false
        bm_presences
    } -result {{room@muc.example.com/me unavailable}}

test bookmarks-remote-nick-renames {a nick changed elsewhere is taken in a joined room} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_push room@muc.example.com true
        bm_in_room room@muc.example.com me
        c.conn clear
        bm_push room@muc.example.com true newme
        bm_presences
    } -result {{room@muc.example.com/newme {}}}

test bookmarks-remote-retract-leaves {a bookmark removed elsewhere leaves its room} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_push room@muc.example.com true
        bm_in_room room@muc.example.com me
        c.conn clear
        bm_push_retract room@muc.example.com
        list [bm_presences] [bm_state room@muc.example.com]
    } -result {{{room@muc.example.com/me unavailable}} missing}

test bookmarks-remote-purge-clears {a purge removes every bookmark and leaves their rooms} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_push room@muc.example.com true
        bm_push other@muc.example.com false
        bm_in_room room@muc.example.com me
        set ::actions {}
        tacky listen bookmarks <Changed> \
            {apply {{ev} { lappend ::actions [dict get $ev -action] }}}
        c.conn clear
        bm_push_purge
        list [bm_presences] [llength [c bookmarks get]] $::actions
    } -result {{{room@muc.example.com/me unavailable}} 0 clear}

test bookmarks-own-echo-is-not-a-change {the echo of our own publish or retract changes nothing} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        bm_in_room room@muc.example.com me
        # Unstar but stay (-leave 0), then the retract's echo arrives.
        c bookmarks item -jid room@muc.example.com -autojoin 1 -nick me -name Room
        bm_push room@muc.example.com true
        c bookmarks remove -jid room@muc.example.com -leave 0
        c.conn clear
        bm_push_retract room@muc.example.com
        list [bm_presences] [c muc isJoined -jid room@muc.example.com]
    } -result {{} 1}

test bookmarks-crossed-echo-keeps-the-newer-change {an echo of an older publish doesn't undo a newer local change} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        # Tick join, then untick it before the first echo comes back.
        c bookmarks item -jid room@muc.example.com -autojoin 1 -nick me -name Room
        c bookmarks leave -jid room@muc.example.com
        c.conn clear
        bm_push room@muc.example.com true
        set mid [list [bm_presences] [c bookmarks autojoin -jid room@muc.example.com]]
        bm_push room@muc.example.com false
        list $mid [bm_presences] [c bookmarks autojoin -jid room@muc.example.com]
    } -result {{{} 0} {} 0}

test bookmarks-no-second-join-while-joining {autojoin doesn't send another join to a room being joined} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        c muc join -jid room@muc.example.com -nick me
        c.conn clear
        bm_push room@muc.example.com true
        bm_presences
    } -result {}

test bookmarks-publish-reconfigures-on-precondition {a publish refused for node options reconfigures the node and publishes again} \
    {*}$bookmarks_common \
    -body {
        c configure -jid user@test.example.com/res
        c bookmarks item -jid room@muc.example.com -autojoin 1 -nick me
        set pub [lindex [lsearch -all -inline -index 1 [lmap s [c.conn get_written] {
            list $s [xsearch $s pubsub publish -get @node]}] urn:xmpp:bookmarks:1] 0 0]
        c.conn clear
        c.conn feed [j iq -type error -id [xsearch $pub -get @id] {
            j error -type cancel {
                j conflict -ns urn:ietf:params:xml:ns:xmpp-stanzas
                j precondition-not-met -ns http://jabber.org/protocol/pubsub#errors
            }
        }]
        set conf [lindex [c.conn get_written] end]
        set confOk [expr {[xsearch $conf pubsub configure -get @node] eq "urn:xmpp:bookmarks:1"}]
        c.conn clear
        c.conn feed [j iq -type result -id [xsearch $conf -get @id]]
        set again [lindex [c.conn get_written] end]
        list $confOk [xsearch $again pubsub publish item -get @id]
    } -result {1 room@muc.example.com}

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
                            j nick -body me
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
                            j nick -body me
                        }
                    }
                }
            }
        }]
        list [bm_state trap@muc.evil.example] [llength [c.conn get_written]]
    } -result {missing 0}

test bookmarks-set-nick-all-one-item-per-publish \
    {setNickAll publishes each bookmark on its own, with the node's options} \
    {*}$bookmarks_common \
    -body {
        bm_insert a@muc.example.com nick old
        bm_insert b@muc.example.com nick old
        c.conn clear
        c bookmarks setNickAll -nick new
        lmap st [c.conn get_written] {
            if {[xsearch $st pubsub publish -get @node] ne "urn:xmpp:bookmarks:1"} continue
            list [llength [xsearch $st pubsub publish item]] \
                [llength [xsearch $st pubsub publish-options]] \
                [xsearch $st pubsub publish item conference nick -get body]
        }
    } -result {{1 1 new} {1 1 new}}
