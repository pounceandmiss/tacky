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
        $client caps getFeatures $ver - get cached feature list for a ver hash
}

snit::type taco_caps {
    variable client

    # Our identity and features (hardcoded, updated manually as XEPs are added)
    variable identities {}
    variable features {}

    # Cached values (invalidated when identity/features change)
    variable cachedQueryNode ""
    variable cachedVer ""

    option -client -readonly yes
    option -node -default "https://tacky.example"

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $self Migrate

        # Default identity
        set identities [list [dict create category client type pc name Tacky lang ""]]

        # Default features
        set features [lsort {
            http://jabber.org/protocol/caps
            http://jabber.org/protocol/disco#info
            urn:xmpp:receipts
            urn:xmpp:chat-markers:0
        }]

        # Register disco#info IQ handler
        $client iq handler get http://jabber.org/protocol/disco#info \
            [mymethod OnDiscoInfoGet]
    }

    destructor {
        catch {$client iq unhandler get http://jabber.org/protocol/disco#info}
    }

    # softwareVersion -to jid -command cmd
    # Queries XEP-0092 Software Version of a target entity.
    # Callback receives dict: name version os (or error 1 error_text msg).
    method softwareVersion {args} {
        set defaults [dict create -to "" -command ""]
        set opts [dict merge $defaults $args]

        set payload [j query -ns jabber:iq:version]
        set iqArgs [list -type get -payload $payload \
            -command [mymethod OnSoftwareVersion [dict get $opts -command]]]
        set toJid [dict get $opts -to]
        if {$toJid ne ""} {
            lappend iqArgs -to $toJid
        }
        $client iq request {*}$iqArgs
    }

    method OnSoftwareVersion {callback stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            set errText [xsearch $stanza error text -get body]
            if {$errText eq ""} {
                set errChild [xsearch $stanza error 0 -get node]
                if {$errChild ne ""} {
                    set errText [dict get $errChild tag]
                }
            }
            {*}$callback [dict create name "" version "" os "" \
                error 1 error_text $errText]
            return
        }

        set queryNode [xsearch $stanza query -ns jabber:iq:version]
        if {$queryNode eq ""} {
            {*}$callback [dict create name "" version "" os "" \
                error 1 error_text "No version info"]
            return
        }
        set queryNode [lindex $queryNode 0]
        set name    [xsearch $queryNode name -get body]
        set version [xsearch $queryNode version -get body]
        set os      [xsearch $queryNode os -get body]
        {*}$callback [dict create name $name version $version os $os]
    }

    # Register an additional disco feature (e.g. namespace+notify for PEP)
    method addFeature {feat} {
        if {$feat ni $features} {
            lappend features $feat
            set features [lsort $features]
            # Invalidate cached ver/query so they get rebuilt
            set cachedVer ""
            set cachedQueryNode ""
        }
    }

    # Return <c/> element dict for inclusion in outgoing presence
    method cNode {} {
        $self BuildIfNeeded
        return [j c -ns http://jabber.org/protocol/caps \
                    -hash sha-1 \
                    -node $options(-node) \
                    -ver $cachedVer]
    }

    # Look up cached features for a verification hash
    method getFeatures {ver} {
        set row [$client db eval {SELECT features FROM caps_cache WHERE ver=$ver}]
        if {$row ne ""} {
            return [lindex $row 0]
        }
        return {}
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
            foreach feat $features {
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

        # Check cache
        set cached [$client db eval {SELECT count(*) FROM caps_cache WHERE ver=$ver}]
        if {$cached} return

        # Query the entity for its disco#info
        set queryNode "$node#$ver"
        $client iq request \
            -to $from \
            -payload [j query -ns http://jabber.org/protocol/disco#info \
                          -node $queryNode] \
            -command [mymethod OnDiscoInfoResult $ver $from]
    }

    method OnDiscoInfoResult {expectedVer from stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} return

        set queryNode [lindex [xsearch $stanza query] 0]
        if {$queryNode eq ""} return

        # Validate: recompute hash and compare
        set computedVer [$self HashDiscoQuery $queryNode]
        if {$computedVer ne $expectedVer} {
            jlog debug "Caps hash mismatch from $from: expected $expectedVer got $computedVer"
            return
        }

        # Extract and store
        set featureList [lsort [xsearch $queryNode feature -gather @var]]
        set featuresStr [join $featureList " "]
        set node [xsearch $queryNode -get @node]

        $client db eval {
            INSERT OR REPLACE INTO caps_cache(ver, node, features)
            VALUES ($expectedVer, $node, $featuresStr)
        }
    }

    method Migrate {} {
        $client db eval {
            CREATE TABLE IF NOT EXISTS caps_cache(
                ver TEXT PRIMARY KEY,
                node TEXT,
                features TEXT
            );
        }
    }
}
