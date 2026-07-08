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
# Outgoing (tacky_native_emit): ["event","module","<Event>",{args}] broadcast
#                               ["result",token,data]                success reply
#                               ["error",token,message]              error reply
#
# The transport glue below mirrors bin/tackyd-json.tcl verbatim; only the two
# transport ends differ (pipesend -> tacky_native_emit, lenpipe reader ->
# tackyd_dispatch). Schema conversion, token wiring, and taco are reused.

package require taco
package require tackyd-json

# Maps callback token -> schema key (e.g. "roster/get") so the emit path can
# serialise the result with the right schema.
variable _token_schemas [dict create]

# Define "tacky" before creating taco_type, because the taco constructor calls
# `tacky emit` for existing accounts.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} {
        # Callback results/errors -> ["result", token, data] / ["error", token, msg]
        if {$module eq "callback" && [dict exists $args -token]} {
            set token [dict get $args -token]
            if {[dict exists $::_token_schemas $token]} {
                set schema [dict get $::_token_schemas $token]
                dict unset ::_token_schemas $token
            } else {
                set schema $module/$event
            }
            set result [dict get $args -result]
            if {$event eq "<Error>"} {
                tacky_native_emit [json::write array \
                    [json::write string error] \
                    $token \
                    [json::write string $result]]
            } else {
                tacky_native_emit [json::write array \
                    [json::write string result] \
                    $token \
                    [jsonify convert $schema $result]]
            }
            return
        }
        # Broadcast events -> ["event", module, "<Event>", {args}]
        set args [strip_dashes $args]
        set json_args [jsonify convert $module/$event $args]
        tacky_native_emit [json::write array \
            [json::write string event] \
            [json::write string $module] \
            [json::write string $event] \
            $json_args]
    }
}

# Dispatch one JSON request array on the backend thread.
#   ["chatlist","search",{"acc":"a@b"},5] -> taco chatlist search -acc a@b (token 5)
proc tackyd_dispatch {msg} {
    set parts [::json::json2dict $msg]
    set module [lindex $parts 0]
    set method [lindex $parts 1]
    set args [lindex $parts 2]
    set args [add_dashes $args]
    # Optional token (4th element) -> wire up -command/-onerror internally.
    set token [lindex $parts 3]
    if {$token ne ""} {
        dict set ::_token_schemas $token $module/$method
        dict set args -command \
            [list tacky emit callback <Result> -token $token -result]
        dict set args -onerror \
            [list tacky emit callback <Error> -token $token -result]
    }
    taco $module $method {*}$args
}

# Create the taco backend. Pass taco_type constructor args (e.g. -transient 0).
# tacky_native_emit must already be defined, since the constructor may emit.
proc tackyd_embed_init {args} {
    taco_type create taco {*}$args
}
