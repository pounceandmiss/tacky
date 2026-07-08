# Threaded JSON embed transport test. thread::send stands in for the C emit
# callback that the shim registers; the backend runs in its own thread and
# bounces each emitted JSON message back to the main thread.
package require tcltest
namespace import ::tcltest::*

# Main-thread sink the backend thread calls (via thread::send -async) per
# emitted JSON message. Complete once the reply for token 1 arrives.
proc on_emit {json} {
    lappend ::received $json
    if {[string match {\["result",1,*} $json]} {
        set ::done 1
    }
}

test embed-threaded-roundtrip {threaded JSON embed dispatches a request and emits its result} \
    -constraints hasThread -setup {
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
} -body {
    thread::send -async $::be {tackyd_dispatch {["account","list",{},1]}}
    set after_id [after 5000 {set ::done -1}]
    vwait ::done
    after cancel $after_id
    if {$::done == -1} {
        return "timed out (received: $::received)"
    }
    expr {[lsearch -exact $::received {["result",1,[]]}] >= 0}
} -cleanup {
    catch {thread::send $::be {catch {taco destroy}}}
    catch {thread::release $::be}
    unset -nocomplain ::be ::received ::done
} -result 1
