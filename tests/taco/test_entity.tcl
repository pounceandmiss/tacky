package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set entity_common [tacky_env -mock conn -account user@test.example.com]

# A contact who sees our presence, and one who does not.
proc entity_roster {} {
    $::_client db eval {
        INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
        VALUES ('friend@example.com', '', 'both', '', 0),
               ('stranger@example.com', '', 'none', '', 0)
    }
}

# Send us a $ns query from $from; return our reply.
proc entity_ask {from ns} {
    $::_client.conn clear
    $::_client.conn feed [j iq -type get -id q1 -from $from -to user@test.example.com/res {
        j [expr {$ns eq "urn:xmpp:time" ? "time" : "query"}] -ns $ns
    }]
    lindex [$::_client.conn get_written] end
}

proc entity_features {} {
    $::_client.conn clear
    $::_client.conn feed [j iq -type get -id d1 -from friend@example.com/x \
        -to user@test.example.com/res {
        j query -ns http://jabber.org/protocol/disco#info
    }]
    xsearch [lindex [$::_client.conn get_written] end] query feature -gather @var
}

test entity-off-by-default {with the settings unset, time and last activity are refused and not advertised} \
    {*}$entity_common \
    -body {
        entity_roster
        set features [entity_features]
        list [xsearch [entity_ask friend@example.com/x urn:xmpp:time] -get @type] \
             [xsearch [entity_ask friend@example.com/x jabber:iq:last] -get @type] \
             [expr {"urn:xmpp:time" in $features}] \
             [expr {"jabber:iq:last" in $features}]
    } -result {error error 0 0}

test entity-time-answers-contacts {with answer_time on, a contact gets our time; a stranger is refused} \
    {*}$entity_common \
    -body {
        entity_roster
        tacky setting set -key answer_time -value 1
        set r [entity_ask friend@example.com/x urn:xmpp:time]
        set tzo [xsearch $r time tzo -get body]
        set utc [xsearch $r time utc -get body]
        list [xsearch $r -get @type] [xsearch $r -get @to] \
             [regexp {^[+-]\d\d:\d\d$} $tzo] \
             [regexp {^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$} $utc] \
             [xsearch [entity_ask stranger@example.com/x urn:xmpp:time] -get @type] \
             [xsearch [entity_ask nobody@example.com/x urn:xmpp:time] -get @type]
    } -result {result friend@example.com/x 1 1 error error}

test entity-time-answers-own-account {our own other devices are answered} \
    {*}$entity_common \
    -body {
        tacky setting set -key answer_time -value 1
        xsearch [entity_ask user@test.example.com/phone urn:xmpp:time] -get @type
    } -result result

test entity-last-activity-follows-the-app {last activity is 0 while active and grows once the app is inactive} \
    {*}$entity_common \
    -body {
        entity_roster
        tacky setting set -key answer_last_activity -value 1
        set active [xsearch [entity_ask friend@example.com/x jabber:iq:last] \
            query -get @seconds]
        tacky app setActive -active 0
        after 1100
        set idle [xsearch [entity_ask friend@example.com/x jabber:iq:last] \
            query -get @seconds]
        tacky app setActive -active 1
        list $active [expr {$idle >= 1}]
    } -result {0 1}

test entity-setting-changes-caps {turning a setting on advertises its feature and re-announces presence} \
    {*}$entity_common \
    -body {
        $::_client.conn fire_state connected
        set ver0 [xsearch [$::_client caps cNode] -get @ver]
        $::_client.conn clear
        tacky setting set -key answer_time -value 1
        set written [$::_client.conn get_written]
        set ver1 [xsearch [$::_client caps cNode] -get @ver]
        list [expr {$ver0 ne $ver1}] \
             [lmap st $written {dict get $st tag}] \
             [expr {"urn:xmpp:time" in [entity_features]}]
    } -result {1 presence 1}
