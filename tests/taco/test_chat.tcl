# Unit tests for taco_chat
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

set chat_common [tacky_env -mock conn -account $acc -extra-setup {
    [$::_client cget -taco] app setActive -active 1
}]

# Helper: a message from alice, stored as if it had arrived.
proc chat_theirs {ts {oid ""}} {
    if {$oid eq ""} { set oid oid$ts }
    $::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid alice@example.com \
        from_jid alice@example.com/phone body "hello $ts" \
        server_id "" own_id "" raw_xml "" origin_id $oid]]
}

proc chat_read_ts {} {
    dict get [tacky message ownRead -acc $::acc -chat alice@example.com] timestamp
}

proc chat_displayed_count {} {
    set n 0
    foreach s [$::_client conn get_written] {
        if {[llength [xsearch $s displayed -ns urn:xmpp:chat-markers:0]] > 0} {
            incr n
        }
    }
    return $n
}

proc chat_active {on} {
    [$::_client cget -taco] app setActive -active $on
}

test chat-open-close {open and close track membership, not a count} \
    {*}$chat_common \
    -body {
        set out {}
        lappend out [tacky chat isOpen -acc $acc -chat alice@example.com]
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat open -acc $acc -chat alice@example.com
        lappend out [tacky chat isOpen -acc $acc -chat alice@example.com]
        tacky chat close -acc $acc -chat alice@example.com
        lappend out [tacky chat isOpen -acc $acc -chat alice@example.com]
    } -result {0 1 0}

test chat-looking-needs-active-app {a chat is looked at only while the app is active} \
    {*}$chat_common \
    -body {
        tacky chat open -acc $acc -chat alice@example.com
        set out [tacky chat isLooking -acc $acc -chat alice@example.com]
        chat_active 0
        lappend out [tacky chat isLooking -acc $acc -chat alice@example.com]
    } -result {1 0}

test chat-view-reads-up-to-the-row {a view reads up to the row on screen, not past it} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        chat_theirs 200
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        list [chat_read_ts] \
            [dict get [tacky message ownRead -acc $acc -chat alice@example.com] unread]
    } -result {100 1}

test chat-view-forward-only {a view behind the watermark moves nothing} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        chat_theirs 200
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -timestamp 200
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        chat_read_ts
    } -result 200

test chat-view-closed-dropped {a view of a chat no one has open reads nothing} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        chat_active 1
        chat_read_ts
    } -result 0

test chat-view-held-while-inactive {a view while the app is inactive lands when it comes back} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        chat_theirs 200
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        tacky chat view -acc $acc -chat alice@example.com -timestamp 200
        set before [chat_read_ts]
        chat_active 1
        list $before [chat_read_ts]
    } -result {0 200}

test chat-view-held-dropped-on-close {closing a chat drops the view it held} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        tacky chat close -acc $acc -chat alice@example.com
        chat_active 1
        chat_read_ts
    } -result 0

test chat-view-sends-displayed {a 1:1 view sends one displayed marker per move} \
    {*}$chat_common \
    -body {
        chat_theirs 100 oid1
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        tacky chat view -acc $acc -chat alice@example.com -timestamp 100
        chat_displayed_count
    } -result 1

test chat-view-room-no-displayed {a room view moves the watermark and sends no marker} \
    {*}$chat_common \
    -body {
        set room room@conf.example.com?join
        $::_client message messagestore store [list [dict create \
            timestamp 100 chat_jid $room from_jid room@conf.example.com/bob \
            body hi server_id "" own_id "" raw_xml "" origin_id oid2]]
        tacky chat open -acc $acc -chat $room
        tacky chat view -acc $acc -chat $room -timestamp 100
        list [dict get [tacky message ownRead -acc $acc -chat $room] timestamp] \
            [chat_displayed_count]
    } -result {100 0}
