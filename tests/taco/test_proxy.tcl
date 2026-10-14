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

# --- proxy_endpoint -------------------------------------------------------

test proxy-endpoint-drops-login {host:port, without the login} -body {
    proxy_endpoint socks5://alice:s3cr3t@proxy.example:9050
} -result proxy.example:9050

test proxy-endpoint-ipv6 {an IPv6 host goes back in brackets} -body {
    proxy_endpoint {socks5://u:p@[2001:db8::1]:1080}
} -result {[2001:db8::1]:1080}

test proxy-endpoint-none {no proxy, no endpoint} -body {
    proxy_endpoint ""
} -result {}

# --- proxy_route ----------------------------------------------------------

# The login a route carries, "" for none
proc route_login {proxy} {
    lassign [proxy_parse $proxy] host port user pass
    list $user $pass
}

test proxy-route-no-tor {without tor the proxy is as stored} -body {
    list [proxy_route "" 0 a@example.com] \
        [proxy_route socks5://127.0.0.1:1080 0 a@example.com]
} -result {{} socks5://127.0.0.1:1080}

test proxy-route-tor-default {tor with no proxy goes to 127.0.0.1:9050} -body {
    proxy_endpoint [proxy_route "" 1 a@example.com]
} -result 127.0.0.1:9050

test proxy-route-tor-address {tor at the proxy given} -body {
    proxy_endpoint [proxy_route {socks5://[::1]:9150} 1 a@example.com]
} -result {[::1]:9150}

test proxy-route-tor-login {tor without a login gets one: the same for an account, another for another} -body {
    set a [route_login [proxy_route "" 1 a@example.com]]
    set a2 [route_login [proxy_route socks5://127.0.0.1:9050 1 a@example.com]]
    set b [route_login [proxy_route "" 1 b@example.com]]
    list [expr {[lindex $a 0] ne ""}] [expr {$a eq $a2}] [expr {$a ne $b}]
} -result {1 1 1}

test proxy-route-tor-login-unrelated {the made-up login says nothing of the account} -body {
    set login [route_login [proxy_route "" 1 romeo@montague.example]]
    expr {[string match *romeo* $login] || [string match *montague* $login]}
} -result 0

test proxy-route-tor-own-login {a login in the proxy is used as given} -body {
    proxy_route socks5://alice:x@127.0.0.1:9050 1 a@example.com
} -result socks5://alice:x@127.0.0.1:9050

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

tacky_test account-tor-round-trip {tor round-trips through set/get, a non-boolean is refused} \
    {*}$common \
    -body {
        set before [wait_call tacky account get -acc user@example.com -field tor]
        tacky account set -acc user@example.com -tor true
        list $before [wait_call tacky account get -acc user@example.com -field tor] \
            [wait_call_error tacky account set -acc user@example.com -tor maybe]
    } -result {0 1 {Invalid tor: maybe}}

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

test account-tor-change-ends-session {turning tor on ends the session, and the client goes through Tor} \
    {*}[tacky_env -mock conn -account user@example.com] -body {
        tacky account enable -acc user@example.com
        set ::_closing {}
        $::_client bus subscribe _ <Closing> {apply {{args} {
            lappend ::_closing [dict get $args -reason]
        }}}
        tacky account set -acc user@example.com -tor 1
        set c [tacky client user@example.com]
        list $::_closing [$c.conn get_connects] \
            [proxy_endpoint [$c cget -proxy]] \
            [expr {[lindex [route_login [$c cget -proxy]] 0] ne ""}]
    } -result {{{proxy changed}} 2 127.0.0.1:9050 1}

test account-tor-off-goes-direct {turning tor off again ends the session and leaves no proxy} \
    {*}[tacky_env -mock conn -account user@example.com] -body {
        tacky account set -acc user@example.com -tor 1
        tacky account enable -acc user@example.com
        set ::_closing {}
        $::_client bus subscribe _ <Closing> {apply {{args} {
            lappend ::_closing [dict get $args -reason]
        }}}
        tacky account set -acc user@example.com -tor 0
        list $::_closing [[tacky client user@example.com] cget -proxy]
    } -result {{{proxy changed}} {}}

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

# --- a proxy that answers: retried or not ---------------------------------
#
# A stand-in proxy that answers each read from the client with the next
# canned reply. Whether the link retries depends on what the proxy said:
# refusing us holds until the settings change, the target being unreachable
# from it may pass.

namespace eval proxytest {
    variable replies {}
    proc fake {replyList} {
        variable replies $replyList
        set s [socket -server ::proxytest::fakeAccept -myaddr 127.0.0.1 0]
        return [list $s [lindex [fconfigure $s -sockname] 2]]
    }
    proc fakeAccept {chan args} {
        variable replies
        fconfigure $chan -translation binary -blocking 0
        fileevent $chan readable [list ::proxytest::fakeRead $chan $replies]
    }
    proc fakeRead {chan pending} {
        if {[catch {read $chan} got] || [eof $chan]} {
            catch {close $chan}
            return
        }
        if {$got eq "" || ![llength $pending]} return
        puts -nonewline $chan [lindex $pending 0]
        flush $chan
        fileevent $chan readable \
            [list ::proxytest::fakeRead $chan [lrange $pending 1 end]]
    }
    # The link's events; the first <ConnError> ends the wait.
    proc record {args} {
        lappend ::_temitted $args
        if {[lindex $args 1] eq "<ConnError>"} { set ::_proxyGone 1 }
    }
    # The greeting's answer (no auth), then a CONNECT reply with `rep`.
    proc connectReply {rep} {
        list [binary format cc 5 0] \
            [binary format ccccx6 5 $rep 0 1]
    }
}

set answered_common {
    -constraints !wasm
    -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::_temitted {}
        set ::_proxyGone ""
    }
    -cleanup {
        catch {_proxyC destroy}
        catch {close $fakeSock}
        jlog configure -logproc ""
    }
}

# What the link said, and where it is, once the first attempt is over.
proc proxytest::outcome {replies} {
    lassign [proxytest::fake $replies] ::fakeSock port
    uplevel #0 [list set fakeSock $::fakeSock]
    conn ::_proxyC -domain example.com -host 127.0.0.1 -port 5222 \
        -tls none -username u -password p -keepalive 0 -wake-check 0 \
        -autoreconnect 1 -proxy socks5://127.0.0.1:$port \
        -emit ::proxytest::record
    ::_proxyC connect
    wait_var ::_proxyGone 5000
    update
    set said {}
    foreach e $::_temitted {
        if {[lindex $e 1] in {<ConnError> <Disconnected>}} {
            lappend said [lindex $e 1] [dict get [lrange $e 2 end] -message]
        }
    }
    list [::_proxyC state] $said
}

test proxy-refusal-stops {a proxy that refuses us stops the link: no retry, <Disconnected>} \
    {*}$answered_common -body {
        proxytest::outcome [list [binary format cc 5 0xFF]]
    } -result {disconnected {<ConnError> {Connect failed: proxy accepts none of our authentication methods} <Disconnected> {Connect failed: proxy accepts none of our authentication methods}}}

test proxy-ruleset-stops {a request the proxy's rules forbid stops the link} \
    {*}$answered_common -body {
        proxytest::outcome [proxytest::connectReply 2]
    } -result {disconnected {<ConnError> {Connect failed: proxy error: connection not allowed by ruleset (2)} <Disconnected> {Connect failed: proxy error: connection not allowed by ruleset (2)}}}

test proxy-target-unreachable-retries {the server unreachable from the proxy is retried, as it would be directly} \
    {*}$answered_common -body {
        proxytest::outcome [proxytest::connectReply 5]
    } -result {waiting {<ConnError> {Connect failed: proxy error: connection refused (5)}}}

test proxy-dead-retries {a proxy that can't be reached is retried} \
    {*}$answered_common -body {
        set fakeSock ""
        conn _proxyC -domain example.com -host 127.0.0.1 -port 5222 \
            -tls none -username u -password p -keepalive 0 -wake-check 0 \
            -autoreconnect 1 -proxy socks5://127.0.0.1:[::proxytest::deadPort] \
            -emit ::proxytest::record
        _proxyC connect
        wait_var ::_proxyGone 5000
        update
        list [_proxyC state] \
            [llength [lsearch -all -glob $::_temitted {conn <Disconnected> *}]]
    } -result {waiting 0}

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

