# taco_http - the HTTP a file transfer needs, from whichever client this build
# has: Tcl's http package over a socket natively, with mtls registered for
# https, and the page's own stack in a browser, reached through zippy's
# ::em::call and wasm/em/http.js. This chooses between the two.
#
#   taco_http get URL -outfile PATH ?-timeout MS? ?-headers DICT?
#                     ?-progress CMD? ?-command CMD? ?-proxy P?  -> token
#   taco_http put URL -infile PATH ?-type MIME? ?-headers DICT?
#                     ?-timeout MS? ?-progress CMD? ?-command CMD?
#                     ?-proxy P?                                 -> token
#   taco_http status  TOKEN    ok | error | timeout | reset ("" while in flight)
#   taco_http ncode   TOKEN    the HTTP status code
#   taco_http error   TOKEN    why it failed, "" otherwise
#   taco_http reset   TOKEN    cancel it
#   taco_http cleanup TOKEN    drop it
#
# -proxy is an account's (see proxysocket.tcl): the request goes through it or
# fails, never around it. A browser has no way to honour one, so there a
# request with a proxy is refused.
#
# -timeout is how long a request may go without moving a byte, not how long it
# may take: a large file over a slow link is still a transfer.
#
# -command is called with the token, -progress with `token total current`. A
# request is always asynchronous - the browser has no other kind, and the
# native side opens and closes its own channel around a callback - so a caller
# that omits -command has to watch `status` for the answer.
#
# Bodies are named by path rather than handed over as channels, which is what
# the browser forces: JavaScript reads and writes Emscripten's filesystem, not
# Tcl channels. The native backend opens and closes
# the channel itself, so a caller sees the same contract either way: the bytes
# are at the path when -command fires.

namespace eval ::taco_http {
    # Whether the native backend has registered its https transport yet.
    variable Registered 0
    # Browser requests: token -> {call id, status, ncode, error, command}.
    variable Requests
    array set Requests {}
    variable Next 0
    # Native requests with a -timeout: token -> the after that resets it.
    variable Idle
    array set Idle {}
    # Native requests: token -> the proxy its socket goes through, "" for
    # none. A socket asked for a token not here is refused, so a request
    # whose route went missing can't fall back to a direct connection.
    variable Route
    array set Route {}
    # Native requests whose proxy handshake is in progress: token ->
    # {handle coroutine}
    variable Handshake
    array set Handshake {}
}

proc taco_http {op args} {
    switch -exact -- $op {
        get     { return [::taco_http::Request GET {*}$args] }
        put     { return [::taco_http::Request PUT {*}$args] }
        status  { return [::taco_http::Query status  {*}$args] }
        ncode   { return [::taco_http::Query ncode   {*}$args] }
        error   { return [::taco_http::Query error   {*}$args] }
        reset   { return [::taco_http::Query reset   {*}$args] }
        cleanup { return [::taco_http::Query cleanup {*}$args] }
    }
    error "unknown taco_http operation \"$op\": must be\
        get, put, status, ncode, error, reset or cleanup"
}

# ::em::call exists only in a wasm build.
proc ::taco_http::Browser {} {
    return [expr {[llength [info commands ::em::call]] > 0}]
}

proc ::taco_http::Request {method url args} {
    array set o {
        -outfile "" -infile "" -type "" -headers "" -timeout 0
        -progress "" -command "" -proxy ""
    }
    array set o $args
    if {[Browser]} {
        if {$o(-proxy) ne ""} {
            error "a proxy can't carry the browser's requests"
        }
        return [BrowserRequest $method $url o]
    }
    return [NativeRequest $method $url o]
}

proc ::taco_http::Query {op token} {
    if {[Browser]} {
        return [BrowserQuery $op $token]
    }
    NativeInit
    if {$op eq "cleanup"} {
        NativeForget $token
    }
    return [::http::$op $token]
}

# The http package is loaded on first use rather than at load: in a browser
# build there is no socket for it to use and nothing that would ever call it,
# and a package required for nothing is a package that can fail for nothing.
proc ::taco_http::NativeInit {} {
    variable Registered

    if {$Registered} return
    # 2.10 for the token on the socket command (useSockThread, below) and
    # for opening that socket in a coroutine, where a handshake can wait.
    package require http 2.10
    # Both schemes, so plain http goes through the proxy too. useSockThread
    # only appends "-type $token": threadlevel stays 0, nothing is threaded.
    ::http::register http 80 [list ::taco_http::Socket 0] {} 1
    ::http::register https 443 [list ::taco_http::Socket 1] {} 1
    set Registered 1
}

# http's socket command: {*}?options? -type TOKEN host port. Direct, it opens
# what the stock command would; through a proxy, a tunnel, waiting in http's
# OpenSocket coroutine for the handshake. mtls is not a load-time dependency:
# a build without it still does plain http, and fails an https transfer where
# it happens rather than at startup.
proc ::taco_http::Socket {tls args} {
    variable Route
    variable Handshake
    set i [lsearch -exact $args -type]
    if {$i < 0} {
        error "no request token for this socket"
    }
    set token [lindex $args $i+1]
    set args [lreplace $args $i $i+1]
    if {![info exists Route($token)]} {
        error "no route for this request"
    }
    set proxy $Route($token)
    if {$proxy eq ""} {
        if {$tls} {
            package require mtls
            return [::mtls::socket {*}$args]
        }
        return [::socket {*}$args]
    }
    if {[info coroutine] eq ""} {
        error "a proxied request has to open its socket in a coroutine"
    }
    set host [lindex $args end-1]
    set port [lindex $args end]
    set Handshake($token) [list [proxy_open $proxy $host $port \
        [list ::taco_http::Tunneled [info coroutine]]] [info coroutine]]
    lassign [yield] status chan
    unset -nocomplain Handshake($token)
    if {$status ne "ok"} {
        error "proxy: $chan"
    }
    if {!$tls} {
        return $chan
    }
    if {[catch {
        package require mtls
        ::mtls::import $chan -servername $host
    } tlschan]} {
        catch {close $chan}
        error $tlschan
    }
    return $tlschan
}

# The request may have gone while its handshake ran; then so does the tunnel.
proc ::taco_http::Tunneled {coro status detail} {
    if {[llength [info commands $coro]]} {
        $coro [list $status $detail]
    } elseif {$status eq "ok"} {
        catch {close $detail}
    }
}

proc ::taco_http::NativeForget {token} {
    variable Route
    variable Handshake
    unset -nocomplain Route($token)
    if {[info exists Handshake($token)]} {
        # Resumed, http's coroutine would carry on with a request it has
        # already finished.
        lassign $Handshake($token) handle coro
        unset Handshake($token)
        proxy_abort $handle
        catch {rename $coro {}}
    }
}

# -- the browser ------------------------------------------------------------

proc ::taco_http::BrowserRequest {method url optsVar} {
    upvar 1 $optsVar o
    variable Requests
    variable Next

    set headers $o(-headers)
    if {$o(-type) ne ""} {
        dict set headers Content-Type $o(-type)
    }
    set token ::taco_http::b[incr Next]
    set progress {}
    if {$o(-progress) ne ""} {
        set progress [list ::taco_http::BrowserProgress $token $o(-progress)]
    }
    set id [::em::call -progress $progress \
        -command [list ::taco_http::BrowserDone $token] \
        tackyHttp $method $url $o(-outfile) $o(-infile) $o(-timeout) {*}$headers]
    set Requests($token) [dict create id $id status "" ncode 0 error "" \
        command $o(-command)]
    return $token
}

# tackyHttp resolves with the HTTP status code, or fails with "timed out",
# "aborted" or what went wrong.
proc ::taco_http::BrowserDone {token result value} {
    variable Requests
    if {![info exists Requests($token)]} return
    if {$result eq "ok"} {
        dict set Requests($token) status ok
        dict set Requests($token) ncode $value
    } else {
        dict set Requests($token) status \
            [dict getdef {{timed out} timeout aborted reset} $value error]
        dict set Requests($token) error $value
    }
    BrowserNotify $token
}

proc ::taco_http::BrowserNotify {token} {
    variable Requests
    if {![info exists Requests($token)]} return
    set cmd [dict get $Requests($token) command]
    if {$cmd ne ""} {
        {*}$cmd $token
    }
}

proc ::taco_http::BrowserProgress {token cmd total current} {
    {*}$cmd $token $total $current
}

proc ::taco_http::BrowserQuery {op token} {
    variable Requests
    if {![info exists Requests($token)]} {
        error "no such request: $token"
    }
    switch -exact -- $op {
        status - ncode - error {
            return [dict get $Requests($token) $op]
        }
        reset {
            # Like the http package, a reset request still calls -command,
            # here from the event loop.
            if {[dict get $Requests($token) status] eq ""} {
                ::em::cancel [dict get $Requests($token) id]
                dict set Requests($token) status reset
                dict set Requests($token) error aborted
                after 0 [list ::taco_http::BrowserNotify $token]
            }
        }
        cleanup {
            if {[dict get $Requests($token) status] eq ""} {
                ::em::cancel [dict get $Requests($token) id]
            }
            unset Requests($token)
        }
    }
}

# -- Tcl's http -------------------------------------------------------------

proc ::taco_http::NativeRequest {method url optsVar} {
    upvar 1 $optsVar o

    NativeInit
    if {$o(-proxy) ne ""} {
        # Malformed, it fails here rather than at the socket.
        proxy_parse $o(-proxy)
    }
    # Not the http package's -timeout: that is armed once at connect and is a
    # deadline on the whole transfer. Ours is re-armed on every block.
    set ms $o(-timeout)
    set opts {}
    set headers $o(-headers)
    # The file is wanted byte for byte, and -progress counts decoded bytes
    # against a compressed Content-Length.
    if {$method eq "GET"} { lappend headers Accept-Encoding identity }
    if {[llength $headers]} { lappend opts -headers $headers }
    if {$method eq "PUT"} {
        set fh [open $o(-infile) rb]
        lappend opts -method PUT -querychannel $fh -queryblocksize 65536
        if {$o(-type) ne ""} { lappend opts -type $o(-type) }
        # The body going up, then the answer coming down.
        lappend opts \
            -queryprogress [list ::taco_http::NativeProgress $ms $o(-progress)] \
            -progress [list ::taco_http::NativeProgress $ms ""]
    } else {
        set fh [open $o(-outfile) wb]
        lappend opts -channel $fh -binary 1 -blocksize 65536 \
            -progress [list ::taco_http::NativeProgress $ms $o(-progress)]
    }
    # The channel is ours, so closing it is too - before the caller's -command
    # runs and looks at the file.
    lappend opts -command [list ::taco_http::NativeDone $fh $o(-command)]
    # A kept-alive socket would carry the next request to the same host
    # whatever route that one asked for.
    lappend opts -keepalive 0
    if {[catch {::http::geturl $url {*}$opts} token]} {
        catch {close $fh}
        return -code error $token
    }
    # In time: http opens the socket from the event loop, never inside
    # geturl (see Socket).
    variable Route
    set Route($token) $o(-proxy)
    # Unless it is over already: geturl can finish a request before returning.
    if {[::http::status $token] eq ""} {
        NativeIdle $token $ms
    }
    return $token
}

# (Re)arm the reset that ends a request quiet for $ms. A reset as timeout
# runs -command, so the caller sees it as it saw the http package's own.
proc ::taco_http::NativeIdle {token ms} {
    variable Idle
    if {$ms <= 0} return
    if {[info exists Idle($token)]} {
        after cancel $Idle($token)
    }
    set Idle($token) [after $ms [list ::taco_http::NativeExpire $token]]
}

# The caller may have cleaned the token up without waiting for its end.
proc ::taco_http::NativeExpire {token} {
    variable Idle
    unset -nocomplain Idle($token)
    catch {::http::reset $token timeout}
}

proc ::taco_http::NativeProgress {ms cmd token total current} {
    NativeIdle $token $ms
    if {$cmd ne ""} {
        {*}$cmd $token $total $current
    }
}

proc ::taco_http::NativeDone {fh cmd token} {
    variable Idle
    if {[info exists Idle($token)]} {
        after cancel $Idle($token)
        unset Idle($token)
    }
    catch {close $fh}
    NativeForget $token
    if {$cmd ne ""} {
        {*}$cmd $token
    }
}
