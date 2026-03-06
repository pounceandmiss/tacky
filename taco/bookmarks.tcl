# taco_bookmarks - manages XEP-0402 PEP Native Bookmarks.

# Stores bookmarks in SQLite, listens for PubSub notifications on
# urn:xmpp:bookmarks:1, and fires events via $client emit for change
# notification.

# tacky bookmarks get -acc $jid
# tacky bookmarks request -acc $jid
# tacky bookmarks item -acc $jid -jid $roomJid ?-name ...? ?-autojoin ...? ?-nick ...? ?-password ...?
# tacky bookmarks remove -acc $jid -jid $roomJid
# tacky bookmarks nick -acc $jid -jid $roomJid -nick $nick
# tacky bookmarks leave -acc $jid -jid $roomJid
# tacky bookmarks autojoin -acc $jid -jid $roomJid
#
# tacky listen bookmarks <Changed> -acc $jid $command
#   -action clear | add | update | remove
#   -jid $roomJid  (present when action is add/update/remove)

snit::type taco_bookmarks {
    variable client

    option -client -readonly yes

    constructor args {
	$self configurelist $args
	set client $options(-client)
	$self Migrate
	$client message pubsub handler urn:xmpp:bookmarks:1 \
	    [mymethod OnNotification]
	catch {$client caps addFeature urn:xmpp:bookmarks:1+notify}
    }

    destructor {
	catch {$client message pubsub unhandler urn:xmpp:bookmarks:1}
    }

    method OnReady {} {
	$self request
    }

    method OnDisconnect {} {}

    # Return full list of bookmarks from local store
    tackymethod get {args} {
	set results {}
	$client db eval {
	    SELECT jid, name, autojoin, nick, password FROM bookmark
	} row {
	    set entry [list -jid $row(jid) -name $row(name) \
		-autojoin $row(autojoin) -nick $row(nick) \
		-password $row(password)]
	    lappend results $entry
	}
	return $results
    }

    # Request all bookmarks from server
    method request {args} {
	$client iq request -type get \
	    -payload [j pubsub -ns http://jabber.org/protocol/pubsub {
		j items -node urn:xmpp:bookmarks:1
	    }] -command [mymethod OnResult]
    }

    # Add or update a bookmark
    # Omitted options are preserved from the DB if the bookmark exists.
    method item {args} {
	set jid [dict get $args -jid]

	# Read existing values as defaults if bookmark exists
	set defaults {-name "" -autojoin false -nick "" -password ""}
	set row [$client db eval {SELECT name, autojoin, nick, password FROM bookmark WHERE jid=$jid}]
	if {[llength $row] == 4} {
	    lassign $row dbName dbAutojoin dbNick dbPassword
	    set defaults [list -name $dbName -autojoin $dbAutojoin \
		-nick $dbNick -password $dbPassword]
	}
	array set opts $defaults
	array set opts [dict remove $args -jid]

	# Optimistic local update
	set autojoinInt [expr {$opts(-autojoin) in {true 1} ? 1 : 0}]
	set existingRow [$client db eval {SELECT extensions_xml FROM bookmark WHERE jid=$jid}]
	set existed [expr {[llength $existingRow] > 0}]
	set extXml [lindex $existingRow 0]
	$client db eval {
	    INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password, extensions_xml)
	    VALUES ($jid, $opts(-name), $autojoinInt, $opts(-nick), $opts(-password), $extXml)
	}
	if {$existed} {
	    $client emit bookmarks <Changed> -action update -jid $jid
	} else {
	    $client emit bookmarks <Changed> -action add -jid $jid
	}
	$self AutojoinOne $jid

	set autojoinVal [expr {$opts(-autojoin) in {true 1} ? "true" : "false"}]

	set confAttrs [list -ns urn:xmpp:bookmarks:1 -autojoin $autojoinVal]
	if {$opts(-name) ne ""} {
	    lappend confAttrs -name $opts(-name)
	}

	$client iq request -type set -payload \
	    [j pubsub -ns http://jabber.org/protocol/pubsub {
		j publish -node urn:xmpp:bookmarks:1 {
		    j item -id $jid {
			j conference {*}$confAttrs {
			    if {$opts(-nick) ne ""} {
				j nick #body $opts(-nick)
			    }
			    if {$opts(-password) ne ""} {
				j password #body $opts(-password)
			    }
			}
		    }
		}
		j publish-options {
		    j x -ns jabber:x:data -type submit {
			j field -var FORM_TYPE -type hidden {
			    j value #body "http://jabber.org/protocol/pubsub#publish-options"
			}
			j field -var pubsub#persist_items {
			    j value #body true
			}
			j field -var pubsub#max_items {
			    j value #body max
			}
			j field -var pubsub#send_last_published_item {
			    j value #body never
			}
			j field -var pubsub#access_model {
			    j value #body whitelist
			}
		    }
		}
	    }]
    }

    # Change nickname in a room and update the bookmark.
    method nick {args} {
	set jid [dict get $args -jid]
	set newNick [dict get $args -nick]
	$self item -jid $jid -nick $newNick
	$client muc nick -jid $jid -nick $newNick
    }

    # Leave a room and disable autojoin.
    method leave {args} {
	set jid [dict get $args -jid]
	$self item -jid $jid -autojoin 0
	$client muc leave -jid $jid
    }

    # Query autojoin state for a single JID
    tackymethod autojoin {args} {
	set jid [dict get $args -jid]
	set row [$client db eval {SELECT autojoin FROM bookmark WHERE jid=$jid}]
	if {[llength $row] == 0} { return 0 }
	return [lindex $row 0]
    }

    # Remove a bookmark
    method remove {args} {
	set jid [dict get $args -jid]
	$client db eval {DELETE FROM bookmark WHERE jid=$jid}
	$client emit bookmarks <Changed> -action remove -jid $jid

	$client iq request -type set -payload \
	    [j pubsub -ns http://jabber.org/protocol/pubsub {
		j retract -node urn:xmpp:bookmarks:1 -notify true {
		    j item -id $jid
		}
	    }]
    }

    method OnResult {stanza} {
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "error"} {
	    return
	}

	$client db eval {BEGIN}
	$client db eval {DELETE FROM bookmark}

	xsearch $stanza pubsub items item -script itemNode {
	    set jid [xsearch $itemNode -get @id]
	    if {$jid eq ""} continue
	    $self StoreItem $jid $itemNode
	}
	$client db eval {COMMIT}

	$client emit bookmarks <Changed> -action clear
	$self AutojoinAll
    }

    method OnNotification {stanza} {
	set eventNodes [xsearch $stanza event -ns http://jabber.org/protocol/pubsub#event]
	if {[llength $eventNodes] == 0} return
	set eventNode [lindex $eventNodes 0]

	# Handle item publications
	xsearch $eventNode items item -script itemNode {
	    set jid [xsearch $itemNode -get @id]
	    if {$jid eq ""} continue

	    set existed [$client db eval {SELECT count(*) FROM bookmark WHERE jid=$jid}]
	    $self StoreItem $jid $itemNode
	    if {$existed} {
		$client emit bookmarks <Changed> -action update -jid $jid
	    } else {
		$client emit bookmarks <Changed> -action add -jid $jid
		$self AutojoinOne $jid
	    }
	}

	# Handle retractions
	xsearch $eventNode items retract -script retractNode {
	    set jid [xsearch $retractNode -get @id]
	    if {$jid eq ""} continue

	    $client db eval {DELETE FROM bookmark WHERE jid=$jid}
	    $client emit bookmarks <Changed> -action remove -jid $jid
	}
    }

    method StoreItem {jid itemNode} {
	set confNodes [xsearch $itemNode conference -ns urn:xmpp:bookmarks:1]
	if {[llength $confNodes] == 0} {
	    set confNodes [xsearch $itemNode conference]
	}
	if {[llength $confNodes] == 0} {
	    # No conference element — store bare entry
	    $client db eval {
		INSERT OR REPLACE INTO bookmark(jid) VALUES ($jid)
	    }
	    return
	}

	set confNode [lindex $confNodes 0]
	set name [xsearch $confNode -get @name]
	set autojoinRaw [xsearch $confNode -get @autojoin]
	set autojoin [expr {$autojoinRaw in {true 1} ? 1 : 0}]
	set nick [xsearch $confNode nick -get body]
	set password [xsearch $confNode password -get body]

	# Preserve unknown extensions
	set extNodes [xsearch $confNode extensions]
	set extensionsXml ""
	if {[llength $extNodes] > 0} {
	    set extensionsXml [jwrite [lindex $extNodes 0]]
	}

	$client db eval {
	    INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password, extensions_xml)
	    VALUES ($jid, $name, $autojoin, $nick, $password, $extensionsXml)
	}
    }

    method AutojoinAll {} {
	$client db eval {SELECT jid, nick, password FROM bookmark WHERE autojoin=1} row {
	    if {[$client muc isJoined -jid $row(jid)]} continue
	    set nick $row(nick)
	    if {$nick eq ""} {
		set nick [jid username [$client cget -jid]]
	    }
	    if {$row(password) ne ""} {
		$client muc join -jid $row(jid) -nick $nick -password $row(password)
	    } else {
		$client muc join -jid $row(jid) -nick $nick
	    }
	}
    }

    method AutojoinOne {jid} {
	set row [$client db eval {SELECT autojoin, nick, password FROM bookmark WHERE jid=$jid}]
	if {[llength $row] != 3} return
	lassign $row autojoin nick password
	if {!$autojoin} return
	if {[$client muc isJoined -jid $jid]} return
	if {$nick eq ""} {
	    set nick [jid username [$client cget -jid]]
	}
	if {$password ne ""} {
	    $client muc join -jid $jid -nick $nick -password $password
	} else {
	    $client muc join -jid $jid -nick $nick
	}
    }

    method Migrate {} {
	$client db eval {
	    CREATE TABLE IF NOT EXISTS bookmark(
		jid TEXT PRIMARY KEY,
		name TEXT,
		autojoin INTEGER DEFAULT 0,
		nick TEXT,
		password TEXT,
		extensions_xml TEXT
	    );
	}
    }
}
