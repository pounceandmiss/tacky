# Tests for taco_nick: XEP-0172 nicks from PEP events
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set nick_common [tacky_env -mock conn -taco-client {
    -domain test.example.com -port 5222
    -username user -password pass -resource res
} -extra-setup {
    c configure -jid user@test.example.com/res
    # PEP nicks are taken from contacts only (pubsub.tcl -contacts).
    c roster StoreItem [j item -jid alice@example.com -subscription both]
    set ::nick_t_changed {}
    tacky listen nick <Changed> {apply {{ev} { lappend ::nick_t_changed [dict get $ev -jid] }}}
}]

proc nick_t_push {from nick} {
    j message -from $from {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node http://jabber.org/protocol/nick {
                j item {
                    j nick -ns http://jabber.org/protocol/nick -body $nick
                }
            }
        }
    }
}

test nick-event-from-a-stranger-is-ignored {a nick event from a bare JID not in the roster files nothing; one from our own account and one from a contact do} \
    {*}$nick_common \
    -body {
        c.conn feed [nick_t_push stranger@example.com "Your Bank"]
        c.conn feed [nick_t_push user@test.example.com Me]
        c.conn feed [nick_t_push alice@example.com Alice]
        list [c nick get -jid stranger@example.com] [c nick get -jid user@test.example.com] \
             [c nick get -jid alice@example.com] $::nick_t_changed
    } -result {{} Me Alice {user@test.example.com alice@example.com}}
