# Unit tests for searchwindow - chat search with an opt-in server pass
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

# -- helpers --------------------------------------------------------------------

proc sw_setup {} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc user@test.example.com
    set ::_client [tacky client user@test.example.com]
    $::_client.conn configure -bound-jid user@test.example.com/res1
    $::_client.conn fire_ready 0
    $::_client.conn clear
}

proc sw_cleanup {} {
    destroy .sw
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
}

proc sw_create {} {
    searchwindow .sw -acc user@test.example.com -jid alice@example.com
    wait
}

# The id of the pending field-discovery IQ (a MAM query with no queryid).
proc sw_fields_iq {} {
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""
            && [xsearch $stanza query -ns urn:xmpp:mam:2 -get @queryid] eq ""} {
            return [dict get $stanza attrs id]
        }
    }
    return ""
}

# Answer that discovery with an archive advertising $fields.
proc sw_answer_fields {fields} {
    set iqId [sw_fields_iq]
    $::_client iq feed [j iq -type result -id $iqId {
        j query -ns urn:xmpp:mam:2 {
            j x -ns jabber:x:data -type form {
                j field -var FORM_TYPE -type hidden {
                    j value #body urn:xmpp:mam:2
                }
                foreach f $fields {
                    j field -var $f
                }
            }
        }
    }]
    wait
}

# MAM search queries written so far (discovery carries no queryid).
proc sw_search_queries {} {
    set n 0
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2 -get @queryid] ne ""} {
            incr n
        }
    }
    return $n
}

# -- tests ----------------------------------------------------------------------

test sw-server-box-enabled-when-advertised {an archive advertising a fulltext field unlocks the server box} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.remote cget -state
} -cleanup { sw_cleanup } -result {normal}

test sw-server-box-disabled-when-not-advertised {an archive without one leaves the box off and says why} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end}
    list [.sw.top.remote cget -state] [.sw.top.remote cget -text]
} -cleanup { sw_cleanup } -result {disabled {Server can't search}}

test sw-searches-locally-by-default {an unticked search never reaches the archive} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.entry insert 0 needle
    .sw.top.search invoke
    wait
    sw_search_queries
} -cleanup { sw_cleanup } -result {0}

test sw-ticking-the-box-queries-the-archive {ticking it adds the server pass to the same search} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.entry insert 0 needle
    .sw.top.remote invoke
    wait
    sw_search_queries
} -cleanup { sw_cleanup } -result {1}
