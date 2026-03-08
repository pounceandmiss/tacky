
if 0 {
    MAM (XEP-0313) query engine.

    Sends MAM IQ queries, collects streamed <result> messages by queryid,
    processes the <fin> IQ response, and calls back with parsed results.

    Usage:
        set qid [$client mam query -with juliet@capulet.li -before {} -max 50 \
                      -command [list mycallback]]
        $client mam query -with juliet@capulet.li -start 2020-01-01T00:00:00Z \
                   -fulltext "hello" -max 50 -command [list mycallback]
        $client mam cancel $qid

    The callback receives a dict:
        messages  - list of raw <result> node dicts (as returned by xsearch)
        complete  - 1 if archive start/end reached
        first     - RSM first stanza-id
        last      - RSM last stanza-id

    For MUC archives, pass -to $roomJid (no -with).
    For DM archives on user's server, omit -to (or pass -with $contactJid).
}

snit::type taco_mam {
    option -client -readonly yes

    variable client
    variable Results     ;# array: Results($queryId) = list of <result> node dicts
    variable Callbacks   ;# array: Callbacks($queryId) = command prefix
    variable FieldCache  ;# array: FieldCache($target) = fulltext field name or ""

    variable idCounter 0

    typevariable KnownFulltextFields [list {{urn:xmpp:fulltext:0}fulltext} withtext]

    constructor {args} {
	$self configurelist $args
	set client $options(-client)
	array set Results {}
	array set Callbacks {}
	array set FieldCache {}
    }

    method OnReady {} {}

    method OnDisconnect {} {
	array unset Results
	array unset Callbacks
	array unset FieldCache
    }

    # =================================================================
    # Public API
    # =================================================================

    # query ?-with jid? ?-to jid? ?-start ts? ?-end ts? ?-fulltext str?
    #        ?-before sid? ?-after sid? ?-max n? -command cmd
    # Returns queryId (use as cancellation token)
    # -start/-end are XEP-0082 timestamps (e.g. 2020-01-01T00:00:00Z)
    method query {args} {
	set defaults [dict create -with "" -to "" -start "" -end "" -fulltext "" \
			  -after "" -max "" -command ""]
	set opts [dict merge $defaults $args]

	set queryId mam[incr idCounter]

	# Track -before presence (special: empty string = "before end")
	dict set opts -has-before [dict exists $opts -before]
	if {![dict exists $opts -before]} {
	    dict set opts -before ""
	}

	set Results($queryId) {}
	set Callbacks($queryId) [dict get $opts -command]

	set ftVal [dict get $opts -fulltext]
	set cacheKey [dict get $opts -to]

	if {$ftVal ne "" && ![info exists FieldCache($cacheKey)]} {
	    # Discover fulltext field before sending query
	    set ffArgs [list -command [mymethod OnFieldsThenQuery $queryId $opts]]
	    if {$cacheKey ne ""} {
		lappend ffArgs -to $cacheKey
	    }
	    $self formfields {*}$ffArgs
	} else {
	    $self SendQuery $queryId $opts
	}

	return $queryId
    }

    # discoverFields ?-to jid?
    # Eagerly discover fulltext field name for a target.
    # No-op if already cached.
    method discoverFields {args} {
	set defaults [dict create -to ""]
	set opts [dict merge $defaults $args]
	set toJid [dict get $opts -to]

	if {[info exists FieldCache($toJid)]} {
	    return
	}

	set ffArgs [list -command [mymethod OnDiscoverFields $toJid]]
	if {$toJid ne ""} {
	    lappend ffArgs -to $toJid
	}
	$self formfields {*}$ffArgs
    }

    # fulltextVar ?target?
    # Returns cached fulltext field name for target, or "" if not cached.
    method fulltextVar {{target ""}} {
	if {[info exists FieldCache($target)]} {
	    return $FieldCache($target)
	}
	return ""
    }

    # queryChat $chatJid ?extra-args...?
    # Convenience: routes to MUC or DM based on ?join suffix
    method queryChat {chatJid args} {
	if {[regexp {(.*)\?join$} $chatJid -> mucjid]} {
	    $self query -to $mucjid {*}$args
	} else {
	    $self query -with $chatJid {*}$args
	}
    }

    method cancel {queryId} {
	unset -nocomplain Results($queryId)
	unset -nocomplain Callbacks($queryId)
    }

    # =================================================================
    # Private: Field Discovery & Query Sending
    # =================================================================

    method SendQuery {queryId opts} {
	if {![info exists Callbacks($queryId)]} return

	set withJid  [dict get $opts -with]
	set startVal [dict get $opts -start]
	set endVal   [dict get $opts -end]
	set ftVal    [dict get $opts -fulltext]
	set hasBefore [dict get $opts -has-before]
	set beforeVal [dict get $opts -before]
	set afterVal [dict get $opts -after]
	set maxVal   [dict get $opts -max]

	# Resolve fulltext field name from cache
	set cacheKey [dict get $opts -to]
	if {[info exists FieldCache($cacheKey)]} {
	    set ftVar $FieldCache($cacheKey)
	} else {
	    set ftVar {{urn:xmpp:fulltext:0}fulltext}
	}

	set payload [j query -queryid $queryId -ns urn:xmpp:mam:2 {
	    j x -ns jabber:x:data -type submit {
		j field -var FORM_TYPE -type hidden {
		    j value #body urn:xmpp:mam:2
		}
		if {$withJid ne ""} {
		    j field -var with {
			j value #body $withJid
		    }
		}
		if {$startVal ne ""} {
		    j field -var start {
			j value #body $startVal
		    }
		}
		if {$endVal ne ""} {
		    j field -var end {
			j value #body $endVal
		    }
		}
		if {$ftVal ne "" && $ftVar ne ""} {
		    j field -var $ftVar {
			j value #body $ftVal
		    }
		}
	    }
	    if {$maxVal ne "" || $hasBefore || $afterVal ne ""} {
		j set -ns http://jabber.org/protocol/rsm {
		    if {$maxVal ne ""} {
			j max #body $maxVal
		    }
		    if {$hasBefore} {
			j before #body $beforeVal
		    }
		    if {$afterVal ne ""} {
			j after #body $afterVal
		    }
		}
	    }
	}]

	set iqArgs [list -type set \
			-payload $payload \
			-command [mymethod OnFin $queryId]]
	if {$cacheKey ne ""} {
	    lappend iqArgs -to $cacheKey
	}

	$client iq request {*}$iqArgs
    }

    method OnFieldsThenQuery {queryId opts fields} {
	set cacheKey [dict get $opts -to]
	$self CacheFields $cacheKey $fields

	if {![info exists Callbacks($queryId)]} {
	    return
	}

	$self SendQuery $queryId $opts
    }

    method OnDiscoverFields {cacheKey fields} {
	$self CacheFields $cacheKey $fields
    }

    method CacheFields {cacheKey fields} {
	foreach f $fields {
	    if {$f in $KnownFulltextFields} {
		set FieldCache($cacheKey) $f
		return
	    }
	}
	set FieldCache($cacheKey) ""
    }

    # metadata ?-to jid? -command cmd
    # Queries the MAM archive metadata (oldest/newest message info).
    # Callback receives dict: start_id start_timestamp end_id end_timestamp
    # Empty archive: all values are empty strings.
    # IQ error: dict includes {error 1}.
    method metadata {args} {
	set defaults [dict create -to "" -command ""]
	set opts [dict merge $defaults $args]

	set payload [j metadata -ns urn:xmpp:mam:2]

	set iqArgs [list -type get \
			-payload $payload \
			-command [mymethod OnMetadataResponse [dict get $opts -command]]]
	set toJid [dict get $opts -to]
	if {$toJid ne ""} {
	    lappend iqArgs -to $toJid
	}

	$client iq request {*}$iqArgs
    }

    method OnMetadataResponse {callback stanza} {
	set iqType [xsearch $stanza -get @type]
	if {$iqType eq "error"} {
	    set errText [xsearch $stanza error text -get body]
	    if {$errText eq ""} {
		set errChild [xsearch $stanza error 0 -get node]
		if {$errChild ne ""} {
		    set errText [dict get $errChild tag]
		}
	    }
	    {*}$callback [dict create \
		start_id "" start_timestamp "" \
		end_id "" end_timestamp "" \
		error 1 error_text $errText]
	    return
	}

	set startId ""
	set startTs ""
	set endId ""
	set endTs ""

	set metaNode [xsearch $stanza metadata -ns urn:xmpp:mam:2]
	if {$metaNode ne ""} {
	    set metaNode [lindex $metaNode 0]

	    set startStamp [xsearch $metaNode start -get @timestamp]
	    if {$startStamp ne ""} {
		set startId [xsearch $metaNode start -get @id]
		set startTs [ParseTimestamp $startStamp]
	    }

	    set endStamp [xsearch $metaNode end -get @timestamp]
	    if {$endStamp ne ""} {
		set endId [xsearch $metaNode end -get @id]
		set endTs [ParseTimestamp $endStamp]
	    }
	}

	{*}$callback [dict create \
	    start_id $startId start_timestamp $startTs \
	    end_id $endId end_timestamp $endTs]
    }

    # formfields ?-to jid? -command cmd
    # Queries the MAM archive for supported query filter fields.
    # Callback receives a list of field var names
    # (e.g. {with start end {{urn:xmpp:fulltext:0}fulltext}}).
    # On error, callback receives empty list.
    method formfields {args} {
	set defaults [dict create -to "" -command ""]
	set opts [dict merge $defaults $args]

	set payload [j query -ns urn:xmpp:mam:2]

	set iqArgs [list -type get \
			-payload $payload \
			-command [mymethod OnFormFields [dict get $opts -command]]]
	set toJid [dict get $opts -to]
	if {$toJid ne ""} {
	    lappend iqArgs -to $toJid
	}

	$client iq request {*}$iqArgs
    }

    method OnFormFields {callback stanza} {
	set iqType [xsearch $stanza -get @type]
	if {$iqType eq "error"} {
	    {*}$callback {}
	    return
	}

	set queryNode [xsearch $stanza query -ns urn:xmpp:mam:2]
	if {$queryNode eq ""} {
	    {*}$callback {}
	    return
	}
	set queryNode [lindex $queryNode 0]

	set fields {}
	set formNodes [xsearch $queryNode x -ns jabber:x:data]
	if {[llength $formNodes] > 0} {
	    set formNode [lindex $formNodes 0]
	    xsearch $formNode field -script fieldNode {
		set var [xsearch $fieldNode -get @var]
		if {$var ne "" && $var ne "FORM_TYPE"} {
		    lappend fields $var
		}
	    }
	}

	{*}$callback $fields
    }

    # =================================================================
    # Message Collection (called by messagemod for result stanzas)
    # =================================================================

    # Called when a <message> containing <result xmlns='urn:xmpp:mam:2'> arrives
    method onResultMessage {stanza} {
	set resultNode [xsearch $stanza result -ns urn:xmpp:mam:2]
	if {$resultNode eq ""} { return 0 }
	set resultNode [lindex $resultNode 0]
	set queryId [xsearch $resultNode -get @queryid]
	if {![info exists Results($queryId)]} {
	    return 0
	}

	lappend Results($queryId) $resultNode
	return 1
    }

    # =================================================================
    # IQ Response (fin)
    # =================================================================

    method OnFin {queryId stanza} {
	if {![info exists Callbacks($queryId)]} return

	set callback $Callbacks($queryId)
	set messages {}
	if {[info exists Results($queryId)]} {
	    set messages $Results($queryId)
	}

	# Parse <fin>
	set finNode [xsearch $stanza query -ns urn:xmpp:mam:2]
	if {$finNode eq ""} {
	    set finNode [xsearch $stanza fin -ns urn:xmpp:mam:2]
	}
	set complete 0
	set first ""
	set last ""

	if {$finNode ne ""} {
	    set finNode [lindex $finNode 0]
	    set completeAttr [xsearch $finNode -get @complete]
	    if {$completeAttr eq "true"} {
		set complete 1
	    }
	    set first [xsearch $finNode set -ns http://jabber.org/protocol/rsm first -get body]
	    set last [xsearch $finNode set -ns http://jabber.org/protocol/rsm last -get body]
	}

	# Check IQ type for errors
	set iqType [xsearch $stanza -get @type]

	# Cleanup
	unset -nocomplain Results($queryId)
	unset -nocomplain Callbacks($queryId)

	if {$iqType eq "error"} {
	    {*}$callback [dict create messages {} complete 0 first "" last "" error 1]
	    return
	}

	{*}$callback [dict create \
	    messages $messages \
	    complete $complete \
	    first $first \
	    last $last]
    }
}

# Parse XEP-0203 delay timestamp (ISO 8601) to epoch microseconds
proc ParseTimestamp {stamp} {
    # Format: 2002-09-10T23:08:25Z or 2002-09-10T23:08:25.123456Z
    # Extract fractional seconds before stripping
    set fracUs 0
    if {[regexp {\.(\d+)} $stamp -> frac]} {
	# Pad or truncate to 6 digits (microseconds)
	set frac [string range "${frac}000000" 0 5]
	set fracUs [scan $frac %d]
	regsub {\.\d+} $stamp {} stamp
    }
    if {[catch {clock scan $stamp -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} result]} {
	if {[catch {clock scan $stamp -format "%Y-%m-%dT%H:%M:%S" -gmt 1} result]} {
	    return ""
	}
    }
    return [expr {$result * 1000000 + $fracUs}]
}
