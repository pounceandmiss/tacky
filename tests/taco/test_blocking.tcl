# Tests for taco_blocking (XEP-0191)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set blocking_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# <Ready> also runs message catchup, which needs a bound JID.
set blocking_ready_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
} -bound-jid user@test.example.com/res]

# By -to: taco_avatar also sends a disco#info on <Ready>, to our bare JID.
proc last_blocking_disco_iq {} {
    set found ""
    foreach iq [c.conn get_written] {
        if {[xsearch $iq query -ns http://jabber.org/protocol/disco#info] ne ""
                && [xsearch $iq -get @to] eq "test.example.com"} {
            set found $iq
        }
    }
    return $found
}

proc discoinfo_result {id jid features} {
    j iq -type result -id $id -from $jid {
        j query -ns http://jabber.org/protocol/disco#info {
            foreach f $features { j feature -var $f }
        }
    }
}

proc blocklist_result {id jids} {
    j iq -type result -id $id {
        j blocklist -ns urn:xmpp:blocking {
            foreach j_ $jids { j item -jid $j_ }
        }
    }
}

test blocking-disco-checks-server-on-ready \
    {<Ready> disco#info's our own server for urn:xmpp:blocking} \
    {*}$blocking_ready_common \
    -body {
        set iq [last_blocking_disco_iq]
        list [xsearch $iq -get @type] [xsearch $iq -get @to]
    } -result {get test.example.com}

test blocking-supported-false-before-confirmed \
    {supported is false until the server actually answers with the feature} \
    {*}$blocking_common \
    -body {
        c blocking supported
    } -result 0

test blocking-refresh-after-support-confirmed \
    {a confirmed server fetches the blocklist and populates the cache} \
    {*}$blocking_ready_common \
    -body {
        set discoIq [last_blocking_disco_iq]
        c.conn feed [discoinfo_result [xsearch $discoIq -get @id] \
            test.example.com {urn:xmpp:blocking}]
        update idletasks
        set fetchIq [lindex [c.conn get_written] end]
        c.conn feed [blocklist_result [xsearch $fetchIq -get @id] \
            {alice@example.com bob@example.com}]
        update idletasks
        list [c blocking supported] [c blocking list]
    } -result {1 {alice@example.com bob@example.com}}

test blocking-not-refreshed-when-unsupported \
    {no blocklist fetch happens when the server never confirms the feature} \
    {*}$blocking_ready_common \
    -body {
        set discoIq [last_blocking_disco_iq]
        c.conn clear
        c.conn feed [discoinfo_result [xsearch $discoIq -get @id] \
            test.example.com {}]
        update idletasks
        list [c blocking supported] [llength [c.conn get_written]]
    } -result {0 0}

test blocking-block-sends-item-jids \
    {block sends one <item> per JID, each in the form given} \
    {*}$blocking_common \
    -body {
        c.conn clear
        c blocking block -jid {alice@example.com/phone bob@example.com example.net}
        set iq [lindex [c.conn get_written] end]
        list [xsearch $iq -get @type] \
            [xsearch $iq block -ns urn:xmpp:blocking item -gather @jid]
    } -result {set {alice@example.com/phone bob@example.com example.net}}

test blocking-block-requires-a-jid {block with no -jid at all is a caller error} \
    {*}$blocking_common \
    -body {
        catch {c blocking block} err
        set err
    } -match glob -result {*-jid*}

test blocking-unblock-empty-means-all \
    {unblock with no -jid sends an empty <unblock/> (unblock everyone)} \
    {*}$blocking_common \
    -body {
        c.conn clear
        c blocking unblockAll
        set iq [lindex [c.conn get_written] end]
        list [xsearch $iq -get @type] \
            [llength [xsearch $iq unblock -ns urn:xmpp:blocking item]]
    } -result {set 0}

test blocking-operation-result-refreshes-list \
    {a successful block re-fetches the blocklist rather than guessing the merge} \
    {*}$blocking_common \
    -body {
        set changed {}
        tacky listen blocking <Changed> {apply {{ev} { set ::changed $ev }}}
        c.conn clear
        c blocking block -jid alice@example.com
        c.conn feed [j iq -type result \
            -id [xsearch [lindex [c.conn get_written] end] -get @id]]
        update idletasks
        set fetchIq [lindex [c.conn get_written] end]
        c.conn feed [blocklist_result [xsearch $fetchIq -get @id] \
            {alice@example.com}]
        update idletasks
        list [c blocking list] [dict get $changed -list]
    } -result {alice@example.com alice@example.com}

test blocking-operation-error-calls-onerror \
    {a rejected block reports through -onerror, not -command} \
    {*}$blocking_common \
    -body {
        set ok 0
        set err ""
        c blocking block -jid alice@example.com \
            -command {apply {{_} { set ::ok 1 }}} \
            -onerror {apply {{msg} { set ::err $msg }}}
        c.conn feed [j iq -type error \
            -id [xsearch [lindex [c.conn get_written] end] -get @id] {
            j error -type auth {
                j not-authorized -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        update idletasks
        list $ok [expr {$err ne ""}]
    } -result {0 1}

test blocking-push-block-acks-and-updates-list \
    {an authorized <block/> push is acked and folded into the cached list} \
    {*}$blocking_common \
    -body {
        set changed {}
        tacky listen blocking <Changed> {apply {{ev} { set ::changed $ev }}}
        c configure -jid user@test.example.com/res
        c.conn clear
        c.conn feed [j iq -type set -id push1 -from user@test.example.com {
            j block -ns urn:xmpp:blocking {
                j item -jid alice@example.com
            }
        }]
        update idletasks
        set ack [lindex [c.conn get_written] end]
        list [xsearch $ack -get @type] [xsearch $ack -get @id] \
            [c blocking list] [dict get $changed -list]
    } -result {result push1 alice@example.com alice@example.com}

test blocking-push-unblock-empty-clears-list \
    {an <unblock/> push with no items clears the whole cached list} \
    {*}$blocking_common \
    -body {
        c configure -jid user@test.example.com/res
        c.conn feed [j iq -type set -id b1 -from user@test.example.com {
            j block -ns urn:xmpp:blocking {
                j item -jid alice@example.com
                j item -jid bob@example.com
            }
        }]
        update idletasks
        c.conn feed [j iq -type set -id u1 -from user@test.example.com {
            j unblock -ns urn:xmpp:blocking
        }]
        update idletasks
        c blocking list
    } -result {}

test blocking-push-from-stranger-rejected \
    {a push from anyone but our own account or server is refused, not applied} \
    {*}$blocking_common \
    -body {
        c configure -jid user@test.example.com/res
        c.conn feed [j iq -type set -id evil1 -from attacker@evil.example {
            j block -ns urn:xmpp:blocking {
                j item -jid alice@example.com
            }
        }]
        update idletasks
        set ack [lindex [c.conn get_written] end]
        list [xsearch $ack -get @type] \
            [xsearch $ack error * -get tag] \
            [c blocking list]
    } -result {error service-unavailable {}}

test blocking-push-invalid-item-rejected \
    {an <item/> with no jid attribute is a bad-request, not silently accepted} \
    {*}$blocking_common \
    -body {
        c configure -jid user@test.example.com/res
        c.conn feed [j iq -type set -id bad1 -from user@test.example.com {
            j block -ns urn:xmpp:blocking {
                j item
            }
        }]
        update idletasks
        set ack [lindex [c.conn get_written] end]
        list [xsearch $ack -get @type] \
            [xsearch $ack error * -get tag] \
            [c blocking list]
    } -result {error bad-request {}}

# -- full JIDs, offline, front end ---------------------------------------

proc confirm_blocklist {jids} {
    set discoIq [last_blocking_disco_iq]
    c.conn feed [discoinfo_result [xsearch $discoIq -get @id] \
        test.example.com {urn:xmpp:blocking}]
    update idletasks
    set fetchIq [lindex [c.conn get_written] end]
    c.conn feed [blocklist_result [xsearch $fetchIq -get @id] $jids]
    update idletasks
}

test blocking-full-jid-item-kept-whole \
    {a full JID is blocked as given (case-folded), not widened to its bare JID} \
    {*}$blocking_common \
    -body {
        c.conn clear
        c blocking block -jid Room@MUC.example.com/Nick
        set iq [lindex [c.conn get_written] end]
        xsearch $iq block item -get @jid
    } -result {room@muc.example.com/Nick}

test blocking-list-kept-over-disconnect \
    {offline, the last list still answers; only support is forgotten} \
    {*}$blocking_ready_common \
    -body {
        confirm_blocklist {alice@example.com}
        c bus publish <Disconnect>
        list [c blocking supported] [c blocking list]
    } -result {0 alice@example.com}

test blocking-unsupported-server-drops-list \
    {a session whose server lacks the feature drops the list it kept, and says so} \
    {*}$blocking_ready_common \
    -body {
        confirm_blocklist {alice@example.com}
        c bus publish <Disconnect>
        set changed none
        tacky listen blocking <Changed> {apply {{ev} { set ::changed $ev }}}
        c.conn clear
        c.conn fire_ready 0
        set discoIq [last_blocking_disco_iq]
        c.conn feed [discoinfo_result [xsearch $discoIq -get @id] \
            test.example.com {}]
        update idletasks
        list [c blocking list] [dict get $changed -list]
    } -result {{} {}}

set blocking_acc_common [tacky_env -mock conn \
    -account user@example.com \
    -bound-jid user@example.com/res1 \
    -extra-setup {$::_client.conn clear}]

test blocking-command-through-front-end \
    {-command fires through libtacky's token callback, which needs a result value} \
    {*}$blocking_acc_common \
    -body {
        set ::done none
        tacky blocking block -acc user@example.com -jid alice@example.com \
            -command {apply {{r} { set ::done [list ok $r] }}} \
            -onerror {apply {{m} { set ::done [list err $m] }}}
        set iq [lindex [$_client.conn get_written] end]
        $_client.conn feed [j iq -type result -id [xsearch $iq -get @id]]
        update idletasks
        set ::done
    } -result {ok {}}
