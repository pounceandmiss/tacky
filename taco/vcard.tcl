if 0 {
    taco_vcard - manages vcard-temp for the user's own identity.

    Fetches the vCard on connect, caches it, and allows reading/updating
    the NICKNAME field.

    Tacky API:
        tacky vcard nick -acc $acc
            Returns cached nickname (empty string if not yet fetched)
        tacky vcard setNick -acc $acc -nick $name -command $cb
            Update NICKNAME and republish vCard
            Callback: {*}$cb ok "" | {*}$cb error $msg

    Events:
        tacky listen vcard <Update> -acc ...
}

snit::type taco_vcard {

    variable client
    variable CachedVCard ""

    option -client -readonly yes

    constructor args {
	$self configurelist $args
	set client $options(-client)
	$client bus subscribe $self <Ready> [mymethod OnReady]
	$client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
	catch {$client bus unsubscribe $self}
    }

    method OnReady {args} {
	$self Fetch
    }

    method OnDisconnect {args} {
	set CachedVCard ""
    }

    # Return cached nickname.
    tackymethod nick {args} {
	if {$CachedVCard eq ""} {return ""}
	xsearch $CachedVCard NICKNAME -get body
    }

    # Update NICKNAME and republish the full vCard.
    method setNick {args} {
	set nick [dict get $args -nick]
	set command [expr {[dict exists $args -command] \
	    ? [dict get $args -command] : ""}]
	if {$CachedVCard eq ""} {
	    $self Fetch [mymethod DoSetNick $nick $command]
	} else {
	    $self DoSetNick $nick $command
	}
    }

    method DoSetNick {nick command args} {
	# Replace or add NICKNAME child
	set children [dict get $CachedVCard children]
	set newChildren {}
	set found 0
	foreach child $children {
	    if {[dict get $child tag] eq "NICKNAME"} {
		dict set child body $nick
		set found 1
	    }
	    lappend newChildren $child
	}
	if {!$found} {
	    lappend newChildren [j NICKNAME #body $nick]
	}
	dict set CachedVCard children $newChildren

	$client iq request -type set \
	    -payload $CachedVCard \
	    -command [mymethod OnPublishResult $command]
    }

    method Fetch {{command ""}} {
	$client iq request \
	    -to [jid bare [$client cget -jid]] \
	    -payload [j vCard -ns vcard-temp] \
	    -command [mymethod OnFetchResult $command]
    }

    method OnFetchResult {command stanza} {
	if {[xsearch $stanza -get @type] eq "error"} {
	    set CachedVCard [j vCard -ns vcard-temp]
	} else {
	    set vcards [xsearch $stanza vCard]
	    if {[llength $vcards] > 0} {
		set CachedVCard [lindex $vcards 0]
	    } else {
		set CachedVCard [j vCard -ns vcard-temp]
	    }
	}
	$client emit vcard <Update>
	if {$command ne ""} {
	    {*}$command
	}
    }

    method OnPublishResult {command stanza} {
	if {$command eq ""} return
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "result"} {
	    $client emit vcard <Update>
	    {*}$command ok ""
	} else {
	    set errText [xsearch $stanza error text -get body]
	    if {$errText eq ""} {
		set errChild [xsearch $stanza error 0 -get node]
		if {$errChild ne ""} {
		    set errText [dict get $errChild tag]
		} else {
		    set errText "vCard update failed"
		}
	    }
	    {*}$command error $errText
	}
    }
}
