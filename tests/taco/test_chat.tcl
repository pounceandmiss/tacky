# Unit tests for taco_chat
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

set chat_common [tacky_env -mock conn -account $acc -extra-setup {
    [$::_client cget -taco] app setActive -active 1
}]

# Helper: a message from alice, stored as if it had arrived.
# Returns the row's id.
proc chat_theirs {ts {oid ""}} {
    if {$oid eq ""} { set oid oid$ts }
    lindex [dict get [$::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid alice@example.com \
        from_jid alice@example.com/phone body "hello $ts" \
        server_id "" own_id "" raw_xml "" origin_id $oid]]] inserted] 0
}

# Helper: our own message, sent at $ts.
proc chat_ours {ts} {
    lindex [dict get [$::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid alice@example.com \
        from_jid $::acc body "reply $ts" \
        server_id "" own_id own$ts raw_xml "" origin_id own$ts]]] inserted] 0
}

# Helper: alice may see our presence, so markers go to her.
proc chat_contact {} {
    $::_client db eval {
        INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
        VALUES ('alice@example.com', '', 'both', '', 0)
    }
}

proc chat_displayed_ids {} {
    set ids {}
    foreach s [$::_client conn get_written] {
        set id [xsearch $s displayed -ns urn:xmpp:chat-markers:0 -get @id]
        if {$id ne ""} { lappend ids $id }
    }
    return $ids
}

# The id of the last row read, "" for none.
proc chat_read_id {} {
    dict get [tacky message ownRead -acc $::acc -chat alice@example.com] id
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
        set a [chat_theirs 100]
        chat_theirs 200
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -id $a
        list [expr {[chat_read_id] eq $a}] \
            [dict get [tacky message ownRead -acc $acc -chat alice@example.com] unread]
    } -result {1 1}

test chat-view-forward-only {a view behind the watermark moves nothing} \
    {*}$chat_common \
    -body {
        set a [chat_theirs 100]
        set b [chat_theirs 200]
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -id $b
        tacky chat view -acc $acc -chat alice@example.com -id $a
        expr {[chat_read_id] eq $b}
    } -result 1

test chat-view-closed-dropped {a view of a chat no one has open reads nothing} \
    {*}$chat_common \
    -body {
        set a [chat_theirs 100]
        tacky chat view -acc $acc -chat alice@example.com -id $a
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        chat_active 1
        chat_read_id
    } -result {}

test chat-view-held-while-inactive {a view while the app is inactive lands when it comes back} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        set b [chat_theirs 200]
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        tacky chat view -acc $acc -chat alice@example.com -id $b
        set before [chat_read_id]
        chat_active 1
        list $before [expr {[chat_read_id] eq $b}]
    } -result {{} 1}

test chat-view-held-dropped-on-close {closing a chat drops the view it held} \
    {*}$chat_common \
    -body {
        set a [chat_theirs 100]
        tacky chat open -acc $acc -chat alice@example.com
        chat_active 0
        tacky chat view -acc $acc -chat alice@example.com -id $a
        tacky chat close -acc $acc -chat alice@example.com
        chat_active 1
        chat_read_id
    } -result {}

test chat-view-sends-displayed {a 1:1 view sends one displayed marker per move} \
    {*}$chat_common \
    -body {
        chat_contact
        set a [chat_theirs 100 oid1]
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -id $a
        tacky chat view -acc $acc -chat alice@example.com -id $a
        chat_displayed_count
    } -result 1

test chat-view-ours-on-the-bottom {a view ending on our own reply marks theirs under it, once} \
    {*}$chat_common \
    -body {
        chat_contact
        chat_theirs 100 oid1
        set b [chat_ours 200]
        tacky chat open -acc $acc -chat alice@example.com
        tacky chat view -acc $acc -chat alice@example.com -id $b
        set c [chat_ours 300]
        tacky chat view -acc $acc -chat alice@example.com -id $c
        chat_displayed_ids
    } -result oid1

test chat-view-room-no-displayed {a room view moves the watermark and sends no marker} \
    {*}$chat_common \
    -body {
        set room room@conf.example.com?join
        set a [lindex [dict get [$::_client message messagestore store [list [dict create \
            timestamp 100 chat_jid $room from_jid room@conf.example.com/bob \
            body hi server_id "" own_id "" raw_xml "" origin_id oid2]]] inserted] 0]
        tacky chat open -acc $acc -chat $room
        tacky chat view -acc $acc -chat $room -id $a
        list [expr {[dict get [tacky message ownRead -acc $acc -chat $room] id] eq $a}] \
            [chat_displayed_count]
    } -result {1 0}

test chat-client-data-roundtrip {client data comes back as stored, open or not} \
    {*}$chat_common \
    -body {
        set out [list [tacky chat clientData -acc $acc -chat alice@example.com]]
        tacky chat setClientData -acc $acc -chat alice@example.com \
            -data {{"view":{"ts":100}}}
        lappend out [tacky chat clientData -acc $acc -chat alice@example.com]
        lappend out [tacky chat clientData -acc $acc -chat bob@example.com]
    } -result {{} {{"view":{"ts":100}}} {}}

test chat-client-data-empty-drops {storing an empty string drops the row} \
    {*}$chat_common \
    -body {
        tacky chat setClientData -acc $acc -chat alice@example.com -data x
        tacky chat setClientData -acc $acc -chat alice@example.com -data ""
        $::_client db eval {SELECT count(*) FROM chat_client_data}
    } -result 0

test chat-client-data-forgotten-with-history {forgetting a chat forgets its client data} \
    {*}$chat_common \
    -body {
        chat_theirs 100
        tacky chat setClientData -acc $acc -chat alice@example.com -data x
        $::_client message messagestore forgetChat alice@example.com
        tacky chat clientData -acc $acc -chat alice@example.com
    } -result {}
