# socks5.tcl - async SOCKS5 client.
#
# Usage:
#   socks5_connect ?-username U -password P? \
#       proxyHost proxyPort destHost destPort cb
#
# cb is invoked as: {*}$cb ok $sock  or  {*}$cb error $msg
#
# Returns a handle for socks5_abort, which drops a handshake still in
# progress: its socket is closed and cb never runs.
#
# On success, the socket is configured -translation binary -encoding binary
# -buffering none -blocking 0, and is handed off ready for tunneled traffic.
# On any error path socks5_connect closes the socket itself before firing
# the callback.
#
# If -username/-password are given, the client offers methods 0 (no auth)
# and 2 (user/pass) and follows the server's choice. If neither option is
# given, only method 0 is offered.
#
# Destination address type:
#   IPv4 literal  -> atyp 1
#   IPv6 literal  -> atyp 4
#   anything else -> atyp 3 (hostname, resolved by the proxy)

package require Tcl 9.0

namespace eval ::socks5 {
    # Per-channel state. Each entry is a dict with keys:
    #   cb       Caller's callback prefix
    #   username Auth username (or empty)
    #   password Auth password (or empty)
    #   destHost Destination hostname/IP
    #   destPort Destination port
    #   state    Current state name
    #   need     Bytes still needed to advance from current state
    #   buffer   Bytes accumulated so far for current state
    variable State
    array set State {}
    # handle -> the after that reports a proxy we could not even dial
    variable Pending
    array set Pending {}
    variable Failed 0

    # SOCKS5 reply codes, RFC 1928 section 6
    variable ReplyCodes
    array set ReplyCodes {
        0 "succeeded"
        1 "general SOCKS server failure"
        2 "connection not allowed by ruleset"
        3 "network unreachable"
        4 "host unreachable"
        5 "connection refused"
        6 "TTL expired"
        7 "command not supported"
        8 "address type not supported"
    }
}

proc socks5_connect {args} {
    set username ""
    set password ""
    while {[llength $args] > 0} {
        switch -- [lindex $args 0] {
            -username { set username [lindex $args 1]; set args [lrange $args 2 end] }
            -password { set password [lindex $args 1]; set args [lrange $args 2 end] }
            default break
        }
    }
    if {[llength $args] != 5} {
        error "wrong # args: socks5_connect ?-username U -password P? proxyHost proxyPort destHost destPort cb"
    }
    lassign $args proxyHost proxyPort destHost destPort cb

    if {[catch {socket -async $proxyHost $proxyPort} sock]} {
        set handle ::socks5::failed[incr ::socks5::Failed]
        set ::socks5::Pending($handle) \
            [after idle [list ::socks5::Unpend $handle $cb "connect failed: $sock"]]
        return $handle
    }
    fconfigure $sock -translation binary -buffering none -blocking 0
    set ::socks5::State($sock) [dict create \
        cb $cb \
        username $username \
        password $password \
        destHost $destHost \
        destPort $destPort \
        state connecting \
        need 0 \
        buffer ""]
    fileevent $sock writable [list ::socks5::OnWritable $sock]
    return $sock
}

proc socks5_abort {handle} {
    variable ::socks5::State
    variable ::socks5::Pending
    if {[info exists Pending($handle)]} {
        after cancel $Pending($handle)
        unset Pending($handle)
    }
    if {[info exists State($handle)]} {
        unset State($handle)
        catch {close $handle}
    }
}

proc ::socks5::Unpend {handle cb msg} {
    variable Pending
    unset -nocomplain Pending($handle)
    {*}$cb error $msg
}

proc ::socks5::OnWritable {sock} {
    variable State
    if {![info exists State($sock)]} return
    fileevent $sock writable {}
    set err [fconfigure $sock -error]
    if {$err ne ""} {
        Fail $sock "connect failed: $err"
        return
    }
    set username [dict get $State($sock) username]
    set password [dict get $State($sock) password]
    set haveAuth [expr {$username ne "" || $password ne ""}]
    if {$haveAuth} {
        set greeting [binary format ccc* 5 2 {0 2}]
    } else {
        set greeting [binary format ccc 5 1 0]
    }
    if {[catch {puts -nonewline $sock $greeting; flush $sock} e]} {
        Fail $sock "write failed: $e"
        return
    }
    dict set State($sock) state greeted
    dict set State($sock) need 2
    dict set State($sock) buffer ""
    fileevent $sock readable [list ::socks5::OnReadable $sock]
}

proc ::socks5::OnReadable {sock} {
    variable State
    if {![info exists State($sock)]} return
    set need [dict get $State($sock) need]
    set buf [dict get $State($sock) buffer]
    set toRead [expr {$need - [string length $buf]}]
    if {$toRead > 0} {
        if {[catch {read $sock $toRead} chunk]} {
            Fail $sock "read failed: $chunk"
            return
        }
        if {[string length $chunk] == 0} {
            if {[eof $sock]} {
                Fail $sock "EOF from proxy during handshake"
            }
            return
        }
        append buf $chunk
        dict set State($sock) buffer $buf
    }
    if {[string length [dict get $State($sock) buffer]] >= $need} {
        Advance $sock
    }
}

proc ::socks5::Advance {sock} {
    variable State
    set st [dict get $State($sock) state]
    set buf [dict get $State($sock) buffer]
    switch -- $st {
        greeted {
            binary scan $buf cucu version method
            if {$version != 5} {
                Fail $sock "unsupported SOCKS version from proxy: $version"
                return
            }
            if {$method == 0xFF} {
                Fail $sock "proxy: no acceptable authentication method"
                return
            }
            if {$method == 0} {
                SendConnect $sock
            } elseif {$method == 2} {
                set username [dict get $State($sock) username]
                set password [dict get $State($sock) password]
                if {$username eq "" && $password eq ""} {
                    Fail $sock "proxy requires authentication but no credentials provided"
                    return
                }
                SendAuth $sock $username $password
            } else {
                Fail $sock "proxy selected unsupported method: $method"
            }
        }
        authing {
            binary scan $buf cucu authver status
            if {$authver != 1} {
                Fail $sock "unsupported auth subnegotiation version: $authver"
                return
            }
            if {$status != 0} {
                Fail $sock "proxy rejected credentials"
                return
            }
            SendConnect $sock
        }
        connect-sent {
            binary scan $buf cucucucu version rep rsv atyp
            if {$version != 5} {
                Fail $sock "bad version in CONNECT reply: $version"
                return
            }
            if {$rep != 0} {
                variable ReplyCodes
                if {[info exists ReplyCodes($rep)]} {
                    Fail $sock "proxy error: $ReplyCodes($rep) ($rep)"
                } else {
                    Fail $sock "proxy error: $rep"
                }
                return
            }
            switch -- $atyp {
                1 {
                    dict set State($sock) state connect-tail
                    dict set State($sock) need 6
                    dict set State($sock) buffer ""
                }
                4 {
                    dict set State($sock) state connect-tail
                    dict set State($sock) need 18
                    dict set State($sock) buffer ""
                }
                3 {
                    dict set State($sock) state connect-tail-hostlen
                    dict set State($sock) need 1
                    dict set State($sock) buffer ""
                }
                default {
                    Fail $sock "bad atyp in CONNECT reply: $atyp"
                }
            }
        }
        connect-tail-hostlen {
            binary scan $buf cu hlen
            dict set State($sock) state connect-tail
            dict set State($sock) need [expr {$hlen + 2}]
            dict set State($sock) buffer ""
        }
        connect-tail {
            fileevent $sock readable {}
            set cb [dict get $State($sock) cb]
            unset State($sock)
            {*}$cb ok $sock
        }
        default {
            Fail $sock "internal: unexpected state $st"
        }
    }
}

proc ::socks5::SendAuth {sock username password} {
    variable State
    if {[string length $username] > 255 || [string length $password] > 255} {
        Fail $sock "username/password too long"
        return
    }
    set req [binary format cca*ca* \
        1 \
        [string length $username] $username \
        [string length $password] $password]
    if {[catch {puts -nonewline $sock $req; flush $sock} e]} {
        Fail $sock "write failed: $e"
        return
    }
    dict set State($sock) state authing
    dict set State($sock) need 2
    dict set State($sock) buffer ""
}

proc ::socks5::SendConnect {sock} {
    variable State
    set destHost [dict get $State($sock) destHost]
    set destPort [dict get $State($sock) destPort]
    if {[catch {AtypAddr $destHost} atypAddr]} {
        Fail $sock $atypAddr
        return
    }
    lassign $atypAddr atyp addr
    set req [binary format ccc 5 1 0]
    append req [binary format c $atyp]
    append req $addr
    append req [binary format S $destPort]
    if {[catch {puts -nonewline $sock $req; flush $sock} e]} {
        Fail $sock "write failed: $e"
        return
    }
    dict set State($sock) state connect-sent
    dict set State($sock) need 4
    dict set State($sock) buffer ""
}

proc ::socks5::AtypAddr {host} {
    if {[regexp {^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$} $host -> a b c d]} {
        if {$a < 256 && $b < 256 && $c < 256 && $d < 256} {
            return [list 1 [binary format cccc $a $b $c $d]]
        }
    }
    if {[string first ":" $host] >= 0} {
        set bytes [ParseIPv6 $host]
        if {$bytes ne ""} {
            return [list 4 $bytes]
        }
        error "invalid IPv6 address: $host"
    }
    if {[string length $host] == 0} {
        error "empty hostname"
    }
    if {[string length $host] > 255} {
        error "hostname too long: $host"
    }
    return [list 3 [binary format ca* [string length $host] $host]]
}

proc ::socks5::ParseIPv6 {addr} {
    set addr [string trim $addr "\[\]"]
    if {![regexp {^[0-9a-fA-F:.]+$} $addr]} { return "" }

    # Embedded IPv4 tail: "...:a.b.c.d" -> "...:HHHH:HHHH"
    if {[regexp {^(.*):(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$} $addr -> head a b c d]} {
        foreach v [list $a $b $c $d] {
            if {$v > 255} { return "" }
        }
        set addr [format "%s:%02x%02x:%02x%02x" $head $a $b $c $d]
    }

    set dcount [regexp -all {::} $addr]
    if {$dcount > 1} { return "" }

    if {$dcount == 1} {
        set pos [string first "::" $addr]
        set left [string range $addr 0 [expr {$pos - 1}]]
        set right [string range $addr [expr {$pos + 2}] end]
        if {$left ne "" && [string index $left end] eq ":"} { return "" }
        if {$right ne "" && [string index $right 0] eq ":"} { return "" }
        set leftParts [expr {$left eq "" ? [list] : [split $left :]}]
        set rightParts [expr {$right eq "" ? [list] : [split $right :]}]
        set fill [expr {8 - [llength $leftParts] - [llength $rightParts]}]
        if {$fill < 1} { return "" }
        set parts [concat $leftParts [lrepeat $fill 0] $rightParts]
    } else {
        set parts [split $addr :]
    }

    if {[llength $parts] != 8} { return "" }
    set bytes ""
    foreach g $parts {
        if {![regexp {^[0-9a-fA-F]{1,4}$} $g]} { return "" }
        scan $g %x val
        append bytes [binary format S $val]
    }
    return $bytes
}

proc ::socks5::Fail {sock msg} {
    variable State
    variable Pending
    if {![info exists State($sock)]} return
    set cb [dict get $State($sock) cb]
    unset State($sock)
    catch {fileevent $sock readable {}}
    catch {fileevent $sock writable {}}
    catch {close $sock}
    set Pending($sock) [after idle [list ::socks5::Unpend $sock $cb $msg]]
}

package provide socks5 0.1
