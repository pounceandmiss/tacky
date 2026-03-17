# --- test helpers ---

variable iq_test_sent {}

proc iqTestSendCmd {stanza} {
    lappend ::iq_test_sent $stanza
}

set common {-setup {
    set iq_test_sent {}
    iq .iq -send-command iqTestSendCmd
} -cleanup {
    .iq destroy
}}

# --- handler tests ---

test iq-handler-register "handler registers request handler" {*}$common -body {
    set received {}
    .iq handler get jabber:iq:version {apply {{stanza} {
        lappend ::received $stanza
    }}}
    .iq feed [j iq -type get -id 1 -from user@example.org {
        j query -ns jabber:iq:version
    }]
    llength $received
} -result {1}

test iq-handler-get-and-set "handler distinguishes get and set" {*}$common -body {
    set got_get 0
    set got_set 0
    .iq handler get urn:test {apply {{stanza} { incr ::got_get }}}
    .iq handler set urn:test {apply {{stanza} { incr ::got_set }}}
    .iq feed [j iq -type get -id 1 {j query -ns urn:test}]
    .iq feed [j iq -type set -id 2 {j query -ns urn:test}]
    list $got_get $got_set
} -result {1 1}

test iq-unhandler "unhandler removes request handler" {*}$common -body {
    set received 0
    .iq handler get urn:test {apply {{stanza} { incr ::received }}}
    .iq feed [j iq -type get -id 1 {j query -ns urn:test}]
    .iq unhandler get urn:test
    .iq feed [j iq -type get -id 2 {j query -ns urn:test}]
    list $received [llength $iq_test_sent]
} -result {1 1}

# --- feed request tests ---

test iq-feed-unknown-request "feed sends error for unknown request" {*}$common -body {
    .iq feed [j iq -type get -id 123 -from user@example.org {
        j query -ns urn:unknown
    }]
    set sent [lindex $iq_test_sent 0]
    list [xsearch $sent -get @type] [xsearch $sent -get @to] [xsearch $sent -get @id]
} -result {error user@example.org 123}

test iq-feed-unknown-request-no-from "feed sends error without to when no from" {*}$common -body {
    .iq feed [j iq -type get -id 123 {j query -ns urn:unknown}]
    set sent [lindex $iq_test_sent 0]
    list [xsearch $sent -get @type] [xsearch $sent -get @to]
} -result {error {}}

# --- feed response tests ---

test iq-feed-response-result "feed calls response handler for result" {*}$common -body {
    set received {}
    .iq request -to user@example.org -payload [j query -ns urn:test] \
        -command {apply {{stanza} { set ::received $stanza }}}
    set sentId [xsearch [lindex $iq_test_sent 0] -get @id]
    .iq feed [j iq -type result -id $sentId -from user@example.org {
        j query -ns urn:test
    }]
    expr {$received ne ""}
} -result {1}

test iq-feed-response-error "feed calls response handler for error" {*}$common -body {
    set received_type {}
    .iq request -to user@example.org -payload [j query -ns urn:test] \
        -command {apply {{stanza} { set ::received_type [xsearch $stanza -get @type] }}}
    set sentId [xsearch [lindex $iq_test_sent 0] -get @id]
    .iq feed [j iq -type error -id $sentId -from user@example.org]
    set received_type
} -result {error}

test iq-feed-response-cleanup "feed removes response handler after call" {*}$common -body {
    set call_count 0
    .iq request -to user@example.org -payload [j query -ns urn:test] \
        -command {apply {{stanza} { incr ::call_count }}}
    set sentId [xsearch [lindex $iq_test_sent 0] -get @id]
    .iq feed [j iq -type result -id $sentId -from user@example.org]
    .iq feed [j iq -type result -id $sentId -from user@example.org]
    set call_count
} -result {1}

test iq-feed-response-no-to-with-from "feed routes response with from when request had no to" {*}$common -body {
    set received {}
    .iq request -payload [j query -ns urn:test] \
        -command {apply {{stanza} { set ::received $stanza }}}
    set sentId [xsearch [lindex $iq_test_sent 0] -get @id]
    # Real servers include from= in responses to server-directed requests
    .iq feed [j iq -type result -id $sentId -from server.example.org {
        j query -ns urn:test
    }]
    expr {$received ne ""}
} -result {1}

test iq-feed-response-no-to-no-from "feed routes response without from when request had no to" {*}$common -body {
    set received {}
    .iq request -payload [j query -ns urn:test] \
        -command {apply {{stanza} { set ::received $stanza }}}
    set sentId [xsearch [lindex $iq_test_sent 0] -get @id]
    .iq feed [j iq -type result -id $sentId {j query -ns urn:test}]
    expr {$received ne ""}
} -result {1}

test iq-feed-response-exact-from-preferred "feed prefers exact from match over empty fallback" {*}$common -body {
    set result_a {}
    set result_b {}
    .iq request -to user@example.org -payload [j query -ns urn:a] \
        -command {apply {{stanza} { set ::result_a got }}}
    .iq request -payload [j query -ns urn:b] \
        -command {apply {{stanza} { set ::result_b got }}}
    set sentA [lindex $iq_test_sent 0]
    set sentB [lindex $iq_test_sent 1]
    set idA [xsearch $sentA -get @id]
    set idB [xsearch $sentB -get @id]
    # Response from user@example.org should hit the exact match, not the fallback
    .iq feed [j iq -type result -id $idA -from user@example.org]
    list $result_a $result_b
} -result {got {}}

test iq-feed-response-no-handler "feed ignores response without handler" {*}$common -body {
    .iq feed [j iq -type result -id 999 -from user@example.org]
    llength $iq_test_sent
} -result {0}

# --- request tests ---

test iq-request-basic "request sends iq stanza" {*}$common -body {
    .iq request -to user@example.org -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    list [xsearch $sent -get @type] [xsearch $sent -get @to] [xsearch $sent query -get ns]
} -result {get user@example.org urn:test}

test iq-request-type-set "request with -type set" {*}$common -body {
    .iq request -type set -to user@example.org -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    xsearch $sent -get @type
} -result {set}

test iq-request-no-to "request without -to omits to attribute" {*}$common -body {
    .iq request -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    xsearch $sent -get @to
} -result {}

test iq-request-custom-id "request with custom -id" {*}$common -body {
    .iq request -id my-custom-id -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    xsearch $sent -get @id
} -result {my-custom-id}

test iq-request-auto-id "request generates unique ids" {*}$common -body {
    .iq request -payload [j query -ns urn:test]
    .iq request -payload [j query -ns urn:test]
    set id1 [xsearch [lindex $iq_test_sent 0] -get @id]
    set id2 [xsearch [lindex $iq_test_sent 1] -get @id]
    expr {$id1 ne $id2}
} -result {1}

# --- respond tests ---

test iq-respond-basic "respond sends result iq" {*}$common -body {
    set request [j iq -type get -id 123 -from user@example.org {j query -ns urn:test}]
    .iq respond -for $request -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    list [xsearch $sent -get @type] [xsearch $sent -get @to] [xsearch $sent -get @id]
} -result {result user@example.org 123}

test iq-respond-error "respond with -type error" {*}$common -body {
    set request [j iq -type get -id 123 -from user@example.org {j query -ns urn:test}]
    .iq respond -type error -for $request -payload [j error -type cancel]
    set sent [lindex $iq_test_sent 0]
    xsearch $sent -get @type
} -result {error}

test iq-respond-no-from "respond without from omits to" {*}$common -body {
    set request [j iq -type get -id 123 {j query -ns urn:test}]
    .iq respond -for $request -payload [j query -ns urn:test]
    set sent [lindex $iq_test_sent 0]
    xsearch $sent -get @to
} -result {}
