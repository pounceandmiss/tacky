# Unit tests for tackyd-json JSON formatting and dispatch logic.
package require tcltest
namespace import ::tcltest::*
package require json
package require json::write
package require tackyd-json

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

# Define the procs under test, wired to our capturing pipesend.
proc _test_on_result {id schema_key result} {
    _test_pipesend [json::write array \
        [json::write string result] \
        $id \
        [jsonify convert $schema_key $result]]
}

proc _test_on_error {id errmsg} {
    _test_pipesend [json::write array \
        [json::write string error] \
        $id \
        [json::write string $errmsg]]
}

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

proc _test_emit {module event args} {
    set args [strip_dashes $args]
    set json_args [jsonify convert $module/$event $args]
    _test_pipesend [json::write array \
        [json::write string event] \
        [json::write string $module] \
        [json::write string $event] \
        $json_args]
}

# -- _on_result tests --------------------------------------------------------

test json-backend-callback-search {callback result with schema} -setup {
    _test_clear
} -body {
    set result [dict create \
        messages [list [dict create timestamp 100 body hi is_outgoing 0]] \
        complete 1]
    _test_on_result 42 message/search $result
    lindex [_test_sent] 0
} -result [json::write array \
    {"result"} 42 \
    [json::write object \
        messages [json::write array \
            [json::write object timestamp 100 body {"hi"} is_outgoing false]] \
        complete true]]

test json-backend-callback-list {callback with list of ints} -setup {
    _test_clear
} -body {
    _test_on_result 7 message/local_search {10 20 30}
    lindex [_test_sent] 0
} -result [json::write array \
    {"result"} 7 \
    [json::write array 10 20 30]]

test json-backend-callback-bool {callback with scalar bool} -setup {
    _test_clear
} -body {
    _test_on_result 3 presence/isOnline 1
    lindex [_test_sent] 0
} -result [json::write array {"result"} 3 true]

test json-backend-callback-roster {roster items use dashless keys} -setup {
    _test_clear
} -body {
    set items [list [dict create jid a@b approved 1 groups {x}]]
    _test_on_result 2 roster/get $items
    lindex [_test_sent] 0
} -result [json::write array \
    {"result"} 2 \
    [json::write array \
        [json::write object jid {"a@b"} approved true groups [json::write array {"x"}]]]]

# -- form type tests ---------------------------------------------------------

test json-type-form {form dict serializes to a nested JSON object} -body {
    jsonify to_json \
        [dict create \
            instructions Configure \
            fields [list \
                [dict create var FORM_TYPE type hidden label FORM_TYPE \
                    required 0 value urn:x] \
                [dict create var langs type list-multi label Languages \
                    required 1 value {en de} \
                    options [list \
                        [dict create label English value en] \
                        [dict create label German value de]]]]] \
        form
} -result [json::write object \
    instructions {"Configure"} \
    fields [json::write array \
        [json::write object var {"FORM_TYPE"} type {"hidden"} label {"FORM_TYPE"} \
            required false value [json::write array {"urn:x"}]] \
        [json::write object var {"langs"} type {"list-multi"} label {"Languages"} \
            required true value [json::write array {"en"} {"de"}] \
            options [json::write array \
                [json::write object label {"English"} value {"en"}] \
                [json::write object label {"German"} value {"de"}]]]]]

# -- double / map hint tests -------------------------------------------------

test json-type-double {double hint emits a JSON number} -body {
    jsonify to_json 1.0 double
} -result 1.0

test json-type-double-empty {empty double is null} -body {
    jsonify to_json "" double
} -result null

test json-type-map {map hint coerces every value to T} -body {
    jsonify to_json [dict create a 100 b 200] {map int}
} -result [json::write object a 100 b 200]

test json-type-map-named {map of a named type coerces nested objects} -body {
    jsonify to_json \
        [dict create laptop [dict create priority 5] phone [dict create priority 3]] \
        {map presence}
} -result [json::write object \
    laptop [json::write object priority 5] \
    phone [json::write object priority 3]]

test json-backend-callback-volume {getVolume result is a JSON number} -setup {
    _test_clear
} -body {
    _test_on_result 8 audio/getVolume 0.75
    lindex [_test_sent] 0
} -result [json::write array {"result"} 8 0.75]

test json-backend-callback-resources {resources is a map of presence objects} -setup {
    _test_clear
} -body {
    _test_on_result 9 presence/resources \
        [dict create laptop [dict create priority 5 show away]]
    lindex [_test_sent] 0
} -result [json::write array \
    {"result"} 9 \
    [json::write object \
        laptop [json::write object priority 5 show {"away"}]]]

test json-backend-callback-call-start {start returns a scalar sid string} -setup {
    _test_clear
} -body {
    _test_on_result 11 calls/start "sid-abc123"
    lindex [_test_sent] 0
} -result [json::write array {"result"} 11 {"sid-abc123"}]

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

test json-backend-emit-event {emit event with schema, dashless keys} -setup {
    _test_clear
} -body {
    _test_emit message <New> \
        -message [dict create timestamp 100 body hello is_outgoing 0]
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"message"} {"<New>"} \
    [json::write object \
        message [json::write object timestamp 100 body {"hello"} is_outgoing false]]]

test json-backend-emit-formatting {emit message with formatting entities} -setup {
    _test_clear
} -body {
    _test_emit message <New> \
        -message [dict create timestamp 100 body {hello bold world} \
                      formatting {bold 6 4}]
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"message"} {"<New>"} \
    [json::write object \
        message [json::write object timestamp 100 body {"hello bold world"} \
            formatting [json::write array \
                [json::write object type {"bold"} offset 6 length 4]]]]]

test json-backend-emit-attachments {emit message with attachments and caption} -setup {
    _test_clear
} -body {
    _test_emit message <New> \
        -message [dict create timestamp 100 body https://h/p.png caption "" \
                      attachments [list [dict create url https://h/p.png \
                          type image name p.png size 20480 mime image/png]]]
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"message"} {"<New>"} \
    [json::write object \
        message [json::write object timestamp 100 body {"https://h/p.png"} \
            caption {""} \
            attachments [json::write array \
                [json::write object url {"https://h/p.png"} type {"image"} \
                    name {"p.png"} size 20480 mime {"image/png"}]]]]]

test json-backend-emit-no-schema {emit event without schema, dashless keys} -setup {
    _test_clear
} -body {
    _test_emit account <Added> -acc user@example.com
    lindex [_test_sent] 0
} -result [json::write array \
    {"event"} {"account"} {"<Added>"} \
    [json::write object acc {"user@example.com"}]]

# -- dispatch (JSON parsing) tests ------------------------------------------

test json-backend-parse-with-id {parse request, add_dashes produces dashed dict} -body {
    set parts [::json::json2dict {["message","search",{"acc":"user@srv","chat":"room@muc"},1]}]
    set args [add_dashes [lindex $parts 2]]
    list [lindex $parts 0] [lindex $parts 1] $args [lindex $parts 3]
} -result {message search {-acc user@srv -chat room@muc} 1}

test json-backend-parse-no-id {parse array request without id} -body {
    set parts [::json::json2dict {["account","list",{}]}]
    list [lindex $parts 0] [lindex $parts 1] [llength $parts]
} -result {account list 3}

test json-backend-parse-with-args {dashless JSON args become dashed Tcl dict} -body {
    set parts [::json::json2dict {["chatlist","get",{"acc":"a@b.c","tag":"w1"}]}]
    set args [add_dashes [lindex $parts 2]]
    list [dict get $args -acc] [dict get $args -tag]
} -result {a@b.c w1}

# -- integration: dispatch through taco via process --------------------------

test json-backend-process-roundtrip {spawn json backend, send request, get response} \
    -constraints hasProcess -setup {
    set backend [file join [file dirname [info script]] .. .. bin tackyd-json.tcl]
    set fd [open |[list [info nameofexecutable] $backend] r+]
    chan configure $fd -translation binary -buffering full -blocking 0
} -body {
    set req [encoding convertto utf-8 {["account","list",{},1]}]
    puts $fd [string length $req]
    puts -nonewline $fd $req
    flush $fd
    chan configure $fd -blocking 0
    after 3000 {set ::_timeout 1}
    fileevent $fd readable {set ::_readable 1}
    vwait ::_readable
    set len [gets $fd]
    set response [encoding convertfrom utf-8 [read $fd $len]]
    set parts [::json::json2dict $response]
    list [lindex $parts 0] [lindex $parts 1]
} -cleanup {
    catch {close $fd}
    catch {unset ::_timeout ::_readable}
} -result {result 1}
