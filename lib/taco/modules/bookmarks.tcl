# taco_bookmarks - manages XEP-0402 PEP Native Bookmarks.

# Stores bookmarks in SQLite, listens for PubSub notifications on
# urn:xmpp:bookmarks:1, and fires events via $client emit for change
# notification.

# tacky bookmarks get -acc $jid
# tacky bookmarks request -acc $jid
# tacky bookmarks item -acc $jid -jid $roomJid ?-name ...? ?-autojoin ...? ?-nick ...? ?-password ...?
# tacky bookmarks remove -acc $jid -jid $roomJid ?-leave 0|1?
#   -leave defaults to 1 (leaves the room first if currently joined, matching
#   the native GUI's "Leave Room" menu item, which is this call unadorned).
#   Pass -leave 0 to drop the bookmark without leaving a room you're in -
#   a plain unstar, as opposed to leaving-and-forgetting.
# tacky bookmarks nick -acc $jid -jid $roomJid -nick $nick
# tacky bookmarks leave -acc $jid -jid $roomJid
# tacky bookmarks autojoin -acc $jid -jid $roomJid
# tacky bookmarks defaultNick -acc $jid ?-nick $newNick?
# tacky bookmarks setNickAll -acc $jid -nick $nick
#
# Changes made on another device arrive as notifications and are applied
# here too: autojoin turned on joins the room, turned off leaves it, a new
# nick is taken in a joined room, and a removed bookmark (or all of them,
# on a purge or node delete) leaves its room.
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

    # Rooms already re-entered after being put out, this stream. One attempt
    # per stream bounds a server that keeps removing us.
    variable mucRejoined {}

    # room -> nick requested by `nick` in a joined room, until the room
    # accepts or refuses it.
    variable nickWanted {}

    # Our own publishes and retracts come back as notifications. Each one
    # sent is remembered until its echo arrives, so the echo isn't taken
    # for a change made on another device:
    #   room -> list of {name autojoin nick password} we published
    #   room -> retracts sent and not yet echoed
    variable pendingPublish {}
    variable pendingRetract {}

    # Fields `item` accepts from a caller. jid is excluded: it is the key and
    # is canonicalized separately, so a caller's raw ?join form must not
    # overwrite it.
    variable item_fields {name autojoin nick password extensions_xml}

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client pubsub handler urn:xmpp:bookmarks:1 -own-only \
            [mymethod OnNotification]
        $client caps addFeature urn:xmpp:bookmarks:1+notify
        $client bus subscribe $self <SessionStart> [mymethod OnReady]
        $client bus subscribe $self muc:<Joining> [mymethod OnMucJoining]
        $client bus subscribe $self muc:<Joined> [mymethod OnMucJoined]
        $client bus subscribe $self muc:<Error> [mymethod OnMucError]
        $client bus subscribe $self muc:<Left> [mymethod OnMucLeft]
        $client bus subscribe $self muc:<NickChanged> [mymethod OnMucNickChanged]
        $client bus subscribe $self muc:<NickError> [mymethod OnMucNickError]
        $client bus subscribe $self <SessionEnd> [mymethod OnDisconnect]
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
    tackymethod -noreturn request {args} {
        $client iq request -type get \
            -payload [j pubsub -ns http://jabber.org/protocol/pubsub {
                j items -node urn:xmpp:bookmarks:1
            }] -command [mymethod OnResult]
    }

    # Add or update a bookmark
    # Omitted options are preserved from the DB if the bookmark exists.
    # If -nick is omitted for a new bookmark, defaults to defaultNick.
    tackymethod -noreturn item {args} {
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
        $self Publish bm
    }

    # Publish one bookmark, the array named by $bmVar, as its own item with
    # the node's publish-options (XEP-0402: one item per publish).
    method Publish {bmVar {retried 0}} {
        upvar 1 $bmVar bm
        dict lappend pendingPublish $bm(jid) [$self EchoKey \
            $bm(name) $bm(autojoin) $bm(nick) $bm(password)]
        $client iq request -type set \
            -command [mymethod OnPublishResult [array get bm] $retried] -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j publish -node urn:xmpp:bookmarks:1 {
                    j #as-is [$self BookmarkItemNode bm]
                }
                j publish-options {
                    j #as-is [$self NodeConfigForm \
                        http://jabber.org/protocol/pubsub#publish-options submit]
                }
            }]
    }

    # The node configuration XEP-0402 requires: as publish-options, and to
    # reconfigure a node that another client created otherwise.
    method NodeConfigForm {formType formKind} {
        j x -ns jabber:x:data -type $formKind {
            j field -var FORM_TYPE -type hidden {
                j value -body $formType
            }
            j field -var pubsub#persist_items {
                j value -body true
            }
            j field -var pubsub#max_items {
                j value -body max
            }
            j field -var pubsub#send_last_published_item {
                j value -body never
            }
            j field -var pubsub#access_model {
                j value -body whitelist
            }
        }
    }

    # What identifies one of our publishes when it is echoed back.
    method EchoKey {name autojoin nick password} {
        list $name [expr {$autojoin in {true 1} ? 1 : 0}] $nick $password
    }

    # The publish/retract IQs above are otherwise fire-and-forget (no
    # -command means the default no-op in iq.tcl silently swallows an error
    # response), which let a failed retract go completely unnoticed: the
    # local row was already gone, so the only sign was the bookmark
    # reappearing from the next `bookmarks request` full refresh, as if the
    # removal had never happened. Raising here instead routes the failure
    # through the normal bgerror -> `error <Background>` path (see
    # taco.tcl's ::taco_bg), which the frontend already surfaces.
    method OnPublishResult {bmList retried stanza} {
        if {[xsearch $stanza -get @type] ne "error"} return
        array set bm $bmList
        # The node exists with a different configuration (created by another
        # client), so the publish-options can't be met. Reconfigure it as
        # XEP-0402 requires and publish once more.
        if {!$retried && [llength [xsearch $stanza error precondition-not-met \
                -ns http://jabber.org/protocol/pubsub#errors]]} {
            $client iq request -type set \
                -command [mymethod OnReconfigured $bmList] -payload \
                [j pubsub -ns http://jabber.org/protocol/pubsub#owner {
                    j configure -node urn:xmpp:bookmarks:1 {
                        j #as-is [$self NodeConfigForm \
                            http://jabber.org/protocol/pubsub#node_config submit]
                    }
                }]
            return
        }
        error "Could not save bookmark for $bm(jid): [$self ErrorCondition $stanza]"
    }

    method OnReconfigured {bmList stanza} {
        array set bm $bmList
        if {[xsearch $stanza -get @type] eq "error"} {
            error "Could not save bookmark for $bm(jid): the bookmarks node\
                could not be reconfigured ([$self ErrorCondition $stanza])"
        }
        $self Publish bm 1
    }

    method OnRetractResult {jid stanza} {
        if {[xsearch $stanza -get @type] ne "error"} return
        error "Could not remove bookmark for $jid: [$self ErrorCondition $stanza]"
    }

    method ErrorCondition {stanza} {
        set condition [xsearch $stanza error * -get tag]
        if {$condition eq ""} { return unknown }
        return $condition
    }

    # Change nickname in a room and update the bookmark. In a joined room
    # the bookmark is updated only once the room accepts the nick
    # (OnMucNickChanged); if the room refused it, the next autojoin would
    # otherwise request the refused nick.
    tackymethod -noreturn nick {args} {
        array set opts $args
        set opts(-jid) [jid norm [jid bare $opts(-jid)]]
        if {[$client muc isJoined -jid $opts(-jid)]} {
            dict set nickWanted $opts(-jid) $opts(-nick)
        } else {
            $self item -jid $opts(-jid) -nick $opts(-nick)
        }
        $client muc nick -jid $opts(-jid) -nick $opts(-nick)
    }

    method OnMucNickChanged {args} {
        array set opts {-jid "" -newNick "" -self 0}
        array set opts $args
        if {!$opts(-self) || ![dict exists $nickWanted $opts(-jid)]} return
        set wanted [dict get $nickWanted $opts(-jid)]
        dict unset nickWanted $opts(-jid)
        if {$opts(-newNick) eq $wanted} {
            $self item -jid $opts(-jid) -nick $wanted
        }
    }

    method OnMucNickError {args} {
        dict unset nickWanted [dict get $args -jid]
    }

    # Leave a room and disable autojoin.
    tackymethod -noreturn leave {args} {
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
        $self Join $jid $nick $password
    }

    # Join with a bookmark row's nick/password; an empty nick falls back to
    # the account default, an empty password means the room is unlocked.
    method Join {jid nick password} {
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
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        array set opts {-jid ""}
        array set opts $args
        dict set mucStatus $opts(-jid) joining
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucJoined {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        array set opts {-jid ""}
        array set opts $args
        dict set mucStatus $opts(-jid) joined
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucError {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        array set opts {-jid "" -error ""}
        array set opts $args
        dict set mucStatus $opts(-jid) error
        dict set mucReason $opts(-jid) $opts(-error)
        $self EmitRoomState $opts(-jid)
    }

    method OnMucLeft {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        array set opts {-jid "" -involuntary 0 -codes {} -destroyed 0}
        array set opts $args
        dict set mucStatus $opts(-jid) left
        dict unset mucReason $opts(-jid)
        $self EmitRoomState $opts(-jid)
        # Don't rejoin a destroyed room: on most services joining recreates it.
        if {$opts(-involuntary) && !$opts(-destroyed)} {
            $self RejoinAfterRemoval $opts(-jid) $opts(-codes)
        }
    }

    # Re-enter a room the server put us out of, but only where being out is
    # a failure rather than a decision: a ban, a kick and a room turning
    # members-only are decisions to respect. AutojoinOne carries the rest of
    # the policy - it re-enters only an autojoin room we are not already in.
    method RejoinAfterRemoval {jid codes} {
        foreach code {301 307 321 322} {
            if {$code in $codes} return
        }
        if {[dict exists $mucRejoined $jid]} return
        dict set mucRejoined $jid 1
        $self AutojoinOne $jid
    }

    method EmitRoomState {jid} {
        $client emit bookmarks <RoomState> -jid $jid \
            -state [$self RoomState $jid] -reason [$self ResolveMucReason $jid]
    }

    method OnDisconnect {args} {
        set mucStatus {}
        set mucReason {}
        set mucRejoined {}
        set nickWanted {}
        set pendingPublish {}
        set pendingRetract {}
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

    # Remove a bookmark, leaving the room first if currently joined unless
    # -leave 0 asks to just unstar it and stay.
    tackymethod -noreturn remove {args} {
        array set opts {-leave 1}
        array set opts $args
        set jid [jid norm [jid bare $opts(-jid)]]
        set doLeave [expr {$opts(-leave) ni {0 false}}]
        if {$doLeave && [$client muc isJoined -jid $jid]} {
            $client muc leave -jid $jid
        }
        $client db eval {DELETE FROM bookmark WHERE jid=$jid}
        $client emit bookmarks <Changed> -action remove -jid $jid

        dict incr pendingRetract $jid
        $client iq request -type set -command [mymethod OnRetractResult $jid] -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j retract -node urn:xmpp:bookmarks:1 -notify true {
                    j item -id $jid
                }
            }]
    }

    method OnResult {stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            # A timeout or other error tells us nothing about the bookmarks,
            # so join the autojoin rooms from the last successful fetch.
            # item-not-found means there are no bookmarks, so the stored
            # list is stale.
            # Only while connected: joins buffered while offline would be
            # sent again by the next session's autojoin.
            if {[dict get [stanza_error $stanza] condition] ne "item-not-found"
                    && [$client conn state] eq "connected"} {
                $self AutojoinAll
            }
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

        # All bookmarks removed at once (XEP-0060 purge or node delete):
        # handled as if each had been retracted.
        if {[llength [xsearch $eventNode purge]]
                || [llength [xsearch $eventNode delete]]} {
            set jids [$client db eval {SELECT jid FROM bookmark}]
            $client db eval {DELETE FROM bookmark}
            $client emit bookmarks <Changed> -action clear
            foreach jid $jids { $self LeaveIfIn $jid }
            return
        }

        xsearch $eventNode items item -script itemNode {
            set jid [jid norm [xsearch $itemNode -get @id]]
            if {$jid eq ""} continue
            $self OnRemoteItem $jid $itemNode
        }

        xsearch $eventNode items retract -script retractNode {
            set jid [jid norm [xsearch $retractNode -get @id]]
            if {$jid eq ""} continue
            if {[dict exists $pendingRetract $jid]} {
                # The echo of our own retract.
                if {[dict incr pendingRetract $jid -1] <= 0} {
                    dict unset pendingRetract $jid
                }
                continue
            }
            if {![$client db exists {SELECT 1 FROM bookmark WHERE jid=$jid}]} continue
            $client db eval {DELETE FROM bookmark WHERE jid=$jid}
            $client emit bookmarks <Changed> -action remove -jid $jid
            $self LeaveIfIn $jid
        }
    }

    # A published bookmark item: the echo of our own publish, or a change
    # from another device, which is stored and acted on if it changed
    # anything.
    method OnRemoteItem {jid itemNode} {
        set old [$self StoredKey $jid]
        $self StoreItem $jid $itemNode
        set new [$self StoredKey $jid]
        # Echo of our own publish: its content is already in the store, so
        # there is nothing to act on, and it must not overwrite a newer
        # local change.
        if {[dict exists $pendingPublish $jid]} {
            set sent [dict get $pendingPublish $jid]
            set i [lsearch -exact $sent $new]
            if {$i >= 0} {
                set sent [lreplace $sent 0 $i]
                if {[llength $sent]} {
                    dict set pendingPublish $jid $sent
                    # A newer publish is still in flight: keep its values,
                    # not this older echo's.
                    $self RestoreRow $jid [lindex $sent end]
                } else {
                    dict unset pendingPublish $jid
                }
                return
            }
        }
        if {$old eq ""} {
            $client emit bookmarks <Changed> -action add -jid $jid
            $self AutojoinOne $jid
            return
        }
        $client emit bookmarks <Changed> -action update -jid $jid
        lassign $old - oldAutojoin oldNick
        lassign $new - newAutojoin newNick
        if {!$oldAutojoin && $newAutojoin} {
            $self AutojoinOne $jid
        } elseif {$oldAutojoin && !$newAutojoin} {
            $self LeaveIfIn $jid
        } elseif {$newNick ne "" && $newNick ne $oldNick
                && [$client muc isJoined -jid $jid]
                && [$client muc myNick -jid $jid] ne $newNick} {
            $client muc nick -jid $jid -nick $newNick
        }
    }

    # The stored bookmark's EchoKey, "" when there is none.
    method StoredKey {jid} {
        $client db eval {
            SELECT name, autojoin, nick, password FROM bookmark WHERE jid=$jid
        } row {
            return [$self EchoKey $row(name) $row(autojoin) $row(nick) $row(password)]
        }
        return ""
    }

    # Write back the fields of our newest in-flight publish over an older
    # echo that StoreItem stored.
    method RestoreRow {jid key} {
        lassign $key name autojoin nick password
        $client db eval {
            UPDATE bookmark SET name=$name, autojoin=$autojoin, nick=$nick,
                password=$password
            WHERE jid=$jid
        }
    }

    # Leave $jid if we are in it or joining it (its bookmark was removed or
    # its autojoin turned off on another device).
    method LeaveIfIn {jid} {
        if {[$client muc isTracked -jid $jid]} {
            $client muc leave -jid $jid
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
                    j nick -body $bm(nick)
                }
                if {$bm(password) ne ""} {
                    j password -body $bm(password)
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

        # One publish per bookmark: a publish carries a single item, and
        # each needs the node's options (a private node, whitelist access).
        $client db eval {
            SELECT jid, name, autojoin, nick, password, extensions_xml
            FROM bookmark
        } bm {
            $self Publish bm
        }
    }

    method AutojoinAll {} {
        $client db eval {SELECT jid, nick, password FROM bookmark WHERE autojoin=1} row {
            if {[$client muc isTracked -jid $row(jid)]} continue
            $self Join $row(jid) $row(nick) $row(password)
        }
    }

    method AutojoinOne {jid} {
        $client db eval {
            SELECT autojoin, nick, password FROM bookmark WHERE jid=$jid
        } row {
            if {!$row(autojoin)} return
            if {[$client muc isTracked -jid $jid]} return
            $self Join $jid $row(nick) $row(password)
        }
    }
}
