# taco_http - the HTTP a file transfer needs, from whichever client this build
# has: Tcl's http package over a socket natively, with mtls registered for
# https, and the page's own stack in a browser, bound by zippy's
# emscripten/httpx.c (::httpx). This chooses between the two.
#
#   taco_http get URL -outfile PATH ?-timeout MS? ?-headers DICT?
#                     ?-progress CMD? ?-command CMD?          -> token
#   taco_http put URL -infile PATH ?-type MIME? ?-headers DICT?
#                     ?-timeout MS? ?-progress CMD? ?-command CMD?  -> token
#   taco_http status  TOKEN    ok | error | timeout | reset ("" while in flight)
#   taco_http ncode   TOKEN    the HTTP status code
#   taco_http error   TOKEN    why it failed, "" otherwise
#   taco_http reset   TOKEN    cancel it
#   taco_http cleanup TOKEN    drop it
#
# -command is called with the token, -progress with `token total current`. A
# request is always asynchronous - the browser has no other kind, and the
# native side opens and closes its own channel around a callback - so a caller
# that omits -command has to watch `status` for the answer.
#
# Bodies are named by path rather than handed over as channels, which is what
# the browser forces (httpx.c says why). The native backend opens and closes
# the channel itself, so a caller sees the same contract either way: the bytes
# are at the path when -command fires.

namespace eval ::taco_http {
    # Whether the native backend has registered its https transport yet.
    variable Registered 0
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

# The browser's client exists only where zippy built httpx in.
proc ::taco_http::Browser {} {
    return [expr {[info exists ::httpx::available] && $::httpx::available}]
}

proc ::taco_http::Request {method url args} {
    array set o {
        -outfile "" -infile "" -type "" -headers "" -timeout 0
        -progress "" -command ""
    }
    array set o $args
    if {[Browser]} {
        return [BrowserRequest $method $url o]
    }
    return [NativeRequest $method $url o]
}

proc ::taco_http::Query {op token} {
    if {[Browser]} {
        # taco_http keeps the http package's vocabulary; httpx keeps the
        # browser's. `reset` is the one word where the two differ, and both
        # callers wrap this in a catch - so getting it wrong cancels nothing
        # and says nothing.
        if {$op eq "reset"} { set op abort }
        return [::httpx::$op $token]
    }
    NativeInit
    return [::http::$op $token]
}

# The http package is loaded on first use rather than at load: in a browser
# build there is no socket for it to use and nothing that would ever call it,
# and a package required for nothing is a package that can fail for nothing.
proc ::taco_http::NativeInit {} {
    variable Registered

    if {$Registered} return
    package require http
    # mtls is not a load-time dependency either: a build without it still does
    # plain http, and fails an https transfer where it happens rather than at
    # startup.
    catch {package require mtls; ::http::register https 443 ::mtls::socket}
    set Registered 1
}

# -- the browser ------------------------------------------------------------

proc ::taco_http::BrowserRequest {method url optsVar} {
    upvar 1 $optsVar o

    set headers $o(-headers)
    if {$o(-type) ne ""} {
        dict set headers Content-Type $o(-type)
    }
    # These four have the same names on both sides; the rest do not.
    set opts {}
    foreach opt {-outfile -infile -progress -command} {
        if {$o($opt) ne ""} { lappend opts $opt $o($opt) }
    }
    if {[llength $headers]} { lappend opts -headers $headers }
    if {$o(-timeout) > 0}   { lappend opts -timeout $o(-timeout) }
    return [::httpx::request $method $url {*}$opts]
}

# -- Tcl's http -------------------------------------------------------------

proc ::taco_http::NativeRequest {method url optsVar} {
    upvar 1 $optsVar o

    NativeInit
    set opts [list -timeout $o(-timeout)]
    if {[llength $o(-headers)]} { lappend opts -headers $o(-headers) }
    if {$method eq "PUT"} {
        set fh [open $o(-infile) rb]
        lappend opts -method PUT -querychannel $fh -queryblocksize 65536
        if {$o(-type) ne ""}     { lappend opts -type $o(-type) }
        if {$o(-progress) ne ""} { lappend opts -queryprogress $o(-progress) }
    } else {
        set fh [open $o(-outfile) wb]
        lappend opts -channel $fh -binary 1 -blocksize 65536
        if {$o(-progress) ne ""} { lappend opts -progress $o(-progress) }
    }
    # The channel is ours, so closing it is too - before the caller's -command
    # runs and looks at the file.
    lappend opts -command [list ::taco_http::NativeDone $fh $o(-command)]
    if {[catch {::http::geturl $url {*}$opts} token]} {
        catch {close $fh}
        return -code error $token
    }
    return $token
}

proc ::taco_http::NativeDone {fh cmd token} {
    catch {close $fh}
    if {$cmd ne ""} {
        {*}$cmd $token
    }
}
