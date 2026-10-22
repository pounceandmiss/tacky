package require sha1
package require base64

if 0 {
    taco_caps - XEP-0115 Entity Capabilities support.

    Generates verification string and <c/> element for outgoing presence.
    Responds to disco#info queries. Processes incoming presence <c/> elements,
    queries and validates remote caps, caches in SQLite.

    Usage:
        Instantiated by Client, not directly.
        $client caps cNode          - get <c/> element dict for inclusion in presence
        $client caps discoFor $ver  - get cached identity + features for a ver hash

    Tacky API:
        tacky caps softwareVersion -acc $acc -to $fullJid -command $cb
}

snit::type taco_caps {
    variable client

    # Our identity and features (hardcoded, updated manually as XEPs are added)
    variable identities {}
    variable features {}
    # Features advertised only while a command says so (a setting):
    # feature -> command prefix returning a boolean. See addFeature.
    variable conditional {}

    # Cached values (invalidated when identity/features change)
    variable cachedQueryNode ""
    variable cachedVer ""

    # ver hashes with a disco#info query in flight, ver -> the JID asked
    variable Resolving -array {}

    # ver hashes waiting for a free slot, ver -> {node jid} to ask, oldest
    # first: Wanted for one our own account or a roster contact named,
    # Strangers for the rest. A ver is in at most one of these and Resolving.
    variable Wanted {}
    variable Strangers {}
    # ver -> {{node jid} ...}: others that named a ver while it was asked or
    # queued, wanted ones first, at most MaxOthers. Asked in turn when the
    # one before gives no answer that hashes to the ver, and told the ver
    # is resolved when one does.
    variable Others -array {}
    typevariable MaxOthers 8

    # ver -> {identities features} read from caps_cache: a hash names its
    # disco#info for good, and every presence and chat list row asks.
    variable Known -array {}
    # vers found not stored, oldest first, so a presence naming one again
    # costs no lookup; past MaxMissing the oldest is forgotten.
    variable Missing {}
    typevariable MaxMissing 4096

    option -client -readonly yes
    option -node -default "https://tacky.example"

    # How many disco#info queries for peers' caps may be in flight at once,
    # how many more may wait for a slot, and how long one waits for its
    # answer (ms) before the slot goes to the next. A transport can present
    # thousands of resources at login, each with a ver of its own; without
    # a bound each was asked at once.
    option -max-queries -default 4
    option -max-queued -default 256
    option -query-timeout -default 20000

    constructor args {
        $self configurelist $args
        set client $options(-client)

        # Default identity
        set identities [list [dict create category client type pc name Tacky lang ""]]

        # Default features
        set features [lsort {
            http://jabber.org/protocol/caps
            http://jabber.org/protocol/disco#info
            urn:xmpp:receipts
            urn:xmpp:ping
            urn:xmpp:chat-markers:0
            urn:xmpp:reactions:0
        }]

        # Register disco#info IQ handler
        $client iq handler get http://jabber.org/protocol/disco#info \
            [mymethod OnDiscoInfoGet]
        $client bus subscribe $self <SessionEnd> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client iq unhandler get http://jabber.org/protocol/disco#info}
    }

    # What waits was named by the session's presences, which go with it;
    # the next session's presences queue what is still unknown. Queries in
    # flight end on their own (an answer or the timeout) and free their
    # slots then.
    method OnDisconnect {args} {
        set Wanted {}
        set Strangers {}
        array unset Others
    }

    # softwareVersion -to jid -command cmd ?-onerror cmd?
    # Queries XEP-0092 Software Version of a target entity.
    # Callback receives dict: name version os; failures go to -onerror.
    tackymethod -async softwareVersion {args} {
        set defaults [dict create -to "" -command "" -onerror ""]
        set opts [dict merge $defaults $args]

        set payload [j query -ns jabber:iq:version]
        set iqArgs [list -type get -payload $payload \
            -command [mymethod OnSoftwareVersion [dict get $opts -command] \
                [dict get $opts -onerror]]]
        set toJid [dict get $opts -to]
        if {$toJid ne ""} {
            lappend iqArgs -to $toJid
        }
        $client iq request {*}$iqArgs
    }

    method OnSoftwareVersion {callback onerror stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            if {$onerror ne ""} { {*}$onerror [stanza_error_text $stanza] }
            return
        }

        set queryNode [xsearch $stanza query -ns jabber:iq:version]
        if {$queryNode eq ""} {
            if {$onerror ne ""} { {*}$onerror "No version info" }
            return
        }
        set queryNode [lindex $queryNode 0]
        set name    [xsearch $queryNode name -get body]
        set version [xsearch $queryNode version -get body]
        set os      [xsearch $queryNode os -get body]
        {*}$callback [dict create name $name version $version os $os]
    }

    # Register an additional disco feature (e.g. namespace+notify for PEP).
    # With -if, the feature is advertised only while {*}$cmd is true; call
    # `refresh` when what it reads changes.
    method addFeature {feat args} {
        if {[dict exists $args -if]} {
            dict set conditional $feat [dict get $args -if]
            set cachedVer ""
            set cachedQueryNode ""
            return
        }
        if {$feat ni $features} {
            lappend features $feat
            set features [lsort $features]
            # Invalidate cached ver/query so they get rebuilt
            set cachedVer ""
            set cachedQueryNode ""
        }
    }

    # The features advertised now: the fixed ones and the conditional ones
    # whose command holds.
    method CurrentFeatures {} {
        set out $features
        dict for {feat cmd} $conditional {
            if {![catch {{*}$cmd} on] && [string is true -strict $on]} {
                lappend out $feat
            }
        }
        lsort -unique $out
    }

    # Rebuild after a conditional feature's command may have changed, and
    # announce the new caps if they did change and a session is up.
    method refresh {} {
        set old $cachedVer
        set cachedVer ""
        set cachedQueryNode ""
        $self BuildIfNeeded
        if {$old eq "" || $old eq $cachedVer} return
        if {[$client conn state] ne "connected"} return
        $client write [j presence {j #as-is [$self cNode]}]
    }

    # Return <c/> element dict for inclusion in outgoing presence
    method cNode {} {
        $self BuildIfNeeded
        return [j c -ns http://jabber.org/protocol/caps \
                    -hash sha-1 \
                    -node $options(-node) \
                    -ver $cachedVer]
    }

    # Cached identity and features for a verification hash, or {} if unknown.
    method discoFor {ver} {
        if {$ver eq ""} {
            return {}
        }
        set row [$self Cached $ver]
        if {$row eq ""} {
            return {}
        }
        lassign $row identities features
        set identity [PreferredIdentity $identities]
        return [dict merge $identity [dict create features $features]]
    }

    # {identities features} stored for $ver, or "" when not resolved.
    method Cached {ver} {
        if {[info exists Known($ver)]} {
            return $Known($ver)
        }
        if {[dict exists $Missing $ver]} {
            return ""
        }
        $client db eval {
            SELECT identities, features FROM caps_cache WHERE ver=$ver
        } row {
            return [set Known($ver) [list $row(identities) $row(features)]]
        }
        if {[dict size $Missing] >= $MaxMissing} {
            dict for {old _} $Missing break
            dict unset Missing $old
        }
        dict set Missing $ver 1
        return ""
    }

    # Of several identities, the client one names the software.
    proc PreferredIdentity {identities} {
        set chosen [lindex $identities 0]
        foreach identity $identities {
            if {[dict get $identity category] eq "client"} {
                set chosen $identity
                break
            }
        }
        if {$chosen eq ""} {
            return {name "" category "" type ""}
        }
        return $chosen
    }

    method BuildIfNeeded {} {
        if {$cachedVer ne ""} return
        $self BuildQueryNode
    }

    method BuildQueryNode {} {
        set cachedQueryNode [j query -ns http://jabber.org/protocol/disco#info \
                                 -node PLACEHOLDER {
            foreach id $identities {
                set idArgs {}
                foreach key {category type name} {
                    set val [dict get $id $key]
                    if {$val ne ""} {
                        lappend idArgs -$key $val
                    }
                }
                set lang [dict get $id lang]
                if {$lang ne ""} {
                    lappend idArgs -xml:lang $lang
                }
                j identity {*}$idArgs
            }
            foreach feat [$self CurrentFeatures] {
                j feature -var $feat
            }
        }]
        set cachedVer [$self HashDiscoQuery $cachedQueryNode]
        dict set cachedQueryNode attrs node "$options(-node)#$cachedVer"
    }

    method VerificationString {queryNode} {
        set s_parts {}

        # 1. Identities sorted by category/type/lang/name
        lappend s_parts {*}[lsort [lmap identity_node [xsearch $queryNode identity] {
            set attrs [dict get $identity_node attrs]
            set lang ""
            foreach langKey {{http://www.w3.org/XML/1998/namespace lang} xml:lang} {
                if {[dict exists $attrs $langKey]} {
                    set lang [dict get $attrs $langKey]
                    break
                }
            }
            join [list \
                      [expr {[dict exists $attrs category] ? [dict get $attrs category] : ""}] \
                      [expr {[dict exists $attrs type] ? [dict get $attrs type] : ""}] \
                      $lang \
                      [expr {[dict exists $attrs name] ? [dict get $attrs name] : ""}] \
                 ] /
        }]]

        # 2. Features sorted
        lappend s_parts {*}[lsort [lmap n [xsearch $queryNode feature] {
            dict get $n attrs var
        }]]

        # 3. Data forms sorted by FORM_TYPE
        set forms [xsearch $queryNode x -ns jabber:x:data]
        set forms [lsort -command {
            apply {{a b} {
                string compare [::taco_caps::GetFormType $a] [::taco_caps::GetFormType $b]
            }}
        } $forms]
        foreach form $forms {
            lappend s_parts [GetFormType $form]
            # Get all fields except FORM_TYPE, sorted by var
            set fields {}
            xsearch $form field -script fieldNode {
                set var [xsearch $fieldNode -get @var]
                if {$var ne "FORM_TYPE"} {
                    lappend fields $fieldNode
                }
            }
            set fields [lsort -command {
                apply {{a b} {
                    string compare [dict get $a attrs var] [dict get $b attrs var]
                }}
            } $fields]
            foreach field $fields {
                lappend s_parts [dict get $field attrs var]
                lappend s_parts {*}[lsort [lmap valueNode [xsearch $field value] {
                    dict get $valueNode body
                }]]
            }
        }

        # Build the string with '<' delimiter
        set s ""
        foreach part $s_parts {
            append s $part<
        }
        return $s
    }

    # Why an answer cannot be hashed, or "": a <feature/> or a form field
    # with no var has nothing for the verification string.
    proc Malformed {queryNode} {
        foreach n [xsearch $queryNode feature] {
            if {[xsearch $n -get @var] eq ""} { return "a feature with no var" }
        }
        foreach form [xsearch $queryNode x -ns jabber:x:data] {
            foreach field [xsearch $form field] {
                if {[xsearch $field -get @var] eq ""} { return "a form field with no var" }
            }
        }
        return ""
    }

    proc GetFormType {form} {
        set valNodes [xsearch $form field @var FORM_TYPE value]
        if {[llength $valNodes] > 0} {
            return [dict get [lindex $valNodes 0] body]
        }
        return ""
    }

    method HashDiscoQuery {queryNode} {
        ::base64::encode [::sha1::sha1 -bin [encoding convertto utf-8 [$self VerificationString $queryNode]]]
    }

    method OnDiscoInfoGet {stanza} {
        $self BuildIfNeeded
        $client iq respond -for $stanza -payload $cachedQueryNode
    }

    method OnPresence {stanza} {
        set cNodes [xsearch $stanza c -ns http://jabber.org/protocol/caps]
        if {[llength $cNodes] == 0} return

        set cNode [lindex $cNodes 0]
        set hash [xsearch $cNode -get @hash]
        set node [xsearch $cNode -get @node]
        set ver  [xsearch $cNode -get @ver]
        set from [xsearch $stanza -get @from]

        if {$ver eq "" || $from eq ""} return
        # Only a SHA-1 ver can be checked against the answer (the legacy
        # form has no @hash); any other would be asked again on every
        # presence, the answer never matching.
        if {$hash ne "sha-1"} return

        # Nothing is cached until the first reply lands, so without this a
        # rosterful of contacts running one client asks each of them.
        if {[info exists Resolving($ver)] || [dict exists $Wanted $ver]} {
            $self NoteOther $ver $node $from
            return
        }
        if {[dict exists $Strangers $ver]} {
            if {[$self IsWanted $from]} {
                # A contact names a ver a stranger queued: it moves up, and
                # is asked of the contact, the stranger kept to fall back on.
                set Others($ver) [list [dict get $Strangers $ver] \
                    {*}[expr {[info exists Others($ver)] ? $Others($ver) : {}}]]
                dict unset Strangers $ver
                dict set Wanted $ver [list $node $from]
            } else {
                $self NoteOther $ver $node $from
            }
            return
        }

        if {[$self Cached $ver] ne ""} return

        $self Enqueue $ver $node $from
    }

    # $from named $ver, which is asked of someone else or waits: kept to
    # ask next should that one not answer, wanted senders first.
    method NoteOther {ver node from} {
        if {[info exists Resolving($ver)] && $Resolving($ver) eq $from} return
        foreach query [list {*}[dict getdef $Wanted $ver {}] \
                {*}[dict getdef $Strangers $ver {}]] {
            if {[lindex $query 1] eq $from} return
        }
        set others [expr {[info exists Others($ver)] ? $Others($ver) : {}}]
        foreach o $others { if {[lindex $o 1] eq $from} return }
        if {[llength $others] >= $MaxOthers} return
        if {[$self IsWanted $from]} {
            set others [linsert $others 0 [list $node $from]]
        } else {
            lappend others [list $node $from]
        }
        set Others($ver) $others
    }

    # Whether a presence from $from is worth asking before a stranger's:
    # our own resources or a roster contact's. (An occupant's presence
    # never gets here: client.tcl keeps it for muc.)
    method IsWanted {from} {
        if {![jid valid $from]} { return 0 }
        set bare [jid norm [jid bare $from]]
        set own [$client cget -jid]
        if {$own ne "" && [jid matches-bare $bare $own]} { return 1 }
        expr {[$client roster subscription -jid $bare] ne ""}
    }

    # Ask for $ver now when a slot is free, or queue it. The queue holds
    # -max-queued vers between both lists; when it is full the newcomer is
    # what goes: a stranger's is dropped, and a wanted one takes the place
    # of the newest stranger's, or is dropped when there is none. A dropped
    # ver is forgotten: the next presence naming it queues it again.
    method Enqueue {ver node from} {
        set query [list $node $from]
        if {[array size Resolving] < $options(-max-queries)
                && [dict size $Wanted] == 0 && [dict size $Strangers] == 0} {
            $self Ask $ver $query
            return
        }
        set wanted [$self IsWanted $from]
        if {[dict size $Wanted] + [dict size $Strangers] >= $options(-max-queued)} {
            if {!$wanted || [dict size $Strangers] == 0} {
                jlog debug "caps: queue full, $ver from $from not asked"
                return
            }
            set dropped [lindex [dict keys $Strangers] end]
            dict unset Strangers $dropped
            unset -nocomplain Others($dropped)
        }
        if {$wanted} {
            dict set Wanted $ver $query
        } else {
            dict set Strangers $ver $query
        }
    }

    # Fill the free slots from the queue, wanted vers first.
    method Pump {} {
        while {[array size Resolving] < $options(-max-queries)} {
            if {[dict size $Wanted]} {
                set q Wanted
            } elseif {[dict size $Strangers]} {
                set q Strangers
            } else {
                return
            }
            dict for {ver query} [set $q] break
            dict unset $q $ver
            $self Ask $ver $query
        }
    }

    method Ask {ver query} {
        lassign $query node from
        set Resolving($ver) $from
        $client iq request \
            -to $from \
            -timeout $options(-query-timeout) \
            -payload [j query -ns http://jabber.org/protocol/disco#info \
                          -node "$node#$ver"] \
            -command [mymethod OnDiscoInfoResult $ver $from]
    }

    # An answer, an error or the timeout: each frees the slot for the next.
    method OnDiscoInfoResult {expectedVer from stanza} {
        unset -nocomplain Resolving($expectedVer)
        set stored 0
        try {
            set stored [$self TakeDiscoInfo $expectedVer $from $stanza]
        } finally {
            set others [expr {[info exists Others($expectedVer)] ? $Others($expectedVer) : {}}]
            unset -nocomplain Others($expectedVer)
            if {$stored} {
                # The others named the same ver: theirs is resolved too.
                foreach o $others {
                    $client bus publish <CapsResolved> -jid [lindex $o 1]
                }
            } elseif {[llength $others]} {
                # No answer that hashes to it: the next who named it is asked.
                set rest [lassign $others next]
                if {[llength $rest]} { set Others($expectedVer) $rest }
                $self Ask $expectedVer $next
            }
            $self Pump
        }
    }

    # 1 when the answer was the ver's and is stored, else 0.
    method TakeDiscoInfo {expectedVer from stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} { return 0 }

        set queryNode [lindex [xsearch $stanza query] 0]
        if {$queryNode eq ""} { return 0 }

        set why [Malformed $queryNode]
        if {$why ne ""} {
            jlog debug "Caps answer from $from for $expectedVer has $why; not cached"
            return 0
        }

        # Validate: recompute hash and compare
        set computedVer [$self HashDiscoQuery $queryNode]
        if {$computedVer ne $expectedVer} {
            jlog debug "Caps hash mismatch from $from: expected $expectedVer got $computedVer"
            return 0
        }

        # Extract and store
        set featureList [lsort [xsearch $queryNode feature -gather @var]]
        set featuresStr [join $featureList " "]
        set node [xsearch $queryNode -get @node]
        set theirIdentities [lmap identityNode [xsearch $queryNode identity] {
            dict create name [xsearch $identityNode -get @name] \
                category [xsearch $identityNode -get @category] \
                type [xsearch $identityNode -get @type]
        }]

        $client db eval {
            INSERT OR REPLACE INTO caps_cache(ver, node, identities, features)
            VALUES ($expectedVer, $node, $theirIdentities, $featuresStr)
        }
        set Known($expectedVer) [list $theirIdentities $featuresStr]
        dict unset Missing $expectedVer

        $client bus publish <CapsResolved> -jid $from
        return 1
    }
}
