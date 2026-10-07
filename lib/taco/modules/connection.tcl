# connection.tcl - XMPP connection types.
#
#   bareconn   Ready as soon as the transport connects. No auth, no SM.
#              Use for server-to-server links or pre-auth scenarios.
#
#   conn       Full XMPP client: SASL (SCRAM-SHA-1/256 with optional
#              tls-exporter binding, or PLAIN), resource binding, XEP-0198
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
#   -starttls bool         Whether to negotiate STARTTLS (default true;
#                          ignored on the websocket transport, where the
#                          browser has already done TLS)
#   -transport t           tcp (default) or websocket: XMPP over a WebSocket,
#                          RFC 7395, over ::websocket (tcllib's API); for
#                          now only in a wasm build (modules/browserws.tcl).
#   -ws-url url            Where the websocket transport connects; empty means
#                          the conventional wss://$host/xmpp-websocket
#   -header-command cmd    Called with the opening <stream:stream> element
#   -footer-command cmd    Called with the closing </stream:stream>
#
# conn-only methods:
#   sm                     Access the stream management component
#
# conn-only options:
#   -host, -port           Server to connect to (default port 5222)
#   -username, -password   SASL credentials
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
    # The ::websocket socket on the websocket transport, "" otherwise
    variable ws
    # That transport's XML reader. The socket transport lets ::jab::readChannel
    # own one per channel; a websocket has no channel, so the reader is fed by
    # hand and kept here.
    variable reader
    # Names the readers apart. A replaced one outlives its replacement's
    # creation by an idle cycle (see DestroyReader), so the name cannot be
    # reused.
    variable readerSeq
    # The host-meta lookup in flight (see Discover): taco_http token and body file.
    variable lookup
    variable lookupFile

    # Host -> endpoint its host-meta named ("" for none), shared by every
    # connection. Failed lookups are not kept, so they are retried.
    typevariable Discovered {}
    # How long a host gets before the convention is tried.
    typevariable DISCOVERY_TIMEOUT 5000

    # Callback when the transport (TCP + optional TLS) is ready for use
    option -ontransportready -default ""
    # Whether to negotiate STARTTLS before declaring transport ready
    option -starttls -default true
    # tcp | websocket. The websocket transport is RFC 7395 over ::websocket (see
    # wsframing.tcl); for now it exists only in a wasm build, where there is no
    # socket to be had and the browser has already done TLS - so -starttls
    # plays no part in it.
    option -transport -default tcp
    # Where that transport connects. Empty asks the host (Discover), then
    # takes ::wsframing::url.
    option -ws-url -default ""
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
        set ws ""
        set reader ""
        set readerSeq 0
        set lookup ""
        set lookupFile ""
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
        if {$ws ne ""} {
            # One call, one message: baseconn writes a whole stanza at a time,
            # and RFC 7395 carries exactly one element per frame.
            if {[catch {::websocket::send $ws text [::wsframing::out $data]} n]
                    || $n < 0} {
                if {$n < 0} { set n "websocket not open" }
                $self close
                {*}$options(-error-command) "Write error: $n"
            }
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
        if {$options(-transport) eq "websocket"} {
            $self ConnectWebsocket
            return
        }
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

    method OnStarttlsComplete {status {detail ""}} {
        if {$status eq "ok"} {
            set socket $detail
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
                set msg "TLS handshake failed"
                if {$detail ne ""} { set msg "TLS: $detail" }
                {*}$options(-error-command) $msg
            }
        }
    }

    # XMPP over a WebSocket (RFC 7395). There is no connect/TLS/STARTTLS
    # sequence here: the browser does all three before the socket opens, and
    # what arrives is an open socket or an error.
    method ConnectWebsocket {} {
        if {![llength [info commands ::websocket::open]]} {
            set state disconnected
            after idle [list {*}$options(-error-command) \
                "no websocket transport in this build"]
            return
        }
        set url $options(-ws-url)
        if {$url eq ""} {
            if {![dict exists $Discovered $host]} {
                $self Discover
                return
            }
            set url [dict get $Discovered $host]
            if {$url eq ""} {
                set url [::wsframing::url $host]
            }
        }
        $self OpenWebsocket $url
    }

    # XEP-0156: ask the host where its websocket is. Any failure (no
    # host-meta, timeout, CORS) falls back to the convention.
    method Discover {} {
        set url [::wsframing::hostMetaUrl $host]
        if {[catch {
            close [file tempfile lookupFile tacky-host-meta]
            set lookup [taco_http get $url -outfile $lookupFile \
                -timeout $DISCOVERY_TIMEOUT -command [mymethod OnDiscovered]]
        } err]} {
            jlog warn "host-meta for $host: $err"
            $self DropLookup
            $self OpenWebsocket [::wsframing::url $host]
        }
    }

    method OnDiscovered {token} {
        # Superseded by a close or a new connect.
        if {$token ne $lookup} {
            catch {taco_http cleanup $token}
            return
        }
        set status [taco_http status $token]
        set code [taco_http ncode $token]
        set doc ""
        if {$status eq "ok" && $code == 200} {
            catch {
                set f [open $lookupFile r]
                fconfigure $f -encoding utf-8
                set doc [read $f]
                close $f
            }
        }
        $self DropLookup
        # A 4xx is an answer too: nothing published.
        if {$status eq "ok" && $code >= 200 && $code < 500} {
            dict set Discovered $host [::wsframing::fromHostMeta $doc]
        }
        set url ""
        if {[dict exists $Discovered $host]} {
            set url [dict get $Discovered $host]
        }
        if {$url eq ""} {
            jlog inform "host-meta for $host: $status $code, none named;\
                trying the conventional endpoint"
            set url [::wsframing::url $host]
        } else {
            jlog inform "host-meta for $host names $url"
        }
        $self OpenWebsocket $url
    }

    method DropLookup {} {
        if {$lookup ne ""} {
            # Cleared first: a reset may run -command synchronously.
            set token $lookup
            set lookup ""
            catch {taco_http reset $token}
            catch {taco_http cleanup $token}
        }
        if {$lookupFile ne ""} {
            catch {file delete $lookupFile}
            set lookupFile ""
        }
    }

    method OpenWebsocket {url} {
        if {[catch {::websocket::open $url [mymethod OnWsEvent] \
                -protocol [list $::wsframing::SUBPROTOCOL]} result]} {
            set state disconnected
            after idle [list {*}$options(-error-command) "Connect failed: $result"]
            return
        }
        set ws $result
    }

    # One event from ::websocket (tcllib's handler shape). A message is fed to
    # the reader as the stream bytes it stands for, so everything above this
    # point - conn's stream restart after SASL, sm, the stanza dispatcher -
    # sees what it would see over TCP. Events for a socket we no longer hold
    # are ignored.
    method OnWsEvent {sock kind msg} {
        if {$sock ne $ws} return
        switch -- $kind {
            connect {
                # RFC 7395 3.1: the server must select the xmpp subprotocol.
                if {$msg ne $::wsframing::SUBPROTOCOL} {
                    $self close
                    {*}$options(-error-command) \
                        "server did not agree to the xmpp subprotocol"
                    return
                }
                $self CreateReader
                set state connected
                if {$options(-ontransportready) ne ""} {
                    {*}$options(-ontransportready)
                }
            }
            text {
                if {[catch {$reader feed [::wsframing::in $msg]} err]} {
                    $self close
                    {*}$options(-error-command) "Read error: $err"
                }
            }
            close {
                lassign $msg code reason
                $self close
                set text "websocket closed ($code)"
                if {$reason ne ""} {
                    append text ": $reason"
                }
                {*}$options(-error-command) $text
            }
            disconnect - error - timeout {
                $self close
                {*}$options(-error-command) $msg
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
        if {$ws ne ""} {
            # A fresh parser, which is also what a stream restart after SASL
            # asks for; the caller does exactly that.
            $self DestroyReader
            set reader [xmppreader $self.reader[incr readerSeq] \
                -command [mymethod OnStanzaIn] \
                -header-command $options(-header-command) \
                -footer-command $options(-footer-command) \
                -error-command $options(-error-command)]
            return
        }
        ::jab::cancelRead $socket
        fconfigure $socket -encoding utf-8 -translation lf
        ::jab::readChannel $socket \
            -command [mymethod OnStanzaIn] \
            -header-command $options(-header-command) \
            -footer-command $options(-footer-command) \
            -error-command $options(-error-command)
    }

    # Destroying a reader is deferred for the same reason ::jab::cancelRead
    # defers it: the call usually comes from inside the reader's own parse -
    # conn restarts the stream from the <success/> handler, which expat is in
    # the middle of dispatching - and deleting the parser under itself takes
    # the interpreter down with it.
    method DestroyReader {} {
        if {$reader ne ""} {
            set old $reader
            set reader ""
            after idle [list catch [list $old destroy]]
        }
    }

    method close {} {
        if {$flushPending} {
            after cancel [mymethod FlushWrite]
            set flushPending 0
        }
        $self DestroyReader
        $self DropLookup
        if {$ws ne ""} {
            # 1000 "normal closure": whatever the stream did, the socket ends
            # cleanly. conn has already sent </stream:stream> - <close/> on
            # this transport - by the time it gets here.
            # Clear ws first, so OnWsEvent ignores the close events
            # ::websocket::close reports.
            set old $ws
            set ws ""
            catch {::websocket::close $old}
        }
        ::jab::cancelRead $socket
        if {$socket ne ""} {
            # Closing mid-STARTTLS strands whatever it had buffered.
            xmpp_starttls_abort $socket
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
        jlog warn "transport error: $msg"
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

# Full XMPP client connection. On top of baseconn, handles SASL
# auth, resource binding, and XEP-0198 stream management (via the sm
# component). Supports auto-reconnect with exponential backoff.
# Flow: connect → STARTTLS → SASL auth → bind → SM enable → ready.

# state (connState) is what external code observes (e.g. UI "connecting…" spinner):
#   disconnected | connecting | authenticating | binding | connected | waiting
# authState drives the stanza dispatcher to the right handler method.
# Both reset to "disconnected" on close() or fatal errors.
# conn emits events via the -emit callback on state transitions and
# connection lifecycle events (<State>, <Disconnected>, <AuthError>).
snit::type conn {
    component base
    component sm

    delegate method socket to base
    delegate option * to base except {-ontransportready -command -header-command -error-command}

    # Remote hostname to connect to
    option -host -default ""
    # Remote port (default 5222 for c2s XMPP)
    option -port -default 5222

    # SASL credentials
    option -username -default ""
    option -password -default ""
    # Requested resource for binding; server may assign one if empty
    option -resource -default ""

    # Called after auth + bind + SM are complete; receives boolean (0=fresh, 1=resumed)
    option -onready -default ""
    # Called on SASL/bind failure; receives message string
    option -onautherror -default ""
    # Called when the server rejects the bind with <conflict/>; the handler
    # is expected to pick a new resource and reconnect
    option -onresourceconflict -default ""
    # Called when conn gives up (autoreconnect off + transport error); receives message
    option -ondisconnect -default ""
    # Called with each received stanza dict
    option -onstanza -default ""

    # Whether to auto-reconnect on transport errors (not auth errors)
    option -autoreconnect -default 0

    # Give up an in-progress connect (TCP+TLS+SASL+bind) after this many ms
    # if it neither succeeds nor errors on its own (e.g. a firewall silently
    # dropping packets leaves the socket in a permanent half-open state with
    # no error to react to). 0 disables the watchdog.
    option -connect-timeout -default 20000

    # Liveness. A connection that is up but carries nothing for -keepalive
    # ms is asked for a sign of life (<r/> with stream management, a
    # XEP-0199 ping without); if nothing at all arrives within
    # -keepalive-timeout ms after that, it is taken as dead and dropped,
    # which -autoreconnect turns into a reconnect (and a resume). Without
    # it a half-open TCP connection is never noticed by a client that
    # mostly listens. 0 disables.
    option -keepalive -default 60000
    option -keepalive-timeout -default 30000

    # How long an explicit `probe` waits for any answer before dropping.
    option -probe-timeout -default 10000

    # Wall-clock tick that notices a suspend: a tick arriving far later
    # than scheduled means the machine slept, and the link is probed. 0
    # disables.
    option -wake-check -default 5000

    # A session must stay up this long (ms) before the reconnect backoff
    # starts over. A server that accepts the login and then drops us at once
    # would otherwise be reconnected to every second, indefinitely.
    option -stable-after -default 30000

    # Command prefix; a false result turns `probe` (and so the wake
    # check) into a no-op. "" always allows.
    option -probe-allowed-command -default ""

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

    # Last failure message, "" once connected; pulled by `tacky observe`.
    variable lastError ""

    # The SASL exchange in progress, {} outside one: mech, and for SCRAM also
    # digest, gs2header, cbdata, bare, serverSignature and step (first,
    # final, verified).
    variable sasl {}

    # Stanzas queued before the session is ready; flushed on connect
    variable writeBuffer [list]

    # After-id for the in-progress-connect watchdog (see -connect-timeout),
    # "" if none is pending.
    variable connectTimeoutAfterId ""

    # Reconnect backoff state
    # After-id for the pending reconnect timer, "" if none
    variable reconnectAfterId ""
    # How many consecutive reconnect attempts so far. Reset once a session
    # has stayed up for -stable-after ms, not as soon as it is ready.
    variable reconnectAttempt 0
    # After-id for that reset, "" if none is pending.
    variable stableAfterId ""
    # Backoff schedule in ms; last value repeats indefinitely
    variable reconnectIntervals {1000 2000 5000 15000 30000 60000}

    # Keepalive: the timer, when anything last arrived, and when the
    # outstanding probe went out (0 when none is).
    variable keepaliveAfterId ""
    variable lastRx 0
    variable probeAt 0
    variable probeSeq 0

    # Wake check: the timer and when it was last armed.
    variable wakeAfterId ""
    variable wakeLast 0

    constructor {args} {
        install base using baseconn $self.base \
            -ontransportready [mymethod OnTransportReady] \
            -command [mymethod OnStanza] \
            -error-command [mymethod OnTransportError]
        install sm using sm $self.sm -write [list $self.base writeStanza] \
            -ack-command [mymethod OnSmAck]
        $self configurelist $args
    }

    destructor {
        $self CancelReconnect
        $self CancelConnectTimeout
        $self StopKeepalive
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
        set sasl {}
        $self SetConnState connecting
        jlog inform "connecting to $options(-host):$options(-port)"
        $base connect $options(-host) $options(-port)
        $self ArmConnectTimeout
    }

    # Gracefully shut down: send </stream:stream> and close the socket. This
    # ends the session, so SM state and the write buffer are dropped: the
    # next connect may be days later, and stale presence or IQs shouldn't go
    # out then. Pending messages stay in the store and are resent from
    # there. No-op if already disconnected.
    method close {} {
        if {$connState eq "disconnected"} return
        $self CancelReconnect
        $self CancelConnectTimeout
        $self StopKeepalive
        set authState disconnected
        set writeBuffer [list]
        $sm reset
        catch {$base writeNow "</stream:stream>"}
        $base close
        $self SetConnState disconnected
    }

    method StartKeepalive {} {
        $self StopKeepalive
        set lastRx [clock milliseconds]
        set probeAt 0
        $self ArmWakeCheck
        if {$options(-keepalive) <= 0} return
        $self ArmKeepalive $options(-keepalive)
    }

    method StopKeepalive {} {
        if {$keepaliveAfterId ne ""} {
            after cancel $keepaliveAfterId
            set keepaliveAfterId ""
        }
        if {$wakeAfterId ne ""} {
            after cancel $wakeAfterId
            set wakeAfterId ""
        }
        if {$stableAfterId ne ""} {
            after cancel $stableAfterId
            set stableAfterId ""
        }
        set probeAt 0
    }

    method OnStable {} {
        set stableAfterId ""
        set reconnectAttempt 0
    }

    # Check now that the link is alive: a no-op unless it is ready, idle
    # for -probe-timeout and not already being probed. Silence for
    # -probe-timeout after the probe drops it.
    method probe {args} {
        if {$authState ne "ready" || $probeAt > 0} return
        if {[clock milliseconds] - $lastRx < $options(-probe-timeout)} return
        if {![$self ProbeAllowed]} return
        if {$keepaliveAfterId ne ""} {
            after cancel $keepaliveAfterId
        }
        $self SendProbe
        $self ArmKeepalive $options(-probe-timeout)
    }

    method ArmWakeCheck {} {
        if {$options(-wake-check) <= 0} return
        if {$wakeAfterId ne ""} { after cancel $wakeAfterId }
        set wakeLast [clock milliseconds]
        set wakeAfterId [after $options(-wake-check) [mymethod WakeTick]]
    }

    # Runs while ready and while a reconnect waits out its backoff. After a
    # wake the network is likely back, so reconnect now instead of waiting
    # out the rest of the backoff (up to a minute).
    method WakeTick {} {
        set wakeAfterId ""
        if {$authState ne "ready" && $connState ne "waiting"} return
        set elapsed [expr {[clock milliseconds] - $wakeLast}]
        if {$elapsed > 3 * $options(-wake-check)} {
            if {$connState eq "waiting"} {
                if {[$self ProbeAllowed]} {
                    jlog inform "clock jumped ${elapsed}ms, reconnecting now"
                    set reconnectAttempt 0
                    $self CancelReconnect
                    set reconnectAfterId [after 0 [mymethod DoReconnect]]
                    return
                }
            } else {
                jlog inform "clock jumped ${elapsed}ms, probing"
                $self probe
            }
        }
        $self ArmWakeCheck
    }

    method ProbeAllowed {} {
        expr {$options(-probe-allowed-command) eq ""
            || ![string is false -strict [{*}$options(-probe-allowed-command)]]}
    }

    method ArmKeepalive {ms} {
        set keepaliveAfterId [after [expr {max($ms, 1)}] [mymethod KeepaliveTick]]
    }

    method KeepaliveTick {} {
        set keepaliveAfterId ""
        if {$authState ne "ready"} return
        set now [clock milliseconds]
        if {$probeAt > 0} {
            if {$lastRx < $probeAt} {
                # The timer fired much later than scheduled, so the process
                # was suspended and the answer may be unread in the socket.
                # Probe again instead of dropping the stream.
                set wait [expr {max($options(-keepalive-timeout), $options(-probe-timeout))}]
                if {$now - $probeAt < 2 * $wait} {
                    $self OnTransportError "no answer from the server"
                    return
                }
                $self SendProbe
                $self ArmKeepalive $options(-probe-timeout)
                return
            }
            set probeAt 0
        }
        # An explicit probe arms this timer even with keepalive off.
        if {$options(-keepalive) <= 0} return
        set idle [expr {$now - $lastRx}]
        if {$idle < $options(-keepalive)} {
            $self ArmKeepalive [expr {$options(-keepalive) - $idle}]
            return
        }
        $self SendProbe
        $self ArmKeepalive $options(-keepalive-timeout)
    }

    # Anything that comes back will do: an <a/>, the ping's result, or
    # any other stanza.
    method SendProbe {} {
        if {[dict get [$sm getInfo] mode] eq "active"} {
            catch {$sm RequestAck}
        } else {
            catch {$base writeStanza [j iq -type get -id keepalive[incr probeSeq] {
                j ping -ns urn:xmpp:ping
            }]}
        }
        set probeAt [clock milliseconds]
    }

    # Give up the in-progress connect attempt if it neither succeeds nor
    # errors on its own within -connect-timeout (see the option's doc).
    method ArmConnectTimeout {} {
        $self CancelConnectTimeout
        if {$options(-connect-timeout) <= 0} return
        set connectTimeoutAfterId \
            [after $options(-connect-timeout) [mymethod OnConnectTimeout]]
    }

    method CancelConnectTimeout {} {
        if {$connectTimeoutAfterId ne ""} {
            after cancel $connectTimeoutAfterId
            set connectTimeoutAfterId ""
        }
    }

    method OnConnectTimeout {} {
        set connectTimeoutAfterId ""
        $self OnTransportError \
            "connect timed out after $options(-connect-timeout)ms"
    }

    method state {args} {
        return $connState
    }

    # Re-emit current state for `tacky observe` (initial-state sync on attach).
    method pull {args} {
        if {$options(-emit) eq ""} return
        array set opts $args
        switch -- $opts(-event) {
            <State> {
                {*}$options(-emit) conn <State> -state $connState
            }
            <ConnError> {
                if {$lastError ne ""} {
                    {*}$options(-emit) conn <ConnError> -message $lastError
                }
            }
            default {
                return -code error \
                    "conn pull: event $opts(-event) is not pullable"
            }
        }
    }

    method SetConnState {s} {
        set connState $s
        if {$s eq "connected"} {
            set lastError ""
            $self CancelConnectTimeout
        }
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
        $self ArmWakeCheck
        jlog inform "reconnect attempt $reconnectAttempt in ${delay}ms"
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
        if {[catch {$sm outStanza $stanza} err]} {
            jlog warn "SM write failed: $err"
            $self OnTransportError $err
            error $err
        }
    }

    # Send all buffered stanzas through the normal write path.
    # If a write triggers SM queue overflow (which fires OnTransportError +
    # reconnect), we stop flushing and re-buffer the remaining stanzas so
    # they survive into the next session.
    method FlushWriteBuffer {} {
        set buf $writeBuffer
        set writeBuffer [list]
        set i 0
        foreach stanza $buf {
            if {[catch {$self write $stanza}]} {
                set writeBuffer [lrange $buf [expr {$i + 1}] end]
                return
            }
            incr i
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
        set lastRx [clock milliseconds]

        if {[dict get $stanza tag] eq "error"
                && [dict get $stanza ns] eq "http://etherx.jabber.org/streams"} {
            $self OnStreamError $stanza
            return
        }

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

    # Process stanzas during SASL negotiation: pick a mechanism and send
    # <auth> on <features>, answer SCRAM <challenge>s, restart the stream
    # on <success> (after checking the SCRAM server signature), error on
    # <failure>.
    method HandleAuthStanza {stanza} {
        set tag [dict get $stanza tag]

        switch -- $tag {
            features {
                $self StartSasl [xsearch $stanza mechanisms mechanism -gather body]
            }
            challenge {
                set step [dict getdef $sasl step ""]
                if {$step eq "first"} {
                    $self ScramFinal [dict get $stanza body]
                } elseif {$step eq "final"} {
                    # Server-final as a challenge rather than in <success>:
                    # check it and acknowledge with an empty response.
                    if {[$self ScramVerify [dict get $stanza body]]} {
                        $base writeStanza [j response \
                            -ns urn:ietf:params:xml:ns:xmpp-sasl]
                    }
                } else {
                    $self OnAuthError "SASL: unexpected challenge"
                }
            }
            success {
                set step [dict getdef $sasl step ""]
                if {$step eq "final"} {
                    if {![$self ScramVerify [dict get $stanza body]]} return
                } elseif {$step ne "" && $step ne "verified"} {
                    $self OnAuthError "SASL: success before the exchange completed"
                    return
                }
                set sasl {}
                # Restart stream - need fresh XML parser
                $base CreateReader
                set authState binding
                $self SetConnState binding
                $base writeNow [::jab::header "" to $options(-host)]
            }
            failure {
                set msg "SASL authentication failed"
                set cond [lindex [xsearch $stanza * -gather tag] 0]
                if {$cond ne "" && $cond ne "text"} {
                    append msg ": $cond"
                }
                $self OnAuthError $msg
            }
        }
    }

    # Pick the strongest offered mechanism we can do and send <auth>.
    method StartSasl {offered} {
        set canScram [scram::available]
        set cbdata [$self ChannelBinding]
        set mech ""
        foreach m {SCRAM-SHA-256-PLUS SCRAM-SHA-1-PLUS SCRAM-SHA-256 SCRAM-SHA-1 PLAIN} {
            if {$m ni $offered} continue
            if {[string match SCRAM-* $m] && !$canScram} continue
            if {[string match *-PLUS $m] && $cbdata eq ""} continue
            set mech $m
            break
        }
        if {$mech eq ""} {
            $self OnAuthError \
                "No supported SASL mechanism (offered: [join $offered {, }])"
            return
        }
        set sasl [dict create mech $mech]
        if {$mech eq "PLAIN"} {
            set body [binary encode base64 [encoding convertto utf-8 \
                "\0$options(-username)\0$options(-password)"]]
        } else {
            if {[string match *-PLUS $mech]} {
                set flag p=tls-exporter
            } elseif {$cbdata ne ""} {
                # We could bind but no -PLUS was offered: flag y, so a server
                # that does support binding detects the downgrade.
                set flag y
                set cbdata ""
            } else {
                set flag n
            }
            lassign [scram::client_first $options(-username) [scram::nonce] \
                $flag] gs2header bare
            dict set sasl digest [scram::digest $mech]
            dict set sasl gs2header $gs2header
            dict set sasl cbdata $cbdata
            dict set sasl bare $bare
            dict set sasl step first
            set body [binary encode base64 \
                [encoding convertto utf-8 $gs2header$bare]]
        }
        # Never the stanza: its body carries the credentials.
        jlog debug "stanza out: auth mechanism=$mech"
        $base writeStanza [j auth \
            -ns urn:ietf:params:xml:ns:xmpp-sasl \
            -mechanism $mech \
            -body $body]
    }

    # Answer the server-first message with the client proof.
    method ScramFinal {body} {
        if {[catch {
            lassign [scram::client_final [dict get $sasl digest] \
                $options(-password) [dict get $sasl gs2header] \
                [dict get $sasl cbdata] [dict get $sasl bare] \
                [$self SaslDecode $body]] final serverSignature
        } err]} {
            $self OnAuthError "SASL: $err"
            return
        }
        dict set sasl step final
        dict set sasl serverSignature $serverSignature
        $base writeStanza [j response \
            -ns urn:ietf:params:xml:ns:xmpp-sasl \
            -body [binary encode base64 [encoding convertto utf-8 $final]]]
    }

    # Check the server-final message; the server proves it knows the
    # password too. Returns 0 (after OnAuthError) if it does not.
    method ScramVerify {body} {
        if {[catch {
            scram::check_server_final [dict get $sasl serverSignature] \
                [$self SaslDecode $body]
        } err]} {
            $self OnAuthError "SASL: $err"
            return 0
        }
        dict set sasl step verified
        return 1
    }

    method SaslDecode {body} {
        encoding convertfrom utf-8 [binary decode base64 $body]
    }

    # tls-exporter channel binding data (RFC 9266), or "" without our own
    # TLS (websocket, -starttls off) or below TLS 1.3: on 1.2 tls-exporter
    # needs the extended master secret, which mtls does not report.
    method ChannelBinding {} {
        set sock [$base socket]
        if {$sock eq ""
                || [catch {::mtls::status $sock} status]
                || ![dict exists $status version]
                || [dict get $status version] ne "TLSv1.3"
                || [catch {::mtls::exporter $sock EXPORTER-Channel-Binding 32} cb]} {
            return ""
        }
        return $cb
    }

    # Process stanzas during resource binding: on <features>, resume the
    # previous stream if there is one (XEP-0198 §5: a resume takes the place
    # of binding), else send the bind request. On bind result, store the
    # bound JID once its bare part checks out and hand off to SM negotiation.
    method HandleBindStanza {stanza} {
        set tag [dict get $stanza tag]

        switch -- $tag {
            features {
                # Let sm check for SM support
                $sm onFeatures $stanza
                if {[$sm resumable]} {
                    set authState sm-negotiating
                    $sm onConnect
                    return
                }
                $self SendBind
            }
            iq {
                set type [dict get $stanza attrs type]
                if {$type eq "result"} {
                    set boundJid [xsearch $stanza bind jid -get body]
                    set want $options(-username)@$options(-host)
                    if {$boundJid eq "" || ![jid matches-bare $boundJid $want]} {
                        $self OnAuthError "Server bound an unexpected JID"
                        return
                    }
                    set options(-bound-jid) $boundJid

                    # Tell sm to enable (it handles the negotiation)
                    set authState sm-negotiating
                    $sm onConnect

                    # Check if sm went straight to running (no SM support)
                    $self CheckSmReady
                } elseif {$type eq "error"} {
                    set cond ""
                    set errChild [xsearch $stanza error 0 -get node]
                    if {$errChild ne ""} {
                        set cond [dict get $errChild tag]
                    }
                    if {$cond eq "conflict" && $options(-onresourceconflict) ne ""} {
                        set authState disconnected
                        $sm onDisconnect
                        $base close
                        {*}$options(-onresourceconflict)
                    } else {
                        $self OnAuthError "Resource binding failed"
                    }
                }
            }
        }
    }

    method SendBind {} {
        set bindStanza [j iq -id bind -type set {
            j bind -ns urn:ietf:params:xml:ns:xmpp-bind {
                if {$options(-resource) ne ""} {
                    j resource -body $options(-resource)
                }
            }
        }]
        jlog debug "stanza out" -stanza $bindStanza
        $base writeStanza $bindStanza
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
        if {[dict get [$sm getInfo] state] eq "resume-failed"} {
            # Nothing is bound yet: bind now, and SM enables a fresh stream
            # once the bind result is in.
            set authState binding
            $self SendBind
            return
        }
        $self CheckSmReady
    }

    # Poll SM state; if it reached "running", transition to ready and
    # fire -onready with a boolean (0=fresh, 1=resumed).
    method CheckSmReady {} {
        set info [$sm getInfo]
        if {[dict get $info state] eq "running"} {
            set authState ready
            $self FlushWriteBuffer
            # FlushWriteBuffer may have triggered an SM overflow →
            # OnTransportError → authState back to disconnected.
            if {$authState ne "ready"} return
            $self SetConnState connected
            $self StartKeepalive
            set stableAfterId [after $options(-stable-after) [mymethod OnStable]]

            if {$options(-onready) ne ""} {
                {*}$options(-onready) [dict get $info resumed]
            }
        }
    }

    # Called on socket read/write errors or EOF. Tears down the session
    # and either schedules a silent reconnect or fires -ondisconnect.
    method OnTransportError {msg} {
        $self CancelConnectTimeout
        $self StopKeepalive
        set authState disconnected
        set lastError $msg
        # Every transport failure arrives here - connect, TLS, read, write - so
        # one line covers them all. Without it the reason only leaves as an
        # event, and a log from a client that never connected reads as silence.
        jlog warn "$options(-host):$options(-port): $msg"
        $sm onDisconnect
        $base close
        if {$options(-autoreconnect)} {
            # Report the reason even while retrying silently, so the UI can show it.
            if {$options(-emit) ne ""} {
                {*}$options(-emit) conn <ConnError> -message $msg
            }
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

    # RFC 6120 §4.9 stream errors. not-authorized is an auth error.
    # conflict (another client took our resource) and the addressing errors
    # stop reconnecting: retrying would kick the other client off or fail
    # again. system-shutdown and reset reconnect as usual; anything else
    # reconnects starting further along the backoff, since a session that
    # was up for a while has reset the attempt count.
    method OnStreamError {stanza} {
        set cond ""
        foreach tag [xsearch $stanza * -gather tag] {
            if {$tag ne "text"} { set cond $tag; break }
        }
        set text [xsearch $stanza text -get body]
        set msg "Stream error: [expr {$cond eq "" ? "undefined-condition" : $cond}]"
        if {$text ne ""} { append msg " ($text)" }
        switch -- $cond {
            not-authorized {
                $self OnAuthError $msg
            }
            conflict - host-unknown - host-gone - improper-addressing -
            invalid-from - unsupported-version {
                $self OnFatalError $msg
            }
            system-shutdown - reset {
                $self OnTransportError $msg
            }
            default {
                set reconnectAttempt [expr {max($reconnectAttempt, 3)}]
                $self OnTransportError $msg
            }
        }
    }

    # Like a transport error, but without the automatic reconnect.
    method OnFatalError {msg} {
        $self CancelReconnect
        $self CancelConnectTimeout
        $self StopKeepalive
        set authState disconnected
        set lastError $msg
        jlog error "$options(-host): $msg"
        $sm onDisconnect
        catch {$base writeNow "</stream:stream>"}
        $base close
        $self SetConnState disconnected
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <ConnError> -message $msg
            {*}$options(-emit) conn <Disconnected> -message $msg
        }
        if {$options(-ondisconnect) ne ""} {
            {*}$options(-ondisconnect) $msg
        }
    }

    # Called on SASL failure or bind error. No reconnect — auth errors
    # are not transient.
    method OnAuthError {message} {
        $self CancelConnectTimeout
        set emitCmd $options(-emit)
        set authErrCmd $options(-onautherror)
        set authState disconnected
        set lastError $message
        # Louder than a transport error: nothing retries this one. The three
        # callers pass a whole sentence, so it needs no prefix.
        jlog error $message
        $sm onDisconnect
        $base close
        $self SetConnState disconnected
        if {$emitCmd ne ""} {
            {*}$emitCmd conn <AuthError> -message $message
        }
        if {$authErrCmd ne ""} {
            {*}$authErrCmd $message
        }
    }

    method OnSmAck {ackedStanzas} {
        if {$options(-emit) ne ""} {
            {*}$options(-emit) sm <Ack> -stanzas $ackedStanzas
        }
    }

    # Expose the SM component for external inspection (e.g. ack counts).
    method sm {} {
        return $sm
    }
}
