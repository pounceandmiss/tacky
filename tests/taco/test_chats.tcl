# Tests for top-chats ordering (last-message)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set chats_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# Helper: insert a message directly into the store
proc chats_insert {chat_jid args} {
    set defaults [dict create \
        timestamp [clock microseconds] \
        from_jid "$chat_jid/someone" \
        body "hello" \
        server_id "" \
        own_id "" \
        raw_xml "" \
        server_status ""]
    set msg [dict merge $defaults [dict create chat_jid $chat_jid] $args]
    c message messagestore store [list $msg]
}

test chats-latest-ordered {latest returns JIDs ordered by most recent message} \
    {*}$chats_common \
    -body {
        set ts [clock microseconds]
        chats_insert alice@example.com timestamp $ts
        chats_insert bob@example.com \
            timestamp [expr {$ts + 1}]
        chats_insert carol@example.com \
            timestamp [expr {$ts + 2}]
        c chats latest
    } -result {carol@example.com bob@example.com alice@example.com}

test chats-latest-strips-join {latest strips ?join suffix from JIDs} \
    {*}$chats_common \
    -body {
        chats_insert room@muc.example.com?join
        c chats latest
    } -result {room@muc.example.com}

test chats-event-new-message {<Updated> fires for new message} \
    {*}$chats_common \
    -body {
        set got {}
        tacky listen chats <Updated> \
            {apply {{ev} { set ::got $ev }}}
        chats_insert alice@example.com
        update idletasks
        dict get $got -jid
    } -result {alice@example.com}

test chats-event-skips-old {old message after new one does not fire event} \
    {*}$chats_common \
    -body {
        set events {}
        tacky listen chats <Updated> \
            -jid alice@example.com \
            {apply {{ev} { lappend ::events $ev }}}
        set now [clock microseconds]
        chats_insert alice@example.com timestamp $now
        update idletasks
        # Insert an older message (MAM backfill)
        set old [expr {$now - 1000000}]
        chats_insert alice@example.com timestamp $old
        update idletasks
        llength $events
    } -result {1}

test chats-dedup-no-event {duplicate message does not fire event} \
    {*}$chats_common \
    -body {
        set events {}
        tacky listen chats <Updated> \
            -jid alice@example.com \
            {apply {{ev} { lappend ::events $ev }}}
        set ts [clock microseconds]
        chats_insert alice@example.com timestamp $ts server_id sid-dup
        update idletasks
        # Duplicate (same server_id — dedup in messagestore skips INSERT)
        chats_insert alice@example.com \
            timestamp [expr {$ts + 1}] server_id sid-dup
        update idletasks
        llength $events
    } -result {1}

test chats-event-debounced {batch inserts produce one event per JID} \
    {*}$chats_common \
    -body {
        set events {}
        tacky listen chats <Updated> \
            -jid alice@example.com \
            {apply {{ev} { lappend ::events $ev }}}
        set ts [clock microseconds]
        set msgs {}
        for {set i 0} {$i < 5} {incr i} {
            lappend msgs [dict create \
                timestamp [expr {$ts + $i}] \
                chat_jid alice@example.com \
                from_jid alice@example.com/phone \
                body "msg $i" \
                server_id "" \
                own_id "" \
                raw_xml "" \
                server_status ""]
        }
        c message messagestore store $msgs
        update idletasks
        llength $events
    } -result {1}
