# Helpers shared by the taco_calls test files.
package provide tacky::callshelpers 0.1

# Live per-call state by sid. The snit instance number differs per test,
# so match the variable instead of naming the instance.
proc calls_state {} {
    foreach v [c.calls info vars] {
        if {[string match *::Calls $v]} { return [set $v] }
    }
    error "calls: no Calls variable"
}

# Events this module emitted, minus the -acc stamped on every one.
proc calls_events {} {
    set out {}
    foreach e $::_emitted {
        if {[lindex $e 0] ne "calls"} continue
        lappend out [list [lindex $e 1] {*}[dict remove [lrange $e 2 end] -acc]]
    }
    return $out
}

proc calls_last_written {} {
    return [lindex [c.conn get_written] end]
}

proc calls_jmi_in {action sid from} {
    j message -from $from -to user@test.example.com -type chat {
        j $action -ns urn:xmpp:jingle-message:0 -id $sid {
            if {$action eq "propose"} {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio
            }
        }
    }
}
