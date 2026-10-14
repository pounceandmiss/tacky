# Integration tests for taco_entity (XEP-0202 Entity Time) against a real
# server: answer_time is per account, so two accounts in one tacky answer
# differently.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::entity_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable ROMEO "romeo@example.local"
    variable JULIET "juliet@example.local"

    proc setup {} {
        variable ROMEO
        variable JULIET
        variable HOST

        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ROMEO -password romeopass -domain $HOST -username romeo
        tacky account add {*}$::tacky_test_account_args -acc $JULIET -password julietpass -domain $HOST -username juliet

        tacky account enable -acc $ROMEO
        tacky account enable -acc $JULIET
        wait_events {
            {conn <State> -acc romeo@example.local -state connected}
            {conn <State> -acc juliet@example.local -state connected}
        }
        # Time is only answered to contacts with a subscription, so each
        # must see the other's presence. As in test_avatar: listen first,
        # approve once the request has arrived.
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set [namespace current]::sees($acc) 0
            tacky listen presence <Changed> -acc $acc -jid $peer \
                [list apply {{var args} { set $var 1 }} [namespace current]::sees($acc)]
            set [namespace current]::asked($acc) 0
            tacky listen roster <Subscribe> -acc $acc -jid $peer -type subscribe \
                [list apply {{var args} { set $var 1 }} [namespace current]::asked($acc)]
        }
        tacky roster subscribe -acc $ROMEO -jid $JULIET
        tacky roster subscribe -acc $JULIET -jid $ROMEO
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set deadline [expr {[clock milliseconds] + 10000}]
            while {![set [namespace current]::asked($acc)]
                    && [tacky roster subscription -acc $acc -jid $peer] ni {from both}} {
                if {[clock milliseconds] > $deadline} {
                    error "no subscription request from $peer reached $acc"
                }
                after 50 [list set [namespace current]::tick 1]
                vwait [namespace current]::tick
            }
            tacky roster approve -acc $acc -jid $peer
        }
        foreach acc [list $ROMEO $JULIET] {
            wait_value [namespace current]::sees($acc) 1 10000
        }
        # The presence can come before the roster push that records the
        # subscription, and that is what the answering side checks.
        foreach {acc peer} [list $ROMEO $JULIET $JULIET $ROMEO] {
            set deadline [expr {[clock milliseconds] + 10000}]
            while {[tacky roster subscription -acc $acc -jid $peer] ne "both"} {
                if {[clock milliseconds] > $deadline} {
                    error "$acc never recorded a mutual subscription with $peer"
                }
                after 50 [list set [namespace current]::tick 1]
                vwait [namespace current]::tick
            }
        }
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    # The type of the reply $from gets asking $to's full JID for its time.
    proc askTime {from to} {
        variable TIMEOUT
        set full [[tacky client $to] cget -jid]
        set var [namespace current]::_reply
        set $var ""
        [tacky client $from] iq request -type get -to $full \
            -payload [j time -ns urn:xmpp:time] \
            -command [list apply {{var st} {
                set $var [xsearch $st -get @type]
            }} $var]
        wait_var $var $TIMEOUT
        set $var
    }

    set common {
        -constraints withServer
        -setup { ::test::entity_int::setup }
        -cleanup { ::test::entity_int::cleanup }
    }

    test entity-int-time-per-account {only the account with answer_time on answers, and flipping it flips the answers} \
        {*}$common -body {
        variable ROMEO
        variable JULIET
        tacky setting set -acc $ROMEO -key answer_time -value 1
        tacky setting set -acc $JULIET -key answer_time -value 0
        set first [list [askTime $JULIET $ROMEO] [askTime $ROMEO $JULIET]]
        tacky setting set -acc $ROMEO -key answer_time -value 0
        tacky setting set -acc $JULIET -key answer_time -value 1
        list {*}$first [askTime $JULIET $ROMEO] [askTime $ROMEO $JULIET]
    } -result {result error error result}
}
