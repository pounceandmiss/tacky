# The account's SOCKS5 proxy, where it needs no proxy to test: parsing, and
# that a proxy which can't be reached ends a connection instead of letting it
# go around. The tunnel itself is tests/taco_integration/test_proxy.tcl's,
# against a real proxy.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

source [file join [file dirname [info script]] dns_responder.tcl]

# --- proxy_parse ----------------------------------------------------------

test proxy-parse-basic {host:port with no auth} -body {
    proxy_parse socks5://127.0.0.1:1080
} -result {127.0.0.1 1080 {} {}}

test proxy-parse-auth {user:pass@host:port} -body {
    proxy_parse socks5://alice:s3cr3t@proxy.example:9050
} -result {proxy.example 9050 alice s3cr3t}

test proxy-parse-user-only {user@host:port with no password} -body {
    proxy_parse socks5://alice@proxy.example:9050
} -result {proxy.example 9050 alice {}}

test proxy-parse-at-in-password {the last @ ends the credentials} -body {
    proxy_parse socks5://alice:p@ss@proxy.example:9050
} -result {proxy.example 9050 alice p@ss}

test proxy-parse-ipv6 {bracketed IPv6 literal, brackets stripped} -body {
    proxy_parse {socks5://[::1]:1080}
} -result {::1 1080 {} {}}

test proxy-parse-ipv6-auth {IPv6 literal with auth} -body {
    proxy_parse {socks5://u:p@[2001:db8::1]:1080}
} -result {2001:db8::1 1080 u p}

test proxy-parse-empty {empty string means disabled} -body {
    proxy_parse ""
} -result {}

test proxy-parse-bad-scheme {a non-socks5 scheme is rejected} -body {
    proxy_parse http://h:1
} -returnCodes error -result {proxy must start with socks5://: http://h:1}

test proxy-parse-no-port {a missing port is rejected} -body {
    proxy_parse socks5://host
} -returnCodes error -match glob -result {*missing a port*}

test proxy-parse-nonnumeric-port {a non-numeric port is rejected} -body {
    proxy_parse socks5://host:abc
} -returnCodes error -match glob -result {*invalid proxy host/port*}

test proxy-parse-port-range {a port past 65535 is rejected} -body {
    proxy_parse socks5://host:65536
} -returnCodes error -match glob -result {*invalid proxy host/port*}

# --- the account field ----------------------------------------------------

set common {
    -setup {
        tacky account add -acc user@example.com
        wait_call tacky account exists -acc user@example.com
    }
}

tacky_test account-proxy-round-trip {the proxy field round-trips through set/get} \
    {*}$common \
    -body {
        tacky account set -acc user@example.com -proxy socks5://127.0.0.1:1080
        wait_call tacky account get -acc user@example.com -field proxy
    } -result socks5://127.0.0.1:1080

tacky_test account-proxy-default {a new account has no proxy} \
    {*}$common \
    -body {
        wait_call tacky account get -acc user@example.com -field proxy
    } -result {}

tacky_test account-proxy-refused {a malformed proxy is refused and not stored} \
    {*}$common \
    -body {
        list [wait_call_error tacky account set -acc user@example.com \
                -proxy http://127.0.0.1:1080] \
            [wait_call tacky account get -acc user@example.com -field proxy]
    } -result {{proxy must start with socks5://: http://127.0.0.1:1080} {}}

# --- a new proxy ends the session on the old route --------------------------

proc proxy_instance {client} {
    namespace qualifiers [lindex [$client info vars] 0]
}

test account-proxy-change-ends-session {a new proxy ends the session, and the same client connects again on it} \
    {*}[tacky_env -mock conn -account user@example.com -capture-emit 1] -body {
        tacky account enable -acc user@example.com
        set old [proxy_instance $::_client]
        set ::_closing {}
        $::_client bus subscribe _ <Closing> {apply {{args} {
            lappend ::_closing [dict get $args -reason]
        }}}
        set ::_emitted {}
        tacky account set -acc user@example.com -proxy socks5://127.0.0.1:1080
        set c [tacky client user@example.com]
        list [expr {[proxy_instance $c] eq $old}] $::_closing \
            [$c.conn get_closed] [$c.conn get_connects] [$c cget -proxy] \
            [lmap e $::_emitted {expr {[lindex $e 0] eq "account" ? $e : [continue]}}]
    } -result {1 {{proxy changed}} 1 2 socks5://127.0.0.1:1080 {}}

test account-proxy-change-disabled-stays-off {a new proxy on a disabled account ends nothing and dials nothing} \
    {*}[tacky_env -mock conn -account user@example.com -enabled 0] -body {
        set c [tacky client user@example.com]
        tacky account set -acc user@example.com -proxy socks5://127.0.0.1:1080
        list [$c.conn get_connects] [$c cget -proxy]
    } -result {0 socks5://127.0.0.1:1080}

test account-proxy-unchanged-keeps-client {setting other fields, or the same proxy, keeps the client} \
    {*}[tacky_env -mock conn -account user@example.com] -body {
        tacky account set -acc user@example.com -proxy socks5://127.0.0.1:1080
        tacky account enable -acc user@example.com
        set c [tacky client user@example.com]
        set old [proxy_instance $c]
        tacky account set -acc user@example.com -host xmpp.example.com
        tacky account set -acc user@example.com -proxy socks5://127.0.0.1:1080
        expr {[proxy_instance [tacky client user@example.com]] eq $old}
    } -result 1

# --- nothing goes around a dead proxy -------------------------------------
#
# A port with nothing listening stands in for a proxy that is down. Next to
# it, a listener stands where the direct connection would go: it must never
# be reached.

namespace eval proxytest {
    variable accepted 0
    proc accept {chan args} {
        variable accepted
        incr accepted
        close $chan
    }
    # A free port, closed again: connecting to it is refused
    proc deadPort {} {
        set s [socket -server {apply {args {}}} -myaddr 127.0.0.1 0]
        set port [lindex [fconfigure $s -sockname] 2]
        close $s
        return $port
    }
}

set dead_common {
    -constraints !wasm
    -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::proxytest::accepted 0
        set direct [socket -server ::proxytest::accept -myaddr 127.0.0.1 0]
        set directPort [lindex [fconfigure $direct -sockname] 2]
        set deadProxy socks5://127.0.0.1:[::proxytest::deadPort]
        set ::_proxyGone ""
    }
    -cleanup {
        catch {_proxyC destroy}
        catch {close $direct}
        catch {dnsresp::stop}
        jlog configure -logproc ""
        unset -nocomplain ::_proxyGone
    }
}

test proxy-dead-conn-no-direct {a dead proxy fails the link, and the server is never dialled} \
    {*}$dead_common -body {
        conn _proxyC -domain example.com -host 127.0.0.1 -port $directPort \
            -tls none -username u -password p -keepalive 0 -wake-check 0 \
            -proxy $deadProxy \
            -ondisconnect {apply {{msg} {set ::_proxyGone $msg}}}
        _proxyC connect
        wait_var ::_proxyGone 5000
        update
        list [string match "Connect failed: can't reach the proxy: *" $::_proxyGone] \
            $::proxytest::accepted
    } -result {1 0}

test proxy-skips-srv {through a proxy no SRV query is sent, the domain goes to the proxy} \
    {*}$dead_common -body {
        # "." under both: asked, these would leave nothing to dial at all
        set ns [dnsresp::start {
            _xmpps-client._tcp.example.com {{0 0 0 .}}
            _xmpp-client._tcp.example.com  {{0 0 0 .}}
        }]
        conn _proxyC -domain example.com -tls none -username u -password p \
            -keepalive 0 -wake-check 0 -proxy $deadProxy \
            -nameservers [list [list 127.0.0.1 $ns]] \
            -ondisconnect {apply {{msg} {set ::_proxyGone $msg}}}
        _proxyC connect
        wait_var ::_proxyGone 5000
        list [string match "Connect failed: can't reach the proxy: *" $::_proxyGone] \
            [dnsresp::queries]
    } -result {1 {}}

test proxy-srv-without-proxy {the control: without a proxy the same conn asks SRV} \
    {*}$dead_common -body {
        # "." under both: asked, these would leave nothing to dial at all
        set ns [dnsresp::start {
            _xmpps-client._tcp.example.com {{0 0 0 .}}
            _xmpp-client._tcp.example.com  {{0 0 0 .}}
        }]
        conn _proxyC -domain example.com -tls none -username u -password p \
            -keepalive 0 -wake-check 0 \
            -nameservers [list [list 127.0.0.1 $ns]] \
            -ondisconnect {apply {{msg} {set ::_proxyGone $msg}}}
        _proxyC connect
        wait_var ::_proxyGone 5000
        list $::_proxyGone [lsort [dnsresp::queries]]
    } -result {{Connect failed: example.com publishes no XMPP service} _xmpp-client._tcp.example.com}

test proxy-dead-http-no-direct {a dead proxy fails an HTTP request, and the host is never dialled} \
    {*}$dead_common -body {
        set out [file tempfile path]
        close $out
        set ::_proxyGone ""
        set tok [taco_http get http://127.0.0.1:$directPort/x -outfile $path \
            -proxy $deadProxy -command {apply {{t} {set ::_proxyGone done}}}]
        wait_var ::_proxyGone 5000
        update
        set r [list [taco_http status $tok] \
            [string match "*proxy:*" [taco_http error $tok]] \
            $::proxytest::accepted]
        taco_http cleanup $tok
        file delete $path
        set r
    } -result {error 1 0}

test proxy-http-direct-still-works {the control: without a proxy the same request reaches the host} \
    {*}$dead_common -body {
        set out [file tempfile path]
        close $out
        set tok [taco_http get http://127.0.0.1:$directPort/x -outfile $path \
            -command {apply {{t} {set ::_proxyGone done}}}]
        wait_var ::_proxyGone 5000
        taco_http cleanup $tok
        file delete $path
        set ::proxytest::accepted
    } -result 1

test proxy-http-socket-needs-route {a socket asked for a request taco_http never routed is refused} \
    -constraints !wasm -body {
        ::taco_http::NativeInit
        ::taco_http::Socket 0 -async -type ::http::nosuch 127.0.0.1 80
    } -returnCodes error -result {no route for this request}

test proxy-http-bad-proxy {a malformed proxy fails the request before anything is opened} \
    -constraints !wasm -body {
        taco_http get http://127.0.0.1:1/x -outfile /nonexistent/x \
            -proxy socks5://nope
    } -returnCodes error -match glob -result {*missing a port*}

