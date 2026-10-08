package require tcltest
namespace import ::tcltest::*
package require taco

# The handshake needs mtls and the close test a listening socket; the wasm
# build has neither.
::tcltest::testConstraint wasm [expr {$::tcl_platform(os) eq "Emscripten"}]

# xmpp_starttls accumulates the pre-TLS reply in ::_xmpp_starttls_data($chan)
# until it sees <proceed/>. Tcl names socket channels after the fd, so a name
# comes back around on a later connection and an uncleared buffer becomes its
# problem.

test starttls-abort-forgets-a-partial-buffer {abort drops what a channel had buffered} \
    -body {
        set ::_xmpp_starttls_data(sockTEST) "<stream:stream id='x'><fea"
        xmpp_starttls_abort sockTEST
        info exists ::_xmpp_starttls_data(sockTEST)
    } -result {0}

test starttls-abort-tolerates-an-unknown-channel {abort on a channel with nothing buffered is a no-op} \
    -body {
        xmpp_starttls_abort sockNEVERSEEN
    } -result {}

test starttls-starts-from-an-empty-buffer {a new handshake ignores a previous one's leftovers} \
    -constraints !wasm -setup {
        set tmp [file join [temporaryDirectory] starttls-reuse.txt]
        set chan [open $tmp w+]
    } \
    -body {
        set ::_xmpp_starttls_data($chan) "leftovers from a dead connection"
        xmpp_starttls $chan example.com {apply {{args} {}}}
        info exists ::_xmpp_starttls_data($chan)
    } -cleanup {
        fileevent $chan readable {}
        close $chan
        file delete $tmp
        unset -nocomplain ::_xmpp_starttls_data($chan)
    } -result {0}

# Answers the client's opening stream but never sends <proceed/>, so the
# client is left holding a partial buffer with the handshake unfinished.
proc st_accept {chan addr port} {
    set ::_st_peer $chan
    fconfigure $chan -blocking 0 -buffering none -translation binary
    fileevent $chan readable [list st_serve $chan]
}

proc st_serve {chan} {
    if {[eof $chan]} {
        fileevent $chan readable {}
        return
    }
    read $chan
    catch {puts -nonewline $chan "<stream:stream id='x'><features"}
}

# Pump the event loop until the client has buffered the partial reply, with a
# deadline so a broken test fails instead of hanging the suite.
proc st_wait_buffered {chan {timeout 5000}} {
    set deadline [expr {[clock milliseconds] + $timeout}]
    while {![info exists ::_xmpp_starttls_data($chan)]} {
        if {[clock milliseconds] > $deadline} {
            error "timed out waiting for STARTTLS data on $chan"
        }
        after 10 {set ::_st_tick 1}
        vwait ::_st_tick
    }
}

test starttls-close-mid-handshake-forgets-the-buffer {a socket closed mid-STARTTLS strands nothing} \
    -constraints !wasm -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::_st_peer ""
        set listener [socket -server st_accept -myaddr 127.0.0.1 0]
        set port [lindex [fconfigure $listener -sockname] 2]
        baseconn bc -domain example.com -starttls true \
            -error-command {apply {{msg} {set ::_st_err $msg}}}
    } \
    -body {
        bc connect 127.0.0.1 $port
        set sock [bc socket]
        st_wait_buffered $sock
        # This is the state a connect timeout or a cancelled reconnect tears
        # down: the readable callback never runs again to clean up after it.
        set buffered [info exists ::_xmpp_starttls_data($sock)]
        bc close
        list $buffered [info exists ::_xmpp_starttls_data($sock)]
    } -cleanup {
        catch {bc destroy}
        catch {close $::_st_peer}
        catch {close $listener}
        jlog configure -logproc ""
        unset -nocomplain ::_st_err ::_st_tick ::_st_peer
    } -result {1 0}

# What the server says before <proceed/>, read from a file standing in for
# the socket.
proc st_reply {text} {
    set tmp [file join [temporaryDirectory] starttls-reply.txt]
    set fh [open $tmp w]; puts -nonewline $fh $text; close $fh
    set chan [open $tmp r]
    set ::_st_result {}
    _xmpp_starttls_readable_cb $chan example.com {apply {{args} {
        set ::_st_result $args
    }}}
    close $chan
    file delete $tmp
    return $::_st_result
}

test starttls-failure-ends-at-once {a <failure/> answer fails the handshake right away} -body {
    st_reply "<stream:stream id='x'><stream:features/><failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
} -result {error {server refused STARTTLS}}

test starttls-buffer-is-bounded {a server that never says <proceed/> is not buffered forever} -body {
    st_reply "<stream:stream id='x'>[string repeat x 70000]"
} -result {error {no STARTTLS answer in the first 64 KiB}}

# -- Trying targets in order (connectTargets) --------------------------------

# A port nothing listens on: take one and give it back.
proc st_closed_port {} {
    set s [socket -server {apply {{args} {}}} -myaddr 127.0.0.1 0]
    set port [lindex [fconfigure $s -sockname] 2]
    close $s
    return $port
}

proc st_wait {var {timeout 5000}} {
    set id [after $timeout [list set $var timeout]]
    vwait $var
    after cancel $id
}

set targets_common {
    -constraints !wasm
    -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::_st_attempts {}
        set ::_st_errors {}
        set ::_st_ready ""
        set ::_st_peer ""
        set listener [socket -server st_accept -myaddr 127.0.0.1 0]
        set open [lindex [fconfigure $listener -sockname] 2]
        baseconn bc -domain example.com \
            -attempt-command {apply {{h p t} {lappend ::_st_attempts [list $p $t]}}} \
            -error-command {apply {{msg} {lappend ::_st_errors $msg; set ::_st_ready error}}} \
            -ontransportready {set ::_st_ready ready}
    }
    -cleanup {
        catch {bc destroy}
        catch {close $::_st_peer}
        catch {close $listener}
        jlog configure -logproc ""
        unset -nocomplain ::_st_attempts ::_st_errors ::_st_ready ::_st_peer
    }
}

test baseconn-targets-next-on-refusal {a refused target gives way to the next} \
    {*}$targets_common -body {
        set closed [st_closed_port]
        bc connectTargets [list [list 127.0.0.1 $closed none] [list 127.0.0.1 $open none]]
        st_wait ::_st_ready
        list $::_st_ready [expr {$::_st_attempts eq [list [list $closed none] [list $open none]]}] \
            $::_st_errors
    } -result {ready 1 {}}

test baseconn-targets-all-fail-once {when every target fails, the error comes once} \
    {*}$targets_common -body {
        bc connectTargets [list [list 127.0.0.1 [st_closed_port] none] \
                                [list 127.0.0.1 [st_closed_port] none]]
        st_wait ::_st_ready
        after 100 {set ::_st_tick 1}; vwait ::_st_tick
        list $::_st_ready [llength $::_st_attempts] [llength $::_st_errors] \
            [string match "Connect failed:*" [lindex $::_st_errors 0]]
    } -result {error 2 1 1}

test baseconn-targets-stuck-handshake-moves-on {a target that never finishes TLS gives way after the attempt timeout} \
    {*}$targets_common -body {
        # st_accept never says <proceed/>
        set plain [socket -server {apply {{c a p} {set ::_st_peer2 $c}}} -myaddr 127.0.0.1 0]
        set plainPort [lindex [fconfigure $plain -sockname] 2]
        bc configure -attempt-timeout 300
        bc connectTargets [list [list 127.0.0.1 $open starttls] [list 127.0.0.1 $plainPort none]]
        st_wait ::_st_ready
        catch {close $::_st_peer2}
        close $plain
        list $::_st_ready \
            [expr {$::_st_attempts eq [list [list $open starttls] [list $plainPort none]]}]
    } -result {ready 1}

test baseconn-targets-need-a-domain {without a domain nothing is dialled} \
    {*}$targets_common -body {
        bc configure -domain ""
        bc connectTargets [list [list 127.0.0.1 $open none]]
        st_wait ::_st_ready
        list $::_st_ready $::_st_errors $::_st_attempts
    } -result {error {{Connect failed: no domain}} {}}
