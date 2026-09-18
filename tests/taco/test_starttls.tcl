package require tcltest
namespace import ::tcltest::*
package require taco

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
    -setup {
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
    -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::_st_peer ""
        set listener [socket -server st_accept -myaddr 127.0.0.1 0]
        set port [lindex [fconfigure $listener -sockname] 2]
        baseconn bc -starttls true \
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
