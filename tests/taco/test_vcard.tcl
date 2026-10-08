# Tests for taco_vcard: our own vCard and its nickname.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set vcard_common [tacky_env -mock conn -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
}]

# The vCard requests written so far: {type id} each.
proc vcard_requests {} {
    set out {}
    foreach stanza [c.conn get_written] {
        if {[llength [xsearch $stanza vCard -ns vcard-temp]]} {
            lappend out [list [xsearch $stanza -get @type] [xsearch $stanza -get @id]]
        }
    }
    return $out
}

# Answer vCard get $id with an error of $condition.
proc vcard_refuse {id condition} {
    c.conn feed [j iq -type error -id $id -from user@test.example.com {
        j error -type wait {
            j $condition -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }
    }]
}

test vcard-failed-fetch-publishes-nothing {a vCard that could not be read is not overwritten} \
    {*}$vcard_common \
    -body {
        c.conn clear
        set ::_vcard_cb {}
        c vcard setNick -nick Juliet -command {apply {{args} {
            set ::_vcard_cb $args
        }}}
        lassign [lindex [vcard_requests] 0] type id
        vcard_refuse $id remote-server-timeout
        list [lmap r [vcard_requests] {lindex $r 0}] [lindex $::_vcard_cb 0]
    } -result {get error}

test vcard-none-yet-publishes-new {item-not-found is no vCard yet: the nick goes out} \
    {*}$vcard_common \
    -body {
        c.conn clear
        c vcard setNick -nick Juliet
        lassign [lindex [vcard_requests] 0] type id
        vcard_refuse $id item-not-found
        lmap r [vcard_requests] {lindex $r 0}
    } -result {get set}
