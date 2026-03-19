#!/usr/bin/env tclsh9.0
# Child process entry point that speaks JSON over lenpipe.
#
# Incoming (stdin):  ["module","method",{args}]          fire-and-forget
#                    ["module","method",{args},token]     request/response
# Outgoing (stdout): ["event","module","<Event>",{args}] broadcast
#                    ["result",token,data]                success reply
#                    ["error",token,message]              error reply
#
package require json
package require json::write
json::write indented false

source [file join [file dirname [info script]] jsonify.tcl]

proc strip_dashes {d} {
    set out {}
    dict for {k v} $d { lappend out [string trimleft $k -] $v }
    return $out
}

proc add_dashes {d} {
    set out {}
    dict for {k v} $d { lappend out -$k $v }
    return $out
}

proc pipesend {msg} {
    puts stdout [string length $msg]
    puts -nonewline stdout $msg
    flush stdout
}

# Maps callback token → schema key (e.g. "roster/get") so the emit
# path can serialise the result with the right schema.
variable _token_schemas [dict create]

# Define "tacky" command before creating taco_type,
# because taco constructor calls `tacky emit` for existing accounts.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} {
        # Callback results/errors → ["result", token, data] / ["error", token, msg]
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
                pipesend [json::write array \
                    [json::write string error] \
                    $token \
                    [json::write string $result]]
            } else {
                pipesend [json::write array \
                    [json::write string result] \
                    $token \
                    [jsonify convert $schema $result]]
            }
            return
        }
        # Broadcast events → ["event", module, "<Event>", {args}]
        set args [strip_dashes $args]
        set json_args [jsonify convert $module/$event $args]
        pipesend [json::write array \
            [json::write string event] \
            [json::write string $module] \
            [json::write string $event] \
            $json_args]
    }
}

# Configure stdout for writing
chan configure stdout -translation lf -encoding utf-8 -buffering full

source [file join [file dirname [info script]] .. taco taco.tcl]

# Read JSON commands from stdin via lenpipe.
# json2dict turns a JSON array into a Tcl list:
#   ["chatlist","search",{"-acc":"a@b"},5] → {chatlist search {-acc a@b} 5}
lenpipe create _pipe stdin \
    -onmessage {apply {{msg} {
        set parts [::json::json2dict $msg]
        set module [lindex $parts 0]
        set method [lindex $parts 1]
        set args [lindex $parts 2]
        set args [add_dashes $args]
        # Optional token (4th element) → wire up -command/-onerror internally.
        set token [lindex $parts 3]
        if {$token ne ""} {
            dict set ::_token_schemas $token $module/$method
            dict set args -command \
                [list tacky emit callback <Result> -token $token -result]
            dict set args -onerror \
                [list tacky emit callback <Error> -token $token -result]
        }
        taco $module $method {*}$args
    }}} \
    -oneof {apply {{} {
        taco destroy
        exit 0
    }}}

taco_type create taco {*}$::argv
vwait forever
