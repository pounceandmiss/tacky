namespace eval ::test::bareconn {

    # Test configuration - matches with_prosody.sh
    variable HOST "example.local"
    variable PORT 5222

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
            set conn [bareconn conn \
                -onready [namespace code onReady] \
                -header-command [namespace code onHeader] \
                -ondisconnect [namespace code onError] \
                -onstanza [namespace code onStanza]]
        }
        -cleanup {
            catch {conn close}
            catch {conn destroy}
        }
    }

    test barebones-int-001 {Connect with automatic TLS} {*}$common -body {
        conn connect $HOST $PORT
        ::test::helpers::waitVar [namespace current]::ready
        expr {[conn state] eq "connected"}
    } -result 1

    test barebones-int-002 {Receive stream header after connect} {*}$common -body {
        conn connect $HOST $PORT
        ::test::helpers::waitVar [namespace current]::ready
        conn write [::jab::header "" to $HOST]
        ::test::helpers::waitVar [namespace current]::headerReceived
        dict exists $receivedHeader attrs from
    } -result 1

    test barebones-int-003 {Features include SASL mechanisms after TLS} {*}$common -body {
        conn connect $HOST $PORT
        ::test::helpers::waitVar [namespace current]::ready
        conn write [::jab::header "" to $HOST]
        ::test::helpers::waitVar [namespace current]::headerReceived
        ::test::helpers::waitVar [namespace current]::stanzas
        set features [lindex $stanzas 0]
        expr {[xsearch $features mechanisms mechanism] ne ""}
    } -result 1

    test barebones-int-004 {Write buffering before connect} {*}$common -body {
        # Write before connecting - should buffer
        conn write [::jab::header "" to $HOST]
        conn connect $HOST $PORT
        ::test::helpers::waitVar [namespace current]::ready
        ::test::helpers::waitVar [namespace current]::headerReceived
        dict exists $receivedHeader attrs from
    } -result 1

    test barebones-int-005 {Connect while already connected is a no-op} {*}$common -body {
        conn connect $HOST $PORT
        ::test::helpers::waitVar [namespace current]::ready
        # Second connect should silently return
        conn connect $HOST $PORT
        expr {[conn state] eq "connected"}
    } -result 1
}

namespace eval ::test::conn {

    # Test configuration - matches with_prosody.sh
    variable HOST "example.local"
    variable PORT 5222
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
            set conn [conn conn \
                -host $HOST \
                -port $PORT \
                -username $USER \
                -password $PASS \
                -onready [namespace code onReady] \
                -ondisconnect [namespace code {onError transport}] \
                -onautherror  [namespace code {onError auth}]]
        }
        -cleanup {
            catch {conn close}
            catch {conn destroy}
        }
    }

    test authorized-int-001 {Connect and authenticate} {*}$common -body {
        conn connect
        vwait [namespace current]::done
        expr {$ready && [conn isReady]}
    } -result 1

    test authorized-int-002 {Gets bound JID after connect} {*}$common -body {
        conn connect
        vwait [namespace current]::done
        set jid [conn cget -bound-jid]
        expr {[string match "*@$HOST*" $jid]}
    } -result 1

    test authorized-int-003 {SM is enabled after connect} {*}$common -body {
        conn connect
        vwait [namespace current]::done
        set smInfo [[conn sm] getInfo]
        # SM should be in "running" state (either active or passthrough)
        expr {[dict get $smInfo state] eq "running"}
    } -result 1

    test authorized-int-004 {Invalid credentials trigger error} -constraints withServer -setup {
        variable HOST
        variable PORT
        reset
        set conn [conn conn \
            -host $HOST \
            -port $PORT \
            -username "baduser" \
            -password "badpass" \
            -onready [namespace code onReady] \
            -ondisconnect [namespace code {onError transport}] \
            -onautherror  [namespace code {onError auth}]]
    } -cleanup {
        catch {conn close}
        catch {conn destroy}
    } -body {
        conn connect
        vwait [namespace current]::done
        expr {$errorMsg ne "" && !$ready}
    } -result 1

    test authorized-int-005 {Write buffering before ready} {*}$common -body {
        # Queue a presence stanza before connecting
        conn write [j presence]
        conn connect
        vwait [namespace current]::done
        # If we got here without error, buffered write was sent
        expr {$ready && [conn isReady]}
    } -result 1
}
