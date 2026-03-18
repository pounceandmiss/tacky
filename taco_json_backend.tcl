#!/usr/bin/env tclsh9.0
# Child process entry point that speaks JSON over lenpipe.
#
# Incoming (stdin):  ["module","method",{args}]        fire-and-forget
#                    ["module","method",{args},id]     with callback
# Outgoing (stdout): ["event","module","event",{args}]
#                    ["callback",id,result]
#                    ["error",id,"message"]
#
# JSON keys omit the Tcl "-" prefix: {"acc":"a@b"} maps to -acc a@b.

package require json
package require json::write
json::write indented false

proc pipesend {msg} {
    puts stdout [string length $msg]
    puts -nonewline stdout $msg
    flush stdout
}

# Strip leading "-" from JSON object keys.
# Safe because json::write escapes quotes inside values (\"), so the
# pattern only matches actual keys (unescaped " followed by -...:).
proc _strip_dashes {json} {
    regsub -all {"-([\w-]+)":} $json {"\1":} json
    return $json
}

# Prefix all top-level dict keys with "-" (JSON input → Tcl args).
proc _prefix_dashes {d} {
    set result {}
    dict for {k v} $d { dict set result -$k $v }
    return $result
}

# Define "tacky" command before creating taco_type,
# because taco constructor calls `tacky emit` for existing accounts.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} {
        set json_args [_strip_dashes [jsonify convert $module/$event $args]]
        pipesend [json::write array \
            [json::write string event] \
            [json::write string $module] \
            [json::write string $event] \
            $json_args]
    }
}

proc _on_result {id schema_key result} {
    pipesend [json::write array \
        [json::write string callback] \
        $id \
        [_strip_dashes [jsonify convert $schema_key $result]]]
}

proc _on_error {id errmsg} {
    pipesend [json::write array \
        [json::write string error] \
        $id \
        [json::write string $errmsg]]
}

# Configure stdout for writing
chan configure stdout -translation lf -encoding utf-8 -buffering full

source [file join [file dirname [info script]] taco taco.tcl]

# Read JSON commands from stdin via lenpipe.
# json2dict turns a JSON array into a Tcl list:
#   ["chatlist","search",{"acc":"a@b"},5] → {chatlist search {acc a@b} 5}
lenpipe create _pipe stdin \
    -onmessage {apply {{msg} {
        set parts [::json::json2dict $msg]
        set module [lindex $parts 0]
        set method [lindex $parts 1]
        set args [_prefix_dashes [lindex $parts 2]]
        set extra {}
        if {[llength $parts] >= 4} {
            set id [lindex $parts 3]
            lappend extra -command [list _on_result $id $module/$method]
            lappend extra -onerror [list _on_error $id]
        }
        taco $module $method {*}$args {*}$extra
    }}} \
    -oneof {apply {{} {
        taco destroy
        exit 0
    }}}

taco_type create taco {*}$::argv
vwait forever
