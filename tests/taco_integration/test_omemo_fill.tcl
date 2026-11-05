# End-to-end cover for the forward fill: a contact writes more OMEMO messages
# than one decrypt may skip while we are offline, and once we are back every
# one of them reads. The limits are lowered for the test (MAX_SKIP to 20, the
# catchup to one page of 50) so 100 messages take the path 1,000+ would.
#
# What happens: the catchup's one page is the newest 50, each further on in
# the chain than MAX_SKIP from the last message read, so each is refused and
# stored undecrypted, and a hole is left below them. The fill then walks the
# chat forward from the message read before we went away: the 50 in the hole
# open in order, and the undecrypted 50 after them are read again and put
# right.
#
# While we are away another session of ours (a bare one) is online, as a
# phone would be: the server hands it the messages rather than keeping them
# in its offline store for us, which would deliver them in order at our
# presence and leave nothing for the archive to tell.

package require tcltest
package require tacky::testhelpers
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::omemo_fill_int {

    variable HOST    "example.local"
    variable TIMEOUT 60000
    variable SENDER  "search3a@example.local"
    variable ME      "search3b@example.local"
    variable COUNT   100

    proc setup {} {
        variable HOST
        variable SENDER
        variable ME
        foreach acc [list $SENDER $ME] {
            set u [lindex [split $acc @] 0]
            tacky account add {*}$::tacky_test_account_args -acc $acc \
                -password ${u}pass -domain $HOST -username $u
        }
        set caughtUp [expect_events [list \
            [list message <CatchupDone> -acc $SENDER -jid ""] \
            [list message <CatchupDone> -acc $ME -jid ""]]]
        tacky account enable -acc $SENDER
        tacky account enable -acc $ME
        wait_expected $caughtUp
        # Our device on our devicelist before the sender reads it.
        set me [tacky client $ME]
        set deadline [expr {[clock milliseconds] + 30000}]
        while {[clock milliseconds] < $deadline} {
            set dev [$me omemo listed_device_id]
            if {$dev ne "" && $dev != 0} break
            after 100 [list set ::test::omemo_fill_int::_tick 1]
            vwait ::test::omemo_fill_int::_tick
        }
        wait_call [tacky client $SENDER] omemo prepareChat -jid $ME
    }

    proc rows {} {
        variable ME
        variable SENDER
        [tacky client $ME] db eval {
            SELECT body, undecrypted FROM chat_message
            WHERE chat_jid=$SENDER AND kind='message' ORDER BY timestamp
        }
    }

    # The server has everything the sender wrote: a ping answered after it.
    proc ping {acc} {
        variable HOST
        variable TIMEOUT
        set ::test::omemo_fill_int::pong 0
        [tacky client $acc] iq request -type get -to $HOST \
            -payload [j ping -ns urn:xmpp:ping] \
            -command [list apply {{args} { set ::test::omemo_fill_int::pong 1 }}]
        wait_value ::test::omemo_fill_int::pong 1 $TIMEOUT
    }

    # The rows once $want of them are there and none is undecrypted (or
    # whatever is there when TIMEOUT runs out).
    proc pollRows {want} {
        variable TIMEOUT
        set deadline [expr {[clock milliseconds] + $TIMEOUT}]
        while {[clock milliseconds] < $deadline} {
            set r [rows]
            if {[llength $r] / 2 >= $want && 1 ni [lmap {b u} $r {set u}]} {
                return $r
            }
            after 200 [list set ::test::omemo_fill_int::_tick 1]
            vwait ::test::omemo_fill_int::_tick
        }
        return [rows]
    }

    set common [concat {-constraints withServer} \
        [tacky_env -extra-setup { ::test::omemo_fill_int::setup } \
            -extra-cleanup {
                set ::taco::omemo::MAX_SKIP 1000
                set ::taco_message::MaxCatchupPages 5
            }]]

    test omemo-int-fill-reads-a-long-run \
        {a run past MAX_SKIP written while we were offline is read in full once we are back} \
        {*}$common -body {
            set SENDER $::test::omemo_fill_int::SENDER
            set ME $::test::omemo_fill_int::ME
            set COUNT $::test::omemo_fill_int::COUNT
            # The anchor: read live, so our session stands right before the run.
            set got [expect_events [list [list message <New> -acc $ME -jid $SENDER]]]
            tacky message send -acc $SENDER -chat $ME -body anchor
            wait_expected $got 30000
            set ::taco::omemo::MAX_SKIP 20
            set ::taco_message::MaxCatchupPages 1
            tacky account disable -acc $ME
            set ::test::omemo_fill_int::otherReady 0
            conn ::test::omemo_fill_int::other -domain $::test::omemo_fill_int::HOST \
                -host $::test::omemo_fill_int::HOST -port $::test::helpers::xmppPort \
                -srv 0 -username search3b -password search3bpass -resource other \
                -onready {apply {args { set ::test::omemo_fill_int::otherReady 1 }}} \
                -onstanza {apply {args {}}}
            ::test::omemo_fill_int::other connect
            wait_value ::test::omemo_fill_int::otherReady 1 $::test::omemo_fill_int::TIMEOUT
            ::test::omemo_fill_int::other write [j presence]
            ::test::omemo_fill_int::ping $SENDER
            for {set i 0} {$i < $COUNT} {incr i} {
                tacky message send -acc $SENDER -chat $ME -body "m $i"
            }
            ::test::omemo_fill_int::ping $SENDER
            ::test::omemo_fill_int::other close
            ::test::omemo_fill_int::other destroy
            set caughtUp [expect_events [list [list message <CatchupDone> -acc $ME -jid ""]]]
            tacky account enable -acc $ME
            wait_expected $caughtUp 30000
            set r [::test::omemo_fill_int::pollRows [expr {$COUNT + 1}]]
            # Every message, read. (Not their order: the server stamps its
            # archive to the second, and all of these share one.)
            set bodies [lmap {b u} $r {set b}]
            set want [list anchor {*}[lmap i [lseq $COUNT] {string cat "m " $i}]]
            list rows [expr {[llength $r] / 2}] \
                undecrypted [llength [lsearch -all -exact [lmap {b u} $r {set u}] 1]] \
                all_read [expr {[lsort $bodies] eq [lsort $want]}]
        } -result [list rows 101 undecrypted 0 all_read 1]
}

cleanupTests
