# Threaded JSON embed transport test. thread::send stands in for the C emit
# callback that the shim registers; the backend runs in its own thread and
# bounces each emitted JSON message back to the main thread.
package require tcltest
namespace import ::tcltest::*

# Main-thread sink the backend thread calls (via thread::send -async) per
# emitted JSON message. Complete once either reply for token 1 arrives, or a
# bgerror report, which is all a tokenless request produces.
proc on_emit {json} {
    lappend ::received $json
    if {[string match {\["result",1,*} $json] ||
        [string match {\["error",1,*} $json] ||
        [string match {BGERROR *} $json]} {
        set ::done 1
    }
}

# Wait for the token 1 reply, or report what did arrive.
proc await_reply {} {
    set after_id [after 5000 {set ::done -1}]
    vwait ::done
    after cancel $after_id
    if {$::done == -1} {
        return "timed out (received: $::received)"
    }
    return ""
}

set embed_common {
    -constraints hasThread
    -setup {
        set ::received {}
        set ::done 0
        set proj [file normalize [file join [file dirname [info script]] .. ..]]
        set main [thread::id]
        set ::be [thread::create]
        # Synchronous sends surface backend setup errors here.
        thread::send $::be [list set ::auto_path $::auto_path]
        thread::send $::be [list set ::proj $proj]
        thread::send $::be [list set ::main $main]
        thread::send $::be {
            lappend auto_path [file join $proj lib]
            # Native-emit stand-in: bounce each JSON message to the main thread.
            proc tacky_native_emit {json} {
                thread::send -async $::main [list on_emit $json]
            }
            source [file join $proj bin tackyd-embed.tcl]
            tackyd_embed_init
        }
    }
    -cleanup {
        catch {thread::send $::be {catch {taco destroy}}}
        catch {thread::release $::be}
        unset -nocomplain ::be ::received ::done
    }
}

test embed-threaded-roundtrip {threaded JSON embed dispatches a request and emits its result} \
    {*}$embed_common -body {
    thread::send -async $::be {tackyd_dispatch {["account","list",{},1]}}
    set timeout [await_reply]
    if {$timeout ne ""} { return $timeout }
    expr {[lsearch -exact $::received {["result",1,[]]}] >= 0}
} -result 1

# Match the text, not just any error: this request has no acc either, which
# fails on its own.
test embed-threaded-base64-error {a bad binary argument answers the token instead of hanging} \
    {*}$embed_common -body {
    thread::send -async $::be {tackyd_dispatch {["avatar","publish",{"data":"!!!"},1]}}
    set timeout [await_reply]
    if {$timeout ne ""} { return $timeout }
    string match {\["error",1,*base64*} [lindex $::received end]
} -result 1

# A tokenless request has nowhere to send a reply, so a synchronous failure can
# only surface through bgerror. The JSON path used to swallow these.
#
# Dispatch from `after 0`, not straight off thread::send: that puts the throw on
# Tcl's background-error path (bgerror), which is what the C shim reaches via
# Tcl_BackgroundException. A bare async send lands in thread::errorproc instead.
set embed_bgerror $embed_common
dict set embed_bgerror -setup "[dict get $embed_common -setup]
    thread::send \$::be {
        proc bgerror {message} {
            thread::send -async \$::main \[list on_emit \"BGERROR \$message\"]
        }
    }"

test embed-threaded-fireforget-error {a tokenless synchronous failure reaches bgerror} \
    {*}$embed_bgerror -body {
    thread::send -async $::be {after 0 {tackyd_dispatch {["avatar","publish",{"data":"Zm9v"}]}}}
    set timeout [await_reply]
    if {$timeout ne ""} { return $timeout }
    expr {[lsearch -glob $::received {BGERROR *}] >= 0}
} -result 1

test embed-threaded-fireforget-decode-error {a tokenless bad argument reaches bgerror} \
    {*}$embed_bgerror -body {
    thread::send -async $::be {after 0 {tackyd_dispatch {["avatar","publish",{"data":"!!!"}]}}}
    set timeout [await_reply]
    if {$timeout ne ""} { return $timeout }
    expr {[lsearch -glob $::received {BGERROR *base64*}] >= 0}
} -result 1
