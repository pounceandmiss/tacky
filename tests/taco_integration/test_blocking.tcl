# Integration tests for taco_blocking (XEP-0191) against a real server.
# The first asserts the server has the feature at all; without it the rest
# would pass vacuously.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::blocking_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    # The support check runs on <SessionStart> alongside catchup; poll for it.
    proc waitBlockingReady {acc} {
        variable TIMEOUT
        set deadline [expr {[clock milliseconds] + $TIMEOUT}]
        while {![[tacky client $acc] blocking supported]} {
            if {[clock milliseconds] > $deadline} {
                error "blocking supported never became true for $acc\
                    -- does the test server enable urn:xmpp:blocking?"
            }
            update
            after 50
        }
    }

    # The messages are OMEMO: a send asks for the peer's device list, and
    # one asked for before the peer has published it comes back as "no
    # OMEMO", failing the send. Wait until the server holds $acc's list.
    proc waitDevicelistPublished {acc} {
        variable TIMEOUT
        set deadline [expr {[clock milliseconds] + $TIMEOUT}]
        while {[clock milliseconds] < $deadline} {
            set flag [namespace current]::_dl
            unset -nocomplain $flag
            [tacky client $acc] iq request -type get \
                -payload [j pubsub -ns http://jabber.org/protocol/pubsub {
                    j items -node eu.siacs.conversations.axolotl.devicelist
                }] \
                -command [list apply {{flag st} {
                    set $flag [xsearch $st -get @type]
                }} $flag]
            vwait $flag
            if {[set $flag] eq "result"} return
            after 100
        }
        error "the device list of $acc never reached the server"
    }

    proc bringUp {} {
        variable HOST
        variable ROMEO
        variable JULIET

        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ROMEO -password romeopass \
            -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass \
            -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET

        wait_events {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
            {message <CatchupDone> -acc romeo@example.local}
            {message <CatchupDone> -acc juliet@example.local}
        }
        waitBlockingReady $ROMEO
        waitDevicelistPublished $ROMEO
        waitDevicelistPublished $JULIET
        clearBlocklist
    }

    # The list outlives the session; left set, it would silence juliet in
    # later suites. Cleared on the way in too, after a run that died.
    proc clearBlocklist {} {
        variable ROMEO
        if {[llength [[tacky client $ROMEO] blocking list]] == 0} return
        [tacky client $ROMEO] blocking unblockAll
        blocklistBecomes $ROMEO {}
    }

    # Polled rather than waited on: one operation yields two or three
    # <Changed> (push, answer, refetch).
    proc blocklistBecomes {acc want {ms 5000}} {
        set deadline [expr {[clock milliseconds] + $ms}]
        while {[clock milliseconds] < $deadline} {
            if {[[tacky client $acc] blocking list] eq $want} return
            update
            after 50
        }
        error "blocklist of $acc is {[[tacky client $acc] blocking list]},\
            wanted {$want}"
    }

    proc cleanup {} {
        catch {clearBlocklist}
        catch {tacky destroy}
    }

    proc julietSays {body} {
        variable ROMEO
        variable JULIET
        [tacky client $JULIET] message send -chat $ROMEO -body $body
    }

    # 1 if juliet's message reaches romeo within $ms. The default is long
    # because a first message waits on OMEMO bundles.
    proc romeoHears {body {ms 10000}} {
        variable ROMEO
        variable JULIET
        set flag [testwait::Flag]
        set tag [namespace tail $flag]
        tacky listen -tag $tag message <New> -acc $ROMEO -jid $JULIET \
            [list ::testwait::Seen $flag]
        julietSays $body
        set got [expr {![catch {testwait::Block $flag $ms "message <New>"}]}]
        tacky unlisten $tag
        unset -nocomplain $flag
        return $got
    }

    set common {
        -constraints withServer
        -setup { ::test::blocking_int::bringUp }
        -cleanup { ::test::blocking_int::cleanup }
    }

    test blocking-int-server-supports-blocking \
        {the test server advertises urn:xmpp:blocking} \
        {*}$common \
        -body {
            variable ROMEO
            list [[tacky client $ROMEO] blocking supported] \
                [[tacky client $ROMEO] blocking list]
        } -result {1 {}}

    test blocking-int-block-then-message-is-not-delivered \
        {once romeo blocks juliet, her messages stop arriving} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET

            # Control: delivery works before the block.
            set before [romeoHears "before the block"]

            [tacky client $ROMEO] blocking block -jid $JULIET
            blocklistBecomes $ROMEO $JULIET
            set after [romeoHears "should not arrive" 3000]

            list $before [[tacky client $ROMEO] blocking list] $after
        } -result {1 juliet@example.local 0}

    test blocking-int-unblock-restores-delivery \
        {unblocking juliet lets her messages back in} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET

            [tacky client $ROMEO] blocking block -jid $JULIET
            blocklistBecomes $ROMEO $JULIET
            [tacky client $ROMEO] blocking unblock -jid $JULIET
            blocklistBecomes $ROMEO {}

            romeoHears "after the unblock"
        } -result 1

    test blocking-int-list-survives-reconnect \
        {the blocklist is the server's: a fresh session fetches it back} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET

            [tacky client $ROMEO] blocking block -jid $JULIET
            blocklistBecomes $ROMEO $JULIET
            tacky account disable -acc $ROMEO
            set seen [expect_events {{blocking <Changed> -acc romeo@example.local}}]
            tacky account enable -acc $ROMEO
            wait_expected $seen
            [tacky client $ROMEO] blocking list
        } -result {juliet@example.local}
}
