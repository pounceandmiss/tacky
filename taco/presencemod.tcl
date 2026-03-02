# tacky presence get -acc $jid -jid $bareJid
# tacky presence resources -acc $jid -jid $bareJid
# tacky presence isOnline -acc $jid -jid $bareJid
#
# tacky listen presence <Changed> -acc $jid $command
#   -action clear           (all presence wiped on disconnect)
#   -jid $bareJid           (presence changed for specific JID)

if 0 {
    taco_presence - tracks 1-1 contact availability (show/status/priority per resource).

    In-memory only — presence is ephemeral (re-received on every reconnect).
    Trusts the server for presence authorization — any presence stanza
    delivered by the server is tracked.

    Usage:
        Instantiated by Client, not directly.
        $client presence get -jid $bareJid        - best-resource presence dict
        $client presence resources -jid $bareJid  - full resource dict
        $client presence isOnline -jid $bareJid   - 1/0

    Events (via $client emit presence ...):
        <Changed> -action clear                   - all presence wiped on disconnect
        <Changed> -jid <bare-jid>                 - presence changed for a specific JID
}

snit::type taco_presence {
    variable client
    # bareJid → dict(resource → {show status priority})
    variable Presence -array {}

    option -client -readonly yes

    constructor args {
	$self configurelist $args
	set client $options(-client)
    }

    method OnReady {} {}

    method OnDisconnect {} {
	array unset Presence *
	$client emit presence <Changed> -action clear
    }

    # Returns best-resource presence: {show $s status $t priority $p}
    # If no resources known, returns {show offline status "" priority 0}
    tackymethod get {args} {
	set bareJid [dict get $args -jid]
	if {![info exists Presence($bareJid)]} {
	    return {show offline status "" priority 0}
	}
	set resDict $Presence($bareJid)
	set bestRes ""
	set bestPri -129
	dict for {res info} $resDict {
	    set pri [dict get $info priority]
	    if {$pri > $bestPri} {
		set bestPri $pri
		set bestRes $res
	    }
	}
	if {$bestRes eq ""} {
	    return {show offline status "" priority 0}
	}
	return [dict get $resDict $bestRes]
    }

    # Returns full resource dict, or {}
    tackymethod resources {args} {
	set bareJid [dict get $args -jid]
	if {![info exists Presence($bareJid)]} {
	    return {}
	}
	return $Presence($bareJid)
    }

    # Returns 1 if any resource is available, 0 otherwise
    tackymethod isOnline {args} {
	set bareJid [dict get $args -jid]
	info exists Presence($bareJid)
    }

    method OnPresence {stanza} {
	set from [xsearch $stanza -get @from]
	if {$from eq ""} return

	set type_ [xsearch $stanza -get @type]

	set bare [jid bare $from]
	set resource [jid resource $from]

	if {$type_ eq "unavailable"} {
	    if {[info exists Presence($bare)]} {
		if {$resource ne ""} {
		    set d $Presence($bare)
		    dict unset d $resource
		    if {[dict size $d] == 0} {
			unset Presence($bare)
		    } else {
			set Presence($bare) $d
		    }
		} else {
		    unset Presence($bare)
		}
	    }
	} else {
	    # Available presence
	    set show [xsearch $stanza show -get body]
	    if {$show eq ""} { set show "available" }
	    set status [xsearch $stanza status -get body]
	    set priority [xsearch $stanza priority -get body]
	    if {$priority eq ""} { set priority 0 }

	    set info [dict create show $show status $status priority $priority]

	    if {![info exists Presence($bare)]} {
		set Presence($bare) [dict create $resource $info]
	    } else {
		dict set Presence($bare) $resource $info
	    }
	}

	$client emit presence <Changed> -jid $bare
    }
}
