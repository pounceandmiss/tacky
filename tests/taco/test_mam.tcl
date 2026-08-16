# Tests for taco_mam result routing
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set mam_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

test mam-result-foreign-sender-dropped {results from senders other than the queried archive are ignored} \
    {*}$mam_common \
    -body {
        c configure -jid user@test.example.com/res
        set got ""
        c mam query -with peer@example.com \
            -command {apply {{r} { set ::got $r }}}
        set req [lindex [c.conn get_written] end]
        set queryId [xsearch $req query -ns urn:xmpp:mam:2 -get @queryid]
        # Forged result from an unrelated sender: must not be stored
        c.conn feed [j message -from evil@evil.example {
            j result -ns urn:xmpp:mam:2 -queryid $queryId -id fake1 {
                j forwarded -ns urn:xmpp:forward:0
            }
        }]
        # Legit result from our own archive
        c.conn feed [j message -from user@test.example.com {
            j result -ns urn:xmpp:mam:2 -queryid $queryId -id real1 {
                j forwarded -ns urn:xmpp:forward:0
            }
        }]
        c.conn feed [j iq -type result -id [xsearch $req -get @id] {
            j fin -ns urn:xmpp:mam:2 -complete true
        }]
        set ids {}
        foreach node [dict get $got messages] {
            lappend ids [xsearch $node -get @id]
        }
        set ids
    } -result {real1}

proc mam_reconnect {resumed} {
    c.conn fire_disconnect "network gone"
    c.conn configure -bound-jid user@test.example.com/res
    c.conn fire_ready $resumed
}

# Start a query answering into ::got, and return the IQ it wrote.
proc mam_query_out {} {
    c configure -jid user@test.example.com/res
    set ::got NEVER
    c mam query -with peer@example.com \
        -command {apply {{r} { set ::got $r }}}
    return [lindex [c.conn get_written] end]
}

proc mam_feed_result {req id} {
    set qid [xsearch $req query -ns urn:xmpp:mam:2 -get @queryid]
    c.conn feed [j message -from user@test.example.com {
        j result -ns urn:xmpp:mam:2 -queryid $qid -id $id {
            j forwarded -ns urn:xmpp:forward:0
        }
    }]
}

proc mam_feed_fin {req} {
    c.conn feed [j iq -type result -id [xsearch $req -get @id] {
        j fin -ns urn:xmpp:mam:2 -complete true
    }]
}

proc mam_result_ids {r} {
    set ids {}
    foreach node [dict get $r messages] {
        lappend ids [xsearch $node -get @id]
    }
    return $ids
}

test mam-query-survives-a-resumed-reconnect {a query outstanding across a resumption still gets its answer} \
    {*}$mam_common \
    -body {
        # Stream management replays the query, so the archive answers the id
        # we already sent - dropping our side of it loses a good reply.
        set req [mam_query_out]
        mam_reconnect 1
        mam_feed_result $req real1
        mam_feed_fin $req
        mam_result_ids $::got
    } -result {real1}

test mam-results-banked-before-a-drop-survive-it {a resumed query assembles both halves} \
    {*}$mam_common \
    -body {
        set req [mam_query_out]
        mam_feed_result $req before1
        mam_reconnect 1
        mam_feed_result $req after1
        mam_feed_fin $req
        mam_result_ids $::got
    } -result {before1 after1}

test mam-disconnect-alone-does-not-settle-the-query {a drop is not an answer} \
    {*}$mam_common \
    -body {
        mam_query_out
        c.conn fire_disconnect "network gone"
        set ::got
    } -result NEVER

test mam-query-answers-an-error-after-a-fresh-reconnect {a session that did not resume settles the query} \
    {*}$mam_common \
    -body {
        # A fresh session cannot answer the old query id; iq re-arms its clock
        # on connect and eventually feeds this on its own behalf.
        set req [mam_query_out]
        mam_reconnect 0
        c.conn feed [j iq -type error -id [xsearch $req -get @id] {
            j error -type wait {
                j remote-server-timeout -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        list [dict get $::got error] [dict get $::got error_condition]
    } -result {1 remote-server-timeout}

test mam-result-muc-archive-matched {MUC query results must come from the room} \
    {*}$mam_common \
    -body {
        c configure -jid user@test.example.com/res
        set got ""
        c mam query -to room@muc.example.com \
            -command {apply {{r} { set ::got $r }}}
        set req [lindex [c.conn get_written] end]
        set queryId [xsearch $req query -ns urn:xmpp:mam:2 -get @queryid]
        # Own-server result for a room query: not the queried archive
        c.conn feed [j message -from user@test.example.com {
            j result -ns urn:xmpp:mam:2 -queryid $queryId -id fake1 {
                j forwarded -ns urn:xmpp:forward:0
            }
        }]
        c.conn feed [j message -from room@muc.example.com {
            j result -ns urn:xmpp:mam:2 -queryid $queryId -id real1 {
                j forwarded -ns urn:xmpp:forward:0
            }
        }]
        c.conn feed [j iq -type result -id [xsearch $req -get @id] \
            -from room@muc.example.com {
            j fin -ns urn:xmpp:mam:2 -complete true
        }]
        set ids {}
        foreach node [dict get $got messages] {
            lappend ids [xsearch $node -get @id]
        }
        set ids
    } -result {real1}
