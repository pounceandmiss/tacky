oo::class create _tacky_router {
    # Dict: _listeners $event $tag $command
    variable _listeners
    # Assign values for tags when not specified
    variable TagCounter

    constructor {} {
	set _listeners [dict create]
	set TagCounter 0
    }

    # listen ?-tag $tag? module event ?-field $value ...? $command
    method listen args {
	set eventIdx [lsearch -glob $args <*>]
	set event [lindex $args $eventIdx]
	set module [lindex $args [expr {$eventIdx - 1}]]
	set command [lindex $args end]
	set filters [lrange $args [expr {$eventIdx + 1}] end-1]
	set tagIdx [lsearch -exact $args -tag]
	if {$tagIdx >= 0} {
	    set tag [lindex $args [expr {$tagIdx + 1}]]
	} else {
	    set tag [incr TagCounter]
	}
	set key [list $module $event]
	dict lappend _listeners $key [list $tag $filters $command]
	return $tag
    }

    method unlisten {tag} {
	dict for {key entries} $_listeners {
	    set filtered {}
	    foreach entry $entries {
		if {[lindex $entry 0] ne $tag} {
		    lappend filtered $entry
		}
	    }
	    if {[llength $filtered] == 0} {
		dict unset _listeners $key
	    } else {
		dict set _listeners $key $filtered
	    }
	}
    }

    method dispatch {module event argsL} {
	set key [list $module $event]
	if {![dict exists $_listeners $key]} return
	foreach entry [dict get $_listeners $key] {
	    lassign $entry _tag filters cmd
	    set match 1
	    foreach {field value} $filters {
		set idx [lsearch -exact $argsL $field]
		if {$idx < 0 || [lindex $argsL [expr {$idx + 1}]] ne $value} {
		    set match 0
		    break
		}
	    }
	    if {$match} {
		{*}$cmd $argsL
	    }
	}
    }
}

set _tacky_taco_script [file join [file dirname [info script]] taco taco.tcl]

oo::class create tacky_type {
    superclass _tacky_router

    constructor {args} {
	next
	if {[info commands taco_type] eq ""} {
	    uplevel #0 source $::_tacky_taco_script
	}
	taco_type taco {*}$args
    }

    destructor {
	catch {taco destroy}
    }

    method emit {module event args} {
	my dispatch $module $event $args
    }

    # Forward all non-router methods directly to taco
    method unknown {module method args} {
	taco $module $method {*}$args
    }
}

oo::class create tacky_threaded_type {
    superclass _tacky_router
    # Daemon thread
    variable TacoTid
    # Our thread
    variable TackyTid

    constructor {args} {
	next
	set TackyTid [thread::id]
	set TacoTid [thread::create]
	thread::send $TacoTid [list source $::_tacky_taco_script]
	thread::send $TacoTid {
	    snit::type tacky_proxy {
		option -tid -readonly yes
		option -target -readonly yes
		method emit {module event args} {
		    thread::send -async $options(-tid) \
			[list $options(-target) dispatch $module $event $args]
		}
	    }
	}
	thread::send $TacoTid [list tacky_proxy tacky -tid $TackyTid -target [self]]
	thread::send $TacoTid [list taco_type create taco {*}$args]
    }

    method emit {module event args} {
	my dispatch $module $event $args
    }

    destructor {
	thread::send $TacoTid {taco destroy}
	thread::release $TacoTid
    }
    # Frontend will always use keyword arguments
    method unknown {module method args} {
	foreach opt {-command -onerror} {
	    if {[dict exists $args $opt]} {
		set orig [dict get $args $opt]
		dict set args $opt [list apply {{tid cmd args} {
		    thread::send -async $tid [list {*}$cmd {*}$args]
		}} $TackyTid $orig]
	    }
	}
	thread::send -async $TacoTid [list taco $module $method {*}$args]
    }

}

if 0 {
    avatarcache_base - shared avatar image cache with refcounting.

    Frontend-agnostic base class: handles refcounting, tag management,
    visibility tracking, thumb fetching, update listening, and
    notification fanout.  Subclasses override three methods to provide
    image primitives:

        CreateImage $data   - create image from PNG bytes, return handle
        DeleteImage $img    - destroy image handle
        CreateDefault       - create a default/placeholder image, return handle

    tk_avatarcache (gui/avatarcache.tcl) provides the Tk implementation.

    API:
        avatarcache track -acc $acc -jid $jid -tag $tag -command $cmd
            Returns an image handle (default initially).
            Calls {*}$cmd $img whenever the image changes.
            -tag identifies this registration for untrack.

        avatarcache untrack -tag $tag
            Unregisters the callback and decrements refcount.
            At zero the image is deleted and avatar invisible is called.

        avatarcache default
            Returns the shared default image handle.
}

oo::class create avatarcache_base {
    variable Images
    variable Refcounts
    variable Tags
    variable DefaultImage

    constructor {} {
	set Images [dict create]
	set Refcounts [dict create]
	set Tags [dict create]
	set DefaultImage [my CreateDefault]
	::tacky listen -tag [self] avatar <Update> \
	    [namespace code {my OnUpdate}]
    }

    destructor {
	catch {::tacky unlisten [self]}
	dict for {key img} $Images {
	    catch {my DeleteImage $img}
	}
	catch {my DeleteImage $DefaultImage}
    }

    method CreateImage {data} { error "abstract: subclass must override" }
    method DeleteImage {img}  { error "abstract: subclass must override" }
    method CreateDefault {}   { error "abstract: subclass must override" }

    method default {} {
	return $DefaultImage
    }

    method track {args} {
	array set opts $args
	set acc $opts(-acc)
	set jid $opts(-jid)
	set tag $opts(-tag)
	set command $opts(-command)
	set key "$acc\n$jid"

	dict set Tags $tag [list $acc $jid $command]

	if {[dict exists $Images $key]} {
	    dict set Refcounts $key [expr {[dict get $Refcounts $key] + 1}]
	    return [dict get $Images $key]
	}

	set img [my CreateDefault]

	dict set Images $key $img
	dict set Refcounts $key 1

	::tacky avatar visible -acc $acc -jid $jid
	::tacky avatar thumb -acc $acc -jid $jid \
	    -command [namespace code [list my OnThumb $key]]

	# Return current image — may have been replaced by a
	# synchronous OnThumb callback during the thumb call above.
	return [dict get $Images $key]
    }

    method untrack {args} {
	array set opts $args
	set tag $opts(-tag)
	if {![dict exists $Tags $tag]} return

	lassign [dict get $Tags $tag] acc jid _command
	dict unset Tags $tag
	set key "$acc\n$jid"

	if {![dict exists $Refcounts $key]} return

	set count [dict get $Refcounts $key]
	if {$count <= 1} {
	    ::tacky avatar invisible -acc $acc -jid $jid
	    catch {my DeleteImage [dict get $Images $key]}
	    dict unset Images $key
	    dict unset Refcounts $key
	} else {
	    dict set Refcounts $key [expr {$count - 1}]
	}
    }

    method OnThumb {key data} {
	if {$data eq "" || ![dict exists $Images $key]} return
	set oldImg [dict get $Images $key]
	set newImg [my CreateImage $data]
	dict set Images $key $newImg
	catch {my DeleteImage $oldImg}
	my Notify $key $newImg
    }

    method OnUpdate {ev} {
	set acc [dict get $ev -acc]
	set jid [dict get $ev -jid]
	set key "$acc\n$jid"
	if {![dict exists $Images $key]} return

	if {[dict exists $ev -action] && [dict get $ev -action] eq "disabled"} {
	    set oldImg [dict get $Images $key]
	    set newImg [my CreateDefault]
	    dict set Images $key $newImg
	    catch {my DeleteImage $oldImg}
	    my Notify $key $newImg
	    return
	}

	::tacky avatar thumb -acc $acc -jid $jid \
	    -command [namespace code [list my OnThumb $key]]
    }

    method Notify {key img} {
	dict for {tag info} $Tags {
	    lassign $info acc jid command
	    if {"$acc\n$jid" eq $key} {
		{*}$command $img
	    }
	}
    }
}

proc tacky_init_threaded {args} {
    package require Thread
    tacky_threaded_type create tacky {*}$args
    if {[info commands tk_avatarcache] ne ""} {
	tk_avatarcache create avatarcache
    }
}

proc tacky_init {args} {
    tacky_type create tacky {*}$args
    if {[info commands tk_avatarcache] ne ""} {
	tk_avatarcache create avatarcache
    }
}

if 0 {

    # -- Event System --

    # Subscribe to events from a module; returns tag; supports field-based filtering.
    tacky listen -tag $tag $module <Event> -field $value $command
    # Unsubscribe from all listeners registered under a tag.
    tacky unlisten $tag

    # -- Account Management (taco/account.tcl) --

    # Add a new XMPP account to the local database.
    tacky account add -acc $jid -password $pwd -domain $dom -username $user
    # List all configured account JIDs.
    #   callback receives: {jid1 jid2 ...}
    #   errors emitted as: error <MethodError> -module account -method list ...
    tacky account list -command $callback
    # Check whether an account exists (returns 0 or 1).
    #   callback receives: 0|1
    tacky account exists -acc $jid -command $callback
    # Get account details; with -field returns single value, without returns full dict.
    #   callback receives: $dictOrValue
    #   use -onerror $cb to handle errors inline instead of via <MethodError>
    tacky account get -acc $jid -field $name -command $callback
    # Update account fields like password or domain.
    tacky account set -acc $jid -password $pwd -domain $dom -username $user
    # Delete an account from the database and clean up its client.
    tacky account remove -acc $jid
    # Enable an account and connect it to the XMPP server.
    tacky account enable -acc $jid
    # Disconnect and disable an account.
    tacky account disable -acc $jid

    # Events:
    # Fired when a new account is created.
    #   -acc $jid
    tacky listen account <Added> $command
    # Fired when an account is enabled and connected.
    #   -acc $jid
    tacky listen account <Enabled> $command
    # Fired when an account is disabled and disconnected.
    #   -acc $jid
    tacky listen account <Disabled> $command
    # Fired when an account is deleted.
    #   -acc $jid
    tacky listen account <Removed> $command

    # -- Settings (taco/setting.tcl) --

    # Get a setting value by key; returns "" if the key doesn't exist.
    #   callback receives: -key $k -value $v
    tacky setting get -key $k -command $callback
    # Set a setting value (upserts); setting to "" clears it.
    tacky setting set -key $k -value $v
    # List all setting keys.
    #   callback receives: {key1 key2 ...}
    tacky setting list -command $callback

    # Events:
    # Fired when a setting is created or changed.
    #   -key $k -value $v
    tacky listen setting <Changed> $command

    # -- Contact List (taco/roster.tcl, XEP-0237) --

    # Return the full roster from the local store as a list of contact dicts.
    tacky roster get -acc $jid
    # Request a roster sync from the server.
    tacky roster request -acc $jid
    # Add or update a roster contact.
    tacky roster item -acc $jid -jid $contact -name $n -groups {g1 g2}
    # Remove a contact from the roster.
    tacky roster remove -acc $jid -jid $contact
    # Query the subscription state for a contact (none, to, from, both).
    tacky roster subscription -acc $jid -jid $contact

    # Events:
    # Fired when the roster changes.
    #   -acc $jid -action clear                    (full roster replaced)
    #   -acc $jid -action add|update|remove -jid $contactJid
    tacky listen roster <Changed> $command
    # Fired on incoming presence subscription stanzas (RFC 6121 §3).
    #   -acc $jid -jid $contactJid -type subscribe|subscribed|unsubscribe|unsubscribed
    tacky listen roster <Subscribe> $command

    # Request a presence subscription from a contact.
    tacky roster subscribe -acc $jid -jid $contact
    # Approve an incoming presence subscription request.
    tacky roster approve -acc $jid -jid $contact
    # Cancel an outgoing presence subscription.
    tacky roster unsubscribe -acc $jid -jid $contact
    # Deny or revoke an incoming presence subscription.
    tacky roster deny -acc $jid -jid $contact
    # Convenience: add roster item + request subscription in one call.
    tacky roster add -acc $jid -jid $contact -name $n -groups {g1 g2}

    # -- MUC Bookmarks (taco/bookmarks.tcl, XEP-0402) --

    # Return all bookmarked rooms from the local store.
    tacky bookmarks get -acc $jid
    # Request bookmarks from the server.
    tacky bookmarks request -acc $jid
    # Add or update a bookmark (omitted options are preserved from DB).
    tacky bookmarks item -acc $jid -jid $room -name $n -autojoin true -nick $n -password $p
    # Remove a bookmark (does not leave the room).
    tacky bookmarks remove -acc $jid -jid $room
    # Change the nickname used in a room and update the bookmark.
    tacky bookmarks nick -acc $jid -jid $room -nick $n
    # Leave a room and disable autojoin for its bookmark.
    tacky bookmarks leave -acc $jid -jid $room
    # Query whether autojoin is enabled for a room (returns 0 or 1).
    tacky bookmarks autojoin -acc $jid -jid $room

    # Events:
    # Fired when bookmarks change.
    #   -acc $jid -action clear                    (full bookmarks replaced)
    #   -acc $jid -action add|update|remove -jid $roomJid
    tacky listen bookmarks <Changed> $command

    # -- In-Band Registration (taco/register.tcl, XEP-0077) --

    # Start a registration handshake with an XMPP server.
    tacky register connect -host $h -port $p -token $t
    # Return the current registration form as a flat list.
    tacky register form -token $t
    # Return raw media bytes for a form field (e.g. CAPTCHA image).
    tacky register media -token $t -var $v
    # Submit a filled registration form to the server.
    tacky register submit -token $t -values {var1 val1 var2 val2}
    # Cancel and clean up the registration session.
    tacky register cancel -token $t

    # Events:
    # Fired when the server sends a registration form, ready to query and fill.
    #   -token $t
    tacky listen register <Form> $command
    # Fired when media data (e.g. CAPTCHA) is available for a form field.
    #   -token $t -var $fieldVar
    tacky listen register <MediaReady> $command
    # Fired when registration completes successfully.
    #   -token $t
    tacky listen register <Success> $command
    # Fired when registration fails.
    #   -token $t -message $msg
    tacky listen register <Error> $command

    # -- User Avatars (taco/avatar.tcl, XEP-0084) --

    # Return avatar metadata for a contact (returns hash, type, dimensions).
    tacky avatar metadata -acc $jid -jid $bare
    # Get raw avatar image bytes by SHA-1 hash.
    tacky avatar data -acc $jid -hash $sha1
    # Get pre-generated 32x32 thumbnail bytes for a contact; returns "" if none.
    tacky avatar thumb -acc $jid -jid $bare
    # Publish your own avatar image (rawData is a positional arg: raw image bytes).
    #   callback receives: ok "" | error $msg
    tacky avatar publish -acc $jid -data $rawBytes -type $mime -width $w -height $h -command $cb
    # Remove your own avatar.
    #   callback receives: ok "" | error $msg
    tacky avatar disable -acc $jid -command $cb

    # Events:
    # Fired when a contact's avatar becomes available or is removed.
    #   -acc $jid -jid $contactJid -hash $sha1         (avatar available)
    #   -acc $jid -jid $contactJid -action disabled     (avatar removed)
    tacky listen avatar <Update> $command

    # -- User Nickname (taco/nick.tcl, XEP-0172) --

    # Set own nick via PEP, vcard-temp, and all bookmarks/joined rooms.
    #   -bookmarks skip: only update the default nick, not existing bookmarks.
    tacky nick set -acc $jid -nick $name ?-bookmarks skip? ?-command $cb?
    # Get cached PEP nick for any JID (returns "" if unknown).
    tacky nick get -acc $jid -jid $bareJid
    # Publish own nick via PEP only (low-level).
    tacky nick publish -acc $jid -nick $name ?-command $cb?
    # Fetch a JID's nick from the server and cache it.
    tacky nick fetch -acc $jid -jid $bareJid

    # Events:
    # Fired when a cached nick changes (own or contact).
    #   -acc $jid -jid $bareJid
    tacky listen nick <Changed> $command

    # -- XML Stream Debugging (taco/debugtap.tcl) --

    # Start capturing raw XML stanzas for an account; returns a tap ID.
    #   Stanzas arrive via debugtap <Stanza> events.
    tacky debugtap on -acc $jid
    # Stop capturing stanzas for the given tap.
    tacky debugtap off -tap $tapId
    # Inject a stanza into the stream via a tap (for debugging/testing).
    tacky debugtap write -tap $tapId -stanza $stanza

    # Events:
    # Fired when a stanza passes through an active tap.
    #   -tap $tapId -dir in|out -stanza $stanza
    tacky listen debugtap <Stanza> $command

    # -- Messages (taco/message.tcl) --

    # Fetch message history for a chat. Local-first with MAM backfill.
    #   callback receives: list of message dicts
    tacky message history -acc $jid -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50? -command $cb
    # Cancel pending history callbacks registered with -tag.
    tacky message cancel -acc $jid -tag $tag

    # Events:
    # Fired when a message is received (1-1, MUC groupchat, and MUC PMs).
    #   -acc $jid -jid $chatJid -from $fullJid -body $text -message $msgDict
    tacky listen message <Received> $command
    # Fired when initial MAM catchup completes on connect.
    #   -acc $jid -count $n
    tacky listen message <CatchupDone> $command

    # -- Presence (taco/presencemod.tcl) --

    # Get best-resource presence for a contact.
    #   returns: {show $s status $t priority $p}
    tacky presence get -acc $jid -jid $bareJid
    # Get full resource dict for a contact, or {}.
    tacky presence resources -acc $jid -jid $bareJid
    # Check if a contact has any available resource (returns 0 or 1).
    tacky presence isOnline -acc $jid -jid $bareJid

    # Events:
    # Fired when a contact's presence changes or all presence is cleared.
    #   -acc $jid -action clear                    (on disconnect)
    #   -acc $jid -jid $bareJid                    (specific contact changed)
    tacky listen presence <Changed> $command

    # -- Multi-User Chat (taco/muc.tcl, XEP-0045) --

    # Join a MUC room.
    tacky muc join -acc $jid -jid $room -nick $nick ?-password $pw? ?-history {maxstanzas 20}?
    # Leave a MUC room.
    tacky muc leave -acc $jid -jid $room ?-status $text?
    # Change nickname in a room.
    tacky muc nick -acc $jid -jid $room -nick $newNick
    # Update availability in a room.
    tacky muc status -acc $jid -jid $room ?-show $val? ?-status $text?
    # Send a groupchat message.
    tacky muc say -acc $jid -jid $room -body $text
    # Send a private message to an occupant.
    tacky muc pm -acc $jid -jid $occupantJid -body $text
    # Set or clear the room subject.
    tacky muc subject -acc $jid -jid $room -body $text
    # Send a mediated invitation.
    tacky muc invite -acc $jid -jid $room -to $invitee ?-reason $text?
    # Decline a mediated invitation.
    tacky muc decline -acc $jid -jid $room -to $inviter ?-reason $text?
    # Request voice in a moderated room.
    tacky muc requestVoice -acc $jid -jid $room
    # Kick an occupant.
    tacky muc kick -acc $jid -jid $room -nick $nick ?-reason $text? ?-command $cb?
    # Set an occupant's role.
    tacky muc role -acc $jid -jid $room -nick $nick -role $r ?-reason $t? ?-command $cb?
    # Set a user's affiliation by bare JID.
    tacky muc affiliation -acc $jid -jid $room -target $bare -affiliation $a ?-reason $t? ?-command $cb?
    # Query a role or affiliation list.
    tacky muc getList -acc $jid -jid $room -what members|outcasts|admins|owners|... ?-command $cb?
    # Get room configuration form.
    tacky muc configGet -acc $jid -jid $room ?-command $cb?
    # Submit room configuration.
    tacky muc configSet -acc $jid -jid $room -fields $formFields ?-command $cb?
    # Cancel room configuration.
    tacky muc configCancel -acc $jid -jid $room ?-command $cb?
    # Accept default config (instant room).
    tacky muc createInstant -acc $jid -jid $room ?-command $cb?
    # Destroy a room.
    tacky muc destroyRoom -acc $jid -jid $room ?-altRoom $jid? ?-reason $t? ?-password $pw? ?-command $cb?
    # Get registration form from room.
    tacky muc registerGet -acc $jid -jid $room ?-command $cb?
    # Submit registration form.
    tacky muc registerSet -acc $jid -jid $room -fields $formFields ?-command $cb?
    # Discover rooms on a MUC service.
    tacky muc discoverRooms -acc $jid -jid $serviceJid ?-command $cb?
    # Discover reserved nickname in a room.
    tacky muc reservedNick -acc $jid -jid $room ?-command $cb?
    # Get room subject.
    tacky muc getSubject -acc $jid -jid $room
    # List occupant dicts.
    tacky muc occupants -acc $jid -jid $room
    # Get single occupant dict by nick.
    tacky muc occupant -acc $jid -jid $room -nick $nick
    # Get our nick in a room.
    tacky muc myNick -acc $jid -jid $room
    # Get our role (moderator, participant, visitor, none).
    tacky muc myRole -acc $jid -jid $room
    # Get our affiliation (owner, admin, member, none, outcast).
    tacky muc myAffiliation -acc $jid -jid $room
    # Check if we have voice (can send messages; false for visitors).
    tacky muc haveVoice -acc $jid -jid $room
    # Check if we're joined.
    tacky muc isJoined -acc $jid -jid $room
    # List joined room JIDs.
    tacky muc rooms -acc $jid

    # Events:
    tacky listen muc <Joined> $cmd             ;# -acc -jid -nick
    tacky listen muc <Left> $cmd               ;# -acc -jid -nick
    tacky listen muc <Error> $cmd              ;# -acc -jid -error -stanza
    tacky listen muc <Presence> $cmd           ;# -acc -jid -nick -occupant
    tacky listen muc <Unavailable> $cmd        ;# -acc -jid -nick -reason -codes -occupant
    tacky listen muc <Subject> $cmd            ;# -acc -jid -nick -subject
    tacky listen muc <Invite> $cmd             ;# -acc -jid -from -reason -password -continue
    tacky listen muc <Decline> $cmd            ;# -acc -jid -from -reason
    tacky listen muc <NickChanged> $cmd        ;# -acc -jid -oldNick -newNick -self
    tacky listen muc <Kicked> $cmd             ;# -acc -jid -nick -actor -reason
    tacky listen muc <Banned> $cmd             ;# -acc -jid -nick -actor -reason
    tacky listen muc <ConfigChanged> $cmd      ;# -acc -jid -codes
    tacky listen muc <RoomCreated> $cmd        ;# -acc -jid
    tacky listen muc <Destroyed> $cmd          ;# -acc -jid -altRoom -reason
    tacky listen muc <VoiceRequest> $cmd       ;# -acc -jid -from -nick -form
    tacky listen muc <AffiliationChanged> $cmd ;# -acc -jid -target -affiliation

    # -- Connection Events --

    # Fired when connection state changes.
    #   -acc $jid -state $state
    #   States: disconnected, connecting, authenticating, binding, connected, waiting
    tacky listen conn <State> $command
    # Fired when an account's XMPP connection is fully established.
    #   -acc $jid -resumed $bool
    tacky listen conn <Ready> $command
    # Fired when an account disconnects from the server.
    #   -acc $jid -message $msg
    tacky listen conn <Disconnected> $command
    # Fired when authentication fails for an account.
    #   -acc $jid -message $msg
    tacky listen conn <AuthError> $command

    # Query connection state synchronously.
    tacky conn state -acc $jid
}
