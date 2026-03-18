# Unit tests for taco_json_backend.tcl JSON formatting and dispatch logic.
# jsonify + json::write are already loaded via tacky.tcl → taco.tcl.

package require json

# -- Helpers: capture pipesend output ----------------------------------------

variable _sent_messages {}

proc _test_pipesend {msg} {
    variable _sent_messages
    lappend _sent_messages $msg
}

proc _test_sent {} {
    variable _sent_messages
    return $_sent_messages
}

proc _test_clear {} {
    variable _sent_messages
    set _sent_messages {}
}

# Mirrors _strip_dashes from taco_json_backend.tcl
proc _test_strip_dashes {json} {
    regsub -all {"-([\w-]+)":} $json {"\1":} json
    return $json
}

# Mirrors _prefix_dashes from taco_json_backend.tcl
proc _test_prefix_dashes {d} {
    set result {}
    dict for {k v} $d { dict set result -$k $v }
    return $result
}

# Define the procs under test, wired to our capturing pipesend.
proc _test_on_result {id schema_key result} {
    _test_pipesend [json::write array \
        [json::write string callback] \
        $id \
        [_test_strip_dashes [jsonify convert $schema_key $result]]]
}

proc _test_on_error {id errmsg} {
    _test_pipesend [json::write array \
        [json::write string error] \
        $id \
        [json::write string $errmsg]]
}

proc _test_emit {module event args} {
    set json_args [_test_strip_dashes [jsonify convert $module/$event $args]]
    _test_pipesend [json::write array \
        [json::write string event] \
        [json::write string $module] \
        [json::write string $event] \
        $json_args]
}

# -- _strip_dashes tests ----------------------------------------------------

test json-backend-strip-dashes {strips leading dash from object keys} -body {
    _test_strip_dashes {{"-acc":"user@srv","-jid":"room@muc"}}
} -result {{"acc":"user@srv","jid":"room@muc"}}

test json-backend-strip-dashes-nested {strips dashes at all levels} -body {
    _test_strip_dashes {{"-occupant":{"-jid":"a@b","-role":"mod"}}}
} -result {{"occupant":{"jid":"a@b","role":"mod"}}}

test json-backend-strip-dashes-no-dash {leaves non-dash keys alone} -body {
    _test_strip_dashes {{"timestamp":100,"body":"hi"}}
} -result {{"timestamp":100,"body":"hi"}}

test json-backend-strip-dashes-value {does not strip dash in values} -body {
    _test_strip_dashes {{"-key":"-value"}}
} -result {{"key":"-value"}}

# -- _prefix_dashes tests ---------------------------------------------------

test json-backend-prefix-dashes {adds dash prefix to dict keys} -body {
    _test_prefix_dashes {acc user@srv chat room@muc}
} -result {-acc user@srv -chat room@muc}

# -- _on_result tests --------------------------------------------------------

test json-backend-callback-search {callback result with schema} -setup {
    _test_clear
} -body {
    set result [dict create \
        messages [list [dict create timestamp 100 body hi hollow 0]] \
        complete 1]
    _test_on_result 42 message/search $result
    lindex [_test_sent] 0
} -result [json::write array \
    {"callback"} 42 \
    [json::write object \
        messages [json::write array \
            [json::write object timestamp 100 body {"hi"} hollow false]] \
        complete true]]

test json-backend-callback-list {callback with list of ints} -setup {
    _test_clear
} -body {
    _test_on_result 7 message/local_search {10 20 30}
    lindex [_test_sent] 0
} -result [json::write array \
    {"callback"} 7 \
    [json::write array 10 20 30]]

test json-backend-callback-bool {callback with scalar bool} -setup {
    _test_clear
} -body {
    _test_on_result 3 presence/isOnline 1
    lindex [_test_sent] 0
} -result [json::write array {"callback"} 3 true]

test json-backend-callback-roster {roster items have dashes stripped} -setup {
    _test_clear
} -body {
    set items [list [dict create -jid a@b -approved 1 -groups {x}]]
    _test_on_result 2 roster/get $items
    lindex [_test_sent] 0
} -result [json::write array \
    {"callback"} 2 \
    [json::write array \
        [json::write object jid {"a@b"} approved true groups [json::write array {"x"}]]]]

# -- _on_error tests ---------------------------------------------------------

test json-backend-error {error message} -setup {
    _test_clear
} -body {
    _test_on_error 5 "not-allowed"
    lindex [_test_sent] 0
} -result [json::write array {"error"} 5 {"not-allowed"}]

test json-backend-error-special-chars {error with special chars} -setup {
    _test_clear
} -body {
    _test_on_error 6 {Account doesn't exist: bob@srv}
    lindex [_test_sent] 0
} -result [json::write array \
    {"error"} 6 \
    [json::write string {Account doesn't exist: bob@srv}]]

# -- emit tests --------------------------------------------------------------

test json-backend-emit-event {emit event with schema, dashes stripped} -setup {
    _test_clear
} -body {
    _test_emit message <Received> \
        -message [dict create timestamp 100 body hello hollow 0] \
        -timestamp 100
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"message"} {"<Received>"} \
    [json::write object \
        message [json::write object timestamp 100 body {"hello"} hollow false] \
        timestamp 100]]

test json-backend-emit-no-schema {emit event without schema, dashes stripped} -setup {
    _test_clear
} -body {
    _test_emit account <Added> -acc user@example.com
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"account"} {"<Added>"} \
    [json::write object acc {"user@example.com"}]]

# -- dispatch (JSON parsing) tests ------------------------------------------

test json-backend-parse-with-id {parse array request with id} -body {
    set parts [::json::json2dict {["message","search",{"acc":"user@srv","chat":"room@muc"},1]}]
    set args [_test_prefix_dashes [lindex $parts 2]]
    list [lindex $parts 0] [lindex $parts 1] $args [lindex $parts 3]
} -result {message search {-acc user@srv -chat room@muc} 1}

test json-backend-parse-no-id {parse array request without id} -body {
    set parts [::json::json2dict {["account","list",{}]}]
    list [lindex $parts 0] [lindex $parts 1] [llength $parts]
} -result {account list 3}

test json-backend-parse-with-args {args get dash-prefixed for taco} -body {
    set parts [::json::json2dict {["chatlist","search",{"acc":"a@b.c","query":"hello"}]}]
    set args [_test_prefix_dashes [lindex $parts 2]]
    list [dict get $args -acc] [dict get $args -query]
} -result {a@b.c hello}

# -- integration: dispatch through taco via process --------------------------

test json-backend-process-roundtrip {spawn json backend, send request, get response} \
    -constraints hasProcess -setup {
    set backend [file join [file dirname [info script]] .. .. taco_json_backend.tcl]
    set fd [open |[list [info nameofexecutable] $backend] r+]
    chan configure $fd -translation lf -encoding utf-8 -buffering full -blocking 0
} -body {
    set req {["account","list",{},1]}
    puts $fd [string length $req]
    puts -nonewline $fd $req
    flush $fd
    chan configure $fd -blocking 1
    after 3000 {set ::_timeout 1}
    fileevent $fd readable {set ::_readable 1}
    vwait ::_readable
    set len [gets $fd]
    set response [read $fd $len]
    set parts [::json::json2dict $response]
    list [lindex $parts 0] [lindex $parts 1]
} -cleanup {
    catch {close $fd}
    catch {unset ::_timeout ::_readable}
} -result {callback 1}
