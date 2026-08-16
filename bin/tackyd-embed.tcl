# Embedded backend entry: speaks JSON to a host via a native emit callback
# instead of length-prefixed stdio (cf. bin/tackyd-json.tcl).
#
# Runs on a dedicated backend thread. The host (the C shim, or a Tcl test)
# must define `tacky_native_emit {json}` before calling tackyd_embed_init;
# every event/result is delivered by calling it with one complete JSON
# message string. Requests are delivered by calling `tackyd_dispatch {json}`
# on this thread.
#
# Incoming (tackyd_dispatch):   ["module","method",{args}]        fire-and-forget
#                               ["module","method",{args},token]   request/response
# Outgoing (tacky_native_emit): ["event","module","Event",{args}]   broadcast
#                               ["result",token,data]                success reply
#                               ["error",token,message]              error reply
#
# Schema conversion, token wiring and dispatch live in the tackyd-json
# package, shared with the daemon; only the sink differs.

package require taco
package require tackyd-json
# For tackyd_split_argv, and for a bgerror that reaches jlog: a host embedding
# us has no console to lose background errors to. Nothing here calls its
# stdio sender.
package require tackyd

tackyd_json_install_emit tacky_native_emit

# Create the taco backend. Pass taco_type constructor args (e.g. -transient 0)
# and jlog's --debug-* flags; without the latter the host's stdout is the only
# sink, which on a service process is nowhere.
# tacky_native_emit must already be defined, since the constructor may emit.
proc tackyd_embed_init {args} {
    lassign [tackyd_split_argv $args] debug tacoArgs
    # Before taco: its constructor logs, and the sink has to exist by then.
    jlog configureDebug {*}$debug
    taco_type create taco {*}$tacoArgs
}
