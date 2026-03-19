# Unit tests for jsonify.tcl

package require json::write
json::write indented false

if {[info commands ::jsonify] eq ""} {
    source [file join [file dirname [info script]] jsonify.tcl]
}

# -- Primitives ---------------------------------------------------------------

test jsonify-string {string encoding} -body {
    jsonify to_json {hello world} string
} -result {"hello world"}

test jsonify-string-escape {string with quotes and backslashes} -body {
    jsonify to_json {say "hi\n"} string
} -result {"say \"hi\\n\""}

test jsonify-int {integer} -body {
    jsonify to_json 42 int
} -result {42}

test jsonify-int-empty {empty int → null} -body {
    jsonify to_json {} int
} -result {null}

test jsonify-bool-true {bool true} -body {
    jsonify to_json 1 bool
} -result {true}

test jsonify-bool-false {bool false} -body {
    jsonify to_json 0 bool
} -result {false}

test jsonify-base64 {binary data to base64} -body {
    jsonify to_json \x89PNG\r\n\x1a\n base64
} -result [json::write string [binary encode base64 \x89PNG\r\n\x1a\n]]

# -- Lists --------------------------------------------------------------------

test jsonify-list-strings {plain list → array of strings} -body {
    jsonify to_json {alice bob carol} list
} -result {["alice","bob","carol"]}

test jsonify-list-int {list of ints} -body {
    jsonify to_json {1 2 3} {list int}
} -result {[1,2,3]}

test jsonify-list-empty {empty list} -body {
    jsonify to_json {} list
} -result {[]}

# -- Dicts ---------------------------------------------------------------------

test jsonify-dict-all-string {dict with no schema → all strings} -body {
    jsonify to_json {name Alice jid alice@example.com} {dict {}}
} -result [json::write object name {"Alice"} jid {"alice@example.com"}]

test jsonify-dict-typed {dict with typed fields} -body {
    jsonify to_json {count 5 complete 1 name test} {dict {count int complete bool}}
} -result [json::write object count 5 complete true name {"test"}]

# -- Named types ---------------------------------------------------------------

test jsonify-named-message {message named type} -body {
    jsonify to_json {timestamp 1000 body hi hollow 1 from_jid a@b} message
} -result [json::write object \
    timestamp 1000 body {"hi"} hollow true from_jid {"a@b"}]

test jsonify-named-roster {roster_item with bool and list fields} -body {
    jsonify to_json {jid a@b name Alice approved 1 groups {work friends}} roster_item
} -result [json::write object \
    jid {"a@b"} name {"Alice"} approved true \
    groups [json::write array {"work"} {"friends"}]]

# -- Schema-based convert ------------------------------------------------------

test jsonify-convert-history {message/history → list of messages} -body {
    set msgs [list \
        [dict create timestamp 100 body hello hollow 0] \
        [dict create timestamp 200 body world hollow 1]]
    jsonify convert message/history $msgs
} -result [json::write array \
    [json::write object timestamp 100 body {"hello"} hollow false] \
    [json::write object timestamp 200 body {"world"} hollow true]]

test jsonify-convert-search {message/search → dict with list and bool} -body {
    set result [dict create \
        messages [list [dict create timestamp 100 body hi hollow 0]] \
        complete 1 \
        last some-id]
    jsonify convert message/search $result
} -result [json::write object \
    messages [json::write array \
        [json::write object timestamp 100 body {"hi"} hollow false]] \
    complete true \
    last {"some-id"}]

test jsonify-convert-presence {event with nested occupant dict} -body {
    set args [dict create \
        jid room@muc \
        occupant [dict create nick Bob jid bob@server role moderator]]
    jsonify convert muc/<Presence> $args
} -result [json::write object \
    jid {"room@muc"} \
    occupant [json::write object nick {"Bob"} jid {"bob@server"} role {"moderator"}]]

test jsonify-convert-unavailable {list of ints + nested dict} -body {
    set args [dict create \
        jid room@muc \
        codes {301 307} \
        occupant [dict create nick Eve role none]]
    jsonify convert muc/<Unavailable> $args
} -result [json::write object \
    jid {"room@muc"} \
    codes [json::write array 301 307] \
    occupant [json::write object nick {"Eve"} role {"none"}]]

test jsonify-convert-bool {scalar bool via schema} -body {
    jsonify convert presence/isOnline 1
} -result {true}

test jsonify-convert-list {plain list via schema} -body {
    jsonify convert chats/latest {a@b c@d e@f}
} -result {["a@b","c@d","e@f"]}

test jsonify-convert-unknown {unknown schema → dict of strings} -body {
    jsonify convert unknown/method {foo bar baz qux}
} -result [json::write object foo {"bar"} baz {"qux"}]

test jsonify-convert-roster {list of named types via schema} -body {
    set items [list \
        [dict create jid a@b approved 1 groups {x}] \
        [dict create jid c@d approved 0 groups {}]]
    jsonify convert roster/get $items
} -result [json::write array \
    [json::write object jid {"a@b"} approved true groups [json::write array {"x"}]] \
    [json::write object jid {"c@d"} approved false groups [json::write array]]]
