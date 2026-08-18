# Unit tests for taco_presence (per-resource presence, XEP-0319, XEP-0115)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set presence_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# The disco#info a contact's caps hash resolves to.
proc disco_query {} {
    j query -ns http://jabber.org/protocol/disco#info {
        j identity -category pubsub -type pep
        j identity -category client -type phone -name Conversations
        j feature -var urn:xmpp:omemo:2
        j feature -var urn:xmpp:receipts
    }
}

proc caps_ver {} {
    c.caps HashDiscoQuery [disco_query]
}

# Available presence, optionally idle and/or advertising caps.
proc presence_available {from args} {
    set opts [dict merge {since "" ver "" node http://conversations.im} $args]
    set since [dict get $opts since]
    set ver [dict get $opts ver]
    set node [dict get $opts node]
    j presence -from $from {
        j show -body away
        j priority -body 3
        if {$since ne ""} {
            j idle -ns urn:xmpp:idle:1 -since $since
        }
        if {$ver ne ""} {
            j c -ns http://jabber.org/protocol/caps -hash sha-1 \
                -node $node -ver $ver
        }
    }
}

# Answer the disco#info query the last presence provoked.
proc answer_disco {from} {
    set id [xsearch [lindex [c.conn get_written] end] -get @id]
    c.conn feed [j iq -type result -from $from -id $id {
        j #as-is [disco_query]
    }]
}

test presence-resource-cap {resources past the cap are dropped, not tracked} \
    {*}$presence_common -body {
        set ::taco_presence::MaxResources 3
        try {
            for {set i 0} {$i < 6} {incr i} {
                c.conn feed [presence_available peer@example.com/res$i]
            }
            dict size [c presence resources -jid peer@example.com]
        } finally {
            set ::taco_presence::MaxResources 50
        }
    } -result 3

test presence-idle-since {XEP-0319 idle timestamp lands as microseconds} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone \
            since 2026-08-15T10:00:00Z]
        dict get [c presence get -jid peer@example.com] idle_since
    } -result [ParseTimestamp 2026-08-15T10:00:00Z]

test presence-idle-absent {a resource that claims no idle time reports 0} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone]
        dict get [c presence get -jid peer@example.com] idle_since
    } -result 0

test presence-idle-unparsable {a malformed idle timestamp reports 0, not ""} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone since yesterday]
        dict get [c presence get -jid peer@example.com] idle_since
    } -result 0

test presence-client-resolves {client details fill in once disco answers} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone ver [caps_ver]]
        set pending [dict get [c presence resources -jid peer@example.com] \
            phone client]
        answer_disco peer@example.com/phone
        set resolved [dict get [c presence resources -jid peer@example.com] \
            phone client]
        list $pending [dict get $resolved name] [dict get $resolved type] \
            [dict get $resolved node] [dict get $resolved features]
    } -result {{} Conversations phone http://conversations.im {urn:xmpp:omemo:2 urn:xmpp:receipts}}

test presence-client-none {a resource advertising no caps keeps client empty} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone]
        dict get [c presence resources -jid peer@example.com] phone client
    } -result {}

test presence-caps-resolved-notifies {a late disco reply re-announces the JID} \
    {*}$presence_common -body {
        set ::presence_changed {}
        tacky listen presence <Changed> {apply {{ev} {
            lappend ::presence_changed [dict getdef $ev -jid ""]
        }}}
        c.conn feed [presence_available peer@example.com/phone ver [caps_ver]]
        set beforeReply $::presence_changed
        answer_disco peer@example.com/phone
        list $beforeReply $::presence_changed
    } -result {peer@example.com {peer@example.com peer@example.com}}

test presence-unavailable-one-resource {going offline drops only that resource} \
    {*}$presence_common -body {
        c.conn feed [presence_available peer@example.com/phone ver [caps_ver]]
        answer_disco peer@example.com/phone
        c.conn feed [presence_available peer@example.com/desktop]
        c.conn feed [j presence -from peer@example.com/phone -type unavailable]
        set left [c presence resources -jid peer@example.com]
        list [dict keys $left] [dict get $left desktop client]
    } -result {desktop {}}

test presence-offline-shape {an unknown JID reports the full offline shape} \
    {*}$presence_common -body {
        c presence get -jid stranger@example.com
    } -result {show offline status "" priority 0 idle_since 0 client {}}
