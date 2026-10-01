if 0 {
    taco_blocking - XEP-0191 Blocking Command.

    On every connect, checks the server for urn:xmpp:blocking and, if it
    has it, fetches the list. Pushes from the server (our other resources'
    changes) are acked and applied.

    Tacky API:
        tacky blocking supported -acc $acc
            -> 0|1, whether this session's server has the feature
        tacky blocking list -acc $acc
            -> blocked JIDs (bare, full or domain), sorted; kept while offline
        tacky blocking block -acc $acc -jid {j1 j2 ...} ?-command $cb? ?-onerror $ecb?
        tacky blocking unblock -acc $acc -jid {j1 j2 ...} ?-command $cb? ?-onerror $ecb?
        tacky blocking unblockAll -acc $acc ?-command $cb? ?-onerror $ecb?
            Callback: {*}$cb "" | {*}$ecb $message

    Events:
        tacky listen blocking <Changed> -acc $acc $cmd
            Payload: -list $blockedJids (the whole list)
}

snit::type taco_blocking {
    typevariable NS urn:xmpp:blocking

    variable client
    variable BlockedList {}
    variable Supported 0

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client iq handler set $NS [mymethod OnPush]
        $client bus subscribe $self <Ready> [mymethod OnReady]
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client iq unhandler set $NS}
    }

    # The list stays; the next <Ready> refetches or drops it.
    method OnDisconnect {args} {
        set Supported 0
    }

    method OnReady {args} {
        $client iq request -type get \
            -to [jid domain [$client cget -jid]] \
            -payload [j query -ns http://jabber.org/protocol/disco#info] \
            -command [mymethod OnDiscoResult]
    }

    method OnDiscoResult {stanza} {
        if {[xsearch $stanza -get @type] ne "result"} return
        set found 0
        xsearch $stanza query feature -script f {
            if {[xsearch $f -get @var] eq $NS} { set found 1 }
        }
        if {!$found} {
            if {[llength $BlockedList]} {
                set BlockedList {}
                $client emit blocking <Changed> -list $BlockedList
            }
            return
        }
        set Supported 1
        $client iq request -type get \
            -payload [j blocklist -ns $NS] \
            -command [mymethod OnRefreshResult]
    }

    method OnRefreshResult {stanza} {
        if {[xsearch $stanza -get @type] ne "result"} return
        set jids {}
        xsearch $stanza blocklist -ns $NS item -script it {
            set j_ [xsearch $it -get @jid]
            if {$j_ ne ""} { lappend jids [jid norm $j_] }
        }
        set BlockedList [lsort -unique $jids]
        $client emit blocking <Changed> -list $BlockedList
    }

    tackymethod supported {args} { return $Supported }
    tackymethod list {args} { return $BlockedList }

    # Not tackymethods: they answer with the IQ result, so -command and
    # -onerror are handled in OnOperationResult, as in taco_avatar.
    method block {args} {
        array set opts {-jid {} -command "" -onerror ""}
        array set opts $args
        if {[llength $opts(-jid)] == 0} {
            error "blocking block: -jid must name at least one JID"
        }
        set jids {}
        foreach j_ $opts(-jid) { lappend jids [jid norm $j_] }
        $client iq request -type set \
            -payload [j block -ns $NS {
                foreach j_ $jids { j item -jid $j_ }
            }] \
            -command [mymethod OnOperationResult $opts(-command) $opts(-onerror)]
    }

    # Empty -jid unblocks everyone (XEP-0191 §3.4).
    method unblock {args} {
        array set opts {-jid {} -command "" -onerror ""}
        array set opts $args
        set jids {}
        foreach j_ $opts(-jid) { lappend jids [jid norm $j_] }
        $client iq request -type set \
            -payload [j unblock -ns $NS {
                foreach j_ $jids { j item -jid $j_ }
            }] \
            -command [mymethod OnOperationResult $opts(-command) $opts(-onerror)]
    }

    method unblockAll {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args
        $self unblock -command $opts(-command) -onerror $opts(-onerror)
    }

    method OnOperationResult {command onerror stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            if {$onerror ne ""} {
                {*}$onerror [$self ErrorText $stanza "Blocking request failed"]
            }
            return
        }
        # The server needn't push our own change back to us.
        $client iq request -type get \
            -payload [j blocklist -ns $NS] \
            -command [mymethod OnRefreshResult]
        # libtacky's callback rewrite needs a result value.
        if {$command ne ""} { {*}$command "" }
    }

    # The server's <text>, or $fallback when it sent none.
    method ErrorText {stanza fallback} {
        set text [dict get [stanza_error $stanza] text]
        if {$text eq ""} { return $fallback }
        return $text
    }

    # Every push is answered, valid or not (XEP-0191).
    method OnPush {stanza} {
        set from [xsearch $stanza -get @from]
        set ownBare [jid norm [jid bare [$client cget -jid]]]
        set fromOk [expr {
            $from eq "" ||
            [jid norm [jid bare $from]] eq $ownBare ||
            [jid norm $from] eq [jid domain $ownBare]
        }]
        if {!$fromOk} {
            $self PushError $stanza cancel service-unavailable
            return
        }

        set payload [lindex [xsearch $stanza 0] 0]
        set tag [dict get $payload tag]
        set jids {}
        set validJid 1
        xsearch $payload item -script it {
            set j_ [xsearch $it -get @jid]
            if {$j_ eq ""} {
                set validJid 0
            } else {
                lappend jids [jid norm $j_]
            }
        }
        if {!$validJid} {
            $self PushError $stanza modify bad-request
            return
        }

        $self AckIq $stanza
        if {$tag eq "block"} {
            set BlockedList [lsort -unique [concat $BlockedList $jids]]
        } elseif {[llength $jids] == 0} {
            set BlockedList {}
        } else {
            set keep {}
            foreach have $BlockedList {
                if {$have ni $jids} { lappend keep $have }
            }
            set BlockedList $keep
        }
        $client emit blocking <Changed> -list $BlockedList
    }

    method AckIq {stanza} {
        lassign [xsearch $stanza -get {@from @id}] from id
        set ackArgs [list -type result -id $id]
        if {$from ne ""} { lappend ackArgs -to $from }
        $client write [j iq {*}$ackArgs]
    }

    method PushError {stanza type_ condition} {
        set payload [j error -type $type_ {
            j $condition -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }]
        $client iq respond -type error -for $stanza -payload $payload
    }
}
