package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set common [tacky_env -capture-emit 1 -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# -- OnReady ----------------------------------------------------------------

test client-onready-sets-jid {OnReady stores bound JID} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        c cget -jid
    } -result {user@test.example.com/res1}

test client-onready-emits-state {a session coming up emits conn <State> connected} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        set found {}
        foreach ev $_emitted {
            if {[lindex $ev 1] eq "<State>"} {
                set found $ev
                break
            }
        }
        list [lindex $found 0] [lindex $found 1] [lindex $found 2] [lindex $found 3] [lindex $found 4] [lindex $found 5]
    } -result {conn <State> -acc user@test.example.com -state connected}

# -- OnDisconnect -----------------------------------------------------------

test client-ondisconnect-emits {OnDisconnect emits conn <Disconnected>} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        set ::_emitted {}
        c.conn fire_disconnect "connection lost"
        # Find the <Disconnected> event
        set found {}
        foreach ev $_emitted {
            if {[lindex $ev 1] eq "<Disconnected>"} {
                set found $ev
                break
            }
        }
        list [lindex $found 0] [lindex $found 1] [lindex $found 2] [lindex $found 3] [lindex $found 4] [lindex $found 5]
    } -result {conn <Disconnected> -acc user@test.example.com -message {connection lost}}

# -- OnAuthError ------------------------------------------------------------

test client-onautherror-emits {OnAuthError emits conn <AuthError>} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        set ::_emitted {}
        c.conn fire_autherror "bad pw"
        # Find the <AuthError> event
        set found {}
        foreach ev $_emitted {
            if {[lindex $ev 1] eq "<AuthError>"} {
                set found $ev
                break
            }
        }
        list [lindex $found 0] [lindex $found 1] [lindex $found 2] [lindex $found 3] [lindex $found 4] [lindex $found 5]
    } -result {conn <AuthError> -acc user@test.example.com -message {bad pw}}

# -- OnStanza routing -------------------------------------------------------

test client-stanza-routes-iq {OnStanza routes iq stanzas to iq component} \
    {*}$common \
    -body {
        set received {}
        c.iq handler get urn:test:client {apply {{stanza} {
            lappend ::received $stanza
        }}}
        c.conn feed [j iq -type get -id 42 -from peer@example.org {
            j query -ns urn:test:client
        }]
        llength $received
    } -result {1}

# -- Bus lifecycle ----------------------------------------------------------

test client-bus-ready-fires {bus publishes <Ready> on non-resumed connect} \
    {*}$common \
    -body {
        set got 0
        c bus subscribe _ <Ready> {apply {{args} { incr ::got }}}
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        set got
    } -result {1}

test client-bus-ready-skipped-on-resume {bus does not publish <Ready> on resume} \
    {*}$common \
    -body {
        set got 0
        c bus subscribe _ <Ready> {apply {{args} { incr ::got }}}
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 1
        set got
    } -result {0}

test client-bus-disconnect-fires {bus publishes <Disconnect> on disconnect} \
    {*}$common \
    -body {
        set got 0
        c bus subscribe _ <Disconnect> {apply {{args} { incr ::got }}}
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        c.conn fire_disconnect "gone"
        set got
    } -result {1}

test client-bus-emit-publishes {emit publishes module:event on bus} \
    {*}$common \
    -body {
        set got {}
        c bus subscribe _ test:<Ping> {apply {{args} { set ::got $args }}}
        c emit test <Ping> -data hello
        set got
    } -result {-data hello}

# -- XEP-0280 carbons ------------------------------------------------------

# Helper: find the first enable-carbons IQ in mock_conn's written log.
proc ::find_enable_carbons {written} {
    foreach s $written {
        if {[xsearch $s -get tag] ne "iq"} continue
        if {[xsearch $s enable -ns urn:xmpp:carbons:2 -get node] ne ""} {
            return $s
        }
    }
    return ""
}

test client-carbons-enabled-on-ready {OnReady sends <enable xmlns=carbons:2/> on fresh session} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        set iq [::find_enable_carbons [c.conn get_written]]
        expr {$iq ne "" && [xsearch $iq -get @type] eq "set"}
    } -result {1}

test client-carbons-not-re-enabled-on-resume {resumed stream preserves carbons state — no re-enable} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 1
        ::find_enable_carbons [c.conn get_written]
    } -result {}

test client-carbons-unwraps-self-sent {<sent> carbon from our own bare JID returns the forwarded inner message} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        set carbon [j message -from user@test.example.com -to user@test.example.com {
            j sent -ns urn:xmpp:carbons:2 {
                j forwarded -ns urn:xmpp:forward:0 {
                    j message -from user@test.example.com/res2 -to peer@example.org/x -type chat {
                        j body -body hello
                    }
                }
            }
        }]
        set inner [c UnwrapCarbon $carbon]
        list [xsearch $inner -get tag] \
             [xsearch $inner -get @from] \
             [xsearch $inner body -get body]
    } -result {message user@test.example.com/res2 hello}

test client-carbons-unwraps-received {<received> carbon also unwraps} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        set carbon [j message -from user@test.example.com -to user@test.example.com {
            j received -ns urn:xmpp:carbons:2 {
                j forwarded -ns urn:xmpp:forward:0 {
                    j message -from peer@example.org/x -to user@test.example.com/res2 -type chat {
                        j body -body howdy
                    }
                }
            }
        }]
        xsearch [c UnwrapCarbon $carbon] body -get body
    } -result {howdy}

test client-carbons-drops-forged {carbon envelope from a foreign bare JID is dropped per XEP-0280 §11} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        # Attacker-shaped envelope: outer @from is not our bare JID.
        # Returning the inner would let any peer inject stanzas as us.
        set carbon [j message -from attacker@evil.org -to user@test.example.com {
            j sent -ns urn:xmpp:carbons:2 {
                j forwarded -ns urn:xmpp:forward:0 {
                    j message -from user@test.example.com/res2 -to peer@example.org/x {
                        j body -body forged
                    }
                }
            }
        }]
        c UnwrapCarbon $carbon
    } -result {}

test client-carbons-ignores-plain {a regular message with no carbon wrapper returns empty} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        set m [j message -from peer@example.org/x -to user@test.example.com -type chat {
            j body -body hi
        }]
        c UnwrapCarbon $m
    } -result {}

# -- changePassword ---------------------------------------------------------

set pw_common [tacky_env -mock conn -account user@test.example.com]

proc pw_reply {args} {
    $::_client.conn feed [j iq -from test.example.com \
        -id [xsearch [lindex [$::_client.conn get_written] end] -get @id] {*}$args]
}

test client-password-stored-without-callback {a confirmed change is stored with no -command} \
    {*}$pw_common \
    -body {
        $::_client changePassword -password newpass
        pw_reply -type result
        list [$::_client cget -password] \
            [tacky account get -acc user@test.example.com -field password]
    } -result {newpass newpass}

test client-password-answers-command {a confirmed change answers -command with an empty result} \
    {*}$pw_common \
    -body {
        set ::pw_reply pending
        $::_client changePassword -password newpass \
            -command {apply {{msg} {set ::pw_reply [list replied $msg]}}}
        pw_reply -type result
        set ::pw_reply
    } -result {replied {}}

test client-password-rejected {a rejected change reports through -onerror and changes nothing} \
    {*}$pw_common \
    -body {
        set ::pw_err ""
        set before [$::_client cget -password]
        $::_client changePassword -password newpass \
            -onerror {apply {{msg} {set ::pw_err $msg}}}
        pw_reply -type error {
            j error -type modify {
                j not-acceptable -ns urn:ietf:params:xml:ns:xmpp-stanzas
                j text -ns urn:ietf:params:xml:ns:xmpp-stanzas -body "Too weak"
            }
        }
        list $::pw_err [expr {[$::_client cget -password] eq $before}]
    } -result {{Too weak} 1}

test client-password-rejected-no-text {a rejected change with no text falls back to the condition} \
    {*}$pw_common \
    -body {
        set ::pw_err ""
        $::_client changePassword -password newpass \
            -onerror {apply {{msg} {set ::pw_err $msg}}}
        pw_reply -type error {
            j error -type modify {
                j not-allowed -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }
        set ::pw_err
    } -result {not-allowed}
