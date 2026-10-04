# taco_http against a real server, whichever backend this build has: Tcl's
# http natively, tackyHttp (XMLHttpRequest) in a browser (browser.mjs
# --scenario tcl). The endpoints are wasm/test/serve.mjs's /_t/ routes;
# natively this file serves them itself. Only what both backends share is
# asserted.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# -- a native server for the /_t/ routes ------------------------------------

namespace eval ::test::httpreq {
    variable Echoed
    array set Echoed {}
    variable Buf
    array set Buf {}
    variable Server ""
    variable AcceptEncoding ""
}

proc ::test::httpreq::accept {ch addr port} {
    variable Buf
    fconfigure $ch -translation binary -blocking 0
    set Buf($ch) ""
    fileevent $ch readable [list ::test::httpreq::readable $ch]
}

proc ::test::httpreq::readable {ch} {
    variable Buf
    if {[catch {read $ch} data] || ([eof $ch] && $data eq "")} {
        catch {close $ch}
        unset -nocomplain Buf($ch)
        return
    }
    append Buf($ch) $data
    set end [string first "\r\n\r\n" $Buf($ch)]
    if {$end < 0} return
    set lines [split [string range $Buf($ch) 0 $end-1] \n]
    set body [string range $Buf($ch) $end+4 end]
    set length 0
    foreach line [lrange $lines 1 end] {
        if {[regexp -nocase {^content-length:\s*(\d+)} $line -> n]} {
            set length $n
        }
        regexp -nocase {^accept-encoding:\s*(\S+)} $line -> \
            ::test::httpreq::AcceptEncoding
    }
    if {[string length $body] < $length} return
    fileevent $ch readable {}
    unset Buf($ch)
    lassign [lindex $lines 0] method path
    route $ch $method $path [string range $body 0 $length-1]
}

proc ::test::httpreq::route {ch method path body} {
    variable Echoed
    lassign [lrange [split $path /] 2 3] route arg
    if {$route eq "echo" && $method eq "PUT"} {
        set Echoed($arg) $body
        respond $ch 201 ""
    } elseif {$route eq "echo" && [info exists Echoed($arg)]} {
        respond $ch 200 $Echoed($arg)
    } elseif {$route eq "status"} {
        respond $ch $arg "status $arg"
    } elseif {$route eq "accept-encoding"} {
        respond $ch 200 $::test::httpreq::AcceptEncoding
    } elseif {$route eq "slow"} {
        after 3000 [list ::test::httpreq::respond $ch 200 slow]
    } else {
        respond $ch 404 "no $path"
    }
}

proc ::test::httpreq::respond {ch code body} {
    catch {
        puts -nonewline $ch "HTTP/1.1 $code X\r\nContent-Length: [string length $body]\r\n"
        puts -nonewline $ch "Connection: close\r\n\r\n$body"
        close $ch
    }
}

if {$::tacky_test_http_base eq "" && ![testConstraint wasm]} {
    set ::test::httpreq::Server \
        [socket -server ::test::httpreq::accept -myaddr 127.0.0.1 0]
    set ::tacky_test_http_base \
        "http://127.0.0.1:[lindex [fconfigure $::test::httpreq::Server -sockname] 2]"
}
testConstraint httpBase [expr {$::tacky_test_http_base ne ""}]
testConstraint nativeHttp [expr {![testConstraint wasm]}]

# -- helpers ------------------------------------------------------------------

# Start a request and wait for its -command (which a native reset runs before
# returning). Returns the token.
proc ::test::httpreq::run {op path args} {
    set ::test::httpreq::done 0
    set token [taco_http $op $::tacky_test_http_base$path {*}$args \
        -command {apply {{t} {set ::test::httpreq::done 1}}}]
    wait
    return $token
}

proc ::test::httpreq::wait {} {
    set id [after 10000 {set ::test::httpreq::done timeout}]
    while {$::test::httpreq::done eq "0"} {
        vwait ::test::httpreq::done
    }
    after cancel $id
}

proc ::test::httpreq::file {name} {
    return [::file join [temporaryDirectory] httpreq-$name]
}

proc ::test::httpreq::put {name data} {
    set f [open [file $name] wb]
    puts -nonewline $f $data
    close $f
}

proc ::test::httpreq::get {name} {
    set f [open [file $name] rb]
    set data [read $f]
    close $f
    return $data
}

proc ::test::httpreq::finish {token} {
    set result [list [taco_http status $token] [taco_http ncode $token]]
    taco_http cleanup $token
    return $result
}

# -- tests --------------------------------------------------------------------

test httpreq-put-then-get {bytes go up and come back down unchanged} \
    -constraints httpBase -body {
        set data "a\0b[encoding convertto utf-8 é中]z"
        ::test::httpreq::put up $data
        set up [::test::httpreq::finish [::test::httpreq::run put \
            /_t/echo/roundtrip -infile [::test::httpreq::file up] \
            -type application/octet-stream]]
        set down [::test::httpreq::finish [::test::httpreq::run get \
            /_t/echo/roundtrip -outfile [::test::httpreq::file down]]]
        list $up $down [expr {[::test::httpreq::get down] eq $data}]
    } -result {{ok 201} {ok 200} 1}

test httpreq-get-reports-progress {a download reports progress up to its size} \
    -constraints httpBase -setup {
        set ::_hr_progress {}
    } -body {
        ::test::httpreq::put big [string repeat 0123456789 20000]
        ::test::httpreq::finish [::test::httpreq::run put /_t/echo/big \
            -infile [::test::httpreq::file big]]
        ::test::httpreq::finish [::test::httpreq::run get /_t/echo/big \
            -outfile [::test::httpreq::file bigdown] \
            -progress {apply {{t total current} {lappend ::_hr_progress $current}}}]
        list [expr {[llength $::_hr_progress] > 0}] [lindex $::_hr_progress end]
    } -cleanup {
        unset -nocomplain ::_hr_progress
    } -result {1 200000}

test httpreq-get-asks-identity {a download asks for no content coding} \
    -constraints {httpBase nativeHttp} -body {
        ::test::httpreq::finish [::test::httpreq::run get /_t/accept-encoding \
            -outfile [::test::httpreq::file ae]]
        ::test::httpreq::get ae
    } -result identity

test httpreq-404-is-an-answer {a 404 completes, with its status code} \
    -constraints httpBase -body {
        ::test::httpreq::finish [::test::httpreq::run get /_t/status/404 \
            -outfile [::test::httpreq::file 404]]
    } -result {ok 404}

test httpreq-timeout {a request past its -timeout ends as timeout} \
    -constraints httpBase -body {
        set token [::test::httpreq::run get /_t/slow -timeout 300 \
            -outfile [::test::httpreq::file slow]]
        set status [taco_http status $token]
        taco_http cleanup $token
        set status
    } -result timeout

test httpreq-reset {a reset request still calls back, as reset} \
    -constraints httpBase -body {
        set ::test::httpreq::done 0
        set token [taco_http get $::tacky_test_http_base/_t/slow \
            -outfile [::test::httpreq::file reset] \
            -command {apply {{t} {set ::test::httpreq::done 1}}}]
        after 100 [list taco_http reset $token]
        ::test::httpreq::wait
        set status [taco_http status $token]
        taco_http cleanup $token
        list $::test::httpreq::done $status
    } -result {1 reset}

foreach name {up down big bigdown ae 404 slow reset} {
    ::file delete [::test::httpreq::file $name]
}
if {$::test::httpreq::Server ne ""} {
    close $::test::httpreq::Server
    set ::tacky_test_http_base ""
}
