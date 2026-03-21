# Unit tests for taco_muc

set muc_common {
    -setup {
        tacky_type create tacky

        rename conn _real_conn
        rename mock_conn conn

        taco_client c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res
    }
    -cleanup {
        catch {c destroy}
        rename conn mock_conn
        rename _real_conn conn
        tacky destroy
    }
}

# -- Helpers --

# Build a MUC presence stanza with <x xmlns='muc#user'> containing an <item>.
# Defaults to self-presence (status code 110).
proc muc_presence {args} {
    set defaults {
        from room@muc.example.com/me
        role participant affiliation member
        self 1 codes {} type ""
    }
    set opts [dict merge $defaults $args]
    set from [dict get $opts from]
    set role [dict get $opts role]
    set affil [dict get $opts affiliation]
    set isSelf [dict get $opts self]
    set extraCodes [dict get $opts codes]
    set type_ [dict get $opts type]

    set presAttrs [list -from $from]
    if {$type_ ne ""} {
        lappend presAttrs -type $type_
    }

    j presence {*}$presAttrs {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -role $role -affiliation $affil
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
    set defaults {-role participant -affiliation member}
    set opts [dict merge $defaults $args]
    c muc join -jid $room -nick $nick
    c.conn feed [muc_presence \
        from $room/$nick \
        role [dict get $opts -role] \
        affiliation [dict get $opts -affiliation] \
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

test muc-message-event {groupchat message emits message <Received> only} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <Received> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body #body "hi all"
        }]
        list [dict get $got -jid] [dict get $got -message body]
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

test muc-private-message-event {private message emits message <Received> only} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <Received> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body #body "secret"
        }]
        list [dict get $got -jid] [dict get $got -message body]
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
            j subject #body "welcome"
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
                    j reason #body "behave"
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
                    j reason #body "spam"
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
                    j reason #body "come join"
                }
                j password #body roompass
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
                    j reason #body "busy"
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
                    j reason #body "moved"
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
                    j value #body http://jabber.org/protocol/muc#request
                }
                j field -var muc#jid {
                    j value #body visitor@example.com
                }
                j field -var muc#roomnick {
                    j value #body newbie
                }
            }
        }]
        list [dict get $got -jid] [dict get $got -from] [dict get $got -nick]
    } -result {room@muc.example.com visitor@example.com newbie}

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

test muc-listen-filters-by-jid {tacky listen filters message <Received> by -jid} \
    {*}$muc_common \
    -body {
        muc_join room1@muc.example.com me
        muc_join room2@muc.example.com me
        set got {}
        tacky listen message <Received> -jid room1@muc.example.com?join \
            {apply {{ev} { lappend ::got [dict get $ev -jid] }}}
        c.conn feed [j message -type groupchat -from room1@muc.example.com/nick {
            j body #body "yes"
        }]
        c.conn feed [j message -type groupchat -from room2@muc.example.com/nick {
            j body #body "no"
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
            j body #body "stored msg"
        }]
        set msgs [c message messagestore get latest room@muc.example.com?join]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {stored msg}}

test muc-groupchat-emits-received {groupchat message emits message <Received> with ?join jid} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <Received> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body #body "event msg"
        }]
        list [dict get $got -jid] [dict get $got -message body]
    } -result {room@muc.example.com?join {event msg}}

test muc-groupchat-own-id-set-for-own-nick {own message via echo sets own_id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id my-msg-id \
            -from room@muc.example.com/me {
            j body #body "my echo"
        }]
        set msg [lindex [c message messagestore get latest room@muc.example.com?join] 0]
        dict get $msg own_id
    } -result {my-msg-id}

test muc-groupchat-own-id-empty-for-other-nick {other user message has empty own_id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -id some-id \
            -from room@muc.example.com/someone {
            j body #body "their msg"
        }]
        set msg [lindex [c message messagestore get latest room@muc.example.com?join] 0]
        dict get $msg own_id
    } -result {}

test muc-groupchat-other-id-no-false-confirm {other user's @id matching pending own_id does not confirm} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        # Send a message (stores as pending with own_id)
        c message send -chat_jid room@muc.example.com?join -body "test"
        set msgs [c message messagestore get latest room@muc.example.com?join]
        set oid [dict get [lindex $msgs 0] own_id]
        # Someone else sends a message with that same @id
        c.conn feed [j message -type groupchat -id $oid \
            -from room@muc.example.com/someone {
            j body #body "coincidence"
        }]
        # Pending message should still be pending
        c db onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='room@muc.example.com?join' AND own_id != ''
        }
    } -result {pending}

test muc-pm-stored {private messages stored under room@muc/nick} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body #body "secret msg"
        }]
        set msgs [c message messagestore get latest room@muc.example.com/someone]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {secret msg}}

test muc-pm-emits-received {private message emits message <Received> with full occupant jid} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        set got {}
        tacky listen message <Received> {apply {{ev} { set ::got $ev }}}
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body #body "secret event"
        }]
        list [dict get $got -jid] [dict get $got -message body]
    } -result {room@muc.example.com/someone {secret event}}

test muc-groupchat-not-in-message-module {groupchat messages don't reach message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body #body "only in muc"
        }]
        llength [c message messagestore get latest room@muc.example.com]
    } -result {0}

test muc-pm-not-in-message-module {MUC PMs don't reach message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from room@muc.example.com/someone {
            j body #body "private"
        }]
        # message module would store under bare JID; should be empty
        llength [c message messagestore get latest room@muc.example.com]
    } -result {0}

test muc-dm-passes-through {DM from non-MUC contact passes through to message module} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "regular dm"
        }]
        set msgs [c message messagestore get latest alice@example.com]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 {regular dm}}

test muc-store-delayed-uses-stamp {stored MUC message uses delay timestamp} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body #body "old msg"
            j delay -ns urn:xmpp:delay -stamp 2024-06-15T12:00:00Z
        }]
        set msg [lindex [c message messagestore get latest room@muc.example.com?join] 0]
        set expected [ParseTimestamp 2024-06-15T12:00:00Z]
        expr {[dict get $msg timestamp] == $expected}
    } -result {1}

test muc-store-extracts-stanza-id {stored MUC message extracts stanza-id} \
    {*}$muc_common \
    -body {
        muc_join room@muc.example.com me
        c.conn feed [j message -type groupchat -from room@muc.example.com/someone {
            j body #body "with sid"
            j stanza-id -ns urn:xmpp:sid:0 -id srv99
        }]
        set msg [lindex [c message messagestore get latest room@muc.example.com?join] 0]
        dict get $msg server_id
    } -result {srv99}
