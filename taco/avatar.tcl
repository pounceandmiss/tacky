package require sha1

if 0 {
    taco_avatar - manages XEP-0084 User Avatar support.

    Listens for avatar metadata PubSub notifications, auto-fetches
    avatar image data, caches in SQLite with pre-generated thumbnails,
    and emits events through the tacky event system.

    Tacky API:
        tacky avatar metadata -acc $acc -jid $jid
            Returns metadata dict: hash type bytes width height
        tacky avatar data -acc $acc -hash $hash
            Returns raw image bytes
        tacky avatar publish -acc $acc -data $rawData ?-type image/png?
            Publish own avatar
        tacky avatar disable -acc $acc
            Disable own avatar

    Events:
        tacky listen avatar <Update> -acc ...
            Payload: -jid <bare-jid> -hash <sha1>
                  or -jid <bare-jid> -action disabled
}

snit::type taco_avatar {

    variable client
    variable VisibleJids
    variable PendingVCardHash
    variable PendingPubSubHash

    option -client -readonly yes

    constructor args {
	$self configurelist $args
	set client $options(-client)
	set VisibleJids [dict create]
	set PendingVCardHash [dict create]
	set PendingPubSubHash [dict create]
	$self Migrate
	$client message pubsub handler urn:xmpp:avatar:metadata \
	    [mymethod OnMetadataNotification]
	catch {$client caps addFeature urn:xmpp:avatar:metadata+notify}
    }

    method OnReady {} {}
    method OnDisconnect {} {
	set VisibleJids [dict create]
	set PendingVCardHash [dict create]
	set PendingPubSubHash [dict create]
    }

    destructor {
	catch {$client message pubsub unhandler urn:xmpp:avatar:metadata}
    }

    # Return avatar metadata for a JID
    tackymethod metadata {args} {
	set jid [dict get $args -jid]
	$client db eval {
	    SELECT hash, type, bytes, width, height
	    FROM avatar_metadata WHERE jid=$jid
	} row {
	    return [list hash $row(hash) type $row(type) bytes $row(bytes) \
			width $row(width) height $row(height)]
	}
	return {}
    }

    # Get raw avatar image bytes by hash
    tackymethod data {args} {
	set hash [dict get $args -hash]
	$client db onecolumn {SELECT data FROM avatar_data WHERE hash=$hash}
    }

    # Fetch vCard avatar for a JID if not already cached.
    method ensureVCard {jid} {
	set has [$client db onecolumn {
	    SELECT count(*) FROM avatar_metadata WHERE jid=$jid
	}]
	if {!$has} {
	    $self FetchVCard $jid
	}
    }

    # Get pre-generated 32x32 thumbnail bytes for a JID; returns "" if none.
    tackymethod thumb {args} {
	set jid [dict get $args -jid]
	$client db eval {
	    SELECT d.thumb FROM avatar_metadata m
	    JOIN avatar_data d ON d.hash = m.hash
	    WHERE m.jid=$jid
	} row { return $row(thumb) }
	return ""
    }

    # Publish own avatar (rawData = raw image bytes)
    # Optional -command callback: {*}$command ok "" / {*}$command error $msg
    method publish {args} {
	array set opts {-type image/png -width "" -height "" -command ""}
	array set opts $args
	set rawData $opts(-data)

	# Compute SHA-1 from raw bytes
	set hash [::sha1::sha1 -hex $rawData]
	set bytes [string length $rawData]

	# Encode for XMPP wire
	set base64Data [binary encode base64 -maxlen 0 $rawData]

	# Build info attributes
	set infoAttrs [list -bytes $bytes -id $hash -type $opts(-type)]
	if {$opts(-width) ne ""} {
	    lappend infoAttrs -width $opts(-width)
	}
	if {$opts(-height) ne ""} {
	    lappend infoAttrs -height $opts(-height)
	}

	set dataPayload [j pubsub -ns http://jabber.org/protocol/pubsub {
	    j publish -node urn:xmpp:avatar:data {
		j item -id $hash {
		    j data -ns urn:xmpp:avatar:data #body $base64Data
		}
	    }
	}]

	# Always chain: data IQ → wait for result → metadata IQ.
	# Publishing metadata before the server confirms data storage
	# causes races on ejabberd/MongooseIM where subscribers try to
	# fetch data that isn't committed yet.
	$client iq request -type set -payload $dataPayload \
	    -command [mymethod OnDataPublished $infoAttrs $hash $opts(-command)]
    }

    method OnDataPublished {infoAttrs hash command stanza} {
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "error"} {
	    if {$command ne ""} {
		set errText [xsearch $stanza error text -get body]
		if {$errText eq ""} { set errText "Avatar data publish failed" }
		{*}$command error $errText
	    }
	    return
	}
	$client iq request -type set -payload \
	    [j pubsub -ns http://jabber.org/protocol/pubsub {
		j publish -node urn:xmpp:avatar:metadata {
		    j item -id $hash {
			j metadata -ns urn:xmpp:avatar:metadata {
			    j info {*}$infoAttrs
			}
		    }
		}
	    }] -command [mymethod OnPublishComplete $command]
    }

    method OnPublishComplete {command stanza} {
	if {$command eq ""} return
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "error"} {
	    set errText [xsearch $stanza error text -get body]
	    if {$errText eq ""} { set errText "Avatar publish failed" }
	    {*}$command error $errText
	} else {
	    {*}$command ok ""
	}
    }

    # Disable own avatar
    # Optional -command callback: {*}$command ok "" / {*}$command error $msg
    method disable {args} {
	array set opts {-command ""}
	array set opts $args

	set cmdOpts [list]
	if {$opts(-command) ne ""} {
	    lappend cmdOpts -command [mymethod OnPublishComplete $opts(-command)]
	}

	$client iq request -type set {*}$cmdOpts -payload \
	    [j pubsub -ns http://jabber.org/protocol/pubsub {
		j publish -node urn:xmpp:avatar:metadata {
		    j item {
			j metadata -ns urn:xmpp:avatar:metadata
		    }
		}
	    }]
    }

    method OnMetadataNotification {stanza} {
	set from [jid bare [xsearch $stanza -get @from]]

	# Check for empty metadata (avatar disabled)
	set infoNodes [xsearch $stanza event items item metadata info]
	if {[llength $infoNodes] == 0} {
	    $client db eval {DELETE FROM avatar_metadata WHERE jid=$from}
	    $client emit avatar <Update> -jid $from -action disabled
	    return
	}

	# Extract info attributes from first <info> element
	set hash [xsearch $stanza event items item metadata info -get @id]
	set type_ [xsearch $stanza event items item metadata info -get @type]
	set bytes [xsearch $stanza event items item metadata info -get @bytes]
	set width [xsearch $stanza event items item metadata info -get @width]
	set height [xsearch $stanza event items item metadata info -get @height]

	# Upsert metadata
	$client db eval {
	    INSERT OR REPLACE INTO avatar_metadata(jid, hash, type, bytes, width, height)
	    VALUES ($from, $hash, $type_, $bytes, $width, $height)
	}

	# Check if data already cached
	set cached [$client db eval {SELECT count(*) FROM avatar_data WHERE hash=$hash}]
	if {$cached} {
	    $client emit avatar <Update> -jid $from -hash $hash
	} elseif {[$self IsVisible $from]} {
	    $self FetchData $from $hash
	} else {
	    dict set PendingPubSubHash $from $hash
	}
    }

    method visible {args} {
	set jid [dict get $args -jid]
	set count 0
	if {[dict exists $VisibleJids $jid]} {
	    set count [dict get $VisibleJids $jid]
	}
	dict set VisibleJids $jid [incr count]
	if {$count == 1} {
	    if {[dict exists $PendingVCardHash $jid]} {
		dict unset PendingVCardHash $jid
		$self FetchVCard $jid
	    }
	    if {[dict exists $PendingPubSubHash $jid]} {
		set hash [dict get $PendingPubSubHash $jid]
		dict unset PendingPubSubHash $jid
		$self FetchData $jid $hash
	    }
	}
    }

    method invisible {args} {
	set jid [dict get $args -jid]
	if {![dict exists $VisibleJids $jid]} return
	set count [dict get $VisibleJids $jid]
	if {$count <= 1} {
	    dict unset VisibleJids $jid
	} else {
	    dict set VisibleJids $jid [expr {$count - 1}]
	}
    }

    method IsVisible {jid} {
	dict exists $VisibleJids $jid
    }

    # XEP-0153: detect vCard avatar hash in presence.
    # Compares to cached hash; triggers FetchVCard only if different.
    # jid: bare JID for rooms, occupant JID (room@muc/nick) for participants.
    method OnVCardPresence {jid stanza} {
	set xNode [xsearch $stanza x -ns vcard-temp:x:update]
	if {$xNode eq ""} return

	set hash [xsearch $stanza x -ns vcard-temp:x:update photo -get body]
	if {$hash eq ""} {
	    set existing [$client db onecolumn {
		SELECT hash FROM avatar_metadata WHERE jid=$jid
	    }]
	    if {$existing ne ""} {
		$client db eval {DELETE FROM avatar_metadata WHERE jid=$jid}
		$client emit avatar <Update> -jid $jid -action disabled
	    }
	    return
	}

	set existing [$client db onecolumn {
	    SELECT hash FROM avatar_metadata WHERE jid=$jid
	}]
	if {$existing eq $hash} return
	if {[$self IsVisible $jid]} {
	    $self FetchVCard $jid
	} else {
	    dict set PendingVCardHash $jid $hash
	}
    }

    method FetchVCard {jid} {
	$client iq request -to $jid -payload \
	    [j vCard -ns vcard-temp] \
	    -command [mymethod OnVCardResult $jid]
    }

    method OnVCardResult {jid stanza} {
	if {[xsearch $stanza -get @type] eq "error"} return

	set base64Data [xsearch $stanza vCard PHOTO BINVAL -get body]
	if {$base64Data eq ""} return

	set type_ [xsearch $stanza vCard PHOTO TYPE -get body]
	if {$type_ eq ""} { set type_ "image/png" }

	set base64Data [string map {\n "" \r "" " " "" \t ""} $base64Data]
	set rawData [::base64::decode $base64Data]
	set hash [::sha1::sha1 $rawData]

	set thumbData [$self MakeThumb $rawData "OnVCardResult jid=$jid"]
	set bytes [string length $rawData]
	$client db eval {
	    INSERT OR REPLACE INTO avatar_data(hash, data, thumb)
	    VALUES ($hash, $rawData, $thumbData)
	}
	$client db eval {
	    INSERT OR REPLACE INTO avatar_metadata(jid, hash, type, bytes, width, height)
	    VALUES ($jid, $hash, $type_, $bytes, 0, 0)
	}

	$client emit avatar <Update> -jid $jid -hash $hash
    }

    method FetchData {jid hash} {
	$client iq request -to $jid -payload \
	    [j pubsub -ns http://jabber.org/protocol/pubsub {
		j items -node urn:xmpp:avatar:data {
		    j item -id $hash
		}
	    }] -command [mymethod OnDataResult $jid $hash]
    }

    method OnDataResult {jid hash stanza} {
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "error"} {
	    return
	}

	set base64Data [xsearch $stanza pubsub items item data -get body]
	if {$base64Data eq ""} {
	    return
	}

	# Strip whitespace from base64 data and decode to raw bytes
	set base64Data [string map {\n "" \r "" " " "" \t ""} $base64Data]
	set rawData [::base64::decode $base64Data]

	set thumbData [$self MakeThumb $rawData "OnDataResult jid=$jid hash=$hash"]
	$client db eval {
	    INSERT OR REPLACE INTO avatar_data(hash, data, thumb)
	    VALUES ($hash, $rawData, $thumbData)
	}

	$client emit avatar <Update> -jid $jid -hash $hash
    }

    method MakeThumb {rawData caller} {
	try {
	    set pipe [open |[list magick - -thumbnail 32x32 png:-] r+]
	    chan configure $pipe -translation binary
	    puts -nonewline $pipe $rawData
	    chan close $pipe write
	    set thumbData [chan read $pipe]
	    chan close $pipe
	    return $thumbData
	} on error {err} {
	    jlog warn "Thumbnail generation failed: $err"
	    return ""
	}
    }

    method Migrate {} {
	$client db eval {
	    CREATE TABLE IF NOT EXISTS avatar_metadata(
		jid TEXT PRIMARY KEY,
		hash TEXT NOT NULL,
		type TEXT NOT NULL,
		bytes INTEGER,
		width INTEGER,
		height INTEGER
	    );
	    CREATE TABLE IF NOT EXISTS avatar_data(
		hash TEXT PRIMARY KEY,
		data BLOB NOT NULL,
		thumb BLOB
	    );
	}
    }
}
