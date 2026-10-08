package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# Both of these drive the transport itself - a socket, a STARTTLS handshake,
# a TCP proxy with a kill switch between client and server - and a wasm build
# has none of it: its transport is a WebSocket the browser owns end to end,
# and the session over it is covered by every other file here, which reach
# the server the same way.
if {[::tcltest::testConstraint wasm]} {
    puts "skipping [file tail [info script]]: no TCP in a wasm build"
    return
}

namespace eval ::test::bareconn {

    # Test configuration - matches with_prosody.sh
    variable HOST "example.local"
    variable PORT $::test::helpers::xmppPort

    # Test state
    variable ready 0
    variable headerReceived 0
    variable receivedHeader {}
    variable stanzas {}

    proc reset {} {
        variable ready
        variable headerReceived
        variable receivedHeader
        variable stanzas

        set ready 0
        set headerReceived 0
        set receivedHeader {}
        set stanzas {}
    }

    proc onReady {} {
        variable ready
        set ready 1
    }

    proc onHeader {header} {
        variable headerReceived
        variable receivedHeader
        set headerReceived 1
        set receivedHeader $header
    }

    proc onStanza {stanza} {
        variable stanzas
        lappend stanzas $stanza
    }

    proc onError {msg} {
        puts "Error: $msg"
    }

    # Common setup/cleanup for most tests
    set common {
        -constraints withServer
        -setup {
            variable HOST
            variable PORT
            reset
            set conn [bareconn c -domain $HOST \
                -onready [namespace code onReady] \
                -header-command [namespace code onHeader] \
                -ondisconnect [namespace code onError] \
                -onstanza [namespace code onStanza]]
        }
        -cleanup {
            catch {c close}
            catch {c destroy}
        }
    }

    test barebones-int-001 {Connect with automatic TLS} {*}$common -body {
        c connect $HOST $PORT
        # First connect against a freshly-started prosody includes cold-cache
        # TLS handshake setup; allow more than the default budget.
        wait_var [namespace current]::ready 5000
        expr {[c state] eq "connected"}
    } -result 1

    test barebones-int-002 {Receive stream header after connect} {*}$common -body {
        c connect $HOST $PORT
        wait_var [namespace current]::ready
        c write [::jab::header "" to $HOST]
        wait_var [namespace current]::headerReceived
        dict exists $receivedHeader attrs from
    } -result 1

    test barebones-int-003 {Features include SASL mechanisms after TLS} {*}$common -body {
        c connect $HOST $PORT
        wait_var [namespace current]::ready
        c write [::jab::header "" to $HOST]
        wait_var [namespace current]::headerReceived
        wait_var [namespace current]::stanzas
        set features [lindex $stanzas 0]
        expr {[xsearch $features mechanisms mechanism] ne ""}
    } -result 1

    test barebones-int-004 {Write buffering before connect} {*}$common -body {
        # Write before connecting - should buffer
        c write [::jab::header "" to $HOST]
        c connect $HOST $PORT
        wait_var [namespace current]::ready
        wait_var [namespace current]::headerReceived
        dict exists $receivedHeader attrs from
    } -result 1

    test barebones-int-005 {Connect while already connected is a no-op} {*}$common -body {
        c connect $HOST $PORT
        wait_var [namespace current]::ready
        # Second connect should silently return
        c connect $HOST $PORT
        expr {[c state] eq "connected"}
    } -result 1
}

namespace eval ::test::conn {

    # Test configuration - matches with_prosody.sh
    variable HOST "example.local"
    variable PORT $::test::helpers::xmppPort
    variable USER "test"
    variable PASS "testpass"

    # Test state
    variable ready 0
    variable errorMsg ""
    variable done 0

    proc reset {} {
        variable ready
        variable errorMsg
        variable done

        set ready 0
        set errorMsg ""
        set done 0
    }

    proc onReady {resumed} {
        variable ready
        variable done
        set ready 1
        set done 1
    }

    proc onError {kind msg} {
        variable errorMsg
        variable done
        set errorMsg $msg
        set done 1
    }

    set common {
        -constraints withServer
        -setup {
            variable HOST
            variable PORT
            variable USER
            variable PASS
            reset
            set conn [conn c \
                -domain $HOST \
                -port $PORT \
                -username $USER \
                -password $PASS \
                -onready [namespace code onReady] \
                -ondisconnect [namespace code {onError transport}] \
                -onautherror  [namespace code {onError auth}]]
        }
        -cleanup {
            catch {c close}
            catch {c destroy}
        }
    }

    test authorized-int-001 {Connect and authenticate} {*}$common -body {
        c connect
        vwait [namespace current]::done
        expr {$ready && [c isReady]}
    } -result 1

    test authorized-int-002 {Gets bound JID after connect} {*}$common -body {
        c connect
        vwait [namespace current]::done
        set jid [c cget -bound-jid]
        expr {[string match "*@$HOST*" $jid]}
    } -result 1

    test authorized-int-003 {SM is enabled after connect} {*}$common -body {
        c connect
        vwait [namespace current]::done
        set smInfo [[c sm] getInfo]
        # SM should be in "running" state (either active or passthrough)
        expr {[dict get $smInfo state] eq "running"}
    } -result 1

    test authorized-int-004 {Invalid credentials trigger error} -constraints withServer -setup {
        variable HOST
        variable PORT
        reset
        set conn [conn c \
            -domain $HOST \
            -port $PORT \
            -username "baduser" \
            -password "badpass" \
            -onready [namespace code onReady] \
            -ondisconnect [namespace code {onError transport}] \
            -onautherror  [namespace code {onError auth}]]
    } -cleanup {
        catch {c close}
        catch {c destroy}
    } -body {
        c connect
        vwait [namespace current]::done
        expr {$errorMsg ne "" && !$ready}
    } -result 1

    test authorized-int-005 {Write buffering before ready} {*}$common -body {
        # Queue a presence stanza before connecting
        c write [j presence]
        c connect
        vwait [namespace current]::done
        # If we got here without error, buffered write was sent
        expr {$ready && [c isReady]}
    } -result 1
}

source [file join [file dirname [info script]] .. taco dns_responder.tcl]
::tcltest::testConstraint directTls \
    [expr {[info exists ::env(XMPP_TLS_PORT)] && $::env(XMPP_TLS_PORT) ne ""}]

namespace eval ::test::address {
    variable HOST "example.local"
    variable PORT $::test::helpers::xmppPort
    variable TLS_PORT [expr {[info exists ::env(XMPP_TLS_PORT)] ? $::env(XMPP_TLS_PORT) : 0}]

    variable ready 0
    variable errorMsg ""
    variable done 0

    proc onReady {resumed} {
        variable ready 1
        variable done 1
    }

    proc onError {msg} {
        variable errorMsg $msg
        variable done 1
    }

    # "ready", or "failed: reason"
    proc try {args} {
        variable HOST
        variable ready 0
        variable errorMsg ""
        variable done 0
        conn c -domain $HOST -username test -password testpass \
            -onready [namespace code onReady] \
            -ondisconnect [namespace code onError] \
            -onautherror [namespace code onError] {*}$args
        set id [after 15000 [list set [namespace current]::done timeout]]
        c connect
        vwait [namespace current]::done
        after cancel $id
        expr {$ready ? "ready" : "failed: $errorMsg"}
    }

    proc closed_port {} {
        set s [socket -server {apply {{args} {}}} -myaddr 127.0.0.1 0]
        set p [lindex [fconfigure $s -sockname] 2]
        close $s
        return $p
    }

    set common {
        -cleanup {
            catch {c close}
            catch {c destroy}
            dnsresp::stop
        }
    }

    # The certificate is for example.local, not 127.0.0.1
    test address-int-host-not-domain {a host other than the domain connects, checked against the domain} \
        {*}$common -constraints withServer -body {
            list [try -host 127.0.0.1 -port $PORT] [c.base tlsMode]
        } -result {ready starttls}

    test address-int-direct-tls {direct TLS on the server's TLS port} \
        {*}$common -constraints {withServer directTls} -body {
            list [try -host 127.0.0.1 -port $TLS_PORT -tls direct] [c.base tlsMode]
        } -result {ready direct}

    test address-int-direct-tls-on-starttls-port {direct TLS to a STARTTLS port fails as TLS, without hanging} \
        {*}$common -constraints withServer -body {
            string match "failed: TLS*" [try -host 127.0.0.1 -port $PORT -tls direct \
                -connect-timeout 10000]
        } -result 1

    test address-int-srv-direct {an _xmpps-client record leads to direct TLS on its port} \
        {*}$common -constraints {withServer directTls} -body {
            set dns [dnsresp::start [list \
                _xmpps-client._tcp.$HOST [list [list 0 0 $TLS_PORT 127.0.0.1]] \
                _xmpp-client._tcp.$HOST nx]]
            list [try -nameservers [list [list 127.0.0.1 $dns]]] [c.base tlsMode] \
                [lsort [dnsresp::queries]]
        } -result [list ready direct [list _xmpp-client._tcp.example.local _xmpps-client._tcp.example.local]]

    test address-int-srv-priority-falls-through {a dead first record gives way to the next} \
        {*}$common -constraints withServer -body {
            set dns [dnsresp::start [list \
                _xmpps-client._tcp.$HOST nx \
                _xmpp-client._tcp.$HOST [list \
                    [list 0 0 [closed_port] 127.0.0.1] \
                    [list 10 0 $PORT 127.0.0.1]]]]
            try -nameservers [list [list 127.0.0.1 $dns]]
        } -result ready

    # Prosody won't authenticate in plaintext; this checks no TLS was tried
    test address-int-none-is-plaintext {tls none never starts TLS} \
        {*}$common -constraints withServer -body {
            set r [try -host 127.0.0.1 -port $PORT -tls none]
            list [c.base tlsMode] [expr {$r eq "ready" || [string match failed:* $r]}]
        } -result {none 1}
}
