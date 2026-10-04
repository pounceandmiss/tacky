# The browser backend: the entry script of the wasm build (zippy's launcher
# runs it when wasm/src/worker.js creates the module). The JSON contract of
# tackyd-embed.tcl, carried by ::em::call to the worker's functions:
#
#   tackyPost json       every reply and event
#   tackyServe           called once taco is up, which is the backend being
#                        ready; each request arrives as a progress step
#                        (`request json`), and the call settles when the page
#                        asks us to stop
#   tackyStopped         taco is destroyed and its databases closed
#   tackyFatal message   the backend did not start; nothing follows
#
# The worker passes its options as environment variables: TACKY_TRANSIENT,
# TACKY_STORE (where the store's directories go) and TACKY_DEBUG (a jlog
# level). A page has neither an rtc stack nor sockets, so media is the page's
# own (`host`, wasm/src/media-host.js) and XMPP goes over a WebSocket.

proc tacky_native_emit {json} {
    ::em::call tackyPost $json
}

proc tacky_web_start {} {
    set args {-media-backend host -transport websocket}
    if {[info exists ::env(TACKY_TRANSIENT)] && $::env(TACKY_TRANSIENT)} {
        lappend args -transient 1
    } else {
        set store $::env(TACKY_STORE)
        lappend args -transient 0 \
            -config-dir $store/config -data-dir $store/data -cache-dir $store/cache
    }
    if {[info exists ::env(TACKY_DEBUG)] && $::env(TACKY_DEBUG) ne ""} {
        lappend args -debug-level $::env(TACKY_DEBUG)
    }
    tackyd_embed_init {*}$args
    # A progress step is `request json`.
    ::em::call -progress {apply {{_ json} {tackyd_dispatch $json}}} \
        -command tacky_web_stop tackyServe
}

proc tacky_web_stop {result value} {
    catch {taco destroy}
    ::em::call tackyStopped
}

if {[catch {
    source [file join [file dirname [info script]] tackyd-embed.tcl]
    tacky_web_start
} err]} {
    ::em::call tackyFatal $err
    return
}
vwait forever
