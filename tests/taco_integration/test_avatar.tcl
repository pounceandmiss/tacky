namespace eval ::test::avatar_int {

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

    variable _awaitCounter 0

    proc publishAndWait {script} {
	set pubVar [namespace current]::_pubDone
	set $pubVar 0
	uplevel 1 $script
	::test::helpers::waitVar $pubVar 5000
    }

    proc setup {} {
	variable ROMEO
	variable JULIET
	variable HOST

	tacky_init
	tacky account add -acc $ROMEO -password romeopass -domain $HOST -username romeo
	tacky account add -acc $JULIET -password julietpass -domain $HOST -username juliet

	tacky account enable -acc $ROMEO
	tacky account enable -acc $JULIET
	tacky roster approve -acc $ROMEO -jid $JULIET
	tacky roster approve -acc $JULIET -jid $ROMEO
	tacky roster subscribe -acc $ROMEO -jid $JULIET
	tacky roster subscribe -acc $JULIET -jid $ROMEO
	::test::helpers::waitEvents {
	    {presence <Changed> -acc romeo@example.local -jid juliet@example.local}
	    {presence <Changed> -acc juliet@example.local -jid romeo@example.local}
	}
    }

    proc cleanup {} {
	variable ROMEO
	variable TIMEOUT

	catch {
	    set var [namespace current]::_disableDone
	    set $var 0
	    tacky avatar disable -acc $ROMEO -command [list apply {{var status msg} {
		set $var 1
	    }} $var]
	    ::test::helpers::waitVar $var $TIMEOUT
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
		-command [list apply {{var status msg} {
		    set $var 1
		}} $pubVar]
	    ::test::helpers::waitVar $pubVar 5000
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
		-command [list apply {{var status msg} {
		    set $var 1
		}} $pubVar]
	    ::test::helpers::waitVar $pubVar 5000
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
		-command [list apply {{var status msg} {
		    set $var 1
		}} $pubVar]
	    ::test::helpers::waitVar $pubVar 5000
	}

	set meta [tacky avatar metadata -acc $JULIET -jid $ROMEO]
	list [expr {[dict get $meta hash] eq $SAMPLE_PNG_HASH}] \
	    [dict get $meta type] \
	    [expr {[dict get $meta bytes] > 0}]
    } -result {1 image/png 1}

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
		-command [list apply {{var status msg} {
		    set $var 1
		}} $pubVar]
	    ::test::helpers::waitVar $pubVar 5000
	}

	# Disable and wait for disabled notification
	set eventArgs [awaitEvent avatar <Update> -acc $JULIET -action disabled {
	    set disVar [namespace current]::_disDone
	    set $disVar 0
	    tacky avatar disable -acc $ROMEO -command [list apply {{var status msg} {
		set $var 1
	    }} $disVar]
	    ::test::helpers::waitVar $disVar 5000
	}]

	set meta [tacky avatar metadata -acc $JULIET -jid $ROMEO]
	list [dict get $eventArgs -action] [expr {$meta eq {}}]
    } -result {disabled 1}
}
