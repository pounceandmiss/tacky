# Unit tests for taco_muc
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set muc_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# -- Helpers --

# Build a MUC presence stanza with <x xmlns='muc#user'> containing an <item>.
# Defaults to self-presence (status code 110).
proc muc_presence {args} {
    set defaults {
        from room@muc.example.com/me
        role participant affiliation member jid ""
        self 1 codes {} type "" occupant ""
    }
    set opts [dict merge $defaults $args]
    set from [dict get $opts from]
    set role [dict get $opts role]
    set affil [dict get $opts affiliation]
    set realJid [dict get $opts jid]
    set isSelf [dict get $opts self]
    set extraCodes [dict get $opts codes]
    set type_ [dict get $opts type]
    set occ [dict get $opts occupant]

    set presAttrs [list -from $from]
    if {$type_ ne ""} {
        lappend presAttrs -type $type_
    }

    set itemAttrs [list -role $role -affiliation $affil]
    if {$realJid ne ""} {
        lappend itemAttrs -jid $realJid
    }

    j presence {*}$presAttrs {
        if {$occ ne ""} {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id $occ
        }
        j x -ns http://jabber.org/protocol/muc#user {
            j item {*}$itemAttrs
            if {$isSelf} {
                j status -code 110
            }
            foreach code $extraCodes {
                j status -code $code
            }
        }
    }
}

# Simulate a full join: send the join command, then feed self-presence back.
proc muc_join {room nick args} {
    set defaults {-role participant -affiliation member -occupant ""}
    set opts [dict merge $defaults $args]
    c muc join -jid $room -nick $nick
    c.conn feed [muc_presence \
        from $room/$nick \
        role [dict get $opts -role] \
        affiliation [dict get $opts -affiliation] \
        occupant [dict get $opts -occupant] \
        self 1]
}

# -- Join / Leave lifecycle ---------------------------------------------------

test muc-join-sends-presence {join sends presence with MUC namespace} \
    {*}$muc_common \
    -body {
        c muc join -jid room@muc.example.com -nick me
        set written [c.conn get_written]
        set p [lindex $written end]
        list [dict get $p tag] \
             [xsearch $p -get @to] \
             [expr {[xsearch $p x -ns http://jabber.org/protocol/muc] ne ""}]
    } -result {presence room@muc.example.com/me 1}

test muc-join-with-password {join includes password in MUC element} \
    {*}$muc_common \
    -body {
        c muc join -jid room@muc.example.com -nick me -password secret
        set p [lindex [c.conn get_written] end]
        xsearch $p x -ns http://jabber.org/protocol/muc password -get body
    } -result {secret}

test muc-join-with-history {join includes history attributes} \
    {*}$muc_common \
    -body {
        c muc join -jid room@muc.example.com -nick me -history {maxstanzas 20}
        set p [lindex [c.conn get_written] end]
        xsearch $p x -ns http://jabber.org/protocol/muc history -get @maxstanzas
    } -result {20}

test muc-not-joined-before-presence {not joined before self-presence arrives} \
    {*}$muc_common \
    -body {
        c muc join -jid room@muc.example.com -nick me
        c muc isJoined -jid room@muc.example.com
    } -result {0}

test muc-joined-after-self-presence {joined after self-presence with 110} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc isJoined -jid room@muc.example.com
    } -result {1}

test muc-joining-event {<Joining> event fires when a join is requested} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Joining> {apply {{ev} { set ::got $ev }}}
        c muc join -jid room@muc.example.com -nick me
        dict get $got -jid
    } -result {room@muc.example.com}

test muc-joined-event {<Joined> event fires on self-presence} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Joined> {apply {{ev} { set ::got $ev }}}
        muc_join room@muc.example.com me
        list [dict get $got -jid] [dict get $got -nick]
    } -result {room@muc.example.com me}

test muc-leave-sends-unavailable {leave sends unavailable presence} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc leave -jid room@muc.example.com
        set p [lindex [c.conn get_written] end]
        list [xsearch $p -get @to] [xsearch $p -get @type]
    } -result {room@muc.example.com/me unavailable}

test muc-leave-with-status {leave includes status message} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc leave -jid room@muc.example.com -status "goodbye"
        set p [lindex [c.conn get_written] end]
        xsearch $p status -get body
    } -result {goodbye}

test muc-left-event {<Left> event fires on self-unavailable} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Left> {apply {{ev} { set ::got $ev }}}
        muc_join room@muc.example.com me
        # Server sends back unavailable with 110
        c.conn feed [muc_presence \
            from room@muc.example.com/me type unavailable self 1]
        list [dict get $got -jid] [dict get $got -nick]
    } -result {room@muc.example.com me}

test muc-not-joined-after-leave {not joined after leave} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/me type unavailable self 1]
        c muc isJoined -jid room@muc.example.com
    } -result {0}

# -- State queries ------------------------------------------------------------

test muc-mynick {myNick returns our nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc myNick -jid room@muc.example.com
    } -result {me}

test muc-myrole {myRole returns our role} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator
        c muc myRole -jid room@muc.example.com
    } -result {moderator}

test muc-myaffiliation {myAffiliation returns our affiliation} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -affiliation owner
        c muc myAffiliation -jid room@muc.example.com
    } -result {owner}

test muc-havevoice-participant {participant has voice} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role participant
        c muc haveVoice -jid room@muc.example.com
    } -result {1}

test muc-havevoice-moderator {moderator has voice} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator
        c muc haveVoice -jid room@muc.example.com
    } -result {1}

test muc-havevoice-visitor {visitor does not have voice} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role visitor
        c muc haveVoice -jid room@muc.example.com
    } -result {0}

test muc-rooms {rooms returns list of joined rooms} \
    {*}$muc_common \
    -body {
        muc_join room1@muc.example.com me
        muc_join room2@muc.example.com me
        lsort [c muc rooms]
    } -result {room1@muc.example.com room2@muc.example.com}

test muc-rooms-excludes-unjoined {rooms excludes pending joins} \
    {*}$muc_common \
    -body {
        muc_join room1@muc.example.com me
        c muc join -jid room2@muc.example.com -nick me
        c muc rooms
    } -result {room1@muc.example.com}

# -- Occupant tracking -------------------------------------------------------

test muc-occupants-listed {occupants returns all occupant dicts} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        # Another occupant joins
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        llength [c muc occupants -jid room@muc.example.com]
    } -result {2}

test muc-occupant-cap {occupants past the cap are dropped, not tracked} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set ::taco_muc::MaxOccupants 3
        try {
            for {set i 0} {$i < 6} {incr i} {
                c.conn feed [muc_presence \
                    from room@muc.example.com/o$i \
                    role participant affiliation member self 0]
            }
            llength [c muc occupants -jid room@muc.example.com]
        } finally {
            set ::taco_muc::MaxOccupants 10000
        }
    } -result 3

test muc-occupant-by-nick {occupant returns dict for a specific nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role moderator affiliation admin self 0]
        set occ [c muc occupant -jid room@muc.example.com -nick other]
        list [dict get $occ nick] [dict get $occ role] [dict get $occ affiliation]
    } -result {other moderator admin}

test muc-occupant-unknown-nick {occupant returns empty for unknown nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc occupant -jid room@muc.example.com -nick ghost
    } -result {}

test muc-occupant-caps-moderator {owner gets role caps on a participant} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator -affiliation owner
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        set caps [dict get [c muc occupant -jid room@muc.example.com -nick other] caps]
        list [dict get $caps kick] [dict get $caps make_moderator] \
             [dict get $caps revoke_voice] [dict get $caps grant_voice]
    } -result {1 1 1 0}

test muc-occupant-caps-ban {admin can ban/revoke a member with a known jid} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator -affiliation admin
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0 jid other@example.com]
        set caps [dict get [c muc occupant -jid room@muc.example.com -nick other] caps]
        list [dict get $caps ban] [dict get $caps revoke_membership] \
             [dict get $caps grant_membership]
    } -result {1 1 0}

test muc-occupant-caps-self {self carries no moderation caps} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator -affiliation owner
        set caps [dict get [c muc occupant -jid room@muc.example.com -nick me] caps]
        list [dict get $caps kick] [dict get $caps ban] [dict get $caps make_moderator]
    } -result {0 0 0}

test muc-occupant-caps-none {a plain participant gets no caps over others} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role participant -affiliation member
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        set caps [dict get [c muc occupant -jid room@muc.example.com -nick other] caps]
        list [dict get $caps kick] [dict get $caps make_moderator] [dict get $caps ban]
    } -result {0 0 0}

test muc-action-error-maps-condition {a failed moderation action reports friendly text} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator -affiliation admin
        set got ""
        c muc role -jid room@muc.example.com -nick other -role none \
            -onerror [list apply {{msg} { set ::got $msg }}]
        set req [lindex [c.conn get_written] end]
        c.conn feed [j iq -type error -id [xsearch $req -get @id] \
            -from room@muc.example.com {
            j error -type auth {
                j forbidden -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        set got
    } -result {You do not have permission to do that}

test muc-action-success-invokes-command {a successful moderation action invokes -command} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator -affiliation admin
        set got no
        c muc kick -jid room@muc.example.com -nick other \
            -command [list apply {{stanza} { set ::got yes }}]
        set req [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $req -get @id] \
            -from room@muc.example.com {}]
        set got
    } -result {yes}

test muc-presence-event {<Presence> event fires for occupant} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen muc <Presence> {apply {{ev} { lappend ::got $ev }}}
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        set ev [lindex $got end]
        list [dict get $ev -jid] [dict get $ev -nick] \
             [dict get [dict get $ev -occupant] role]
    } -result {room@muc.example.com other participant}

test muc-unavailable-event {<Unavailable> event fires when occupant leaves} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        set got {}
        tacky listen muc <Unavailable> {apply {{ev} { set ::got $ev }}}
        c.conn feed [muc_presence \
            from room@muc.example.com/other type unavailable self 0]
        list [dict get $got -jid] [dict get $got -nick]
    } -result {room@muc.example.com other}

test muc-occupant-removed-on-leave {occupant removed from list on departure} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        c.conn feed [muc_presence \
            from room@muc.example.com/other type unavailable self 0]
        llength [c muc occupants -jid room@muc.example.com]
    } -result {1}

# -- Nick change --------------------------------------------------------------

test muc-nick-sends-presence {nick sends presence to new nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc nick -jid room@muc.example.com -nick newme
        set p [lindex [c.conn get_written] end]
        xsearch $p -get @to
    } -result {room@muc.example.com/newme}

test muc-nick-changed-event {<NickChanged> event fires on 303} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen muc <NickChanged> {apply {{ev} { set ::got $ev }}}
        # Server sends unavailable with 303 + new nick in item
        c.conn feed [j presence -from room@muc.example.com/me -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role participant -affiliation member -nick newme
                j status -code 303
                j status -code 110
            }
        }]
        list [dict get $got -oldNick] [dict get $got -newNick] [dict get $got -self]
    } -result {me newme 1}

test muc-nick-changed-updates-mynick {nick change updates myNick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j presence -from room@muc.example.com/me -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role participant -affiliation member -nick newme
                j status -code 303
                j status -code 110
            }
        }]
        c muc myNick -jid room@muc.example.com
    } -result {newme}

# -- Messaging ----------------------------------------------------------------

test muc-say-sends-groupchat {say sends groupchat message with id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn clear
        c muc say -jid room@muc.example.com -body "hello room"
        set m [lindex [c.conn get_written] end]
        list [xsearch $m -get @type] \
             [xsearch $m -get @to] \
             [xsearch $m body -get body] \
             [expr {[xsearch $m -get @id] ne ""}]
    } -result {groupchat room@muc.example.com {hello room} 1}

test muc-message-event {groupchat message emits message <New> only} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <New> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "hi all"
        }]
        list [dict get $got -jid] [dict get $got -message content body]
    } -result {room@muc.example.com?join {hi all}}

test muc-pm-sends-chat {pm sends chat message with muc#user marker} \
    {*}$muc_common \
    -body {
        c muc pm -jid room@muc.example.com/someone -body "psst"
        set m [lindex [c.conn get_written] end]
        list [xsearch $m -get @type] \
             [xsearch $m -get @to] \
             [xsearch $m body -get body] \
             [expr {[xsearch $m x -ns http://jabber.org/protocol/muc#user] ne ""}]
    } -result {chat room@muc.example.com/someone psst 1}

test muc-private-message-event {private message emits message <New> only} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <New> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body -body "secret"
        }]
        list [dict get $got -jid] [dict get $got -message content body]
    } -result {room@muc.example.com/someone secret}

# -- Subject ------------------------------------------------------------------

test muc-subject-sends {subject sends groupchat with subject element} \
    {*}$muc_common \
    -body {
        c muc subject -jid room@muc.example.com -body "new topic"
        set m [lindex [c.conn get_written] end]
        list [xsearch $m -get @type] [xsearch $m subject -get body]
    } -result {groupchat {new topic}}

test muc-subject-event {<Subject> event fires and updates getSubject} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen muc <Subject> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com/admin {
            j subject -body "welcome"
        }]
        list [dict get $got -nick] [dict get $got -subject] \
             [c muc getSubject -jid room@muc.example.com]
    } -result {admin welcome welcome}

# -- Kick / Ban ---------------------------------------------------------------

test muc-kicked-event {<Kicked> event fires on 307} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/other \
            role participant affiliation member self 0]
        set got {}
        tacky listen muc <Kicked> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j presence -from room@muc.example.com/other -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role none -affiliation none {
                    j actor -nick admin
                    j reason -body "behave"
                }
                j status -code 307
            }
        }]
        list [dict get $got -nick] [dict get $got -actor] [dict get $got -reason]
    } -result {other admin behave}

test muc-banned-event {<Banned> event fires on 301} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_presence \
            from room@muc.example.com/troll \
            role participant affiliation member self 0]
        set got {}
        tacky listen muc <Banned> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j presence -from room@muc.example.com/troll -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role none -affiliation outcast {
                    j actor -nick admin
                    j reason -body "spam"
                }
                j status -code 301
            }
        }]
        list [dict get $got -nick] [dict get $got -reason]
    } -result {troll spam}

# -- Invite / Decline ---------------------------------------------------------

test muc-invite-sends {invite sends mediated invitation} \
    {*}$muc_common \
    -body {
        c muc invite -jid room@muc.example.com -to bob@example.com -reason "join us"
        set m [lindex [c.conn get_written] end]
        list [xsearch $m -get @to] \
             [xsearch $m x -ns http://jabber.org/protocol/muc#user invite -get @to] \
             [xsearch $m x -ns http://jabber.org/protocol/muc#user invite reason -get body]
    } -result {room@muc.example.com bob@example.com {join us}}

test muc-invite-event {<Invite> event fires on incoming invitation} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Invite> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -from room@muc.example.com {
            j x -ns http://jabber.org/protocol/muc#user {
                j invite -from alice@example.com {
                    j reason -body "come join"
                }
                j password -body roompass
            }
        }]
        list [dict get $got -jid] [dict get $got -from] \
             [dict get $got -reason] [dict get $got -password]
    } -result {room@muc.example.com alice@example.com {come join} roompass}

test muc-decline-event {<Decline> event fires on incoming decline} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Decline> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -from room@muc.example.com {
            j x -ns http://jabber.org/protocol/muc#user {
                j decline -from bob@example.com {
                    j reason -body "busy"
                }
            }
        }]
        list [dict get $got -jid] [dict get $got -from] [dict get $got -reason]
    } -result {room@muc.example.com bob@example.com busy}

# -- Error handling -----------------------------------------------------------

test muc-error-event {<Error> event fires on presence error} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <Error> {apply {{ev} { set ::got $ev }}}
        c muc join -jid room@muc.example.com -nick me
        c.conn feed [j presence -from room@muc.example.com/me -type error {
            j error -type auth {
                j not-authorized
            }
        }]
        list [dict get $got -jid] [dict get $got -error]
    } -result {room@muc.example.com not-authorized}

test muc-error-cleans-up-room {error before join cleans up room state} \
    {*}$muc_common \
    -body {
        c muc join -jid room@muc.example.com -nick me
        c.conn feed [j presence -from room@muc.example.com/me -type error {
            j error -type auth {
                j not-authorized
            }
        }]
        c muc isJoined -jid room@muc.example.com
    } -result {0}

test muc-join-callback-on-error {join -command callback fires on error} \
    {*}$muc_common \
    -body {
        set got {}
        c muc join -jid room@muc.example.com -nick me \
            -command [list apply {{ev} { set ::got $ev }}]
        c.conn feed [j presence -from room@muc.example.com/me -type error {
            j error -type auth {
                j registration-required
            }
        }]
        list [dict get $got -jid] [dict get $got -error]
    } -result {room@muc.example.com registration-required}

# -- Room destroyed -----------------------------------------------------------

test muc-destroyed-event {<Destroyed> event fires} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen muc <Destroyed> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j presence -from room@muc.example.com/me -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role none -affiliation none
                j destroy -jid newroom@muc.example.com {
                    j reason -body "moved"
                }
                j status -code 110
            }
        }]
        list [dict get $got -jid] [dict get $got -altRoom] [dict get $got -reason]
    } -result {room@muc.example.com newroom@muc.example.com moved}

test muc-destroyed-cleans-up {destroyed cleans up room state} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j presence -from room@muc.example.com/me -type unavailable {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -role none -affiliation none
                j destroy
                j status -code 110
            }
        }]
        c muc isJoined -jid room@muc.example.com
    } -result {0}

# -- Room created (201) ------------------------------------------------------

test muc-room-created-event {<RoomCreated> fires on status 201} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <RoomCreated> {apply {{ev} { set ::got $ev }}}
        c muc join -jid room@muc.example.com -nick me
        c.conn feed [muc_presence \
            from room@muc.example.com/me \
            role moderator affiliation owner \
            self 1 codes {201}]
        dict get $got -jid
    } -result {room@muc.example.com}

# -- Config changed -----------------------------------------------------------

test muc-config-changed-event {<ConfigChanged> fires on status codes in groupchat} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen muc <ConfigChanged> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com {
            j x -ns http://jabber.org/protocol/muc#user {
                j status -code 104
            }
        }]
        list [dict get $got -jid] [dict get $got -codes]
    } -result {room@muc.example.com 104}

# -- Voice request ------------------------------------------------------------

test muc-request-voice-sends {requestVoice sends form submission} \
    {*}$muc_common \
    -body {
        c muc requestVoice -jid room@muc.example.com
        set m [lindex [c.conn get_written] end]
        list [xsearch $m -get @to] \
             [xsearch $m x -ns jabber:x:data -get @type] \
             [xsearch $m x -ns jabber:x:data field @var muc#role value -get body]
    } -result {room@muc.example.com submit participant}

test muc-voice-request-event {<VoiceRequest> event fires} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role moderator
        set got {}
        tacky listen muc <VoiceRequest> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -from room@muc.example.com {
            j x -ns jabber:x:data -type submit {
                j field -var FORM_TYPE {
                    j value -body http://jabber.org/protocol/muc#request
                }
                j field -var muc#jid {
                    j value -body visitor@example.com
                }
                j field -var muc#roomnick {
                    j value -body newbie
                }
            }
        }]
        list [dict get $got -jid] [dict get $got -from] [dict get $got -nick]
    } -result {room@muc.example.com visitor@example.com newbie}

# -- Room configuration -------------------------------------------------------

test muc-config-get-returns-form {configGet delivers a parsed form dict} \
    {*}$muc_common \
    -body {
        set got {}
        c muc configGet -jid room@muc.example.com \
            -command [list apply {{form} { set ::got $form }}]
        set req [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $req -get @id] \
            -from room@muc.example.com {
            j query -ns http://jabber.org/protocol/muc#owner {
                j x -ns jabber:x:data -type form {
                    j field -var FORM_TYPE -type hidden {
                        j value -body http://jabber.org/protocol/muc#roomconfig
                    }
                    j field -var muc#roomconfig_roomname -type text-single {
                        j value -body Lobby
                    }
                }
            }
        }]
        list [dict get $got type] \
             [lmap f [dict get $got fields] {dict get $f var}]
    } -result {form {FORM_TYPE muc#roomconfig_roomname}}

test muc-discover-rooms-occupants-from-form {discoverRooms reads occupancy from the disco form} \
    {*}$muc_common \
    -body {
        set got {}
        c muc discoverRooms -jid muc.example.com \
            -command [list apply {{rooms} { set ::got $rooms }}]
        set req [lindex [c.conn get_written] end]
        c.conn feed [j iq -type result -id [xsearch $req -get @id] \
            -from muc.example.com {
            j query -ns http://jabber.org/protocol/disco#items {
                j item -jid room@muc.example.com -name Lobby {
                    j x -ns jabber:x:data -type result {
                        j field -var FORM_TYPE -type hidden {
                            j value -body http://jabber.org/protocol/muc#roominfo
                        }
                        j field -var muc#roominfo_occupants {
                            j value -body 42
                        }
                    }
                }
            }
        }]
        set room [lindex $got 0]
        list [dict get $room jid] [dict get $room occupants]
    } -result {room@muc.example.com 42}

test muc-discover-rooms-error {a rejected discovery reports through -onerror} \
    {*}$muc_common \
    -body {
        set ::muc_err ""
        c muc discoverRooms -jid muc.example.com \
            -command [list apply {{rooms} {set ::muc_err unexpected}}] \
            -onerror [list apply {{msg} {set ::muc_err $msg}}]
        set req [lindex [c.conn get_written] end]
        c.conn feed [j iq -type error -id [xsearch $req -get @id] \
            -from muc.example.com {
            j error -type cancel {
                j forbidden -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        set ::muc_err
    } -result {You do not have permission to do that}

# -- Role/affiliation change via presence ------------------------------------

test muc-role-change-updates-state {role change via presence updates haveVoice} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -role visitor
        set before [c muc haveVoice -jid room@muc.example.com]
        # Moderator grants voice (role changes to participant)
        c.conn feed [muc_presence \
            from room@muc.example.com/me \
            role participant affiliation member \
            self 1]
        set after [c muc haveVoice -jid room@muc.example.com]
        list $before $after
    } -result {0 1}

# -- Disconnect clears state --------------------------------------------------

test muc-disconnect-clears-rooms {disconnect clears all room state} \
    {*}$muc_common \
    -body {
        muc_join room1@muc.example.com me
        muc_join room2@muc.example.com me
        c.conn fire_disconnect "gone"
        list [c muc isJoined -jid room1@muc.example.com] \
             [c muc isJoined -jid room2@muc.example.com] \
             [llength [c muc rooms]]
    } -result {0 0 0}

# -- tacky listen filtering ---------------------------------------------------

test muc-listen-filters-by-jid {tacky listen filters message <New> by -jid} \
    {*}$muc_common \
    -body {
        muc_join room1@muc.example.com me
        muc_join room2@muc.example.com me
        set got {}
        tacky listen message <New> -jid room1@muc.example.com?join \
            {apply {{ev} { lappend ::got [dict get $ev -jid] }}}
        c.conn feed [j message -type groupchat -from room1@muc.example.com/nick {
            j body -body "yes"
        }]
        c.conn feed [j message -type groupchat -from room2@muc.example.com/nick {
            j body -body "no"
        }]
        set got
    } -result {room1@muc.example.com?join}

# -- Affiliation changed while not in room ------------------------------------

test muc-affiliation-changed-event {<AffiliationChanged> fires on status 101} \
    {*}$muc_common \
    -body {
        set got {}
        tacky listen muc <AffiliationChanged> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -from room@muc.example.com {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -jid user@example.com -affiliation member
                j status -code 101
            }
        }]
        list [dict get $got -jid] [dict get $got -target] \
             [dict get $got -affiliation]
    } -result {room@muc.example.com user@example.com member}

# -- Join callback on success -------------------------------------------------

test muc-join-callback-on-success {join -command callback fires on success} \
    {*}$muc_common \
    -body {
        set got {}
        c muc join -jid room@muc.example.com -nick me \
            -command [list apply {{ev} { set ::got $ev }}]
        c.conn feed [muc_presence \
            from room@muc.example.com/me \
            role participant affiliation member self 1]
        list [dict get $got -jid] [dict get $got -nick]
    } -result {room@muc.example.com me}

# -- Case insensitivity -------------------------------------------------------

test muc-jid-case-insensitive {room JID is case-insensitive} \
    {*}$muc_common \
    -body {
        muc_join Room@MUC.Example.Com me
        list [c muc isJoined -jid room@muc.example.com] \
             [c muc myNick -jid ROOM@MUC.EXAMPLE.COM]
    } -result {1 me}

# -- Message storage -----------------------------------------------------------

test muc-groupchat-stored {groupchat messages stored under room@muc?join} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "stored msg"
        }]
        set msgs [dict get [c message messagestore get latest room@muc.example.com?join] messages]
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
    } -result {1 {stored msg}}

test muc-groupchat-emits-received {groupchat message emits message <New> with ?join jid} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <New> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "event msg"
        }]
        list [dict get $got -jid] [dict get $got -message content body]
    } -result {room@muc.example.com?join {event msg}}

test muc-groupchat-own-id-set-for-own-nick {own message via echo sets own_id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id my-msg-id \
            -from room@muc.example.com/me {
            j body -body "my echo"
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg own_id
    } -result {my-msg-id}

test muc-groupchat-own-id-empty-for-other-nick {other user message has empty own_id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id some-id \
            -from room@muc.example.com/someone {
            j body -body "their msg"
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg own_id
    } -result {}

test muc-groupchat-other-id-no-false-confirm {other user's @id matching pending own_id does not confirm} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        # Send a message (stores as pending with own_id)
        c message send -chat room@muc.example.com?join -body "test"
        set msgs [dict get [c message messagestore get latest room@muc.example.com?join] messages]
        set oid [dict get [lindex $msgs 0] own_id]
        # Someone else sends a message with that same @id
        c.conn feed [j message -type groupchat -id $oid \
            -from room@muc.example.com/someone {
            j body -body "coincidence"
        }]
        # Pending message should still be pending
        c db onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='room@muc.example.com?join' AND own_id != ''
        }
    } -result {pending}

test muc-groupchat-occupant-id-not-own-without-self-id \
    {a stanza with an occupant-id is not own while our own occupant-id is unknown} \
    {*}$muc_common \
    -body {
        # join sent, self-presence not back yet: myOccupantId still ""
        c muc join -jid room@muc.example.com -nick me
        c.conn feed [j message -type groupchat -id spoof-id \
            -from room@muc.example.com/me {
            j body -body "not mine"
            j occupant-id -ns urn:xmpp:occupant-id:0 -id imposter
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg own_id
    } -result {}

test muc-groupchat-own-by-occupant-id-not-nick \
    {a matching occupant-id marks a message own even under a different nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id my-msg-id \
            -from room@muc.example.com/renamed {
            j body -body "my echo"
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg own_id
    } -result {my-msg-id}

test muc-stanza-id-not-from-room-ignored \
    {a <stanza-id> stamped by anyone but the room is not the room's server_id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "forged sid"
            j stanza-id -ns urn:xmpp:sid:0 -id forged -by user@test.example.com
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg server_id
    } -result {}

test muc-pm-stored {private messages stored under room@muc/nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body -body "secret msg"
        }]
        set msgs [dict get [c message messagestore get latest room@muc.example.com/someone] messages]
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
    } -result {1 {secret msg}}

test muc-pm-emits-received {private message emits message <New> with full occupant jid} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <New> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body -body "secret event"
        }]
        list [dict get $got -jid] [dict get $got -message content body]
    } -result {room@muc.example.com/someone {secret event}}

test muc-groupchat-not-in-message-module {groupchat messages don't reach message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "only in muc"
        }]
        llength [dict get [c message messagestore get latest room@muc.example.com] messages]
    } -result {0}

test muc-pm-not-in-message-module {MUC PMs don't reach message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body -body "private"
        }]
        # message module would store under bare JID; should be empty
        llength [dict get [c message messagestore get latest room@muc.example.com] messages]
    } -result {0}

test muc-dm-passes-through {DM from non-MUC contact passes through to message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from alice@example.com/phone {
            j body -body "regular dm"
        }]
        set msgs [dict get [c message messagestore get latest alice@example.com] messages]
        list [llength $msgs] [dict get [lindex $msgs 0] content body]
    } -result {1 {regular dm}}

test muc-store-delayed-uses-stamp {stored MUC message uses delay timestamp} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "old msg"
            j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        set expected [ParseTimestamp 2024-06-15T12:00:00Z]
        expr {[dict get $msg timestamp] == $expected}
    } -result {1}

test muc-store-extracts-stanza-id {stored MUC message extracts stanza-id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body -body "with sid"
            j stanza-id -ns urn:xmpp:sid:0 -id srv99 -by room@muc.example.com
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg server_id
    } -result {srv99}

test muc-groupchat-unknown-room-dropped {groupchat from a room we never joined is ignored} \
    {*}$muc_common \
    -body {
        c.conn feed [j message -type groupchat -from evil@muc.evil.example/mallory {
            j body -body "injected"
        }]
        list [llength [dict get [c message messagestore get latest evil@muc.evil.example?join] messages]] \
            [c muc getSubject -jid evil@muc.evil.example]
    } -result {0 {}}

# -- Reactions (XEP-0444) -----------------------------------------------------

test muc-reaction-occupant-id {a groupchat reaction keyed by occupant-id aggregates onto the target} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/someone {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j body -body "hi all"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/other {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j reactions -ns urn:xmpp:reactions:0 -id srv1 { j reaction -body 👍 }
        }]
        set msgs [dict get [c message messagestore get latest room@muc.example.com?join] messages]
        dict get [lindex $msgs 0] reactions
    } -result {👍 {reactors other mine 0}}

test muc-reaction-no-occupant-id-dropped {a groupchat reaction with no occupant-id is dropped (fail-closed)} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/someone {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j body -body "hi all"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/other {
            j reactions -ns urn:xmpp:reactions:0 -id srv1 { j reaction -body 👍 }
        }]
        set msgs [dict get [c message messagestore get latest room@muc.example.com?join] messages]
        dict exists [lindex $msgs 0] reactions
    } -result 0

# -- Own occupant-id (XEP-0421) -----------------------------------------------

test muc-self-occupant-id-tracked {self-presence occupant-id is captured and exposed} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c muc myOccupantId -jid room@muc.example.com
    } -result {occ-me}

test muc-self-occupant-id-absent {no occupant-id in self-presence leaves it empty (non-0421 room)} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c muc myOccupantId -jid room@muc.example.com
    } -result {}

test muc-own-message-by-occupant-id-despite-nick \
    {our own message is detected by occupant-id even when the nick was service-rewritten} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id my-msg-id \
            -from room@muc.example.com/me-renamed {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j body -body "still mine"
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg is_outgoing
    } -result {1}

test muc-own-message-not-fooled-by-nick-spoof \
    {a message using our nick but a different occupant-id is not treated as ours} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id spoof-id \
            -from room@muc.example.com/me {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-impostor
            j body -body "not mine"
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg is_outgoing
    } -result {0}

test muc-own-reaction-keyed-by-occupant-id \
    {our own reaction keys by occupant-id, so the reflected echo does not double-count} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/someone {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j body -body "hi all"
        }]
        set ts [dict get [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0] timestamp]
        c message react -chat room@muc.example.com?join -timestamp $ts -emoji 👍
        # Room reflects our reaction back stamped with our occupant-id.
        c.conn feed [j message -type groupchat -from room@muc.example.com/me {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j reactions -ns urn:xmpp:reactions:0 -id srv1 { j reaction -body 👍 }
        }]
        set msgs [dict get [c message messagestore get latest room@muc.example.com?join] messages]
        dict get [lindex $msgs 0] reactions
    } -result {👍 {reactors me mine 1}}

test muc-occupant-id-stored-on-message {a peer message persists its occupant-id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-someone
            j body -body "hi"
        }]
        set msg [lindex [dict get [c message messagestore get latest room@muc.example.com?join] messages] 0]
        dict get $msg occupant_id
    } -result {occ-someone}

# -- Edits (XEP-0308) / moderation (XEP-0425) in a MUC ------------------------

proc muc_msgs {} {
    dict get [c message messagestore get latest room@muc.example.com?join] messages
}

test muc-edit-by-occupant-id \
    {a groupchat correction from the same occupant-id swaps the body} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/other {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j body -body "helo"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/other {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j replace -ns urn:xmpp:message-correct:0 -id srv1
            j body -body "hello"
        }]
        set m [lindex [muc_msgs] 0]
        list [dict get $m content body] [dict get $m edited] [llength [muc_msgs]]
    } -result {hello 1 1}

test muc-edit-occupant-spoof-rejected \
    {a correction from a different occupant-id does not edit the original} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/other {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j body -body "helo"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/impostor {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-impostor
            j replace -ns urn:xmpp:message-correct:0 -id srv1
            j body -body "HACKED"
        }]
        set m [lindex [muc_msgs] 0]
        list [dict get $m content body] [dict get $m edited]
    } -result {helo 0}

test muc-moderation-tombstones \
    {a moderated retraction broadcast from the room bare jid tombstones the message} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/other {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j body -body "spam"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com {
            j retract -ns urn:xmpp:message-retract:1 -id srv1 {
                j moderated -ns urn:xmpp:message-moderate:1 \
                    -by room@muc.example.com/mod
            }
        }]
        dict get [lindex [muc_msgs] 0] retracted
    } -result {1}

test muc-occupant-retract-ignored \
    {a <retract> from an occupant (not the room bare jid) is not honored} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/other {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j body -body "keep me"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/other {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j retract -ns urn:xmpp:message-retract:1 -id srv1
        }]
        dict get [lindex [muc_msgs] 0] retracted
    } -result {0}

test muc-moderate-sends-iq \
    {moderate sends a XEP-0425 moderate IQ to the room referencing the stanza-id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c.conn feed [j message -type groupchat -id srv1 \
            -from room@muc.example.com/other {
            j stanza-id -ns urn:xmpp:sid:0 -id srv1 -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-other
            j body -body "spam"
        }]
        set ts [dict get [lindex [muc_msgs] 0] timestamp]
        c message moderate -chat room@muc.example.com?join -timestamp $ts
        set iq [lindex [c.conn get_written] end]
        list [xsearch $iq moderate -ns urn:xmpp:message-moderate:1 -get @id] \
             [llength [xsearch $iq moderate retract \
                 -ns urn:xmpp:message-retract:1]]
    } -result {srv1 1}

# -- Editing our OWN MUC message (occupant-id backfill + auth) ----------------

test muc-own-edit-roundtrip-no-duplicate \
    {our own message's echo backfills occupant_id, and the correction echo re-applies without duplicating} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c message send -chat room@muc.example.com?join -body "а"
        set oid [dict get [lindex [muc_msgs] 0] own_id]
        # Room echoes our message back with a stanza-id + our occupant-id.
        c.conn feed [j message -type groupchat -id $oid \
            -from room@muc.example.com/me {
            j stanza-id -ns urn:xmpp:sid:0 -id srvA -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j body -body "а"
        }]
        set m [lindex [muc_msgs] 0]
        set backfilled [dict get $m occupant_id]
        # Correct it. The edit references the origin-id (our @id, oid), NOT
        # the stanza-id, so a strict peer can correlate it (XEP-0308).
        c message edit -chat room@muc.example.com?join \
            -timestamp [dict get $m timestamp] -body "б"
        # Room echoes the correction back, reflecting our <replace id=oid>.
        c.conn feed [j message -type groupchat -id corr1 \
            -from room@muc.example.com/me {
            j stanza-id -ns urn:xmpp:sid:0 -id srvB -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j replace -ns urn:xmpp:message-correct:0 -id $oid
            j body -body "б"
        }]
        set msgs [muc_msgs]
        list $backfilled [llength $msgs] \
            [dict get [lindex $msgs 0] content body] [dict get [lindex $msgs 0] edited]
    } -result {occ-me 1 б 1}

test muc-edit-replace-id-is-origin-not-stanza-id \
    {a MUC correction references the origin-id, never the room stanza-id (XEP-0308)} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c message send -chat room@muc.example.com?join -body "а"
        set oid [dict get [lindex [muc_msgs] 0] own_id]
        # Confirm the send so the row carries a stanza-id distinct from oid.
        c.conn feed [j message -type groupchat -id $oid \
            -from room@muc.example.com/me {
            j stanza-id -ns urn:xmpp:sid:0 -id srvA -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j body -body "а"
        }]
        set m [lindex [muc_msgs] 0]
        c message edit -chat room@muc.example.com?join \
            -timestamp [dict get $m timestamp] -body "б"
        set sent [lindex [c.conn get_written] end]
        set replaceId [xsearch $sent replace \
            -ns urn:xmpp:message-correct:0 -get @id]
        list [expr {$replaceId eq $oid}] [expr {$replaceId eq "srvA"}]
    } -result {1 0}

test muc-own-edit-spoof-still-rejected \
    {a correction of our own message from a different occupant-id is not applied to it} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me -occupant occ-me
        c message send -chat room@muc.example.com?join -body "mine"
        set oid [dict get [lindex [muc_msgs] 0] own_id]
        c.conn feed [j message -type groupchat -id $oid \
            -from room@muc.example.com/me {
            j stanza-id -ns urn:xmpp:sid:0 -id srvA -by room@muc.example.com
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-me
            j body -body "mine"
        }]
        c.conn feed [j message -type groupchat -from room@muc.example.com/impostor {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id occ-evil
            j replace -ns urn:xmpp:message-correct:0 -id srvA
            j body -body "HACKED"
        }]
        set mine ""
        foreach msg [muc_msgs] {
            if {[dict get $msg own_id] eq $oid} { set mine $msg }
        }
        list [dict get $mine content body] [dict get $mine edited]
    } -result {mine 0}

# -- Error stanzas from a room ------------------------------------------------
#
# Some servers report putting us out of a room by returning the broadcast
# they could not deliver as type=error, with the removal notice folded in:
# `role none` + status 110 is about us, while the body and occupant-id still
# belong to whoever wrote the message. XEP-0045 7.14 asks for a
# <presence type='unavailable'> instead, so nothing else recognises it.

proc muc_error {args} {
    set defaults {
        from room@muc.example.com/me by room@muc.example.com
        role none codes 110 body "" occupant "" sid "" x 1
    }
    set opts [dict merge $defaults $args]
    set from [dict get $opts from]
    set by [dict get $opts by]
    set role [dict get $opts role]
    set codes [dict get $opts codes]
    set body [dict get $opts body]
    set occ [dict get $opts occupant]
    set sid [dict get $opts sid]
    set withX [dict get $opts x]

    j message -type error -from $from -id 60f2fa56-6ebc-40d2-aa72-99b3f7a5c5a7 {
        if {$sid ne ""} {
            j stanza-id -ns urn:xmpp:sid:0 -id $sid -by $by
        }
        if {$occ ne ""} {
            j occupant-id -ns urn:xmpp:occupant-id:0 -id $occ
        }
        j error -type cancel {
            j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas
            j text -ns urn:ietf:params:xml:ns:xmpp-stanzas \
                -body "User session terminated"
        }
        if {$withX} {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -jid user@test.example.com/res -role $role \
                    -affiliation member
                foreach code $codes {
                    j status -code $code
                }
            }
        }
        if {$body ne ""} {
            j body -body $body
        }
    }
}

test muc-error-no-phantom-chat {a room's error stanza never becomes a 1:1 chat} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_error body "no see how." occupant other-occ \
                         sid 1787209304870024]
        list [c db onecolumn {
                  SELECT count(*) FROM chat_message
                  WHERE chat_jid='room@muc.example.com'}] \
             [c db onecolumn {
                  SELECT count(*) FROM chat_message
                  WHERE chat_jid='room@muc.example.com?join'
                    AND kind='message'}]
    } -result {0 0}

test muc-error-bodyless-no-chat {a bodyless room error makes no chat row either} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_error]
        c db onecolumn {SELECT count(*) FROM chat_message}
    } -result 0

test muc-error-removal-leaves-room {110 with role none in an error puts us out} \
    {*}$muc_common \
    -body {
        set ::got {}
        tacky listen muc <Left> {apply {{ev} { set ::got $ev }}}
        muc_join room@muc.example.com me
        c.conn feed [muc_error]
        list [dict get $::got -jid] [dict get $::got -nick] \
             [dict get $::got -involuntary] \
             [c muc isJoined -jid room@muc.example.com]
    } -result {room@muc.example.com me 1 0}

test muc-error-without-removal-notice-stays {an error with no 110 leaves us joined} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [muc_error codes {} body "bounced"]
        list [c muc isJoined -jid room@muc.example.com] \
             [c db onecolumn {SELECT count(*) FROM chat_message}]
    } -result {1 0}

test muc-error-unknown-room-not-claimed {an error from a room we are not in stores nothing} \
    {*}$muc_common \
    -body {
        c.conn feed [muc_error from other@muc.example.com/me \
                         by other@muc.example.com body "bounced"]
        c db onecolumn {SELECT count(*) FROM chat_message}
    } -result 0

test muc-error-removal-rejoins-autojoin-room {being put out re-enters an autojoin room} \
    {*}$muc_common \
    -body {
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 1, 'me', '')
        }
        muc_join room@muc.example.com me
        c.conn clear
        c.conn feed [muc_error]
        set tos {}
        foreach st [c.conn get_written] {
            lappend tos [xsearch $st -get @to]
        }
        set tos
    } -result {room@muc.example.com/me}

test muc-error-removal-skips-non-autojoin-room {a room we do not autojoin is left alone} \
    {*}$muc_common \
    -body {
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 0, 'me', '')
        }
        muc_join room@muc.example.com me
        c.conn clear
        c.conn feed [muc_error]
        llength [c.conn get_written]
    } -result 0

test muc-error-removal-rejoins-once-per-stream {a room that keeps ejecting us gets one answer} \
    {*}$muc_common \
    -body {
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 1, 'me', '')
        }
        muc_join room@muc.example.com me
        c.conn clear
        c.conn feed [muc_error]
        muc_join room@muc.example.com me
        c.conn feed [muc_error]
        set joins 0
        foreach st [c.conn get_written] {
            if {[xsearch $st -get @to] eq "room@muc.example.com/me"} {
                incr joins
            }
        }
        set joins
    } -result 2

test muc-left-voluntary-not-involuntary {leaving on purpose is not a removal} \
    {*}$muc_common \
    -body {
        set ::got {}
        tacky listen muc <Left> {apply {{ev} { set ::got $ev }}}
        muc_join room@muc.example.com me
        c muc leave -jid room@muc.example.com
        c.conn feed [muc_presence from room@muc.example.com/me \
                         type unavailable role none self 1]
        dict get $::got -involuntary
    } -result 0

test muc-left-kick-reports-codes {a kick reports its status codes on <Left>} \
    {*}$muc_common \
    -body {
        set ::got {}
        tacky listen muc <Left> {apply {{ev} { set ::got $ev }}}
        muc_join room@muc.example.com me
        c.conn feed [muc_presence from room@muc.example.com/me \
                         type unavailable role none self 1 codes 307]
        list [dict get $::got -involuntary] [dict get $::got -codes]
    } -result {1 {110 307}}

test muc-left-kick-not-rejoined {a kick is an answer, not a failure to retry} \
    {*}$muc_common \
    -body {
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 1, 'me', '')
        }
        muc_join room@muc.example.com me
        c.conn clear
        c.conn feed [muc_presence from room@muc.example.com/me \
                         type unavailable role none self 1 codes 307]
        llength [c.conn get_written]
    } -result 0

test muc-left-voluntary-writes-no-rejoin {leaving an autojoin room on purpose stays left} \
    {*}$muc_common \
    -body {
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 1, 'me', '')
        }
        muc_join room@muc.example.com me
        c muc leave -jid room@muc.example.com
        c.conn clear
        c.conn feed [muc_presence from room@muc.example.com/me \
                         type unavailable role none self 1]
        list [llength [c.conn get_written]] \
             [c muc isJoined -jid room@muc.example.com]
    } -result {0 0}

test muc-error-after-leave-not-rejoined {a room answering our leave with an error stays left} \
    {*}$muc_common \
    -body {
        set ::got {}
        tacky listen muc <Left> {apply {{ev} { set ::got $ev }}}
        c db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ('room@muc.example.com', 'Room', 1, 'me', '')
        }
        muc_join room@muc.example.com me
        c muc leave -jid room@muc.example.com
        c.conn clear
        c.conn feed [muc_error]
        list [dict get $::got -involuntary] [llength [c.conn get_written]]
    } -result {0 0}
