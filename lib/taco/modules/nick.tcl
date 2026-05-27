# taco_nick - manages XEP-0172 User Nickname via PEP.

# Publishes and receives nicknames via PubSub node
# http://jabber.org/protocol/nick.  Caches nicknames in SQLite and
# fires events on change.

# tacky nick set -acc $acc -nick $nick ?-command $cb?
#     Set own nick via PEP and vcard-temp
# tacky nick get -acc $acc -jid $bareJid
#     Returns cached nick string or ""
# tacky nick publish -acc $acc -nick $nick ?-command $cb?
#     Publish own nick via PEP only
# tacky nick fetch -acc $acc -jid $bareJid
#     Fetch nick from server and cache it
#
# tacky listen nick <Changed> -acc $acc $command
#   -jid $bareJid

snit::type taco_nick {
    variable client

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $self Migrate
        $client pubsub handler http://jabber.org/protocol/nick \
            [mymethod OnNotification]
        $client caps addFeature http://jabber.org/protocol/nick+notify
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client pubsub unhandler http://jabber.org/protocol/nick}
    }

    # Set own nick via PEP, vcard-temp, and bookmarks.
    # Updates all existing bookmarks and joined rooms unless -bookmarks skip.
    method set {args} {
        array set opts {-command ""}
        array set opts $args
        $self publish -nick $opts(-nick) -command $opts(-command)
        $client vcard setNick -nick $opts(-nick)
        if {[dict getdef $args -bookmarks ""] eq "skip"} {
            $client bookmarks defaultNick -nick $opts(-nick)
        } else {
            $client bookmarks setNickAll -nick $opts(-nick)
        }
    }

    # Get cached nick for a JID.  Returns the nick string or "".
    tackymethod get {args} {
        set jid [jid norm [dict get $args -jid]]
        $client db onecolumn {SELECT nick FROM pep_nick WHERE jid=$jid}
    }

    # Publish own nick via PubSub.
    method publish {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set \
            -command [mymethod OnPublishResult $opts(-nick) $opts(-command)] \
            -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j publish -node "http://jabber.org/protocol/nick" {
                    j item {
                        j nick -ns "http://jabber.org/protocol/nick" \
                            #body $opts(-nick)
                    }
                }
            }]
    }

    # Fetch nick from server (IQ get on the PEP node).
    method fetch {args} {
        set jid [jid norm [dict get $args -jid]]
        $client iq request -to $jid -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j items -node "http://jabber.org/protocol/nick"
            }] -command [mymethod OnFetchResult $jid]
    }

    method OnPublishResult {nick userCmd stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ ne "error"} {
        set jid [jid norm [jid bare [$client cget -jid]]]
            $client db eval {
                INSERT OR REPLACE INTO pep_nick(jid, nick)
                VALUES ($jid, $nick)
            }
            $client emit nick <Changed> -jid $jid
        }
        if {$userCmd ne ""} {
            {*}$userCmd $stanza
        }
    }

    method OnFetchResult {jid stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} return

        set nick [xsearch $stanza pubsub items item nick -get body]

        $client db eval {
            INSERT OR REPLACE INTO pep_nick(jid, nick)
            VALUES ($jid, $nick)
        }
        $client emit nick <Changed> -jid $jid
    }

    method OnNotification {stanza} {
        set from [jid norm [jid bare [xsearch $stanza -get @from]]]

        set nick [xsearch $stanza event items item nick -get body]

        $client db eval {
            INSERT OR REPLACE INTO pep_nick(jid, nick)
            VALUES ($from, $nick)
        }
        $client emit nick <Changed> -jid $from
    }

    method Migrate {} {
        $client db eval {
            CREATE TABLE IF NOT EXISTS pep_nick(
                jid TEXT PRIMARY KEY,
                nick TEXT NOT NULL DEFAULT ''
            );
        }
    }
}
