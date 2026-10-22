# Helpers for the taco_calls state-machine and ICE restart tests: calls
# brought to each state against the mock media backend, and what they wrote.
package provide tacky::callsmachine 0.1
package require tacky::callshelpers

set ::CM_PEER peer@example.com/phone
set ::cm_seq 0
set ::CM_ME user@test.example.com/res

# -- Helpers --

proc cm_sdp {{ufrag abc} {pwd xyzxyzxyzxyzxyzxyzxyzx}} {
    return "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE audio\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=ice-ufrag:$ufrag\r\na=ice-pwd:$pwd\r\na=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\na=mid:audio\r\na=sendrecv\r\n"
}

proc cm_pc {sid} {
    dict get [dict get [calls_state] $sid] pc
}

proc cm_field {sid key} {
    dict get [dict get [calls_state] $sid] $key
}

# A Jingle IQ from the peer: an audio content with an ice-udp transport,
# which the description and transport actions all carry.
proc cm_jingle {action sid {from ""} {id cm1}} {
    if {$from eq ""} { set from $::CM_PEER }
    j iq -type set -from $from -to $::CM_ME -id $id {
        j jingle -ns urn:xmpp:jingle:1 -action $action -sid $sid {
            j content -creator initiator -name audio -senders both {
                j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                    j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                }
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                    -ufrag def -pwd defdefdefdefdefdefdefd {
                    # An answer takes a role; anything else offers both.
                    j fingerprint -ns urn:xmpp:jingle:apps:dtls:0 -hash sha-256 \
                        -setup [expr {$action eq "session-accept" ? "active" : "actpass"}] \
                        -body CC:DD
                    j candidate -foundation 1 -component 1 -protocol udp \
                        -priority 2122260223 -ip 192.0.2.7 -port 7777 \
                        -type host -id c1 -generation 0
                }
            }
            if {$action eq "session-terminate"} {
                j reason { j success }
            }
        }
    }
}

proc cm_answer_extdisco {} {
    set id ""
    foreach w [c.conn get_written] {
        if {[dict get $w tag] ne "iq"} continue
        set child [lindex [dict get $w children] 0]
        if {$child ne "" && [dict get $child tag] eq "services"} {
            set id [xsearch $w -get @id]
        }
    }
    if {$id eq ""} { error "no extdisco request was written" }
    c.conn feed [j iq -type result -from test.example.com -to $::CM_ME -id $id {
        j services -ns urn:xmpp:extdisco:2
    }]
}

# A Jingle IQ from the peer whose payload is the nodes $children.
proc cm_jingle_with {action sid children {id cm1}} {
    set jingle [j jingle -ns urn:xmpp:jingle:1 -action $action -sid $sid]
    dict set jingle children $children
    j iq -type set -from $::CM_PEER -to $::CM_ME -id $id { j #as-is $jingle }
}

# The Jingle error condition (urn:xmpp:jingle:errors:1) of our reply to the
# IQ with $id, "" if none.
proc cm_reply_jingle_error {{id cm1}} {
    xsearch [cm_reply $id] error * -ns urn:xmpp:jingle:errors:1 -get tag
}

# The last <jingle> with $action we sent, "" if none.
proc cm_sent {action} {
    set out ""
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $jn -get @action] eq $action} { set out $jn }
    }
    return $out
}

# Our reply to the IQ with $id, or "" if none went out.
proc cm_reply {{id cm1}} {
    foreach w [c.conn get_written] {
        if {[dict get $w tag] eq "iq" && [xsearch $w -get @id] eq $id
                && [xsearch $w -get @type] in {result error}} {
            return $w
        }
    }
    return ""
}

proc cm_reply_word {{id cm1}} {
    set w [cm_reply $id]
    if {$w eq ""} { return none }
    if {[xsearch $w -get @type] eq "result"} { return result }
    return [xsearch $w error * -ns urn:ietf:params:xml:ns:xmpp-stanzas -get tag]
}

# The <jingle> actions and JMI elements we wrote, in order.
proc cm_wire {} {
    set out {}
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $w -get @type] eq "set"} {
            lappend out [xsearch $jn -get @action]
            continue
        }
        foreach a {propose proceed ringing reject retract finish} {
            if {[xsearch $w $a -ns urn:xmpp:jingle-message:0 -get node] ne ""} {
                lappend out jmi-$a
            }
        }
    }
    return $out
}

# The last session-terminate we sent.
proc cm_terminate {} {
    set out ""
    foreach w [c.conn get_written] {
        set jn [xsearch $w jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jn ne "" && [xsearch $jn -get @action] eq "session-terminate"} {
            set out $jn
        }
    }
    return $out
}

proc cm_events {} {
    lmap e [calls_events] { lindex $e 0 }
}

proc cm_terminal_count {} {
    llength [lsearch -all -regexp [cm_events] {^<(Ended|Failed)>$}]
}

# Calls in each session state. Each returns the sid and leaves the wire
# cleared, so what a test sees is what its own input caused.
proc cm_in {state role} {
    set sid [cm_reach $state $role tk-cm[incr ::cm_seq]]
    if {[cm_field $sid state] ne $state} {
        error "cm_in: $role is in [cm_field $sid state], not $state"
    }
    c.conn clear
    set ::_emitted {}
    return $sid
}

proc cm_reach {state role sid} {
    switch -- $role,$state {
        caller,proposed {
            set sid [c.calls start -to peer@example.com]
        }
        caller,proceeded {
            set sid [c.calls start -to peer@example.com]
            c.conn feed [calls_jmi_in proceed $sid $::CM_PEER]
        }
        caller,pending {
            set sid [cm_reach proceeded caller $sid]
            cm_answer_extdisco
            mockmedia::drive localDescription [cm_pc $sid] [cm_sdp] offer
        }
        caller,established {
            set sid [cm_reach pending caller $sid]
            c.conn feed [cm_jingle session-accept $sid $::CM_PEER cm0]
        }
        callee,ringing {
            c.conn feed [calls_jmi_in propose $sid $::CM_PEER]
        }
        callee,proceeded {
            cm_reach ringing callee $sid
            c.calls accept -sid $sid
        }
        callee,pending {
            cm_reach proceeded callee $sid
            c.conn feed [cm_jingle session-initiate $sid $::CM_PEER cm0]
            cm_answer_extdisco
        }
        callee,established {
            cm_reach pending callee $sid
            mockmedia::drive localDescription [cm_pc $sid] [cm_sdp ghi] answer
        }
        default { error "cm_reach: no $role in $state" }
    }
    return $sid
}

# A call in $state with its media path brought to $transport.
proc cm_transport {transport {role caller}} {
    set sid [cm_in established $role]
    set pc [cm_pc $sid]
    switch -- $transport {
        idle        {}
        checking    { mockmedia::drive connectionState $pc connecting }
        connected   { mockmedia::drive connectionState $pc connected }
        interrupted {
            mockmedia::drive connectionState $pc connected
            mockmedia::drive connectionState $pc disconnected
        }
    }
    if {[cm_field $sid transport] ne $transport} {
        error "cm_transport: in [cm_field $sid transport], not $transport"
    }
    c.conn clear
    set ::_emitted {}
    return $sid
}

# Whatever is still up goes, so the next case is not turned away as busy.
proc cm_drop_all {} {
    foreach row [c.calls list] {
        c.calls hangup -sid [dict get $row sid]
    }
    c.conn clear
    set ::_emitted {}
}

proc cm_wait {ms} {
    after $ms {set ::cm_waited 1}
    vwait ::cm_waited
}

