# taco_entity - answers queries about this client: XEP-0202 Entity Time
# and XEP-0012 Last Activity.
#
# Each is off unless its taco-level setting is on: answer_time and
# answer_last_activity. They reveal the user's timezone and how long they
# have been away, so even when on they are answered only to our own account
# and to contacts who see our presence anyway (subscription from or both);
# anyone else gets service-unavailable, as when the setting is off. The
# features are advertised only while the setting is on (caps addFeature -if).
#
# Last Activity answers how long the app has been inactive (app idleSeconds,
# from the frontend's app setActive), 0 while it is in use.

snit::type taco_entity {
    option -client -readonly yes

    variable client

    constructor {args} {
        $self configurelist $args
        set client $options(-client)
        $client iq handler get urn:xmpp:time [mymethod OnTime]
        $client iq handler get jabber:iq:last [mymethod OnLast]
        $client caps addFeature urn:xmpp:time \
            -if [list taco_setting_get $client answer_time 0]
        $client caps addFeature jabber:iq:last \
            -if [list taco_setting_get $client answer_last_activity 0]
    }

    destructor {
        catch {$client iq unhandler get urn:xmpp:time}
        catch {$client iq unhandler get jabber:iq:last}
    }

    method OnTime {stanza} {
        if {![$self Allowed $stanza answer_time]} {
            $self Refuse $stanza
            return
        }
        set now [clock seconds]
        set tzo [clock format $now -format %z]
        set tzo "[string range $tzo 0 2]:[string range $tzo 3 4]"
        set utc [clock format $now -format %Y-%m-%dT%H:%M:%SZ -timezone :UTC]
        $self Reply $stanza [j time -ns urn:xmpp:time {
            j tzo -body $tzo
            j utc -body $utc
        }]
    }

    method OnLast {stanza} {
        if {![$self Allowed $stanza answer_last_activity]} {
            $self Refuse $stanza
            return
        }
        set idle 0
        catch {set idle [[$client cget -taco] app idleSeconds]}
        $self Reply $stanza [j query -ns jabber:iq:last -seconds $idle]
    }

    # The setting is on, and the asker is our own account or a contact
    # with a presence subscription to us.
    method Allowed {stanza key} {
        if {![string is true -strict [taco_setting_get $client $key 0]]} {
            return 0
        }
        set from [jid norm [jid bare [xsearch $stanza -get @from]]]
        if {$from eq [jid norm [jid bare [$client cget -jid]]]} { return 1 }
        if {[catch {$client roster subscription -jid $from} sub]} { return 0 }
        expr {$sub in {from both}}
    }

    method Reply {stanza payload} {
        lassign [xsearch $stanza -get {@id @from}] id from
        set reply [j iq -type result -id $id {
            j #as-is $payload
        }]
        if {$from ne ""} { dict set reply attrs to $from }
        $client write $reply
    }

    # What an unsupported query gets (RFC 6120 8.4), so a refusal does not
    # tell the asker that the feature exists.
    method Refuse {stanza} {
        lassign [xsearch $stanza -get {@id @from}] id from
        set reply [j iq -type error -id $id {
            j error -type cancel {
                j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        if {$from ne ""} { dict set reply attrs to $from }
        $client write $reply
    }
}
