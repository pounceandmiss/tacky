package require sha1
package require tclwuffs

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
        tacky avatar publish -acc $acc -data $rawData ?-type image/png? ?-tag $tag? ?-command $cb?
            Publish own avatar
        tacky avatar disable -acc $acc ?-tag $tag? ?-command $cb?
            Disable own avatar
        tacky avatar cancel -acc $acc -tag $tag
            Cancel a pending -command callback by tag

    Events:
        tacky listen avatar <Update> -acc ...
            Payload: -jid <bare-jid> -hash <sha1>
                  or -jid <bare-jid> -action disabled
        tacky listen avatar <Progress> -acc ...
            Payload: -acc <bare-jid> -message <status string>
}

snit::type taco_avatar {

    variable client
    variable VisibleJids
    variable PendingVCardHash
    variable PendingPubSubHash
    variable ActiveTags

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set VisibleJids [dict create]
        set PendingVCardHash [dict create]
        set PendingPubSubHash [dict create]
        array set ActiveTags {}
        $self Migrate
        $client pubsub handler urn:xmpp:avatar:metadata \
            [mymethod OnMetadataNotification]
        $client caps addFeature urn:xmpp:avatar:metadata+notify
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    method OnDisconnect {args} {
        set VisibleJids [dict create]
        set PendingVCardHash [dict create]
        set PendingPubSubHash [dict create]
        array unset ActiveTags
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client pubsub unhandler urn:xmpp:avatar:metadata}
    }

    # Return avatar metadata for a JID
    tackymethod metadata {args} {
        set jid [jid norm [dict get $args -jid]]
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
        set jid [jid norm $jid]
        set has [$client db onecolumn {
            SELECT count(*) FROM avatar_metadata WHERE jid=$jid
        }]
        if {!$has} {
            $self FetchVCard $jid
        }
    }

    # Get pre-generated 32x32 thumbnail bytes for a JID; returns "" if none.
    tackymethod thumb {args} {
        set jid [jid norm [dict get $args -jid]]
        $client db eval {
            SELECT d.thumb FROM avatar_metadata m
            JOIN avatar_data d ON d.hash = m.hash
            WHERE m.jid=$jid
        } row { return $row(thumb) }
        return ""
    }

    # Publish own avatar (rawData = raw image bytes)
    # Optional -command callback: {*}$command [list ok ""] / {*}$command [list error $msg]
    method publish {args} {
        array set opts {-type image/png -width "" -height "" -command "" -tag ""}
        array set opts $args
        set acc [dict get $args -acc]
        if {$opts(-tag) ne ""} {
            set ActiveTags($opts(-tag)) 1
        }
        $client emit avatar <Progress> -acc $acc -message "Resizing image..."
        set rawData [$self ResizeForPublish $opts(-data)]
        set opts(-type) image/png
        set opts(-width) ""
        set opts(-height) ""

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
        set publishCtx [list \
            acc $acc hash $hash \
            rawData $rawData type $opts(-type) bytes $bytes \
            width $opts(-width) height $opts(-height)]
        $client emit avatar <Progress> -acc $acc -message "Uploading avatar data..."
        $client iq request -type set -payload $dataPayload \
            -command [mymethod OnDataPublished $infoAttrs $hash $publishCtx $opts(-tag) $opts(-command)]
    }

    method OnDataPublished {infoAttrs hash publishCtx tag command stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            if {$command ne "" && ($tag eq "" || [info exists ActiveTags($tag)])} {
                set errText [xsearch $stanza error text -get body]
                if {$errText eq ""} { set errText "Avatar data publish failed" }
                {*}$command [list error $errText]
            }
            return
        }
        set acc [dict get $publishCtx acc]
        $client emit avatar <Progress> -acc $acc -message "Updating metadata..."
        $client iq request -type set -payload \
            [j pubsub -ns http://jabber.org/protocol/pubsub {
                j publish -node urn:xmpp:avatar:metadata {
                    j item -id $hash {
                        j metadata -ns urn:xmpp:avatar:metadata {
                            j info {*}$infoAttrs
                        }
                    }
                }
            }] -command [mymethod OnPublishComplete $publishCtx $tag $command]
    }

    method OnPublishComplete {publishCtx tag command stanza} {
        set stype [xsearch $stanza -get @type]
        if {$tag ne "" && ![info exists ActiveTags($tag)]} {
            set command ""
        }
        if {$stype ne "error"} {
            if {$publishCtx ne ""} {
                # Cache locally and emit update so UI reflects the change
                # immediately, without waiting for the server PEP echo.
                set jid [dict get $publishCtx acc]
                set hash [dict get $publishCtx hash]
                set rawData [dict get $publishCtx rawData]
                set type_ [dict get $publishCtx type]
                set bytes [dict get $publishCtx bytes]
                set width [dict get $publishCtx width]
                set height [dict get $publishCtx height]
                set thumbData [$self MakeThumb $rawData "publish jid=$jid"]
                $client db eval {
                    INSERT OR REPLACE INTO avatar_data(hash, data, thumb)
                    VALUES ($hash, $rawData, $thumbData)
                }
                $client db eval {
                    INSERT OR REPLACE INTO avatar_metadata(jid, hash, type, bytes, width, height)
                    VALUES ($jid, $hash, $type_, $bytes, $width, $height)
                }
                $client emit avatar <Update> -jid $jid -hash $hash
            }
            if {$command ne ""} {
                {*}$command [list ok ""]
            }
        } else {
            if {$command ne ""} {
                set errText [xsearch $stanza error text -get body]
                if {$errText eq ""} { set errText "Avatar publish failed" }
                {*}$command [list error $errText]
            }
        }
    }

    # Disable own avatar
    # Optional -command callback: {*}$command [list ok ""] / {*}$command [list error $msg]
    method disable {args} {
        array set opts {-command "" -tag ""}
        array set opts $args
        if {$opts(-tag) ne ""} {
            set ActiveTags($opts(-tag)) 1
        }

        set cmdOpts [list]
        if {$opts(-command) ne ""} {
            lappend cmdOpts -command [mymethod OnPublishComplete {} $opts(-tag) $opts(-command)]
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

    method cancel {args} {
        unset -nocomplain ActiveTags([dict get $args -tag])
    }

    method OnMetadataNotification {stanza} {
        set from [jid norm [jid bare [xsearch $stanza -get @from]]]

        # Check for empty metadata (avatar disabled)
        set infoNodes [xsearch $stanza event items item metadata info]
        if {[llength $infoNodes] == 0} {
            set had [$client db onecolumn {
                SELECT count(*) FROM avatar_metadata WHERE jid=$from
            }]
            $client db eval {DELETE FROM avatar_metadata WHERE jid=$from}
            if {$had} {
                $client emit avatar <Update> -jid $from -action disabled
            }
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
        set jid [jid norm [dict get $args -jid]]
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
        set jid [jid norm [dict get $args -jid]]
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
        set jid [jid norm $jid]
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

    # Re-encoding through wuffs strips source metadata, so identical input
    # yields identical PNG bytes (and hash) regardless of when it runs.
    method ResizeForPublish {rawData} {
        try {
            set d [::tclwuffs::decode $rawData]
            lassign [$self FitWithin [dict get $d width] [dict get $d height] 128] tw th
            return [::tclwuffs::resize_bytes $rawData $tw $th]
        } on error {err} {
            jlog warn "Avatar resize failed: $err"
            return $rawData
        }
    }

    method MakeThumb {rawData caller} {
        try {
            set d [::tclwuffs::decode $rawData]
            lassign [$self FitWithin [dict get $d width] [dict get $d height] 32] tw th
            return [::tclwuffs::resize_bytes $rawData $tw $th]
        } on error {err} {
            jlog warn "Thumbnail generation failed: $err"
            return ""
        }
    }

    # Largest dimensions fitting within max*max, preserving aspect, never
    # upscaling. Returns {w h}.
    method FitWithin {w h max} {
        if {$w <= $max && $h <= $max} {
            return [list $w $h]
        }
        if {$w >= $h} {
            set nw $max
            set nh [expr {int(round(double($h) * $max / $w))}]
        } else {
            set nh $max
            set nw [expr {int(round(double($w) * $max / $h))}]
        }
        return [list [expr {max($nw, 1)}] [expr {max($nh, 1)}]]
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
