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

    # Command prefix returning our bound JID ("" before bind); used to
    # decide which senders may answer server-directed requests
    option -own-jid-command -default ""

    # Milliseconds to wait for a response before answering the handler
    # ourselves. 0 waits forever.
    option -default-timeout -default 60000

    # Pending timers, and {timeout to id} per outstanding request, both
    # keyed like ResponseHandlers
    variable Timers
    variable Pending

    # Timers only run while the session is up: offline requests are buffered
    # until connect, and sent ones are replayed by stream management.
    variable Live 0

    constructor args {
        $self configurelist $args
    }

    destructor {
        foreach key [array names Timers] {
            after cancel $Timers($key)
        }
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
                # RFC 6120 8.1.2.1: a response only counts when it comes
                # from the entity the request was addressed to.  Requests
                # with no -to (stored at ",$id") are answered by our own
                # server with no from, our bare JID, or the bare domain;
                # conversely a request to our own bare JID may be answered
                # with no from.
                set own ""
                if {$options(-own-jid-command) ne ""} {
                    set own [{*}$options(-own-jid-command)]
                }
                set fromSelf [jid fromMe $from $own]
                if {!$fromSelf && $own ne "" && [jid valid $from]} {
                    set fromSelf [string equal -nocase \
                        [jid norm $from] [jid domain $own]]
                }
                set keys [list "$from,$id"]
                if {$fromSelf} {
                    lappend keys ",$id"
                    if {$own ne ""} {
                        lappend keys "[jid bare $own],$id"
                    }
                }
                set handler ""
                foreach key $keys {
                    if {[info exists ResponseHandlers($key)]} {
                        set handler $ResponseHandlers($key)
                        $self Forget $key
                        break
                    }
                }
                if {$handler ne ""} {
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

    # Start or stop the clock on every outstanding request.
    method live {flag} {
        if {$flag == $Live} return
        set Live $flag
        if {$Live} {
            foreach key [array names Pending] {
                $self ArmTimer $key
            }
        } else {
            foreach key [array names Timers] {
                after cancel $Timers($key)
            }
            array unset Timers
        }
    }

    method ArmTimer {key} {
        $self CancelTimer $key
        lassign $Pending($key) timeout
        if {!$Live || $timeout <= 0} return
        set Timers($key) [after $timeout [mymethod OnTimeout $key]]
    }

    method CancelTimer {key} {
        if {[info exists Timers($key)]} {
            after cancel $Timers($key)
            unset Timers($key)
        }
    }

    method Forget {key} {
        $self CancelTimer $key
        unset -nocomplain Pending($key)
        unset -nocomplain ResponseHandlers($key)
    }

    # Answer with the error stanza a refusing server would have sent, so
    # existing error branches handle it unchanged.
    method OnTimeout {key} {
        if {![info exists ResponseHandlers($key)]} return
        set handler $ResponseHandlers($key)
        lassign $Pending($key) _timeout to id
        $self Forget $key
        set optionalFrom {}
        if {$to ne ""} {
            set optionalFrom [list -from $to]
        }
        {*}$handler [j iq {*}$optionalFrom -type error -id $id {
            j error -type wait {
                j remote-server-timeout -ns urn:ietf:params:xml:ns:xmpp-stanzas
                j text -ns urn:ietf:params:xml:ns:xmpp-stanzas \
                    #body "No response from the server"
            }
        }]
    }

    # Use: iq request get|set -payload $payload -command $command -to $jid
    # Sends request of $type (=get|set) to $jid with $payload. If $command is specified, it will be called when we get a response
    # -timeout overrides -default-timeout for this request; 0 waits forever.
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
        set key $opts(-to),$opts(-id)
        set ResponseHandlers($key) $opts(-command)
        if {![info exists opts(-timeout)]} {
            set opts(-timeout) $options(-default-timeout)
        }
        set Pending($key) [list $opts(-timeout) $opts(-to) $opts(-id)]
        $self ArmTimer $key
        set _iq [j iq \
                                {*}$optionalTo \
                                -type $opts(-type) \
                                -id $opts(-id) {
                                    j /as-is $opts(-payload)
                                }]
        {*}$options(-send-command) $_iq
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
