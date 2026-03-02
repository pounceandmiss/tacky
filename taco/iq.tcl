if 0 {
    To set up this module you need to give it a `-send-command` option and to call its `feed` method with incoming stanzas.

    To use this module:
    $client iq handler get|set $ns $command
    $client iq request -payload $payload -command $command -to $jid
    $client iq respond -for $stanza -payload [j query -ns ...]
}

snit::type iq {
    # Array of incoming request handlers in the form
    # RequestHandlers($type,$ns)=$cmdPref where $cmdPref gets called like
    # {*}$cmdPref $stanza
    variable RequestHandlers

    # Array of incoming response handlers in the form
    # ResponseHandlers($jid,$id)=$cmdPref $cmdPref gets called like
    # {*}$cmdPref $stanza
    variable ResponseHandlers

    # Counter for generating unique IQ IDs
    variable idCounter 0

    # Command prefix to be invoke for sending stanzas (be that
    # requests or responses) in the form {*}$cmdPrefix $jid $stanza
    option -send-command

    constructor args {
	$self configurelist $args
    }

    # Invoke when we receive an incoming stanza
    method feed {stanza} {
	lassign [xsearch $stanza -get {@type @id @from}] type_ id from
	set ns [xsearch $stanza 0 -get ns]

	switch -- $type_ {
	    "get" -
	    "set" {
		if {[info exists RequestHandlers($type_,$ns)]} {
		    {*}$RequestHandlers($type_,$ns) $stanza
		} else {
		    jlog debug "Unknown stanza" -stanza $stanza
		    set errorResponse [j iq -type error -id $id {
			j error -type cancel {
			    j feature-not-implemented -ns urn:ietf:params:xml:ns:xmpp-stanzas
			}
		    }]
		    if {$from ne ""} {
			dict set errorResponse attrs to $from
		    }
		    {*}$options(-send-command) $errorResponse
		}
	    }
	    "error" -
	    "result" {
		# Try exact match first, then fall back to empty-from key,
		# then fall back to any handler matching the id.
		# Requests with no -to store handlers at ("",$id), but real
		# servers include from= in the response (RFC 6120 §8.1.2.1).
		# Conversely, requests with -to may get from="" responses
		# when addressed to the user's own bare JID.
		set key "$from,$id"
		if {![info exists ResponseHandlers($key)] && $from ne ""} {
		    set key ",$id"
		}
		if {![info exists ResponseHandlers($key)]} {
		    # IQ ids are unique per stream, so matching by id alone
		    # is safe when the from doesn't match.
		    foreach k [array names ResponseHandlers *,$id] {
			set key $k
			break
		    }
		}
		if {[info exists ResponseHandlers($key)]} {
		    set handler $ResponseHandlers($key)
		    unset ResponseHandlers($key)
		    {*}$handler $stanza
		} else {
		    jlog debug "Unrequested response?" -stanza $stanza
		}
	    }
	}
    }

    # Registers handler for incoming iq requests of $type (= get|set) and containing a payload of $ns
    method handler {type_ ns command} {
	set RequestHandlers($type_,$ns) $command
    }

    # Unregisters handler for incoming iq requests
    method unhandler {type_ ns} {
	unset -nocomplain RequestHandlers($type_,$ns)
    }

    # Cancel all pending response handlers (used on fresh reconnect)
    method cancelAll {} {
	array unset ResponseHandlers
    }

    # Use: iq request get|set -payload $payload -command $command -to $jid
    # Sends request of $type (=get|set) to $jid with $payload. If $command is specified, it will be called when we get a response
    method request {args} {
	array set opts {-type get -command control::no-op -to ""}
	array set opts $args

	# Allow supplying custom id, otherwise fill automatically
	if {![info exists opts(-id)]} {
	    set opts(-id) [incr idCounter]
	}

	# Stanzas can have no -to if they're addressed to the server
	if {$opts(-to) eq ""} {
	    set optionalTo {}
	} else {
	    set optionalTo [list -to $opts(-to)]
	}
	set ResponseHandlers($opts(-to),$opts(-id)) $opts(-command)
	{*}$options(-send-command) [j iq \
					{*}$optionalTo \
					-type $opts(-type) \
					-id $opts(-id) {
					    j /as-is $opts(-payload)
					}]
    }

    # Use: $client iq respond result|error -for $stanza -payload $payload
    # Sends response of $type (=result|error) in response to $stanza (i.e. the stanza's jid with the same id) with payload $payload
    method respond {args} {
	array set opts {-type result}
	array set opts $args

	lassign [xsearch $opts(-for) -get {@from @id}] from id
	if {$from ne ""} {
	    set params(-to) $from
	}
	set params(-type) $opts(-type)
	set params(-id) $id
	{*}$options(-send-command) [j iq {*}[array get params] {j /as-is $opts(-payload)}]
    }
}
