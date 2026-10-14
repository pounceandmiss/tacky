package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# Accounts that go through Tor, against a real one. Run by
#
#   tests/servers/with_tor.sh <suite>
#
# whose Tor never reaches the network: what is checked is what Tor itself
# sees and says - the login each connection brings, which decides the
# circuits it may share, and Tor's own refusals. That nothing goes around
# the proxy is test_proxy.tcl's, in its jail: Tor is a SOCKS5 proxy there.

::tcltest::testConstraint torRig \
    [expr {[info exists ::env(TOR_SOCKS)] && $::env(TOR_SOCKS) ne ""}]

namespace eval ::test::tor {
    variable HOST example.local
    # Every STREAM NEW the control port reported: {target username}, the
    # username "" for a connection that brought no login
    variable Streams {}
    variable Control ""

    proc proxy {} { return $::env(TOR_SOCKS) }

    # Tor's control port, telling of every stream from here on
    proc listen {} {
        variable Control
        variable Streams
        set Streams {}
        set Control [socket 127.0.0.1 $::env(TOR_CONTROL_PORT)]
        fconfigure $Control -translation crlf -buffering line
        set f [open $::env(TOR_COOKIE) rb]
        binary scan [read $f] H* cookie
        close $f
        foreach cmd [list "AUTHENTICATE $cookie" "SETEVENTS STREAM"] {
            puts $Control $cmd
            set reply [gets $Control]
            if {![string match 250* $reply]} {
                error "tor control: $cmd: $reply"
            }
        }
        fileevent $Control readable [namespace code OnControl]
    }

    proc OnControl {} {
        variable Control
        variable Streams
        if {[gets $Control line] < 0} {
            if {[eof $Control]} { close $Control; set Control "" }
            return
        }
        if {![regexp {^650 STREAM \d+ NEW \d+ (\S+)} $line -> target]} return
        set user ""
        regexp {SOCKS_USERNAME="([^"]*)"} $line -> user
        lappend Streams [list $target $user]
        set [namespace current]::changed 1
    }

    # The usernames of the streams to TARGET, once there are COUNT of them
    proc usernames {target count} {
        variable Streams
        set deadline [expr {[clock milliseconds] + 20000}]
        while 1 {
            set users [lmap s $Streams {
                expr {[lindex $s 0] eq $target ? [lindex $s 1] : [continue]}
            }]
            if {[llength $users] >= $count} {
                return [lrange $users 0 $count-1]
            }
            set left [expr {$deadline - [clock milliseconds]}]
            if {$left <= 0} {
                error "streams to $target: [llength $users] of $count"
            }
            set id [after $left [list set [namespace current]::changed 0]]
            vwait [namespace current]::changed
            after cancel $id
        }
    }

    proc setup {} {
        tacky_init
        listen
    }

    proc cleanup {} {
        variable Control
        catch {tacky destroy}
        if {$Control ne ""} {
            catch {close $Control}
            set Control ""
        }
    }

    proc add {acc args} {
        variable HOST
        tacky account add {*}$::tacky_test_account_args -acc $acc \
            -password pass -domain $HOST -host $HOST {*}$args
    }

    proc target {} {
        variable HOST
        return $HOST:$::test::helpers::xmppPort
    }
}

test tor-int-own-circuits {each account comes to Tor with a login of its own, which names neither} \
    -constraints torRig \
    -setup ::test::tor::setup -cleanup ::test::tor::cleanup -body {
        ::test::tor::add romeo@example.local -proxy [::test::tor::proxy] -tor 1
        ::test::tor::add juliet@example.local -proxy [::test::tor::proxy] -tor 1
        tacky account enable -acc romeo@example.local
        lassign [::test::tor::usernames [::test::tor::target] 1] romeo
        tacky account enable -acc juliet@example.local
        set users [::test::tor::usernames [::test::tor::target] 2]
        set juliet [lsearch -inline -exact -not $users $romeo]
        list [expr {$romeo ne "" && $juliet ne "" && $romeo ne $juliet}] \
            [regexp -nocase {romeo|juliet|example} "$romeo $juliet"]
    } -result {1 0}

test tor-int-off-no-login {without tor the same proxy is used as given: no login} \
    -constraints torRig \
    -setup ::test::tor::setup -cleanup ::test::tor::cleanup -body {
        ::test::tor::add romeo@example.local -proxy [::test::tor::proxy]
        tacky account enable -acc romeo@example.local
        ::test::tor::usernames [::test::tor::target] 1
    } -result {{}}

test tor-int-given-login {a login in the proxy is the one Tor sees} \
    -constraints torRig \
    -setup ::test::tor::setup -cleanup ::test::tor::cleanup -body {
        regsub {^socks5://} [::test::tor::proxy] {socks5://alice:x@} proxy
        ::test::tor::add romeo@example.local -proxy $proxy -tor 1
        tacky account enable -acc romeo@example.local
        ::test::tor::usernames [::test::tor::target] 1
    } -result alice

test tor-int-register-own-circuit {a registration through Tor has a login of its own, not an account's} \
    -constraints torRig \
    -setup ::test::tor::setup -cleanup ::test::tor::cleanup -body {
        ::test::tor::add romeo@example.local -proxy [::test::tor::proxy] -tor 1
        tacky account enable -acc romeo@example.local
        lassign [::test::tor::usernames [::test::tor::target] 1] romeo
        tacky register connect -domain $::test::tor::HOST \
            -host $::test::tor::HOST -port $::test::helpers::xmppPort \
            -proxy [::test::tor::proxy] -tor 1 -token t
        set users [::test::tor::usernames [::test::tor::target] 2]
        set reg [lsearch -inline -exact -not $users $romeo]
        expr {$reg ne "" && $reg ne $romeo}
    } -result 1

# Tor answers a malformed onion address itself, network or not, and no
# retry could change that: the account stops, as for any proxy refusal.
test tor-int-invalid-onion {an invalid onion address ends the connection rather than retrying} \
    -constraints torRig \
    -setup ::test::tor::setup -cleanup ::test::tor::cleanup -body {
        ::test::tor::add romeo@example.local -proxy [::test::tor::proxy] -tor 1 \
            -host notanonionaddress.onion
        set ::_torErr ""
        set tag [tacky listen conn <ConnError> -acc romeo@example.local {apply {{a} {
            if {$::_torErr eq ""} { set ::_torErr [dict get $a -message] }
        }}}]
        set stopped [expect_events [list \
            [list conn <Disconnected> -acc romeo@example.local]]]
        tacky account enable -acc romeo@example.local
        wait_expected $stopped 20000
        tacky unlisten $tag
        list $::_torErr [[tacky client romeo@example.local] conn state]
    } -result {{Connect failed: proxy error: invalid onion address (246)} disconnected}
