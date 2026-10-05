package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

::tcltest::testConstraint smServer [info exists ::env(XMPP_SM)]

# Dropped connections against a real server, with a room joined. A reconnect
# that could not resume used to keep every room marked joined, so autojoin
# skipped them and the rooms went quiet until a restart.
namespace eval ::test::muc_reconnect_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"
    # A room per test: with stream management the last test's sessions
    # still hibernate in its room under the same nicks.
    variable ROOM ""
    variable CHAT ""
    variable RoomSeq 0

    proc joinRoom {acc nick {unlock 0}} {
        variable ROOM
        set seen [expect_events [list [list muc <Joined> -acc $acc -jid $ROOM]]]
        [tacky client $acc] muc join -jid $ROOM -nick $nick
        wait_expected $seen
        if {$unlock} {
            wait_call [tacky client $acc] muc createInstant -jid $ROOM
        }
    }

    # Round-trip an IQ to our own server: whatever we sent before it has
    # been handled once the answer is back.
    proc settleWithServer {acc} {
        wait_call [tacky client $acc] iq request -type get -to [jid domain $acc] \
            -payload [j query -ns http://jabber.org/protocol/disco#info]
    }

    # Drop the transport the way a network failure does. Unresumable is a
    # drop past the server's resume window: the reconnect is a fresh stream.
    proc drop {acc {resumable 0}} {
        set c [tacky client $acc]
        if {!$resumable} { [$c conn sm] ResumeFailed }
        $c conn OnTransportError "simulated drop"
    }

    proc said {acc body} {
        return [[tacky client $acc] db onecolumn {
            SELECT count(*) FROM chat_message WHERE body=$body
        }]
    }

    proc setup {} {
        variable HOST
        variable ROMEO
        variable JULIET
        variable ROOM
        variable CHAT
        variable RoomSeq

        set ROOM "mucreconnect[incr RoomSeq]-[clock milliseconds]@conference.example.local"
        set CHAT $ROOM?join
        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ROMEO -password romeopass \
            -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass \
            -domain $HOST -username juliet
        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET
        wait_events {
            {message <CatchupDone> -acc romeo@example.local}
            {message <CatchupDone> -acc juliet@example.local}
        }

        joinRoom $ROMEO romeo 1
        joinRoom $JULIET juliet
        # A fresh stream refetches bookmarks from the server and autojoins
        # only those.
        tacky bookmarks item -acc $JULIET -jid $ROOM -autojoin 1 -nick juliet
        settleWithServer $JULIET
    }

    proc cleanup {} {
        variable JULIET
        variable ROOM
        catch {
            tacky bookmarks remove -acc $JULIET -jid $ROOM
            settleWithServer $JULIET
        }
        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::muc_reconnect_int::setup }
        -cleanup { ::test::muc_reconnect_int::cleanup }
    }

    test muc-int-fresh-stream-rejoins-autojoin-room \
        {a reconnect that could not resume leaves the room, rejoins it, and hears it again} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            variable CHAT

            set seen [expect_events [list \
                [list muc <Left> -acc $JULIET -jid $ROOM -disconnected 1] \
                [list muc <Joined> -acc $JULIET -jid $ROOM]]]
            drop $JULIET
            # Past the reconnect backoff and the bookmarks refetch.
            wait_expected $seen 30000

            set seen [expect_events [list [list message <New> -acc $JULIET -jid $CHAT]]]
            [tacky client $ROMEO] message send -chat $CHAT -body "after the drop"
            wait_expected $seen
            list [[tacky client $JULIET] muc isJoined -jid $ROOM] \
                [said $JULIET "after the drop"]
        } -result {1 1}

    # With stream management the server keeps the session (XEP-0198 5), so
    # the room is never left.
    test muc-int-resumed-stream-stays-in-room \
        {a reconnect that resumes stays in the room, without a Left} \
        {*}$common -constraints {withServer && notMongoose && notEjabberd && !wasm && smServer} \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            variable CHAT

            set ::test::muc_reconnect_int::left 0
            tacky listen -tag reconnect-left muc <Left> -acc $JULIET -jid $ROOM \
                {apply {{args} { incr ::test::muc_reconnect_int::left }}}
            set seen [expect_events [list \
                [list conn <State> -acc $JULIET -state connected]]]
            drop $JULIET 1
            wait_expected $seen 30000

            set seen [expect_events [list [list message <New> -acc $JULIET -jid $CHAT]]]
            [tacky client $ROMEO] message send -chat $CHAT -body "after the resume"
            wait_expected $seen
            tacky unlisten reconnect-left
            list [dict get [[[tacky client $JULIET] conn sm] getInfo] resumed] \
                $::test::muc_reconnect_int::left \
                [[tacky client $JULIET] muc isJoined -jid $ROOM] \
                [said $JULIET "after the resume"]
        } -result {1 0 1 1}
}
