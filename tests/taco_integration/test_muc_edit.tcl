package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# End-to-end regression for the XEP-0308 MUC correction id (the bug where an
# edit in a room shows up as a fresh message on other clients). Two accounts
# join a real Prosody room; one sends then edits; we assert the correction's
# on-wire <replace id> is the message's origin-id (the id peers correlate
# against), NOT the room-assigned stanza-id. A tacky<->tacky body/dedup check
# alone can't catch this: our own receiver matches the id-triple leniently, so
# it would tolerate a stanza-id here; only the wire value exposes the defect.
namespace eval ::test::muc_edit_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"
    variable ROOM "muctest@conference.example.local"
    variable CHAT "muctest@conference.example.local?join"

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

    # Join $acc to the room. The first joiner creates a locked instant room;
    # $unlock submits the empty owner config form so a second occupant can
    # enter (Prosody keeps a freshly created room locked until then).
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

    proc msgs {acc} {
        variable CHAT
        return [dict get \
            [[tacky client $acc] message messagestore get latest $CHAT] messages]
    }

    proc rowOfBody {acc body} {
        set found ""
        foreach m [msgs $acc] {
            if {[dict get $m body] eq $body} { set found $m }
        }
        return $found
    }

    proc setup {} {
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
            {conn <Ready> -acc romeo@example.local}
            {conn <Ready> -acc juliet@example.local}
        }
        ::test::helpers::waitEvents {
            {message <CatchupDone> -acc romeo@example.local}
            {message <CatchupDone> -acc juliet@example.local}
        }

        joinRoom $ROMEO romeo 1
        joinRoom $JULIET juliet
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::muc_edit_int::setup }
        -cleanup { ::test::muc_edit_int::cleanup }
    }

    test muc-int-edit-replace-id-is-origin-not-stanza-id \
        {a MUC correction goes out referencing the origin-id, not the room stanza-id} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET
            variable CHAT

            # Juliet posts to the room; wait until Romeo receives it.
            awaitEvent message <New> -acc $ROMEO -jid $CHAT {
                [tacky client $JULIET] message send -chat $CHAT -body "первое"
            }

            # The origin-id is Juliet's own_id, reflected verbatim to every
            # occupant as the message @id (peers correlate corrections against
            # it). The stanza-id is the room-assigned server_id Romeo recorded.
            set jRow [rowOfBody $JULIET "первое"]
            set rRow [rowOfBody $ROMEO "первое"]
            set originId [dict get $jRow own_id]
            set serverId [dict get $rRow server_id]
            if {$originId eq "" || $serverId eq ""} {
                error "expected Juliet own_id and Romeo server_id; got\
                       own_id='$originId' server_id='$serverId'"
            }
            if {$originId eq $serverId} {
                error "own_id and server_id coincide ($originId); the room did\
                       not assign a distinct stanza-id, test can't discriminate"
            }

            # Juliet edits her own message; wait for Romeo's in-place patch.
            set jts [dict get $jRow timestamp]
            awaitEvent message <Patch> -acc $ROMEO -jid $CHAT {
                [tacky client $JULIET] message edit \
                    -chat $CHAT -timestamp $jts -body "второе"
            }

            # Romeo's stored row: the correction applied in place (no dup),
            # and its recorded wire form references the origin-id.
            set rMsgs [msgs $ROMEO]
            set nFirst 0
            set nSecond 0
            set rawxml ""
            foreach m $rMsgs {
                switch -- [dict get $m body] {
                    "первое" { incr nFirst }
                    "второе" { incr nSecond; set rawxml [dict get $m raw_xml] }
                }
            }
            set replaceId ""
            regexp {<replace [^>]*id='([^']*)'} $rawxml -> replaceId

            list [expr {$nSecond == 1}] [expr {$nFirst == 0}] \
                 [expr {$replaceId eq $originId}] \
                 [expr {$replaceId eq $serverId}]
        } -result {1 1 1 0}
}
