# Unit tests for taco_notify
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

# The delay only exists to lose a race with the user reading a live
# arrival; zero it so tests don't wait on the event loop.
set notify_common [tacky_env -mock conn -account $acc -extra-setup {
    [$::_client cget -taco] setting set -key notify_delay_ms -value 0
    set ::alerts {}
    tacky listen notify <Alert> {apply {{ev} {
        lappend ::alerts [list [dict get $ev -jid] [dict get $ev -mention] \
            [dict get $ev -unread]]
    }}}
}]

# Helper: an inbound 1:1 message.
proc notify_incoming {body {id m1}} {
    $::_client conn feed [j message -type chat -id $id \
        -from alice@example.com/phone {
            j body #body $body
        }]
}

# Helper: an inbound room message from another occupant.
proc notify_room_message {room nick body {id r1}} {
    $::_client conn feed [j message -type groupchat -id $id \
        -from $room/$nick {
            j body #body $body
        }]
}

# Helper: join a room - send it, then feed the self-presence that makes muc
# emit <Joined>, so myNick resolves for mention detection.
proc notify_join {room nick} {
    $::_client muc join -jid $room -nick $nick
    $::_client conn feed [j presence -from $room/$nick {
        j x -ns http://jabber.org/protocol/muc#user {
            j item -role participant -affiliation member
            j status -code 110
        }
    }]
}

# Helper: local timestamp of a chat's newest stored message.
proc notify_newest_ts {jid} {
    set res [$::_client message messagestore get latest $jid]
    return [dict get [lindex [dict get $res messages] end] timestamp]
}

# Helper: just the chat jids that alerted.
proc notify_jids {} {
    return [lmap a $::alerts {lindex $a 0}]
}

test notify-incoming-alerts {an inbound 1:1 message alerts} \
    {*}$notify_common -body {
        notify_incoming "hello"
        notify_jids
    } -result {alice@example.com}

test notify-own-send-silent {our own message never alerts} \
    {*}$notify_common -body {
        tacky message send -acc $acc -chat alice@example.com -body "hi"
        notify_jids
    } -result {}

test notify-muted-chat-silent {a muted 1:1 chat does not alert} \
    {*}$notify_common -body {
        tacky notify set -acc $acc -chat alice@example.com -muted 1
        notify_incoming "hello"
        notify_jids
    } -result {}

test notify-already-read-silent {a message behind the watermark never alerts} \
    {*}$notify_common -body {
        notify_incoming "first"
        set ts [notify_newest_ts alice@example.com]
        tacky message markOwnRead -acc $acc -chat alice@example.com \
            -timestamp $ts
        set ::alerts {}
        notify_incoming "second" m2
        tacky message markOwnRead -acc $acc -chat alice@example.com \
            -timestamp [notify_newest_ts alice@example.com]
        set ::alerts {}
        # Re-announcing a watermark we already passed changes nothing.
        tacky message markOwnRead -acc $acc -chat alice@example.com \
            -timestamp $ts
        notify_jids
    } -result {}

test notify-read-cancels-pending {reading inside the delay window cancels the alert} \
    {*}$notify_common -body {
        [$::_client cget -taco] setting set -key notify_delay_ms -value 5000
        notify_incoming "hello"
        tacky message markOwnRead -acc $acc -chat alice@example.com \
            -timestamp [notify_newest_ts alice@example.com]
        notify_jids
    } -result {}

test notify-unread-count-rides-alert {the alert carries the chat's unread total} \
    {*}$notify_common -body {
        notify_incoming "one" m1
        notify_incoming "two" m2
        lmap a $::alerts {lindex $a 2}
    } -result {1 2}

# Rooms default to muted, so only a nick match gets through.
test notify-room-default-mentions-only {ordinary room traffic is silent} \
    {*}$notify_common -body {
        notify_join room@conf.example.com me
        notify_room_message room@conf.example.com bob "good morning all"
        notify_jids
    } -result {}

test notify-room-mention-alerts {a room message naming our nick alerts} \
    {*}$notify_common -body {
        notify_join room@conf.example.com me
        notify_room_message room@conf.example.com bob "me: are you there?"
        list [notify_jids] [lindex [lindex $::alerts 0] 1]
    } -result {room@conf.example.com?join 1}

test notify-room-mentions-off-silent {mentions=0 silences even a nick match} \
    {*}$notify_common -body {
        notify_join room@conf.example.com me
        tacky notify set -acc $acc -chat room@conf.example.com?join -mentions 0
        notify_room_message room@conf.example.com bob "me: hello"
        notify_jids
    } -result {}

test notify-room-unmuted-alerts-all {an unmuted room alerts on ordinary traffic} \
    {*}$notify_common -body {
        notify_join room@conf.example.com me
        tacky notify set -acc $acc -chat room@conf.example.com?join -muted 0
        notify_room_message room@conf.example.com bob "good morning all"
        notify_jids
    } -result {room@conf.example.com?join}

# Catch-up: messages that landed while we were away. Stored directly and
# settled by hand - the MAM machinery that produces <CatchupDone> is covered
# in test_message.tcl; what matters here is the sweep it triggers.
proc notify_store_unread {jid count} {
    set base [clock microseconds]
    set msgs {}
    for {set i 0} {$i < $count} {incr i} {
        lappend msgs [dict create \
            timestamp [expr {$base + $i}] chat_jid $jid \
            from_jid $jid/phone body "backlog $i" \
            server_id "" own_id "" raw_xml "" server_status ""]
    }
    $::_client message messagestore store $msgs
}

proc notify_catchup_done {jid} {
    $::_client bus publish message:<CatchupDone> -jid $jid -count 0
}

test notify-catchup-alerts {a backlog alerts once settled, carrying the true total} \
    {*}$notify_common -body {
        notify_store_unread alice@example.com 3
        notify_catchup_done alice@example.com
        list [llength $::alerts] [lindex [lindex $::alerts end] 2]
    } -result {3 3}

test notify-catchup-caps-burst {a large backlog is capped, but the total is not} \
    {*}$notify_common -body {
        notify_store_unread alice@example.com 15
        notify_catchup_done alice@example.com
        list [llength $::alerts] [lindex [lindex $::alerts end] 2]
    } -result {10 15}

test notify-catchup-no-realert {settling twice does not announce the backlog again} \
    {*}$notify_common -body {
        notify_store_unread alice@example.com 3
        notify_catchup_done alice@example.com
        set first [llength $::alerts]
        notify_catchup_done alice@example.com
        list $first [llength $::alerts]
    } -result {3 3}

test notify-catchup-respects-mute {a muted chat's backlog stays silent} \
    {*}$notify_common -body {
        tacky notify set -acc $acc -chat alice@example.com -muted 1
        notify_store_unread alice@example.com 3
        notify_catchup_done alice@example.com
        notify_jids
    } -result {}

test notify-catchup-skips-read {a backlog already read elsewhere stays silent} \
    {*}$notify_common -body {
        notify_store_unread alice@example.com 3
        tacky message markOwnRead -acc $acc -chat alice@example.com \
            -timestamp [notify_newest_ts alice@example.com]
        set ::alerts {}
        notify_catchup_done alice@example.com
        notify_jids
    } -result {}

test notify-policy-defaults {rooms default muted, 1:1 does not; both keep mentions} \
    {*}$notify_common -body {
        set direct [tacky notify get -acc $acc -chat alice@example.com]
        set room [tacky notify get -acc $acc -chat room@conf.example.com?join]
        list [dict get $direct muted] [dict get $direct mentions] \
            [dict get $room muted] [dict get $room mentions]
    } -result {0 1 1 1}

test notify-set-emits-settings {changing policy announces it} \
    {*}$notify_common -body {
        set ::ev {}
        tacky listen notify <Settings> {apply {{e} { set ::ev $e }}}
        tacky notify set -acc $acc -chat alice@example.com -muted 1
        list [dict get $::ev -jid] [dict get $::ev -muted] \
            [dict get $::ev -mentions]
    } -result {alice@example.com 1 1}

test notify-set-keeps-untouched-field {setting one field leaves the other alone} \
    {*}$notify_common -body {
        tacky notify set -acc $acc -chat alice@example.com -mentions 0
        set p [tacky notify get -acc $acc -chat alice@example.com]
        list [dict get $p muted] [dict get $p mentions]
    } -result {0 0}
