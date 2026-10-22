# Unit tests for capsmod (XEP-0115)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set caps_common [tacky_env -stub-emit 1 -mock conn -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
}]

test caps-verstr-1 {XEP-0115 example verification string} {*}$caps_common -body {
    # Build the XEP example disco#info query node using j
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {http://psi-im.org#q07IKJEyjvHSyhy//CH0CxmKi8w=} {
        j identity -xml:lang en -category client -name {Psi 0.11} -type pc
        j identity -xml:lang el -category client -name "\u03A8 0.11" -type pc
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/disco#items
        j feature -var http://jabber.org/protocol/muc
        j x -ns jabber:x:data -type result {
            j field -var FORM_TYPE -type hidden {
                j value -body urn:xmpp:dataforms:softwareinfo
            }
            j field -var ip_version -type text-multi {
                j value -body ipv4
                j value -body ipv6
            }
            j field -var os {
                j value -body Mac
            }
            j field -var os_version {
                j value -body 10.5.1
            }
            j field -var software {
                j value -body Psi
            }
            j field -var software_version {
                j value -body 0.11
            }
        }
    }]

    c.caps VerificationString $queryNode
} -result "client/pc/el/\u03A8 0.11<client/pc/en/Psi 0.11<http://jabber.org/protocol/caps<http://jabber.org/protocol/disco#info<http://jabber.org/protocol/disco#items<http://jabber.org/protocol/muc<urn:xmpp:dataforms:softwareinfo<ip_version<ipv4<ipv6<os<Mac<os_version<10.5.1<software<Psi<software_version<0.11<"

test caps-hash-1 {XEP-0115 example hash} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {http://psi-im.org#q07IKJEyjvHSyhy//CH0CxmKi8w=} {
        j identity -xml:lang en -category client -name {Psi 0.11} -type pc
        j identity -xml:lang el -category client -name "\u03A8 0.11" -type pc
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/disco#items
        j feature -var http://jabber.org/protocol/muc
        j x -ns jabber:x:data -type result {
            j field -var FORM_TYPE -type hidden {
                j value -body urn:xmpp:dataforms:softwareinfo
            }
            j field -var ip_version -type text-multi {
                j value -body ipv4
                j value -body ipv6
            }
            j field -var os {
                j value -body Mac
            }
            j field -var os_version {
                j value -body 10.5.1
            }
            j field -var software {
                j value -body Psi
            }
            j field -var software_version {
                j value -body 0.11
            }
        }
    }]

    c.caps HashDiscoQuery $queryNode
} -result {q07IKJEyjvHSyhy//CH0CxmKi8w=}

test caps-hash-2 {Cheogram real-world verification hash} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {https://cheogram.com#hAx0qhppW5/ZjrpXmbXW0F2SJVM=} {
        j identity -type phone -name Cheogram -category client
        j feature -var eu.siacs.conversations.axolotl.devicelist+notify
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/chatstates
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/muc
        j feature -var http://jabber.org/protocol/nick+notify
        j feature -var http://jabber.org/protocol/xhtml-im
        j feature -var jabber:iq:version
        j feature -var jabber:x:conference
        j feature -var jabber:x:oob
        j feature -var urn:xmpp:avatar:metadata+notify
        j feature -var urn:xmpp:bob
        j feature -var urn:xmpp:bookmarks:1+notify
        j feature -var urn:xmpp:chat-markers:0
        j feature -var urn:xmpp:idle:1
        j feature -var urn:xmpp:jingle-message:0
        j feature -var urn:xmpp:jingle:1
        j feature -var urn:xmpp:jingle:apps:dtls:0
        j feature -var urn:xmpp:jingle:apps:file-transfer:5
        j feature -var urn:xmpp:jingle:apps:rtp:1
        j feature -var urn:xmpp:jingle:apps:rtp:audio
        j feature -var urn:xmpp:jingle:apps:rtp:video
        j feature -var urn:xmpp:jingle:jet-omemo:0
        j feature -var urn:xmpp:jingle:jet:0
        j feature -var urn:xmpp:jingle:transports:ibb:1
        j feature -var urn:xmpp:jingle:transports:ice-udp:1
        j feature -var urn:xmpp:jingle:transports:s5b:1
        j feature -var urn:xmpp:jingle:transports:webrtc-datachannel:1
        j feature -var urn:xmpp:mds:displayed:0+notify
        j feature -var urn:xmpp:message-correct:0
        j feature -var urn:xmpp:ping
        j feature -var urn:xmpp:receipts
        j feature -var urn:xmpp:time
    }]

    c.caps HashDiscoQuery $queryNode
} -result {hAx0qhppW5/ZjrpXmbXW0F2SJVM=}

test caps-disco-identity {a resolved hash reports the client identity, not the first} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category pubsub -type pep
        j identity -category client -type phone -name Conversations
        j feature -var urn:xmpp:receipts
    }]
    set ver [c.caps HashDiscoQuery $queryNode]
    c.conn feed [j presence -from peer@example.com/phone {
        j c -ns http://jabber.org/protocol/caps -hash sha-1 \
            -node http://conversations.im -ver $ver
    }]
    c.conn feed [j iq -type result -from peer@example.com/phone \
        -id [xsearch [lindex [c.conn get_written] end] -get @id] {
            j #as-is $queryNode
        }]
    c.caps discoFor $ver
} -result {name Conversations category client type phone features urn:xmpp:receipts}

test caps-disco-coalesced {presences sharing an unresolved hash ask once} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name Tacky
        j feature -var urn:xmpp:receipts
    }]
    set ver [c.caps HashDiscoQuery $queryNode]
    set before [llength [c.conn get_written]]
    foreach nick {one two three} {
        c.conn feed [j presence -from room@conference.example.com/$nick {
            j c -ns http://jabber.org/protocol/caps -hash sha-1 \
                -node http://tacky.example -ver $ver
        }]
    }
    set queries 0
    foreach s [lrange [c.conn get_written] $before end] {
        if {[llength [xsearch $s query \
                -ns http://jabber.org/protocol/disco#info]] > 0} {
            incr queries
        }
    }
    set queries
} -result 1

# Only a contact's presence is kept with its caps (presence resources); a
# room occupant's is muc's, and nothing reads its caps, so none is asked.
test caps-occupant-not-asked {a room occupant's caps are not asked for} {*}$caps_common -body {
    set before [llength [c.conn get_written]]
    c.conn feed [j presence -from room@conference.example.com/someone {
        j c -ns http://jabber.org/protocol/caps -hash sha-1 \
            -node http://tacky.example -ver occupant-ver=
        j x -ns http://jabber.org/protocol/muc#user {
            j item -affiliation none -role participant
        }
    }]
    llength [lmap s [lrange [c.conn get_written] $before end] {
        if {![llength [xsearch $s query -ns http://jabber.org/protocol/disco#info]]} continue
        set s
    }]
} -result 0

# A <feature/> or a form <field/> with no var is a malformed answer: refused,
# not a throw on every presence naming the ver.
test caps-feature-without-var-is-not-cached {an answer with a bare <feature/>, or a form field with no var, caches nothing and does not throw} {*}$caps_common -body {
    set ver [c.caps HashDiscoQuery [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name X
        j feature -var urn:xmpp:jingle:1
    }]]
    set bare [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name X
        j feature
    }]
    set noVarField [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name X
        j x -ns jabber:x:data -type result {
            j field -var FORM_TYPE -type hidden { j value -body urn:x }
            j field { j value -body y }
        }
    }]
    set codes {}
    foreach {who answer} [list a@example.com/x $bare b@example.com/y $noVarField] {
        c.conn feed [j presence -from $who {
            j c -ns http://jabber.org/protocol/caps -hash sha-1 -node http://x -ver $ver
        }]
        set id [xsearch [lindex [c.conn get_written] end] -get @id]
        lappend codes [catch {
            c.conn feed [j iq -type result -from $who -id $id { j #as-is $answer }]
        }]
    }
    list $codes [c.caps discoFor $ver]
} -result {{0 0} {}}

test caps-disco-unknown {an unresolved hash reports nothing} {*}$caps_common -body {
    c.caps discoFor sha-1-nobody-published-this
} -result {}

test caps-non-sha1-ver-is-not-asked {a ver under a hash this client cannot check, or with no hash, is not asked for} {*}$caps_common -body {
    c.conn clear
    c.conn feed [j presence -from peer@example.com/a {
        j c -ns http://jabber.org/protocol/caps -hash sha-256 -node http://x -ver abc=
    }]
    c.conn feed [j presence -from peer@example.com/b {
        j c -ns http://jabber.org/protocol/caps -node http://x -ext legacy -ver 1.0
    }]
    c.conn get_written
} -result {}

# A ver is not bound to the first JID that named it; when that one gives no
# answer, the next who named it is asked, and both are told.
test caps-ver-asked-of-the-next-who-named-it {a ver whose first JID answers an error is asked of another that named it, which resolves it for both} {*}$caps_common -body {
    set q [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name X
        j feature -var urn:xmpp:jingle:1
    }]
    set ver [c.caps HashDiscoQuery $q]
    set ::capsq_resolved {}
    c bus subscribe capsq_test <CapsResolved> {apply {{args} {lappend ::capsq_resolved [dict get $args -jid]}}}
    c.conn clear
    foreach who {lurker@example.com/x friend@example.com/y other@example.com/z} {
        c.conn feed [j presence -from $who {
            j c -ns http://jabber.org/protocol/caps -hash sha-1 -node http://example.com -ver $ver
        }]
    }
    set first [lindex [c.conn get_written] end]
    c.conn feed [j iq -type error -from lurker@example.com/x -id [xsearch $first -get @id] {
        j error -type cancel { j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas }
    }]
    set second [lindex [c.conn get_written] end]
    c.conn feed [j iq -type result -from friend@example.com/y -id [xsearch $second -get @id] {
        j #as-is $q
    }]
    c bus unsubscribe capsq_test
    list [llength [c.conn get_written]] [xsearch $first -get @to] [xsearch $second -get @to] \
        [dict get [c.caps discoFor $ver] features] $::capsq_resolved
} -result {2 lurker@example.com/x friend@example.com/y urn:xmpp:jingle:1 {friend@example.com/y other@example.com/z}}

# -- a presence flood: queries bounded, misses remembered ----------------------

# A disco#info naming client X$i, and the ver it hashes to.
proc capsq_query {i} {
    j query -ns http://jabber.org/protocol/disco#info {
        j identity -category client -type pc -name X$i
    }
}
proc capsq_ver {i} { c.caps HashDiscoQuery [capsq_query $i] }

# Present client X$i from $from.
proc capsq_presence {i {from ""}} {
    if {$from eq ""} { set from peer$i@example.com/x }
    c.conn feed [j presence -from $from {
        j c -ns http://jabber.org/protocol/caps -hash sha-1 \
            -node http://example.com -ver [capsq_ver $i]
    }]
}

# The caps queries written so far (disco#info with a node), oldest first,
# as {to ver id}.
proc capsq_asked {} {
    set out {}
    foreach s [c.conn get_written] {
        if {[dict get $s tag] ne "iq"} continue
        set node [xsearch $s query -ns http://jabber.org/protocol/disco#info -get @node]
        if {$node eq ""} continue
        lappend out [list [xsearch $s -get @to] [lindex [split $node #] end] [xsearch $s -get @id]]
    }
    return $out
}

# Answer the query asked for client X$i, with its disco#info or an error.
proc capsq_answer {i {type result}} {
    set ver [capsq_ver $i]
    foreach a [capsq_asked] {
        lassign $a to v id
        if {$v ne $ver} continue
        if {$type eq "result"} {
            c.conn feed [j iq -type result -from $to -id $id { j #as-is [capsq_query $i] }]
        } else {
            c.conn feed [j iq -type error -from $to -id $id {
                j error -type cancel { j item-not-found -ns urn:ietf:params:xml:ns:xmpp-stanzas }
            }]
        }
        return
    }
    error "client X$i was not asked"
}

# How many caps_cache reads $script makes.
proc capsq_count_lookups {script} {
    set ::capsq_lookups 0
    set db [c cget -db]
    set cb [list apply {{cmd op} {
        if {[string match *caps_cache* $cmd] && [string match *SELECT* $cmd]} {
            incr ::capsq_lookups
        }
    }}]
    trace add execution $db enter $cb
    try {
        uplevel 1 $script
    } finally {
        trace remove execution $db enter $cb
    }
    return $::capsq_lookups
}

test caps-flood-asks-at-most-max-queries {a hundred presences with a hundred unknown vers ask four at once, the first four, and queue the rest} {*}$caps_common -body {
    c.conn clear
    for {set i 1} {$i <= 100} {incr i} { capsq_presence $i }
    set asked [capsq_asked]
    list [c.caps cget -max-queries] [llength $asked] \
        [expr {[lmap a $asked { lindex $a 1 }] eq [lmap i {1 2 3 4} { capsq_ver $i }]}]
} -result {4 4 1}

test caps-flood-an-answer-releases-the-next {a result and an error each free their slot for the oldest queued ver} {*}$caps_common -body {
    c.conn clear
    for {set i 1} {$i <= 10} {incr i} { capsq_presence $i }
    set out [llength [capsq_asked]]
    capsq_answer 1
    lappend out [llength [capsq_asked]] [expr {[lindex [capsq_asked] end 1] eq [capsq_ver 5]}]
    capsq_answer 2 error
    lappend out [llength [capsq_asked]] [expr {[lindex [capsq_asked] end 1] eq [capsq_ver 6]}] \
        [expr {[c.caps discoFor [capsq_ver 1]] ne ""}]
} -result {4 5 1 6 1 1}

# Request timers run only while a session is up.
set caps_live_common [tacky_env -stub-emit 1 -mock conn -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
} -bound-jid user@test.example.com/res]

test caps-flood-a-timeout-releases-the-next {a query left unanswered past -query-timeout frees its slot} {*}$caps_live_common -body {
    c.caps configure -query-timeout 50
    c.conn clear
    for {set i 1} {$i <= 8} {incr i} { capsq_presence $i }
    set out [llength [capsq_asked]]
    after 200 { set ::capsq_waited 1 }
    vwait ::capsq_waited
    lappend out [llength [capsq_asked]]
} -result {4 8}

test caps-flood-queue-is-bounded {past -max-queued waiting vers a stranger's newest are dropped, and a dropped ver presented again is asked} {*}$caps_common -body {
    c.caps configure -max-queued 10
    c.conn clear
    for {set i 1} {$i <= 100} {incr i} { capsq_presence $i }
    # Answer everything as it is asked: 4 in flight and 10 queued are all
    # that were kept, in the order they came.
    set n 0
    while {$n < [llength [capsq_asked]]} {
        set ver [lindex [capsq_asked] $n 1]
        for {set i 1} {[capsq_ver $i] ne $ver} {incr i} {}
        capsq_answer $i
        incr n
    }
    set kept [llength [capsq_asked]]
    set inOrder [expr {[lmap a [capsq_asked] { lindex $a 1 }] eq [lmap i {1 2 3 4 5 6 7 8 9 10 11 12 13 14} { capsq_ver $i }]}]
    capsq_presence 50
    list $kept $inOrder [llength [capsq_asked]] [lindex [capsq_asked] end 0]
} -result {14 1 15 peer50@example.com/x}

test caps-flood-contacts-first {a roster contact's ver is asked before strangers queued earlier, takes a full queue's newest stranger's place, and a ver a stranger queued moves up when a contact names it} {*}$caps_common -body {
    c roster StoreItem [j item -jid friend@example.com -subscription both]
    c roster StoreItem [j item -jid mate@example.com -subscription to]
    c.caps configure -max-queued 4
    c.conn clear
    for {set i 1} {$i <= 8} {incr i} { capsq_presence $i }
    # In flight 1-4, queued 5-8 (full). The contact's 20 displaces 8; mate
    # names 6, queued for a stranger, which moves up behind 20.
    capsq_presence 20 friend@example.com/phone
    capsq_presence 6 mate@example.com/pc
    foreach i {1 2 3 4} { capsq_answer $i error }
    lmap a [lrange [capsq_asked] 4 end] { lindex $a 0 }
} -result {friend@example.com/phone mate@example.com/pc peer5@example.com/x peer7@example.com/x}

test caps-miss-is-remembered {a ver found missing is not looked up again, and stops being missing once its answer is stored} {*}$caps_common -body {
    set ver [capsq_ver 1]
    set first [capsq_count_lookups { c.caps discoFor $ver }]
    set again [capsq_count_lookups {
        c.caps discoFor $ver
        c.caps discoFor $ver
    }]
    c.conn clear
    capsq_presence 1
    capsq_answer 1
    set after [capsq_count_lookups { set d [c.caps discoFor $ver] }]
    list $first $again $after [dict get $d name]
} -result {1 0 0 X1}

test caps-flood-repeated-presence-costs-no-lookup {a flood that names the same unknown vers again reads the store once per ver} {*}$caps_common -body {
    c.caps configure -max-queued 0
    capsq_count_lookups {
        foreach round {1 2 3} {
            for {set i 1} {$i <= 20} {incr i} { capsq_presence $i }
        }
    }
} -result 20

test caps-flood-queue-goes-with-the-session {a session end drops what waits; queries in flight still end and nothing queued is asked after} {*}$caps_common -body {
    c.conn clear
    for {set i 1} {$i <= 10} {incr i} { capsq_presence $i }
    c bus publish <SessionEnd>
    foreach i {1 2 3 4} { capsq_answer $i }
    set n [llength [capsq_asked]]
    capsq_presence 7
    list $n [llength [capsq_asked]] [dict get [c.caps discoFor [capsq_ver 4]] name]
} -result {4 5 X4}
