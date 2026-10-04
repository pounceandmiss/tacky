# browserws.tcl - tcllib's ::websocket client API over the browser's
# WebSocket (wasm/em/ws.js, via ::em::call). Defined only in a wasm build,
# and only if ::websocket::open isn't defined yet. Not a package, so the
# bundled tcllib websocket is never loaded instead.
#
#   ::websocket::open url handler ?-protocol list?   -> sock
#   ::websocket::send sock text msg                  -> length sent
#   ::websocket::close sock ?code? ?reason?
#
# The handler is called as `{*}handler sock type msg` with tcllib's types:
# connect (msg is the negotiated subprotocol), text, error, then
# close {code reason} and disconnect. Text messages only.

if {[llength [info commands ::em::call]]
        && ![llength [info commands ::websocket::open]]} {

namespace eval ::websocket {
    # sock -> {call id, handler}
    variable Socks
    array set Socks {}
    # sock -> the reason the browser gave with its close
    variable Reasons
    array set Reasons {}
    variable Next 0
}

proc ::websocket::open {url handler args} {
    variable Socks
    variable Next

    set protocols {}
    foreach {opt value} $args {
        switch -glob -- $opt {
            -prot* { set protocols $value }
            default { error "$opt is not a recognised option" }
        }
    }
    set sock emws[incr Next]
    set id [::em::call -progress [list ::websocket::Event $sock] \
        -command [list ::websocket::Closed $sock] \
        tackyWsOpen $sock $url {*}$protocols]
    set Socks($sock) [list $id $handler]
    return $sock
}

proc ::websocket::send {sock type {msg ""}} {
    variable Socks
    if {![info exists Socks($sock)]} {
        error "$sock is not a WebSocket"
    }
    if {![string match t* $type]} {
        error "only text messages in a browser"
    }
    # A failed send arrives as an error event.
    ::em::call -command [list ::websocket::Sent $sock] tackyWsSend $sock $msg
    return [string length $msg]
}

proc ::websocket::close {sock {code 1000} {reason ""}} {
    variable Socks
    if {![info exists Socks($sock)]} {
        error "$sock is not a WebSocket"
    }
    variable Reasons
    ::em::call -command list tackyWsClose $sock $code $reason
    set Reasons($sock) $reason
    Closed $sock ok $code
}

proc ::websocket::Event {sock kind payload} {
    variable Socks
    variable Reasons
    if {![info exists Socks($sock)]} return
    if {$kind eq "close"} {
        set Reasons($sock) $payload
        return
    }
    Push $sock $kind $payload
}

proc ::websocket::Sent {sock result value} {
    if {$result ne "ok"} {
        Event $sock error $value
    }
}

# The open call settled with the close code, or failed: report close and
# disconnect, once.
proc ::websocket::Closed {sock result value} {
    variable Socks
    variable Reasons
    if {![info exists Socks($sock)]} return
    lassign $Socks($sock) id handler
    unset Socks($sock)
    ::em::cancel $id
    if {$result eq "ok"} {
        set msg [list $value [expr {[info exists Reasons($sock)] ? $Reasons($sock) : ""}]]
    } else {
        set msg [list 1006 $value]
    }
    unset -nocomplain Reasons($sock)
    Push $sock close $msg $handler
    Push $sock disconnect "Disconnected from remote end" $handler
}

proc ::websocket::Push {sock type msg {handler ""}} {
    variable Socks
    if {$handler eq ""} {
        set handler [lindex $Socks($sock) 1]
    }
    if {[catch {{*}$handler $sock $type $msg} err]} {
        after idle [list error $err]
    }
}

}
