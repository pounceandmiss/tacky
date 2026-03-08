# connection.tcl - XMPP connection types.
#
#   bareconn   Ready as soon as the transport connects. No auth, no SM.
#              Use for server-to-server links or pre-auth scenarios.
#
#   conn       Full XMPP client: SASL PLAIN auth, resource binding, XEP-0198
#              stream management, auto-reconnect with exponential backoff.
#              Use for normal client-to-server connections.
#
# Both track connection state (disconnected|connecting|connected).
# conn adds authenticating, binding, and waiting states.
#
# Common methods:
#   connect host port      Start async TCP+TLS connection (bareconn)
#   connect                Start connection using -host/-port options (conn)
#   close                  Tear down the connection
#   isReady                True when the connection is usable
#   write data             Queue raw data (sent immediately if ready)
#   writeStanza stanza     Serialize a stanza dict and write it
#   state                  Current connection state
#   socket                 Raw socket channel from baseconn
#
# Common options:
#   -onready               Transport ready (bareconn) / session ready (conn)
#   -ondisconnect cmd      Called with message string on transport error/EOF
#   -onstanza cmd          Called with each stanza dict
#   -starttls bool         Whether to negotiate STARTTLS (default true)
#   -header-command cmd    Called with the opening <stream:stream> element
#   -footer-command cmd    Called with the closing </stream:stream>
#
# conn-only methods:
#   sm                     Access the stream management component
#
# conn-only options:
#   -host, -port           Server to connect to (default port 5222)
#   -username, -password   SASL PLAIN credentials
#   -resource              Requested resource for binding
#   -onautherror cmd       Called with message on SASL/bind failure
#   -autoreconnect bool    Auto-reconnect on transport errors (default off)
#   -bound-jid             Full JID assigned by the server (read-only)
#   -emit cmd              Event callback: {*}$cmd conn <Event> ...
#
# Usage:
#
#   bareconn create bc \
#       -starttls false \
#       -onready       {puts "transport up"} \
#       -ondisconnect  {apply {{msg} {puts "lost: $msg"}}}
#   bc connect example.com 5269
#
#   conn create c \
#       -host example.com -port 5222 \
#       -username alice -password secret \
#       -onready       {apply {{resumed} {puts "ready (resumed=$resumed)"}}} \
#       -ondisconnect  {apply {{msg} {puts "disconnected: $msg"}}} \
#       -onautherror   {apply {{msg} {puts "auth failed: $msg"}}} \
#       -autoreconnect 1
#   c connect

# Base Connection - manages the TCP socket, optional STARTTLS, and XML
# stream parsing via xmppreader. No SASL auth, resource binding, or
# stream management - those are handled by the higher-level types.
snit::type baseconn {
    # The TCP (or TLS-wrapped) socket channel, "" when not connected
    variable socket
    # disconnected | connecting | connected
    variable state
    # Remote hostname, set on connect
    variable host
    # Whether an "after idle" flush is already scheduled
    variable flushPending

    # Callback when the transport (TCP + optional TLS) is ready for use
    option -ontransportready -default ""
    # Whether to negotiate STARTTLS before declaring transport ready
    option -starttls -default true
    # Callback for each top-level XMPP stanza received (node dict)
    option -command -default control::no-op
    # Callback for the opening <stream:stream> element (node dict)
    option -header-command -default control::no-op
    # Callback for the closing </stream:stream>
    option -footer-command -default control::no-op
    # Callback for read errors, write errors, and EOF
    option -error-command -default control::no-op
    # Debug hook: called as {*}$cmd $dir $stanza for in/out stanzas
    option -ondebugstanza -default ""

    constructor {args} {
        $self configurelist $args
        set socket ""
        set state disconnected
        set host ""
        set flushPending 0
    }

    destructor {
        $self close
    }

    method state {} {
        return $state
    }

    # Serialize a stanza dict and write it to the socket immediately.
    method writeStanza {stanza} {
        if {$options(-ondebugstanza) ne ""} {
            {*}$options(-ondebugstanza) out $stanza
        }
        $self writeNow [jwrite $stanza]
    }

    # Direct socket write (for protocol-level stuff).
    # Defers flush to "after idle" so burst writes (e.g. AutojoinAll)
    # coalesce into a single TLS record / TCP send.
    method writeNow {data} {
        if {$state ne "connected"} {
            return
        }
        if {[catch {
            puts -nonewline $socket $data
            if {!$flushPending} {
                set flushPending 1
                after idle [mymethod FlushWrite]
            }
        } err]} {
            $self close
            {*}$options(-error-command) "Write error: $err"
        }
    }

    method FlushWrite {} {
        set flushPending 0
        if {$state ne "connected"} return
        if {[catch {flush $socket} err]} {
            $self close
            {*}$options(-error-command) "Write error: $err"
        }
    }

    method connect {h port} {
        if {$state ne "disconnected"} {
            return
        }
        set host $h
        set state connecting
        if {[catch {
            set socket [socket -async $host $port]
        } err]} {
            set state disconnected
            after idle [list {*}$options(-error-command) "Connect failed: $err"]
            return
        }
        fconfigure $socket -blocking 0 -buffering full -translation binary
        fileevent $socket writable [list $self OnSocketConnected]
    }

    method OnSocketConnected {} {
        fileevent $socket writable {}
        set err [fconfigure $socket -error]
        if {$err ne ""} {
            catch {close $socket}
            set socket ""
            set state disconnected
            {*}$options(-error-command) "Connect failed: $err"
            return
        }
        if {$options(-starttls)} {
            xmpp_starttls $socket $host [list $self OnStarttlsComplete]
        } else {
            $self CreateReader
            set state connected
            if {$options(-ontransportready) ne ""} {
                {*}$options(-ontransportready)
            }
        }
    }

    method OnStarttlsComplete {status {tlsSocket ""}} {
        if {$status eq "ok"} {
            set socket $tlsSocket
            $self CreateReader
            set state connected
            if {$options(-ontransportready) ne ""} {
                {*}$options(-ontransportready)
            }
        } else {
            catch {close $socket}
            set socket ""
            set state disconnected
            if {$options(-error-command) ne "control::no-op"} {
                {*}$options(-error-command) "STARTTLS failed"
            }
        }
    }

    method OnStanzaIn {stanza} {
        if {$options(-ondebugstanza) ne ""} {
            {*}$options(-ondebugstanza) in $stanza
        }
        {*}$options(-command) $stanza
    }

    method CreateReader {} {
	::jab::cancelRead $socket
        fconfigure $socket -encoding utf-8 -translation lf
        ::jab::readChannel $socket \
            -command [mymethod OnStanzaIn] \
            -header-command $options(-header-command) \
            -footer-command $options(-footer-command) \
            -error-command $options(-error-command)
    }

    method close {} {
        set flushPending 0
        ::jab::cancelRead $socket
        if {$socket ne ""} {
            catch {close $socket}
            set socket ""
        }
        set state disconnected
    }

    method socket {} {
        return $socket
    }
}

# Barebones Connection - wraps baseconn with a write buffer.
# Ready as soon as the transport connects. No auth, no SM.
# Useful for server-to-server or pre-auth scenarios.
snit::type bareconn {
    component base

    delegate method state to base
    delegate method socket to base
    delegate option * to base except {-ontransportready -command -error-command}

    # Callback when the transport is up and the connection is usable
    option -onready -default ""
    # Called on transport error/EOF; receives message string
    option -ondisconnect -default ""
    # Called with each received stanza dict
    option -onstanza -default ""

    # disconnected | connecting | connected
    variable connState disconnected
    # Raw data queued before the transport is ready; flushed on connect
    variable writeBuffer

    constructor {args} {
        install base using baseconn $self.base \
            -ontransportready [mymethod OnTransportReady] \
            -command [mymethod OnStanza] \
            -error-command [mymethod OnTransportError]
        $self configurelist $args
        set writeBuffer {}
    }

    method OnStanza {stanza} {
        jlog debug "stanza in" -stanza $stanza
        if {$options(-onstanza) ne ""} {
            {*}$options(-onstanza) $stanza
        }
    }

    destructor {
        catch {$base destroy}
    }

    method isReady {} {
        return [expr {$connState eq "connected"}]
    }

    method connState {} {
        return $connState
    }

    method connect {args} {
        set connState connecting
        $base connect {*}$args
    }

    method close {} {
        $base close
        set connState disconnected
    }

    method OnTransportError {msg} {
        $base close
        set connState disconnected
        if {$options(-ondisconnect) ne ""} {
            {*}$options(-ondisconnect) $msg
        }
    }

    method write {data} {
        if {[$self isReady]} {
            $base writeNow $data
        } else {
            lappend writeBuffer $data
        }
    }

    method writeStanza {stanza} {
        jlog debug "stanza out" -stanza $stanza
        if {[$self isReady]} {
            $base writeStanza $stanza
        } else {
            lappend writeBuffer [jwrite $stanza]
        }
    }

    method OnTransportReady {} {
        set connState connected
        $self FlushBuffer
        if {$options(-onready) ne ""} {
            {*}$options(-onready)
        }
    }

    method FlushBuffer {} {
        foreach data $writeBuffer {
            $base writeNow $data
        }
        set writeBuffer {}
    }
}

# Full XMPP client connection. On top of baseconn, handles SASL PLAIN
# auth, resource binding, and XEP-0198 stream management (via the sm
# component). Supports auto-reconnect with exponential backoff.
# Flow: connect → STARTTLS → SASL auth → bind → SM enable → ready.

# state (connState) is what external code observes (e.g. UI "connecting…" spinner):
#   disconnected | connecting | authenticating | binding | connected | waiting
# authState drives the stanza dispatcher to the right handler method.
# Both reset to "disconnected" on close() or fatal errors.
# conn emits events via the -emit callback on state transitions and
# connection lifecycle events (<State>, <Ready>, <Disconnected>, <AuthError>).
snit::type conn {
    component base
    component sm

    delegate method socket to base
    delegate option * to base except {-ontransportready -command -header-command -error-command}

    # Remote hostname to connect to
    option -host -default ""
    # Remote port (default 5222 for c2s XMPP)
    option -port -default 5222

    # SASL PLAIN credentials
    option -username -default ""
    option -password -default ""
    # Requested resource for binding; server may assign one if empty
    option -resource -default ""

    # Called after auth + bind + SM are complete; receives boolean (0=fresh, 1=resumed)
    option -onready -default ""
    # Called right after resource binding succeeds, before SM negotiation
    option -onbound -default ""
    # Called on SASL/bind failure; receives message string
    option -onautherror -default ""
    # Called when conn gives up (autoreconnect off + transport error); receives message
    option -ondisconnect -default ""
    # Called with each received stanza dict
    option -onstanza -default ""

    # Whether to auto-reconnect on transport errors (not auth errors)
    option -autoreconnect -default 0

    # Event callback: {*}$cmd conn <Event> ...
    option -emit -default ""

    # The full JID assigned by the server after binding (read-only)
    option -bound-jid -default ""

    # Auth/session negotiation phase:
    #   disconnected | authenticating | binding | sm-negotiating | ready
    variable authState disconnected

    # Unified public connection state:
    #   disconnected | connecting | authenticating | binding | connected | waiting
    variable connState disconnected

    # Stanzas queued before the session is ready; flushed on connect
    variable writeBuffer [list]

    # Reconnect backoff state
    # After-id for the pending reconnect timer, "" if none
    variable reconnectAfterId ""
    # How many consecutive reconnect attempts so far (resets on success)
    variable reconnectAttempt 0
    # Backoff schedule in ms; last value repeats indefinitely
    variable reconnectIntervals {1000 2000 5000 15000 30000 60000}

    constructor {args} {
        install base using baseconn $self.base \
            -ontransportready [mymethod OnTransportReady] \
            -command [mymethod OnStanza] \
            -error-command [mymethod OnTransportError]
        install sm using sm $self.sm -write [list $self.base writeStanza]
        $self configurelist $args
    }

    destructor {
        $self CancelReconnect
        catch {$sm destroy}
        catch {$base destroy}
    }

    # Start a new connection: cancel any pending reconnect, reset state,
    # and kick off the async TCP connect via baseconn.
    method connect {} {
        $self CancelReconnect
        if {$authState ne "disconnected"} {
            $sm onDisconnect
            $base close
        }
        set authState disconnected
        $self SetConnState connecting
        $base connect $options(-host) $options(-port)
    }

    # Gracefully shut down: send </stream:stream>, close socket, notify SM.
    # No-op if already disconnected.
    method close {} {
        if {$connState eq "disconnected"} return
        $self CancelReconnect
        set authState disconnected
        $sm onDisconnect
        catch {$base writeNow "</stream:stream>"}
        $base close
        $self SetConnState disconnected
    }

    method state {args} {
        return $connState
    }

    method SetConnState {s} {
        set connState $s
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <State> -state $s
        }
    }

    # Queue a reconnect attempt after a backoff delay. No-op if close()
    # was called (connState == disconnected). Caps at the last interval.
    method ScheduleReconnect {} {
        if {$connState eq "disconnected"} return   ;# close() was called
        $self CancelReconnect                       ;# cancel any existing timer
        set maxIdx [expr {[llength $reconnectIntervals] - 1}]
        set idx [expr {min($reconnectAttempt, $maxIdx)}]
        set delay [lindex $reconnectIntervals $idx]
        incr reconnectAttempt
        $self SetConnState waiting
        set reconnectAfterId [after $delay [mymethod DoReconnect]]
    }

    # Fire when the backoff timer expires. Attempts connect; reschedules
    # on failure.
    method DoReconnect {} {
        if {$reconnectAfterId eq ""} return   ;# timer was cancelled
        set reconnectAfterId ""
        if {[catch {$self connect} err]} {
            $self ScheduleReconnect
        }
    }

    # Cancel any pending reconnect timer.
    method CancelReconnect {} {
        if {$reconnectAfterId ne ""} {
            after cancel $reconnectAfterId
            set reconnectAfterId ""
        }
    }

    # True when auth, bind, and SM negotiation are all complete.
    method isReady {} {
        return [expr {$authState eq "ready"}]
    }

    method writeStanza {stanza} { $self write $stanza }

    # Write a stanza directly to the transport, bypassing SM tracking
    # and the write buffer. Use for stanzas that must go out before
    # the session is fully ready (e.g. initial presence after bind).
    method writeImmediate {stanza} {
        jlog debug "stanza out" -stanza $stanza
        $base writeStanza $stanza
    }

    # Send a stanza through the SM component for ack tracking/queuing.
    # If the session isn't ready yet, queues the stanza for later.
    method write {stanza} {
        if {$authState ne "ready"} {
            lappend writeBuffer $stanza
            return
        }
        jlog debug "stanza out" -stanza $stanza
        $sm outStanza $stanza
    }

    # Send all buffered stanzas through the normal write path.
    method FlushWriteBuffer {} {
        set buf $writeBuffer
        set writeBuffer [list]
        foreach stanza $buf {
            $self write $stanza
        }
    }

    # Called by baseconn when TCP+TLS is up. Opens the XMPP stream and
    # begins SASL authentication.
    method OnTransportReady {} {
        set authState authenticating
        $self SetConnState authenticating
        $base writeNow [::jab::header "" to $options(-host)]
    }

    # Central stanza dispatcher: routes to the handler for the current
    # authState phase, or to SM + callback once the session is ready.
    method OnStanza {stanza} {
        jlog debug "stanza in" -stanza $stanza

        switch -- $authState {
            authenticating {
                $self HandleAuthStanza $stanza
            }
            binding {
                $self HandleBindStanza $stanza
            }
            sm-negotiating {
                $self HandleSmStanza $stanza
            }
            ready {
                $sm inStanza $stanza
                if {$options(-onstanza) ne ""} {
                    {*}$options(-onstanza) $stanza
                }
            }
        }
    }

    # Process stanzas during SASL negotiation: send PLAIN auth on
    # <features>, restart stream on <success>, error on <failure>.
    method HandleAuthStanza {stanza} {
        set tag [dict get $stanza tag]

        switch -- $tag {
            features {
                set saslPlain [base64::encode "\0$options(-username)\0$options(-password)"]
                set authStanza [j auth \
                    -ns urn:ietf:params:xml:ns:xmpp-sasl \
                    -mechanism PLAIN \
                    #body $saslPlain]
                jlog debug "stanza out" -stanza $authStanza
                $base writeStanza $authStanza
            }
            success {
                # Restart stream - need fresh XML parser
                $base CreateReader
                set authState binding
                $self SetConnState binding
                $base writeNow [::jab::header "" to $options(-host)]
            }
            failure {
                $self OnAuthError "SASL authentication failed"
            }
        }
    }

    # Process stanzas during resource binding: on <features>, send bind
    # request (and let SM inspect features). On bind result, store the
    # bound JID and hand off to SM negotiation.
    method HandleBindStanza {stanza} {
        set tag [dict get $stanza tag]

        switch -- $tag {
            features {
                # Let sm check for SM support
                $sm onFeatures $stanza

                # Send bind request
                set bindStanza [j iq -id bind -type set {
                    j bind -ns urn:ietf:params:xml:ns:xmpp-bind {
                        if {$options(-resource) ne ""} {
                            j resource #body $options(-resource)
                        }
                    }
                }]
                jlog debug "stanza out" -stanza $bindStanza
                $base writeStanza $bindStanza
            }
            iq {
                set type [dict get $stanza attrs type]
                if {$type eq "result"} {
                    set boundJid [xsearch $stanza bind jid -get body]
                    set options(-bound-jid) $boundJid

                    # Fire onbound before SM so the stanza is sent during the SM roundtrip
                    if {$options(-onbound) ne ""} {
                        {*}$options(-onbound)
                    }

                    # Tell sm to enable (it handles the negotiation)
                    set authState sm-negotiating
                    $sm onConnect

                    # Check if sm went straight to running (no SM support)
                    $self CheckSmReady
                } elseif {$type eq "error"} {
                    $self OnAuthError "Resource binding failed"
                }
            }
        }
    }

    # Feed stanzas to SM during enable/resume negotiation. Non-SM
    # stanzas are also forwarded via -onstanza (server may send stanzas
    # before SM finishes). Checks if SM has reached "running" after each.
    method HandleSmStanza {stanza} {
        $sm inStanza $stanza
        if {[dict get $stanza ns] ne "urn:xmpp:sm:3"} {
            if {$options(-onstanza) ne ""} {
                {*}$options(-onstanza) $stanza
            }
        }
        $self CheckSmReady
    }

    # Poll SM state; if it reached "running", transition to ready and
    # fire -onready with a boolean (0=fresh, 1=resumed).
    method CheckSmReady {} {
        set info [$sm getInfo]
        if {[dict get $info state] eq "running"} {
            set authState ready
            set reconnectAttempt 0
            $self FlushWriteBuffer
            $self SetConnState connected

            set resumed [dict get $info resumed]
            if {$options(-emit) ne ""} {
                {*}$options(-emit) conn <Ready> -resumed $resumed
            }
            if {$options(-onready) ne ""} {
                {*}$options(-onready) $resumed
            }
        }
    }

    # Called on socket read/write errors or EOF. Tears down the session
    # and either schedules a silent reconnect or fires -ondisconnect.
    method OnTransportError {msg} {
        set authState disconnected
        $sm onDisconnect
        $base close
        if {$options(-autoreconnect)} {
            $self ScheduleReconnect
        } else {
            $self SetConnState disconnected
            if {$options(-emit) ne ""} {
                {*}$options(-emit) conn <Disconnected> -message $msg
            }
            if {$options(-ondisconnect) ne ""} {
                {*}$options(-ondisconnect) $msg
            }
        }
    }

    # Called on SASL failure or bind error. No reconnect — auth errors
    # are not transient.
    method OnAuthError {message} {
        set authState disconnected
        $sm onDisconnect
        $base close
        $self SetConnState disconnected
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <AuthError> -message $message
        }
        if {$options(-onautherror) ne ""} {
            {*}$options(-onautherror) $message
        }
    }

    # Expose the SM component for external inspection (e.g. ack counts).
    method sm {} {
        return $sm
    }
}
