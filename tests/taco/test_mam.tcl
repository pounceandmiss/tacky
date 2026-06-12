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
