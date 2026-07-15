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
# tacky bookmarks defaultNick -acc $jid ?-nick $newNick?
# tacky bookmarks setNickAll -acc $jid -nick $nick
#
# tacky listen bookmarks <Changed> -acc $jid $command
#   -action clear | add | update | remove
#   -jid $roomJid  (present when action is add/update/remove)
#
# tacky listen bookmarks <RoomState> -acc $jid $command
#   -jid $roomJid
#   -state joined | joining | error | disconnected | idle
#   -reason $errorCondition  (empty unless state is error)

snit::type taco_bookmarks {
    variable client
    variable mucStatus {}
    variable mucReason {}

    # Fields `item` accepts from a caller. jid is excluded: it is the key and
    # is canonicalized separately, so a caller's raw ?join form must not
    # overwrite it.
    variable item_fields {name autojoin nick password extensions_xml}

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $self Migrate
        $client pubsub handler urn:xmpp:bookmarks:1 -own-only \
            [mymethod OnNotification]
        $client caps addFeature urn:xmpp:bookmarks:1+notify
        $client bus subscribe $self <Ready> [mymethod OnReady]
        $client bus subscribe $self muc:<Joining> [mymethod OnMucJoining]
        $client bus subscribe $self muc:<Joined> [mymethod OnMucJoined]
        $client bus subscribe $self muc:<Error> [mymethod OnMucError]
        $client bus subscribe $self muc:<Left> [mymethod OnMucLeft]
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client pubsub unhandler urn:xmpp:bookmarks:1}
    }

    method OnReady {args} {
        $self request
    }

    # Return full list of bookmarks from local store, with derived
    # room_state/room_reason per item.
    tackymethod get {args} {
        set results {}
        foreach {jid name autojoin nick password} [$client db eval {
            SELECT jid, name, autojoin, nick, password FROM bookmark
        }] {
            lappend results [list jid $jid name $name \
                autojoin $autojoin nick $nick password $password \
                room_state [$self RoomState $jid] \
                room_reason [$self ResolveMucReason $jid]]
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
    # If -nick is omitted for a new bookmark, defaults to defaultNick.
    method item {args} {
        # Load existing bookmark or defaults
        array set bm {name "" autojoin 0 nick "" password "" extensions_xml ""}
        # jid bare canonicalizes chat-JID input (drops a ?join suffix);
        # bookmarks are keyed by bare room JID
        set bm(jid) [jid norm [jid bare [dict get $args -jid]]]
        set existed 0
        $client db eval {
            SELECT name, autojoin, nick, password, extensions_xml
            FROM bookmark WHERE jid=$bm(jid)
        } bm {
            set existed 1
        }

        # Apply caller overrides
        foreach {k v} $args {
            set field [string range $k 1 end]
            if {$field in $item_fields} {
                set bm($field) $v
            }
        }

        if {$bm(nick) eq ""} {
            set bm(nick) [$self defaultNick]
        }

        # Optimistic local update
        set bm(autojoin) [expr {$bm(autojoin) in {true 1} ? 1 : 0}]
        $client db eval {
            INSERT OR REPLACE INTO bookmark(jid, name, autojoin, nick, password, extensions_xml)
            VALUES ($bm(jid), $bm(name), $bm(autojoin), $bm(nick), $bm(password), $bm(extensions_xml))
        }
        if {$existed} {
            $client emit bookmarks <Changed> -action update -jid $bm(jid)
        } else {
            $client emit bookmarks <Changed> -action add -jid $bm(jid)
        }
        $self AutojoinOne $bm(jid)

        $client iq request -type set -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j publish -node urn:xmpp:bookmarks:1 {
                    j #as-is [$self BookmarkItemNode bm]
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
        array set opts $args
        set opts(-jid) [jid norm [jid bare $opts(-jid)]]
        $self item -jid $opts(-jid) -nick $opts(-nick)
        $client muc nick -jid $opts(-jid) -nick $opts(-nick)
    }

    # Leave a room and disable autojoin.
    method leave {args} {
        set jid [jid norm [jid bare [dict get $args -jid]]]
        $self item -jid $jid -autojoin 0
        $client muc leave -jid $jid
    }

    # Re-send a join request using the bookmark's stored nick/password,
    # without touching the autojoin flag.  Used to re-attempt a room that
    # was dropped (e.g. an IRC gateway disconnect) without auto-retrying.
    tackymethod forceJoin {args} {
        set jid [jid norm [jid bare [dict get $args -jid]]]
        set nick ""
        set password ""
        $client db eval {
            SELECT nick, password FROM bookmark WHERE jid=$jid
        } row {
            set nick $row(nick)
            set password $row(password)
        }
        if {$nick eq ""} {
            set nick [$self defaultNick]
        }
        if {$password ne ""} {
            $client muc join -jid $jid -nick $nick -password $password
        } else {
            $client muc join -jid $jid -nick $nick
        }
    }

    # Get or set the default nickname for new bookmarks.
    # Falls back to JID username if unset.
    tackymethod defaultNick {args} {
        if {[dict exists $args -nick]} {
            set newNick [dict get $args -nick]
            $client db eval {
                INSERT OR REPLACE INTO bookmark_config(key, value)
                VALUES('default_nick', $newNick)
            }
            return $newNick
        }
        set row [$client db eval {
            SELECT value FROM bookmark_config WHERE key='default_nick'
        }]
        if {[llength $row] > 0 && [lindex $row 0] ne ""} {
            return [lindex $row 0]
        }
        return [jid username [$client cget -jid]]
    }

    # Query autojoin state for a single JID
    tackymethod autojoin {args} {
        set jid [jid norm [jid bare [dict get $args -jid]]]
        set row [$client db eval {SELECT autojoin FROM bookmark WHERE jid=$jid}]
        if {[llength $row] == 0} { return 0 }
        return [lindex $row 0]
    }

    # --- Room join-state tracking (muc status folded with membership) ---

    method OnMucJoining {args} {
        array set opts {-jid ""}
        array set opts $args
        dict set mucStatus $opts(-jid) joining
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucJoined {args} {
        array set opts {-jid ""}
        array set opts $args
        dict set mucStatus $opts(-jid) joined
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucError {args} {
        array set opts {-jid "" -error ""}
        array set opts $args
        dict set mucStatus $opts(-jid) error
        dict set mucReason $opts(-jid) $opts(-error)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucLeft {args} {
        array set opts {-jid ""}
        array set opts $args
        dict set mucStatus $opts(-jid) left
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
    }

    method EmitRoomState {jid} {
        $client emit bookmarks <RoomState> -jid $jid \
            -state [$self RoomState $jid] -reason [$self ResolveMucReason $jid]
    }

    method OnDisconnect {args} {
        set mucStatus {}
        set mucReason {}
    }

    method ResolveMucStatus {jid} {
        if {[dict exists $mucStatus $jid]} {
            return [dict get $mucStatus $jid]
        }
        return ""
    }

    method ResolveMucReason {jid} {
        if {[dict exists $mucReason $jid]} {
            return [$self JoinErrorText [dict get $mucReason $jid]]
        }
        return ""
    }

    # Ready join-failure copy for a raw stanza error condition, so the GUI
    # displays it without interpreting the condition itself.
    method JoinErrorText {condition} {
        switch -- $condition {
            not-authorized          { return "Password required or incorrect" }
            forbidden               { return "You are banned from this room" }
            registration-required   { return "Membership required to join" }
            conflict                { return "Nickname already in use" }
            service-unavailable     { return "Room is full" }
            item-not-found          { return "Room does not exist" }
            remote-server-not-found -
            remote-server-timeout   { return "Room server unreachable" }
            jid-malformed           { return "Invalid nickname" }
            gone                    { return "Room no longer exists" }
            default                 { return "Could not join room" }
        }
    }

    # Derived room state for the UI, folding raw join status together with
    # membership (autojoin).  A room we joined and dropped out of reads as
    # "disconnected" only if we're still a member; the initial unattempted
    # state is plain "idle".
    #   joined | joining | error | disconnected | idle
    method RoomState {jid} {
        switch -- [$self ResolveMucStatus $jid] {
            joined  { return joined }
            joining { return joining }
            error   { return error }
            left {
                if {[$self autojoin -jid $jid] in {1 true}} {
                    return disconnected
                }
                return idle
            }
            default { return idle }
        }
    }

    # Remove a bookmark and leave the room if joined
    method remove {args} {
        set jid [jid norm [jid bare [dict get $args -jid]]]
        if {[$client muc isJoined -jid $jid]} {
            $client muc leave -jid $jid
        }
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
        set jid [jid norm [xsearch $itemNode -get @id]]
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
        set jid [jid norm [xsearch $itemNode -get @id]]
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
        set jid [jid norm [xsearch $retractNode -get @id]]
            if {$jid eq ""} continue

            $client db eval {DELETE FROM bookmark WHERE jid=$jid}
            $client emit bookmarks <Changed> -action remove -jid $jid
        }
    }

    # Build a standalone <item><conference>...</conference></item> node.
    # bmVar is the name of an array with keys: jid, name, autojoin, nick,
    # password, extensions_xml.
    # Must be called outside a j context; insert with j #as-is.
    method BookmarkItemNode {bmVar} {
        upvar 1 $bmVar bm
        set autojoinVal [expr {$bm(autojoin) in {true 1} ? "true" : "false"}]
        set confAttrs [list -ns urn:xmpp:bookmarks:1 -autojoin $autojoinVal]
        if {$bm(name) ne ""} {
            lappend confAttrs -name $bm(name)
        }
        j item -id $bm(jid) {
            j conference {*}$confAttrs {
                if {$bm(nick) ne ""} {
                    j nick #body $bm(nick)
                }
                if {$bm(password) ne ""} {
                    j password #body $bm(password)
                }
                if {$bm(extensions_xml) ne ""} {
                    # XEP-0402 4.2: extensions from other clients MUST be
                    # preserved on republish
                    j #as-is [xmppreader string $bm(extensions_xml)]
                }
            }
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

    # Update nickname on all bookmarks and optionally in joined rooms.
    tackymethod setNickAll {args} {
        set newNick [dict get $args -nick]
        $self defaultNick -nick $newNick

        $client db eval {UPDATE bookmark SET nick=$newNick}

        $client db eval {SELECT jid FROM bookmark} row {
            $client emit bookmarks <Changed> -action update -jid $row(jid)
            if {[$client muc isJoined -jid $row(jid)]} {
                $client muc nick -jid $row(jid) -nick $newNick
            }
        }

        # Single IQ with all items
        $client iq request -type set -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j publish -node urn:xmpp:bookmarks:1 {
                    $client db eval {
                        SELECT jid, name, autojoin, nick, password, extensions_xml
                        FROM bookmark
                    } bm {
                        j #as-is [$self BookmarkItemNode bm]
                    }
                }
            }]
    }

    method AutojoinAll {} {
        $client db eval {SELECT jid, nick, password FROM bookmark WHERE autojoin=1} row {
            if {[$client muc isJoined -jid $row(jid)]} continue
            set nick $row(nick)
            if {$nick eq ""} {
                set nick [$self defaultNick]
            }
            if {$row(password) ne ""} {
                $client muc join -jid $row(jid) -nick $nick -password $row(password)
            } else {
                $client muc join -jid $row(jid) -nick $nick
            }
        }
    }

    method AutojoinOne {jid} {
        $client db eval {
            SELECT autojoin, nick, password FROM bookmark WHERE jid=$jid
        } row {
            if {!$row(autojoin)} return
            if {[$client muc isJoined -jid $jid]} return
            if {$row(nick) eq ""} {
                set row(nick) [$self defaultNick]
            }
            if {$row(password) ne ""} {
                $client muc join -jid $jid -nick $row(nick) -password $row(password)
            } else {
                $client muc join -jid $jid -nick $row(nick)
            }
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
            CREATE TABLE IF NOT EXISTS bookmark_config(
                key TEXT PRIMARY KEY,
                value TEXT
            );
        }
    }
}
