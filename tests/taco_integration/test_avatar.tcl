package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco
package require base64
package require sha1

namespace eval ::test::avatar_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    # 1x1 transparent PNG pixel (~68 bytes). publish is passthrough: the bytes
    # are stored and sent verbatim, so the on-wire hash is over these bytes.
    variable SAMPLE_PNG_B64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
    variable SAMPLE_PNG_RAW [::base64::decode $SAMPLE_PNG_B64]
    variable SAMPLE_PNG_HASH [::sha1::sha1 -hex $SAMPLE_PNG_RAW]

    # Helper: awaitEvent
    #
    # Registers a tacky listener with filters, runs a script, waits for the
    # event via wait_var. Returns the event args list.
    #
    # Usage:
    #   awaitEvent module <Event> ?-field value ...? script

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

    variable _awaitCounter 0

    proc publishAndWait {script} {
        set pubVar [namespace current]::_pubDone
        set $pubVar 0
        uplevel 1 $script
        wait_var $pubVar 5000
    }

    proc setup {} {
        variable ROMEO
        variable JULIET
        variable HOST

        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ROMEO -password romeopass -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET
        wait_events {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
        }
        # Listen before subscribing: the presences can arrive before a
        # listener registered afterwards.
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set [namespace current]::sees($acc) 0
            tacky listen presence <Changed> -acc $acc -jid $peer \
                [list apply {{var args} { set $var 1 }} [namespace current]::sees($acc)]
            set [namespace current]::asked($acc) 0
            tacky listen roster <Subscribe> -acc $acc -jid $peer -type subscribe \
                [list apply {{var args} { set $var 1 }} [namespace current]::asked($acc)]
        }
        tacky roster subscribe -acc $ROMEO -jid $JULIET
        tacky roster subscribe -acc $JULIET -jid $ROMEO
        # Approve a request once it has arrived, as a user would. Sent
        # before it, the approval is a pre-approval (RFC 6121 3.4), which a
        # server need not keep: MongooseIM drops it.
        # Already subscribed (an earlier test in this run), no request comes.
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set deadline [expr {[clock milliseconds] + 10000}]
            while {![set [namespace current]::asked($acc)]
                    && [tacky roster subscription -acc $acc -jid $peer] ni {from both}} {
                if {[clock milliseconds] > $deadline} {
                    error "no subscription request from $peer reached $acc"
                }
                after 50 [list set [namespace current]::tick 1]
                vwait [namespace current]::tick
            }
            tacky roster approve -acc $acc -jid $peer
        }
        foreach acc [list $ROMEO $JULIET] {
            wait_value [namespace current]::sees($acc) 1 10000
        }
        tacky avatar visible -acc $JULIET -jid $ROMEO
    }

    proc cleanup {} {
        variable ROMEO
        variable TIMEOUT

        catch {
            set var [namespace current]::_disableDone
            set $var 0
            tacky avatar disable -acc $ROMEO -command [list apply {{var result} {
                set $var 1
            }} $var]
            wait_var $var $TIMEOUT
        }

        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::avatar_int::setup }
        -cleanup { ::test::avatar_int::cleanup }
    }

    # --- Romeo publishes, Juliet receives notification ---

    test avatar-int-publish "Romeo publishes avatar, Juliet receives Update with correct hash" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            wait_var $pubVar 5000
        }]

        set hash [dict get $eventArgs -hash]
        expr {$hash eq $SAMPLE_PNG_HASH}
    } -result 1

    # --- Juliet can fetch the actual image data ---

    test avatar-int-fetch-data "Juliet retrieves avatar data matching what Romeo published" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            wait_var $pubVar 5000
        }

        set data [tacky avatar data -acc $JULIET -hash $SAMPLE_PNG_HASH]
        expr {$data eq $SAMPLE_PNG_RAW}
    } -result 1

    # --- Juliet has correct metadata ---

    test avatar-int-metadata "Juliet has correct avatar metadata for Romeo" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -width 128 -height 128 \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            wait_var $pubVar 5000
        }

        # Passthrough advertises the caller-supplied type/width/height in <info>.
        set meta [tacky avatar metadata -acc $JULIET -jid $ROMEO]
        list [expr {[dict get $meta hash] eq $SAMPLE_PNG_HASH}] \
            [dict get $meta type] \
            [expr {[dict get $meta bytes] > 0}] \
            [dict get $meta width] [dict get $meta height]
    } -result {1 image/png 1 128 128}

    # --- Fresh-startup: Juliet loads Romeo's pre-existing avatar on connect ---

    # Not on MongooseIM: on a reconnect with caps it already knows, it doesn't
    # send a contact's last published item (XEP-0163 says it should), and
    # Tacky relies on that push.
    test avatar-int-fresh-startup "Juliet loads Romeo's pre-existing avatar via initial PEP push on a fresh connect" {*}$common -constraints {withServer && notMongoose} -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        # Juliet goes offline (simulate app shutdown).
        awaitEvent conn <State> -acc $JULIET -state disconnected {
            tacky account disable -acc $JULIET
        }

        # Romeo publishes an avatar while Juliet is offline, so Juliet never
        # sees a live notification and has nothing cached.
        set pubVar [namespace current]::_pubDone
        set $pubVar 0
        tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
            -command [list apply {{var result} {
                set $var 1
            }} $pubVar]
        wait_var $pubVar 5000

        # Juliet starts fresh: reconnect, mark Romeo visible, and expect the
        # avatar to arrive via the server's initial PEP push.
        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            tacky account enable -acc $JULIET
            wait_events {
                {conn <State> -acc juliet@example.local -state connected}
            }
            tacky avatar visible -acc $JULIET -jid $ROMEO
        }]

        set hash [dict get $eventArgs -hash]
        expr {$hash eq $SAMPLE_PNG_HASH}
    } -result 1

    # --- Reconnect: visibility set once (as the GUI does) survives a reconnect ---

    test avatar-int-reconnect-visibility "Avatar still fetched after a reconnect without re-marking visible" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        # setup already marked Romeo visible for Juliet, once. The GUI never
        # re-marks visibility across a reconnect, so model that: bounce Juliet's
        # connection without calling `avatar visible` again.
        awaitEvent conn <State> -acc $JULIET -state disconnected {
            tacky account disable -acc $JULIET
        }
        tacky account enable -acc $JULIET
        wait_events {
            {conn <State> -acc juliet@example.local -state connected}
        }

        # Romeo now publishes. Juliet should still receive and fetch it.
        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            wait_var $pubVar 5000
        }]

        set hash [dict get $eventArgs -hash]
        expr {$hash eq $SAMPLE_PNG_HASH}
    } -result 1

    # --- Romeo disables avatar ---

    test avatar-int-disable "Romeo disables avatar, Juliet receives disabled Update" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable ROMEO
        variable JULIET

        # Publish first
        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            wait_var $pubVar 5000
        }

        # Disable and wait for the empty-hash removal notification
        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -hash "" {
            set disVar [namespace current]::_disDone
            set $disVar 0
            tacky avatar disable -acc $ROMEO -command [list apply {{var result} {
                set $var 1
            }} $disVar]
            wait_var $disVar 5000
        }]

        set meta [tacky avatar metadata -acc $JULIET -jid $ROMEO]
        list [dict get $eventArgs -hash] [expr {$meta eq {}}]
    } -result {{} 1}
}
