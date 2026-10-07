package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# A room's avatar against a real server: the owner sets and then removes
# the room's vCard photo, and the other occupant's client picks up both
# changes from the room's presence and disco#info (XEP-0153, XEP-0486).
namespace eval ::test::muc_avatar_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"
    variable ROOM "avatartest@conference.example.local"

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
            wait_var $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }
        tacky unlisten $tag
        return [set $var]
    }

    proc joinRoom {acc nick {unlock 0}} {
        variable ROOM
        variable TIMEOUT
        awaitEvent muc <Joined> -acc $acc -jid $ROOM {
            [tacky client $acc] muc join -jid $ROOM -nick $nick
        }
        if {$unlock} {
            set done [namespace current]::_unlock_[incr [namespace current]::_awaitCounter]
            set $done 0
            [tacky client $acc] muc createInstant -jid $ROOM \
                -command [list apply {{dv args} { set $dv 1 }} $done]
            wait_var $done $TIMEOUT
        }
    }

    # Set the room's vCard as its owner: with a photo of $bytes, or none.
    proc setRoomPhoto {acc bytes} {
        variable ROOM
        variable TIMEOUT
        set done [namespace current]::_vcard_[incr [namespace current]::_awaitCounter]
        set $done ""
        [tacky client $acc] iq request -type set -to $ROOM \
            -command [list apply {{dv st} { set $dv [xsearch $st -get @type] }} $done] \
            -payload [j vCard -ns vcard-temp {
                if {$bytes ne ""} {
                    j PHOTO {
                        j TYPE -body image/png
                        j BINVAL -body [binary encode base64 $bytes]
                    }
                }
            }]
        wait_var $done $TIMEOUT
        set $done
    }

    proc setup {} {
        variable HOST
        variable ROMEO
        variable JULIET
        variable ROOM
        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ROMEO -password romeopass \
            -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass \
            -domain $HOST -username juliet
        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET
        wait_events {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
        }
        joinRoom $ROMEO romeo 1
        # Juliet marks the room visible, so a new hash is fetched at once.
        [tacky client $JULIET] avatar visible -jid $ROOM
        joinRoom $JULIET juliet
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    # Not on MongooseIM: its rooms have no vCard (feature-not-implemented).
    test muc-avatar-int-follows-the-room \
        {an occupant's client picks up the room avatar the owner sets, and its removal} \
        -constraints {withServer && notMongoose} \
        -setup { ::test::muc_avatar_int::setup } \
        -cleanup { ::test::muc_avatar_int::cleanup } \
        -body {
            variable ROMEO
            variable JULIET
            variable ROOM
            set bytes "not really a png, but bytes all the same"
            set want [::sha1::sha1 $bytes]
            set set [awaitEvent avatar <Update> -acc $JULIET -jid $ROOM {
                set stored [setRoomPhoto $ROMEO $bytes]
            }]
            set got [dict get $set -hash]
            set cleared [awaitEvent avatar <Update> -acc $JULIET -jid $ROOM {
                setRoomPhoto $ROMEO ""
            }]
            list $stored [expr {$got eq $want}] [dict get $cleared -hash] \
                [[tacky client $JULIET] avatar metadata -jid $ROOM]
        } -result {result 1 {} {}}
}
