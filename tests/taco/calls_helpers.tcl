# Helpers shared by the taco_calls test files.
package provide tacky::callshelpers 0.1

# Live per-call state: sid -> the call's fields (taco_calls::call Fields).
proc calls_state {} {
    set out {}
    foreach row [c.calls list] {
        set sid [dict get $row sid]
        dict set out $sid [[call_of $sid] Fields]
    }
    return $out
}

# The call for $sid (taco_calls::call).
proc call_of {sid} { c.calls Call $sid }

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

# $reason: the XEP-0166 condition a <reason/> child carries, if any.
proc calls_jmi_in {action sid from {reason ""}} {
    j message -from $from -to user@test.example.com -type chat {
        j $action -ns urn:xmpp:jingle-message:0 -id $sid {
            if {$action eq "propose"} {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio
            }
            if {$reason ne ""} {
                j reason -ns urn:xmpp:jingle:1 { j $reason }
            }
        }
    }
}
