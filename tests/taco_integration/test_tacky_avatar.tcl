package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::tacky_avatar {

    variable HOST "example.local"
    variable PORT 5222
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    # 1x1 transparent PNG pixel (~68 bytes)
    variable SAMPLE_PNG_B64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
    variable SAMPLE_PNG_RAW [::base64::decode $SAMPLE_PNG_B64]
    variable SAMPLE_PNG_HASH [::sha1::sha1 -hex $SAMPLE_PNG_RAW]

    # Helper: awaitEvent
    #
    # Registers a tacky listener with filters, runs a script, waits for the
    # event via waitVar. Returns the event args list.
    #
    # Usage:
    #   awaitEvent module <Event> ?-field value ...? script

    proc awaitEvent {args} {
        variable TIMEOUT
        # Last arg is the script to run
        set script [lindex $args end]
        # Everything before the script is: module event ?filters...?
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

    variable _awaitCounter 0

    proc setup {} {
        variable HOST
        variable ROMEO
        variable JULIET

        tacky_init
        tacky account add -acc $ROMEO -password romeopass -domain $HOST -username romeo
        tacky account add -acc $JULIET -password julietpass -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET
        ::test::helpers::waitEvents {
            {conn <Ready> -acc romeo@example.local}
            {conn <Ready> -acc juliet@example.local}
        }
        tacky roster subscribe -acc $ROMEO -jid $JULIET
        tacky roster subscribe -acc $JULIET -jid $ROMEO
        tacky roster approve -acc $ROMEO -jid $JULIET
        tacky roster approve -acc $JULIET -jid $ROMEO
        ::test::helpers::waitEvents {
            {presence <Changed> -acc romeo@example.local -jid juliet@example.local}
            {presence <Changed> -acc juliet@example.local -jid romeo@example.local}
        }
        tacky avatar visible -acc $JULIET -jid $ROMEO
    }

    proc cleanup {} {
        variable ROMEO
        variable TIMEOUT

        # Disable avatar to leave server state clean
        catch {
            set var [namespace current]::_disableDone
            set $var 0
            tacky avatar disable -acc $ROMEO -command [list apply {{var result} {
                set $var 1
            }} $var]
            ::test::helpers::waitVar $var $TIMEOUT
        }

        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::tacky_avatar::setup }
        -cleanup { ::test::tacky_avatar::cleanup }
    }

    test tacky-avatar-publish "Romeo publishes avatar, Juliet receives Update with correct hash" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        # Publish and wait for Juliet's <Update> notification
        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            ::test::helpers::waitVar $pubVar 5000
        }]

        set hash [dict get $eventArgs -hash]
        expr {$hash eq $SAMPLE_PNG_HASH}
    } -result 1

    test tacky-avatar-fetch "Juliet retrieves raw image data matching what Romeo published" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable ROMEO
        variable JULIET

        # Publish and wait for notification
        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            ::test::helpers::waitVar $pubVar 5000
        }

        # Fetch the avatar data through tacky API
        set data [tacky avatar data -acc $JULIET -hash [::sha1::sha1 -hex $SAMPLE_PNG_RAW]]
        expr {$data eq $SAMPLE_PNG_RAW}
    } -result 1

    test tacky-avatar-metadata "Juliet has correct metadata for Romeo after publish" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable SAMPLE_PNG_HASH
        variable ROMEO
        variable JULIET

        # Publish and wait for notification
        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            ::test::helpers::waitVar $pubVar 5000
        }

        set meta [tacky avatar metadata -acc $JULIET -jid $ROMEO]
        list [expr {[dict get $meta hash] eq $SAMPLE_PNG_HASH}] \
            [dict get $meta type] \
            [expr {[dict get $meta bytes] > 0}]
    } -result {1 image/png 1}

    test tacky-avatar-disable "Romeo disables avatar, Juliet receives Update with disabled action" {*}$common -body {
        variable SAMPLE_PNG_RAW
        variable ROMEO
        variable JULIET

        # First publish so there's something to disable
        awaitEvent avatar <Update> -acc $JULIET -jid $ROMEO {
            set pubVar [namespace current]::_pubDone
            set $pubVar 0
            tacky avatar publish -acc $ROMEO -data $SAMPLE_PNG_RAW -type image/png \
                -command [list apply {{var result} {
                    set $var 1
                }} $pubVar]
            ::test::helpers::waitVar $pubVar 5000
        }

        # Now disable and wait for the disabled notification
        set eventArgs [awaitEvent avatar <Update> -acc $JULIET -action disabled {
            set disVar [namespace current]::_disDone
            set $disVar 0
            tacky avatar disable -acc $ROMEO -command [list apply {{var result} {
                set $var 1
            }} $disVar]
            ::test::helpers::waitVar $disVar 5000
        }]

        dict get $eventArgs -action
    } -result disabled

    test tacky-avatar-metadata-cleared "Juliet has empty metadata after Romeo disables avatar" {*}$common -body {
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
            ::test::helpers::waitVar $pubVar 5000
        }

        # Disable and wait for disabled notification
        awaitEvent avatar <Update> -acc $JULIET -action disabled {
            set disVar [namespace current]::_disDone
            set $disVar 0
            tacky avatar disable -acc $ROMEO -command [list apply {{var result} {
                set $var 1
            }} $disVar]
            ::test::helpers::waitVar $disVar 5000
        }

        # Metadata should now be empty
        tacky avatar metadata -acc $JULIET -jid $ROMEO
    } -result {}
}
