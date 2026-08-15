# tacky presence get -acc $jid -jid $bareJid
# tacky presence resources -acc $jid -jid $bareJid
# tacky presence isOnline -acc $jid -jid $bareJid
#
# tacky listen presence <Changed> -acc $jid $command
#   -action clear           (all presence wiped on disconnect)
#   -jid $bareJid           (presence changed for specific JID)

if 0 {
    taco_presence - tracks 1-1 contact availability per resource:
    show/status/priority, XEP-0319 idle time, XEP-0115 client details.

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
    # bareJid -> dict(resource -> {show status priority idle_since caps_node caps_ver})
    variable Presence -array {}

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
        $client bus subscribe $self <CapsResolved> [mymethod OnCapsResolved]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    method OnDisconnect {args} {
        array unset Presence *
        $client emit presence <Changed> -action clear
    }

    method OnCapsResolved {args} {
        set bareJid [jid norm [jid bare [dict get $args -jid]]]
        if {[info exists Presence($bareJid)]} {
            $client emit presence <Changed> -jid $bareJid
        }
    }

    # Returns best-resource presence, or the offline shape if none are known.
    tackymethod get {args} {
        set bareJid [jid norm [dict get $args -jid]]
        if {![info exists Presence($bareJid)]} {
            return [Offline]
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
            return [Offline]
        }
        return [$self Entry [dict get $resDict $bestRes]]
    }

    # Returns dict(resource -> presence), or {}
    tackymethod resources {args} {
        set bareJid [jid norm [dict get $args -jid]]
        if {![info exists Presence($bareJid)]} {
            return {}
        }
        set result {}
        dict for {res info} $Presence($bareJid) {
            dict set result $res [$self Entry $info]
        }
        return $result
    }

    proc Offline {} {
        return {show offline status "" priority 0 idle_since 0 client {}}
    }

    # Public shape of one stored resource.
    method Entry {info} {
        set ver [dict get $info caps_ver]
        set disco [$client caps discoFor $ver]
        if {$disco eq ""} {
            set clientInfo {}
        } else {
            set clientInfo [dict merge \
                [dict create node [dict get $info caps_node] ver $ver] $disco]
        }
        return [dict create \
            show [dict get $info show] \
            status [dict get $info status] \
            priority [dict get $info priority] \
            idle_since [dict get $info idle_since] \
            client $clientInfo]
    }

    # Returns 1 if any resource is available, 0 otherwise
    tackymethod isOnline {args} {
        set bareJid [jid norm [dict get $args -jid]]
        info exists Presence($bareJid)
    }

    method OnPresence {stanza} {
        set from [xsearch $stanza -get @from]
        if {$from eq ""} return

        set type_ [xsearch $stanza -get @type]

        set bare [jid norm [jid bare $from]]
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

            set since [xsearch $stanza idle -ns urn:xmpp:idle:1 -get @since]
            set idle [expr {$since ne "" ? [ParseTimestamp $since] : ""}]
            if {$idle eq ""} { set idle 0 }

            set capsNs http://jabber.org/protocol/caps
            set info [dict create show $show status $status priority $priority \
                idle_since $idle \
                caps_node [xsearch $stanza c -ns $capsNs -get @node] \
                caps_ver [xsearch $stanza c -ns $capsNs -get @ver]]

            if {![info exists Presence($bare)]} {
                set Presence($bare) [dict create $resource $info]
            } else {
                dict set Presence($bare) $resource $info
            }
        }

        $client emit presence <Changed> -jid $bare
    }
}
