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

oo::class create tacky_type {
    superclass _tacky_router

    constructor {args} {
	next
	if {[info commands taco_type] eq ""} {
	    uplevel #0 source [file join [file dirname [info script]] taco taco.tcl]
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
    method unknown {name args} {
	taco $name {*}$args
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
	thread::send $TacoTid [list source [file join [file dirname [info script]] taco taco.tcl]]
	thread::send $TacoTid [list taco_type create taco {*}$args]
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
    }

    method emit {module event args} {
	my dispatch $module $event $args
    }

    destructor {
	thread::release $TacoTid
    }
    # Frontend will always use keyword arguments
    method unknown {name args} {
	if {[dict exists $args -command]} {
	    set origCmd [dict get $args -command]
	    dict set args -command [list apply {{tid cmd result} {
		thread::send -async $tid [list {*}$cmd $result]
	    }} $TackyTid $origCmd]
	}
	thread::send -async $TacoTid [list taco $name {*}$args]
    }

}

proc tacky_init_threaded {args} {
    package require Thread
    tacky_threaded_type create tacky {*}$args
}

proc tacky_init {args} {
    tacky_type create tacky {*}$args
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

    # -- XML Stream Debugging (taco/debugtap.tcl) --

    # Start capturing raw XML stanzas for an account; returns a tap ID.
    #   callback receives: $tapId
    tacky debugtap on -acc $jid -onstanza $callback -command $cb
    # Stop capturing stanzas for the given tap.
    tacky debugtap off -tap $tapId
    # Inject a stanza into the stream via a tap (for debugging/testing).
    tacky debugtap write -tap $tapId -stanza $stanza

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
