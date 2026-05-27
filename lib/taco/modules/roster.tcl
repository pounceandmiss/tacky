# tacky roster get -acc $jid
# tacky roster request -acc $jid
# tacky roster item -acc $jid -jid $contactJid ?-name ...? ?-groups ...?
# tacky roster remove -acc $jid -jid $contactJid
# tacky roster subscription -acc $jid -jid $contactJid
# tacky roster subscribe -acc $jid -jid $contact
# tacky roster approve -acc $jid -jid $contact
# tacky roster unsubscribe -acc $jid -jid $contact
# tacky roster deny -acc $jid -jid $contact
# tacky roster add -acc $jid -jid $contact ?-name ...? ?-groups ...?
#
# tacky listen roster <Changed> -acc $jid $command
#   -action clear | add | update | remove
#   -jid $contactJid  (present when action is add/update/remove)
#
# tacky listen roster <Subscribe> -acc $jid $command
#   -jid $contactJid
#   -type subscribe | subscribed | unsubscribe | unsubscribed

if 0 {
    taco_roster - manages XMPP roster (contact list).

    Writes XML stanza data directly to SQL (no intermediary item dicts).
    Uses xsearch instead of deprecated jsearch/jget.
    Fires events via $client emit for change notification.

    Usage:
        Instantiated by Client, not directly.
        $client roster get                                  - return full roster from local store
        $client roster request                              - request roster from server
        $client roster item -jid $jid ?-name ...? ?-groups ...? - add or update contact
        $client roster remove -jid $jid                     - remove contact
        $client roster subscription -jid $jid               - query subscription state

    Events (via $client emit roster ...):
        <Changed> -action clear                     - full roster replaced
        <Changed> -action add -jid <jid>            - item added
        <Changed> -action update -jid <jid>         - item updated
        <Changed> -action remove -jid <jid>         - item removed
}

snit::type taco_roster {
    variable client

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $self Migrate
        $client iq handler set jabber:iq:roster [mymethod OnPush]
        $client bus subscribe $self <Ready> [mymethod OnReady]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    method OnReady {args} {
        $self request
    }

    # Return full roster from local store
    tackymethod get {args} {
        set results {}
        $client db eval {
            SELECT jid, name, subscription, ask, approved FROM roster_item
        } row {
            set entry [list jid $row(jid) name $row(name) \
                subscription $row(subscription) ask $row(ask) \
                approved $row(approved)]
            # Gather groups for this item
            set groups [$client db eval {
                SELECT group_name FROM roster_item_group
                WHERE roster_item_jid=$row(jid) ORDER BY group_name
            }]
            lappend entry groups $groups
            lappend results $entry
        }
        return $results
    }

    # Request roster from server
    method request {args} {
        set verAttr {}
        $client db eval {SELECT value FROM roster_ver} {
            dict set verAttr -ver $value
        }
        $client iq request \
            -payload [j query -ns jabber:iq:roster {*}$verAttr] \
            -command [mymethod OnResult]
    }

    # Add or update a roster item (atomic replace per RFC 6121 2.4)
    method item {args} {
        set jid [jid norm [dict get $args -jid]]
        set hasGroups [dict exists $args -groups]
        array set opts {-name "" -groups {}}
        array set opts [dict remove $args -jid]

        if {!$hasGroups} {
            set opts(-groups) [$client db eval {
                SELECT group_name FROM roster_item_group
                WHERE roster_item_jid=$jid ORDER BY group_name
            }]
        }

        set itemAttrs [list -jid $jid]
        if {$opts(-name) ne ""} {
            lappend itemAttrs -name $opts(-name)
        }

        $client iq request -type set -payload [j query -ns jabber:iq:roster {
            j item {*}$itemAttrs {
                foreach group $opts(-groups) {
                    j group #body $group
                }
            }
        }]
    }

    # Return subscription state for a JID (none/to/from/both or "" if absent)
    tackymethod subscription {args} {
        set jid [jid norm [dict get $args -jid]]
        $client db onecolumn {SELECT subscription FROM roster_item WHERE jid=$jid}
    }

    # Remove a roster item
    method remove {args} {
        set jid [jid norm [dict get $args -jid]]
        $client iq request -type set -payload [j query -ns jabber:iq:roster {
            j item -jid $jid -subscription remove
        }]
    }

    # Handle roster query result (full roster)
    method OnResult {stanza} {
        set type_ [xsearch $stanza -get @type]

        # Server returned an error (e.g. item-not-found, internal-server-error)
        if {$type_ eq "error"} {
            return
        }

        # Empty IQ-result (no query child) means server has nothing new
        # and will send changes via roster pushes (roster versioning)
        if {[llength [xsearch $stanza query]] == 0} {
            return
        }

        $client db eval {BEGIN}
        $client db eval {DELETE FROM roster_item; DELETE FROM roster_item_group}

        set ver [xsearch $stanza query -get @ver]
        $client db eval {DELETE FROM roster_ver}
        if {$ver ne ""} {
            $client db eval {INSERT INTO roster_ver VALUES ($ver)}
        }

        xsearch $stanza query item -script itemNode {
            set subscription [xsearch $itemNode -get @subscription]
            if {$subscription eq ""} {
                dict set itemNode attrs subscription none
            }

            # In a roster result, ignore invalid subscription values
            if {$subscription ni {none to from both ""}} {
                jlog error "Ignoring subscription='$subscription' for [xsearch $itemNode -get @jid]" -stanza $itemNode
                dict set itemNode attrs subscription none
            }

            $self StoreItem $itemNode
        }
        $client db eval {COMMIT}

        $client emit roster <Changed> -action clear
    }

    # Handle roster push (single item update from server)
    method OnPush {stanza} {
        # RFC 6121 2.1.6: MUST ignore unless from is absent or matches
        # the user's bare JID
        set from [xsearch $stanza -get @from]
        if {$from ne "" && ![jid matches-bare $from [$client cget -jid]]} {
            return
        }

        set ver [xsearch $stanza query -get @ver]
        $client db eval {DELETE FROM roster_ver}
        if {$ver ne ""} {
            $client db eval {INSERT INTO roster_ver VALUES ($ver)}
        }

        # Respond to the push per RFC 6121
        $client iq respond -for $stanza -payload [j query -ns jabber:iq:roster]

        xsearch $stanza query item -script itemNode {
        set jid [jid norm [xsearch $itemNode -get @jid]]
            set subscription [xsearch $itemNode -get @subscription]
            if {$subscription eq ""} {
                set subscription none
            }

            # In a roster push, ignore invalid subscription values
            if {$subscription ni {none to from both remove}} {
                jlog error "Ignoring subscription='$subscription' for $jid" -stanza $itemNode
                return
            }

            if {$subscription eq "remove"} {
                $client db eval {DELETE FROM roster_item WHERE jid=$jid}
                $client db eval {DELETE FROM roster_item_group WHERE roster_item_jid=$jid}
                $client emit roster <Changed> -action remove -jid $jid
            } else {
                set existed [$client db eval {SELECT count(*) FROM roster_item WHERE jid=$jid}]
                $self StoreItem $itemNode
                if {$existed} {
                    $client emit roster <Changed> -action update -jid $jid
                } else {
                    $client emit roster <Changed> -action add -jid $jid
                }
            }
        }
    }

    method subscribe {args} {
        set jid [jid norm [dict get $args -jid]]
        $client write [j presence -type subscribe -to $jid]
    }

    method approve {args} {
        set jid [jid norm [dict get $args -jid]]
        $client write [j presence -type subscribed -to $jid]
    }

    method unsubscribe {args} {
        set jid [jid norm [dict get $args -jid]]
        $client write [j presence -type unsubscribe -to $jid]
    }

    method deny {args} {
        set jid [jid norm [dict get $args -jid]]
        $client write [j presence -type unsubscribed -to $jid]
    }

    # Convenience: add roster item + request subscription in one call
    method add {args} {
        $self item {*}$args
        $self subscribe -jid [dict get $args -jid]
    }

    # Handle incoming subscription presence (called from client OnStanza)
    method OnSubscription {stanza} {
        set from [xsearch $stanza -get @from]
        if {$from eq ""} return
        set type_ [xsearch $stanza -get @type]
        $client emit roster <Subscribe> -jid [jid norm [jid bare $from]] -type $type_
    }

    # Extract item XML node directly into SQL
    method StoreItem {itemNode} {
        set jid [jid norm [xsearch $itemNode -get @jid]]
        set name [xsearch $itemNode -get @name]
        set subscription [xsearch $itemNode -get @subscription]
        set ask [xsearch $itemNode -get @ask]
        set approved [xsearch $itemNode -get @approved]

        if {$subscription eq ""} {
            set subscription none
        }
        if {$approved eq ""} {
            set approved 0
        }

        $client db eval {
            INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
            VALUES ($jid, $name, $subscription, $ask, $approved)
        }
        $client db eval {DELETE FROM roster_item_group WHERE roster_item_jid=$jid}
        foreach groupBody [xsearch $itemNode group -gather body] {
            $client db eval {
                INSERT OR IGNORE INTO roster_item_group(roster_item_jid, group_name)
                VALUES($jid, $groupBody)
            }
        }
    }

    method Migrate {} {
        $client db eval {
            CREATE TABLE IF NOT EXISTS roster_item(
                jid PRIMARY KEY,
                name,
                subscription,
                ask,
                approved
            );
            CREATE TABLE IF NOT EXISTS roster_item_group(
                group_name,
                roster_item_jid,
                PRIMARY KEY(group_name, roster_item_jid)
            );
            CREATE TABLE IF NOT EXISTS roster_ver(value);
        }
    }
}
