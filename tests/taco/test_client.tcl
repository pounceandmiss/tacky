set common {
    -setup {
        tacky_type create tacky
        oo::objdefine tacky method emit {module event args} {
            lappend ::_emitted [list $module $event {*}$args]
        }
        set ::_emitted {}

        # Inject mock_conn via rename (same pattern as test_conn.tcl)
        rename conn _real_conn
        rename mock_conn conn

        taco_client c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res
    }
    -cleanup {
        catch {c destroy}
        rename conn mock_conn
        rename _real_conn conn
        tacky destroy
    }
}

# -- OnReady ----------------------------------------------------------------

test client-onready-sets-jid {OnReady stores bound JID} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        c cget -jid
    } -result {user@test.example.com/res1}

test client-onready-emits-event {OnReady emits conn <Ready>} \
    {*}$common \
    -body {
        c.conn configure -bound-jid "user@test.example.com/res1"
        c.conn fire_ready 0
        # Find the <Ready> event (fire_ready now emits via -emit)
        set found {}
        foreach ev $_emitted {
            if {[lindex $ev 1] eq "<Ready>"} {
                set found $ev
                break
            }
        }
        list [lindex $found 0] [lindex $found 1] [lindex $found 2] [lindex $found 3] [lindex $found 4] [lindex $found 5]
    } -result {conn <Ready> -acc user@test.example.com -resumed 0}

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
