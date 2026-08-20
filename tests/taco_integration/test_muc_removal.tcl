package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# End-to-end cover for being put out of a room by a real server, and for what
# its error stanzas do to us.
#
# The bug behind it: a room's undeliverable broadcast came back as type=error
# with the "you are out" notice folded in; we filed its echoed body as a
# private message from the room, and left the room marked joined.
namespace eval ::test::muc_removal_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"
    variable ROOM "mucremoval@conference.example.local"
    variable CHAT "mucremoval@conference.example.local?join"

    variable _awaitCounter 0

    # Register a listener, run $script (its last arg), and return the event's
    # argument list once it fires. Errors on timeout.
    proc awaitEvent {args} {
        variable TIMEOUT
        set script [lindex $args end]
        set listenerArgs [lrange $args 0 end-1]

        set var [namespace current]::_await_[incr [namespace current]::_awaitCounter]
        set $var ""

        set tag [tacky listen {*}$listenerArgs [list apply {{var argsL} {
            set $var $argsL
        }} $var]]

        uplevel 1 $script

        try {
            ::test::helpers::waitVar $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }

        tacky unlisten $tag
        return [set $var]
    }

    proc joinRoom {acc nick {unlock 0}} {
        variable ROOM
        set ev [awaitEvent muc <Joined> -acc $acc -jid $ROOM {
            [tacky client $acc] muc join -jid $ROOM -nick $nick
        }]
        if {$unlock} {
            variable TIMEOUT
            set done [namespace current]::_unlock_[incr [namespace current]::_awaitCounter]
            set ${done} 0
            [tacky client $acc] muc createInstant -jid $ROOM \
                -command [list apply {{dv args} { set $dv 1 }} $done]
            ::test::helpers::waitVar $done $TIMEOUT
        }
        return $ev
    }

    # Round-trip an IQ to the room and wait for its answer. Anything the room
    # sent earlier is in front of that answer on the same stream, so this
    # settles without a sleep.
    proc settleWithRoom {acc} {
        variable ROOM
        variable TIMEOUT
        set done [namespace current]::_settle_[incr [namespace current]::_awaitCounter]
        set ${done} 0
        [tacky client $acc] iq request -type get -to $ROOM \
            -payload [j query -ns http://jabber.org/protocol/disco#info] \
            -command [list apply {{dv args} { set $dv 1 }} $done]
        ::test::helpers::waitVar $done $TIMEOUT
    }

    # Rows stored under a chat jid, whatever kind.
    proc rowCount {acc chatJid} {
        return [[tacky client $acc] db onecolumn {
            SELECT count(*) FROM chat_message WHERE chat_jid=$chatJid
        }]
    }

    proc bookmarkAutojoin {acc jid flag} {
        [tacky client $acc] db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password)
            VALUES ($jid, 'Removal room', $flag, 'juliet', '')
        }
    }

    proc bringUp {} {
        variable HOST
        variable ROMEO
        variable JULIET

        tacky_init
        tacky account add -acc $ROMEO -password romeopass \
            -domain $HOST -username romeo
        tacky account add -acc $JULIET -password julietpass \
            -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET

        ::test::helpers::waitEvents {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
        }
        ::test::helpers::waitEvents {
            {message <CatchupDone> -acc romeo@example.local}
            {message <CatchupDone> -acc juliet@example.local}
        }
    }

    proc setup {} {
        variable ROMEO
        variable JULIET
        bringUp
        joinRoom $ROMEO romeo 1
        joinRoom $JULIET juliet
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::muc_removal_int::setup }
        -cleanup { ::test::muc_removal_int::cleanup }
    }

    test muc-int-kick-is-an-involuntary-left \
        {a real kick puts us out and says the server did it} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM

            set ev [awaitEvent muc <Left> -acc $JULIET -jid $ROOM {
                [tacky client $ROMEO] muc kick -jid $ROOM -nick juliet
            }]
            list [dict get $ev -involuntary] \
                 [expr {307 in [dict get $ev -codes]}] \
                 [[tacky client $JULIET] muc isJoined -jid $ROOM]
        } -result {1 1 0}

    test muc-int-kick-is-not-rejoined \
        {a kick is an answer, so an autojoin room is not re-entered} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM

            bookmarkAutojoin $JULIET $ROOM 1
            awaitEvent muc <Left> -acc $JULIET -jid $ROOM {
                [tacky client $ROMEO] muc kick -jid $ROOM -nick juliet
            }
            settleWithRoom $JULIET
            [tacky client $JULIET] muc isJoined -jid $ROOM
        } -result 0

    test muc-int-bounced-groupchat-is-not-a-chat \
        {a room's error bounce never becomes a conversation with the room} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            variable CHAT

            # Put Juliet out, then have her send anyway: the room bounces it
            # back as type=error with the body echoed. That echo used to be
            # stored as an incoming message from the room's bare jid.
            awaitEvent muc <Left> -acc $JULIET -jid $ROOM {
                [tacky client $ROMEO] muc kick -jid $ROOM -nick juliet
            }
            [tacky client $JULIET] write \
                [j message -to $ROOM -type groupchat -id bounce-me {
                    j body -body "this cannot land"
                }]
            settleWithRoom $JULIET
            list [rowCount $JULIET $ROOM] \
                 [[tacky client $JULIET] db onecolumn {
                      SELECT count(*) FROM chat_message
                      WHERE body='this cannot land'}]
        } -result {0 0}
}
