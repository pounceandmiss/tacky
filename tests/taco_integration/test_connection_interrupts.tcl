# TcpProxy - transparent byte-level TCP proxy with kill switch
#
# Sits between client and server, forwarding raw bytes. TLS handshakes
# pass through end-to-end (the proxy never terminates TLS). Calling
# "kill" abruptly severs both sides, causing the client's reader to
# see EOF -- same as a real network drop from the server.

snit::type TcpProxy {
    variable listenSock ""
    variable clientSock ""
    variable serverSock ""
    variable serverHost
    variable serverPort
    variable localPort 0

    constructor {shost sport} {
        set serverHost $shost
        set serverPort $sport
        set listenSock [socket -server [mymethod OnAccept] 0]
        set localPort [lindex [fconfigure $listenSock -sockname] 2]
    }

    method port {} { return $localPort }

    method OnAccept {chan addr port} {
        set clientSock $chan
        set serverSock [socket $serverHost $serverPort]
        foreach s [list $clientSock $serverSock] {
            fconfigure $s -blocking 0 -buffering none -translation binary
        }
        fileevent $clientSock readable [mymethod Fwd clientSock serverSock]
        fileevent $serverSock readable [mymethod Fwd serverSock clientSock]
    }

    method Fwd {fromVar toVar} {
        set from [set $fromVar]
        set to [set $toVar]
        if {[catch {set data [read $from]}] || [eof $from]} {
            $self kill
            return
        }
        catch {puts -nonewline $to $data; flush $to}
    }

    method kill {} {
        foreach sock {clientSock serverSock} {
            if {[set $sock] ne ""} {
                catch {fileevent [set $sock] readable {}}
                catch {close [set $sock]}
                set $sock ""
            }
        }
    }

    destructor {
        $self kill
        if {$listenSock ne ""} {
            catch {close $listenSock}
        }
    }
}

namespace eval ::test::BareInterrupt {

    variable HOST "example.local"
    variable PORT 5222

    variable ready 0
    variable transportError ""
    variable done 0

    proc reset {} {
        variable ready 0
        variable transportError ""
        variable done 0
    }

    proc onReady {} {
        variable ready; variable done
        set ready 1; set done 1
    }

    proc onTransportError {msg} {
        variable transportError; variable done
        set transportError $msg; set done 1
    }

    set common {
        -constraints withServer
        -setup {
            variable HOST; variable PORT
            reset
            set proxy [TcpProxy proxy $HOST $PORT]
            set proxyPort [proxy port]
            set conn [bareconn conn \
                -onready [namespace code onReady] \
                -ondisconnect [namespace code onTransportError]]
        }
        -cleanup {
            catch {conn close}
            catch {conn destroy}
            catch {proxy destroy}
        }
    }

    test bare-int-interrupt-001 {Error callback fires on connection loss} \
        {*}$common -body {
        conn connect $HOST $proxyPort
        ::test::helpers::waitVar [namespace current]::done
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        expr {$transportError ne ""}
    } -result 1

    test bare-int-interrupt-002 {State is disconnected after connection loss} \
        {*}$common -body {
        conn connect $HOST $proxyPort
        ::test::helpers::waitVar [namespace current]::done
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        # Current implementation auto-closes transport on error
        expr {[conn state] eq "disconnected"}
    } -result 1
}

namespace eval ::test::AuthInterrupt {

    variable HOST "example.local"
    variable PORT 5222
    variable USER "test"
    variable PASS "testpass"

    variable ready 0
    variable errorMsg ""
    variable done 0
    variable lastState ""

    proc reset {} {
        variable ready 0
        variable errorMsg ""
        variable done 0
        variable lastState ""
    }

    proc onReady {resumed} {
        variable ready; variable done
        set ready 1; set done 1
    }

    proc onError {kind msg} {
        variable errorMsg; variable done
        set errorMsg $msg; set done 1
    }

    proc onEmit {args} {
        variable lastState
        set event [lindex $args 1]
        if {$event eq "<State>"} {
            set idx [lsearch -exact $args -state]
            set lastState [lindex $args [expr {$idx + 1}]]
        }
    }

    # Common setup: proxy + conn through the proxy
    set common {
        -constraints withServer
        -setup {
            variable HOST; variable PORT; variable USER; variable PASS
            reset
            set proxy [TcpProxy proxy $HOST $PORT]
            set proxyPort [proxy port]
            set conn [conn conn \
                -host $HOST \
                -port $proxyPort \
                -username $USER \
                -password $PASS \
                -emit [namespace code onEmit] \
                -onready [namespace code onReady] \
                -ondisconnect [namespace code {onError transport}] \
                -onautherror  [namespace code {onError auth}]]
        }
        -cleanup {
            catch {conn close}
            catch {conn destroy}
            catch {proxy destroy}
        }
    }

    # ---- While fully connected ----

    test auth-int-interrupt-001 {onerror fires on loss while ready} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done
        if {!$ready} { error "did not reach ready" }
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        expr {$errorMsg ne ""}
    } -result 1

    test auth-int-interrupt-002 {isReady false after loss while ready} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        expr {![conn isReady]}
    } -result 1

    # ---- During SASL authentication ----

    test auth-int-interrupt-003 {onerror fires on loss during authentication} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitForState [namespace current]::lastState authenticating
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        expr {$errorMsg ne "" && !$ready}
    } -result 1

    # ---- During resource binding ----

    test auth-int-interrupt-004 {onerror fires on loss during binding} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitForState [namespace current]::lastState binding
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        expr {$errorMsg ne "" && !$ready}
    } -result 1

    # ---- Cleanup after loss ----

    test auth-int-interrupt-005 {Close after loss during auth is safe} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitForState [namespace current]::lastState authenticating
        proxy kill
        ::test::helpers::waitVar [namespace current]::done
        conn close
        expr {![conn isReady]}
    } -result 1
}

namespace eval ::test::AutoReconnect {

    variable HOST "example.local"
    variable PORT 5222
    variable USER "test"
    variable PASS "testpass"

    variable readyCount 0
    variable errorKind ""
    variable errorMsg ""
    variable stateLog {}
    variable lastState ""
    variable done 0

    proc reset {} {
        variable readyCount 0
        variable errorKind ""
        variable errorMsg ""
        variable stateLog {}
        variable lastState ""
        variable done 0
    }

    proc onReady {resumed} {
        variable readyCount; variable done
        incr readyCount
        set done 1
    }

    proc onError {kind msg} {
        variable errorKind; variable errorMsg
        set errorKind $kind
        set errorMsg $msg
    }

    proc onEmit {args} {
        variable stateLog; variable lastState
        set event [lindex $args 1]
        if {$event eq "<State>"} {
            set idx [lsearch -exact $args -state]
            set s [lindex $args [expr {$idx + 1}]]
            lappend stateLog $s
            set lastState $s
        }
    }

    # Common setup: proxy + conn with -autoreconnect 1
    set common {
        -constraints withServer
        -setup {
            variable HOST; variable PORT; variable USER; variable PASS
            reset
            set proxy [TcpProxy proxy $HOST $PORT]
            set proxyPort [proxy port]
            set conn [conn conn \
                -host $HOST \
                -port $proxyPort \
                -username $USER \
                -password $PASS \
                -autoreconnect 1 \
                -emit [namespace code onEmit] \
                -onready [namespace code onReady] \
                -ondisconnect [namespace code {onError transport}] \
                -onautherror  [namespace code {onError auth}]]
        }
        -cleanup {
            catch {conn close}
            catch {conn destroy}
            catch {proxy destroy}
        }
    }

    test reconnect-001 {Auto-reconnect succeeds after proxy kill} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done 6000
        list $readyCount [conn isReady] [conn state]
    } -result {2 1 connected}

    test reconnect-002 {state sequence is correct through reconnect} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done 6000
        set stateLog
    } -result {connecting authenticating binding connected waiting connecting authenticating binding connected}

    test reconnect-003 {state reaches waiting before reconnect} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        proxy kill
        ::test::helpers::waitForState [namespace current]::lastState waiting
        conn state
    } -result waiting

    test reconnect-004 {close during waiting cancels reconnect} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        proxy kill
        ::test::helpers::waitForState [namespace current]::lastState waiting
        conn close
        list [conn state] $readyCount
    } -result {disconnected 1}

    test reconnect-005 {Second reconnect also succeeds (backoff resets)} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        # First reconnect cycle
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done 6000
        # Second reconnect cycle
        set done 0
        proxy kill
        ::test::helpers::waitVar [namespace current]::done 6000
        set readyCount
    } -result 3

    test reconnect-006 {isReady is false during waiting state} \
        {*}$common -body {
        conn connect
        ::test::helpers::waitVar [namespace current]::done 6000
        proxy kill
        ::test::helpers::waitForState [namespace current]::lastState waiting
        conn isReady
    } -result 0
}
