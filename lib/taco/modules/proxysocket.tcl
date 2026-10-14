# proxysocket.tcl - an account's SOCKS5 proxy, shared by everything that
# opens a connection for it: the XMPP link (baseconn) and HTTP (taco_http).
#
#   proxy_parse PROXY                -> {host port user pass}, "" for none
#   proxy_endpoint PROXY             -> "host:port" with no login, "" for none
#   proxy_route PROXY TOR KEY        -> the proxy an account goes through
#   proxy_open PROXY HOST PORT CB    -> handle for proxy_abort
#       {*}$CB ok $chan | {*}$CB error $message
#   proxy_abort HANDLE               the handshake ends, CB never runs
#
# Through a proxy nothing falls back to a direct connection: a caller that
# can't get a tunnel fails. HOST goes to the proxy as a name (SOCKS5 atyp 3),
# so it is resolved there and never looked up here.
#
# Tor is a SOCKS5 proxy too: proxy_route turns an account's proxy and tor
# fields into the one it goes through.

package require socks5

namespace eval ::proxysocket {
    # Where Tor listens when the account names no address for it
    variable TorDefault socks5://127.0.0.1:9050
    # key -> the made-up login that keeps it on circuits of its own
    variable Isolation
    array set Isolation {}
}

# Parse "socks5://[user:pass@]host:port" into {host port user pass}.
# Returns "" for an empty/disabled proxy. Errors on a malformed value.
proc proxy_parse {s} {
    if {$s eq ""} {
        return ""
    }
    if {![regsub {^socks5://} $s {} rest]} {
        error "proxy must start with socks5://: $s"
    }
    set user ""
    set pass ""
    set at [string last @ $rest]
    if {$at >= 0} {
        set cred [string range $rest 0 [expr {$at - 1}]]
        set rest [string range $rest [expr {$at + 1}] end]
        set colon [string first : $cred]
        if {$colon >= 0} {
            set user [string range $cred 0 [expr {$colon - 1}]]
            set pass [string range $cred [expr {$colon + 1}] end]
        } else {
            set user $cred
        }
    }
    # host:port, where host may be a bracketed IPv6 literal [::1].
    if {[string index $rest 0] eq "\["} {
        set close [string first "\]" $rest]
        if {$close < 0} {
            error "unterminated IPv6 literal in proxy: $s"
        }
        set host [string range $rest 1 [expr {$close - 1}]]
        set tail [string range $rest [expr {$close + 1}] end]
        if {[string index $tail 0] ne ":"} {
            error "proxy is missing a port: $s"
        }
        set port [string range $tail 1 end]
    } else {
        set colon [string last : $rest]
        if {$colon < 0} {
            error "proxy is missing a port: $s"
        }
        set host [string range $rest 0 [expr {$colon - 1}]]
        set port [string range $rest [expr {$colon + 1}] end]
    }
    if {$host eq "" || ![string is integer -strict $port]
            || $port < 1 || $port > 65535} {
        error "invalid proxy host/port: $s"
    }
    return [list $host $port $user $pass]
}

# Where PROXY is, fit to show: host:port, an IPv6 host back in brackets, and
# never the login. "" for no proxy.
proc proxy_endpoint {s} {
    if {$s eq ""} {
        return ""
    }
    lassign [proxy_parse $s] host port
    if {[string first : $host] >= 0} {
        set host "\[$host\]"
    }
    return $host:$port
}

# The proxy an account's connections go through: PROXY as it is, or with TOR
# set, Tor at PROXY or, when that's "", at its usual address. Tor keeps
# connections that log in differently on different circuits, so an account
# whose PROXY has no login gets one of its own, the same for every KEY
# (the account) in this process and unrelated to it. A login in PROXY is
# used as given, so accounts can share one on purpose.
proc proxy_route {proxy tor key} {
    if {!$tor} {
        return $proxy
    }
    if {$proxy eq ""} {
        set proxy $::proxysocket::TorDefault
    }
    lassign [proxy_parse $proxy] host port user pass
    if {$user ne "" || $pass ne ""} {
        return $proxy
    }
    variable ::proxysocket::Isolation
    if {![info exists Isolation($key)]} {
        package require mtls
        binary scan [::mtls::randombytes 16] H* Isolation($key)
    }
    set login $Isolation($key)
    regsub {^socks5://} $proxy "socks5://$login:$login@" proxy
    return $proxy
}

proc proxy_open {proxy host port cb} {
    lassign [proxy_parse $proxy] pHost pPort pUser pPass
    set auth {}
    if {$pUser ne "" || $pPass ne ""} {
        set auth [list -username $pUser -password $pPass]
    }
    return [socks5_connect {*}$auth $pHost $pPort $host $port $cb]
}

proc proxy_abort {handle} {
    socks5_abort $handle
}
