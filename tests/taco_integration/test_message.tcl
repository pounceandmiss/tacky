package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::message_int {

    variable HOST "example.local"
    variable PORT 5222
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    variable _awaitCounter 0

    proc awaitEvent {args} {
        variable TIMEOUT
        set script [lindex $args end]
        set listenerArgs [lrange $args 0 end-1]

        set var [namespace current]::_await_[incr [namespace current]::_awaitCounter]
        set $var ""

        set tag [tacky listen {*}$listenerArgs [list apply {{var argsL} {
            set $var $argsL
        }} $var]]

        uplevel 1 $script

        try {
            ::test::helpers::waitVar $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }

        tacky unlisten $tag
        return [set $var]
    }

    # Helper: call tacky message history with -command and wait for result
    proc historyWait {args} {
        variable TIMEOUT
        set var [namespace current]::_hist_[incr [namespace current]::_awaitCounter]
        set ${var}_done 0

        tacky message history {*}$args \
            -command [list apply {{dv rv result} {
                set $rv $result
                set $dv 1
            }} ${var}_done $var]

        ::test::helpers::waitVar ${var}_done $TIMEOUT
        return [set $var]
    }

    proc setup {} {
        variable HOST
        variable ROMEO
        variable JULIET

        tacky_init
        tacky account add -acc $ROMEO -password romeopass \
            -domain $HOST -username romeo
        tacky account add -acc $JULIET -password julietpass \
            -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET

        # Wait for both connections to be ready and catchup done
        ::test::helpers::waitEvents {
            {conn <Ready> -acc romeo@example.local}
            {conn <Ready> -acc juliet@example.local}
        }
        ::test::helpers::waitEvents {
            {message <CatchupDone> -acc romeo@example.local}
            {message <CatchupDone> -acc juliet@example.local}
        }
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    # Send a message from juliet to romeo and wait for it to be received
    proc sendAndReceive {body} {
        variable ROMEO
        variable JULIET

        set ev [awaitEvent message <Received> -acc $ROMEO -jid $JULIET {
            set client [tacky client $JULIET]
            $client conn writeImmediate [j message \
                -type chat -to $ROMEO {
                    j body #body $body
                }]
        }]
        return $ev
    }

    set common {
        -constraints withServer
        -setup { ::test::message_int::setup }
        -cleanup { ::test::message_int::cleanup }
    }

    # -- Basic: history returns messages after send ---

    test message-int-history-after-send \
        {history returns messages sent between contacts} \
        {*}$common \
        -body {
            sendAndReceive "hello from juliet"

            set result [historyWait -acc $ROMEO -chat $JULIET -limit 50]

            set found 0
            foreach msg $result {
                if {[dict get $msg body] eq "hello from juliet"} {
                    set found 1
                }
            }
            set found
        } -result {1}

    # -- MAM backfill works when local data is insufficient ---

    test message-int-mam-backfill \
        {history triggers MAM backfill and returns results via callback} \
        {*}$common \
        -body {
            for {set i 0} {$i < 3} {incr i} {
                sendAndReceive "msg $i"
            }

            set result [historyWait -acc $ROMEO -chat $JULIET -limit 50]

            set count 0
            foreach msg $result {
                if {[string match "msg *" [dict get $msg body]]} {
                    incr count
                }
            }
            expr {$count >= 3}
        } -result {1}

    # -- server_id is a valid archive ID ---

    test message-int-server-id-valid \
        {stored server_id is a valid MAM archive ID} \
        {*}$common \
        -body {
            sendAndReceive "server id test"

            set result [historyWait -acc $ROMEO -chat $JULIET -limit 50]

            set msg [lindex $result end]
            set sid [dict get $msg server_id]
            expr {$sid ne ""}
        } -result {1}

    # -- Catchup on reconnect populates local store ---

    test message-int-catchup-populates \
        {DoCatchup on connect populates the local message store} \
        {*}$common \
        -body {
            sendAndReceive "catchup test msg"

            # Destroy and recreate — simulates app restart
            cleanup
            tacky_init
            tacky account add -acc $ROMEO -password romeopass \
                -domain $HOST -username romeo
            tacky account enable -acc $ROMEO

            ::test::helpers::waitEvents {
                {message <CatchupDone> -acc romeo@example.local}
            }

            set result [historyWait -acc $ROMEO -chat $JULIET -limit 50]

            set found 0
            foreach msg $result {
                if {[dict get $msg body] eq "catchup test msg"} {
                    set found 1
                }
            }
            set found
        } -result {1}

    # -- Sentinels ---

    # `message messagestore` is a snit -public component delegate: you
    # always have to call a subcommand on the same line. ms forwards
    # the subcommand inline so tests can stay readable.
    proc ms {acc args} {
        [tacky client $acc] message messagestore {*}$args
    }

    test message-int-reconnect-overlap-clears-sentinel \
        {reconnect places a sentinel; catchup overlap (preserved DB) sweeps it} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET

            # Baseline: one message exchanged with both connected.
            sendAndReceive "before disconnect"
            if {[llength [dict get [ms $ROMEO get latest $JULIET] messages]] == 0} {
                error "baseline message not stored"
            }

            # Disable romeo (preserves DB + client; just disconnects).
            tacky account disable -acc $ROMEO

            # Juliet sends another message while romeo is offline. The
            # server archives it for romeo's account.
            set jclient [tacky client $JULIET]
            $jclient conn writeImmediate [j message \
                -type chat -to $ROMEO {
                    j body #body "during disconnect"
                }]
            after 300

            # Re-enable romeo. OnReady places a reconnect sentinel for
            # juliet, then DoCatchup pulls both messages; overlap on
            # "before disconnect" proves the bracket empty so the
            # sentinel sweeps.
            tacky account enable -acc $ROMEO
            ::test::helpers::waitEvents {
                {message <CatchupDone> -acc romeo@example.local}
            }

            llength [ms $ROMEO sentinel list $JULIET]
        } -result {0}

    test message-int-history-mam-complete-removes-sentinel \
        {history MAM with empty result + complete=true clears the bounding sentinel} \
        {*}$common \
        -body {
            variable ROMEO
            variable JULIET

            # Anchor: one message exchanged so we have a citizen to bound.
            set ev [sendAndReceive "anchor"]
            set ts [dict get $ev -message timestamp]

            # Manually place an older-side sentinel.
            ms $ROMEO sentinel add $JULIET older $ts
            if {[llength [ms $ROMEO sentinel list $JULIET]] != 1} {
                error "sentinel not placed; got [ms $ROMEO sentinel list $JULIET]"
            }

            # history -before $ts: local is empty older than the anchor
            # and bounded by the sentinel, so MAM fires. Server has
            # nothing older and returns empty + complete=true, so
            # OnFetch removes the bounding sentinel.
            historyWait -acc $ROMEO -chat $JULIET -before $ts -limit 50

            llength [ms $ROMEO sentinel list $JULIET]
        } -result {0}
}
