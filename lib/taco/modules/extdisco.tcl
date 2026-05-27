# XEP-0215 External Service Discovery — fetches STUN/TURN servers from
# the user's XMPP server on demand. The calls module triggers a fetch
# right before it needs a peer connection (caller: on <proceed>, callee:
# on session-initiate) so whatever the server advertises feeds straight
# into ::rtc::pc::new -ice-servers. No fallback: if the server doesn't
# support extdisco, calls run with host candidates only (LAN-reachable
# peers will still connect; everything else needs the server admin to
# wire up a TURN service).
#
# Public API:
#   $client extdisco fetch -command $cmd
#     Sends one extdisco iq to our server. Asynchronously invokes
#       {*}$cmd $iceServerUrls
#     where $iceServerUrls is a list of libdatachannel URL strings,
#     e.g. {stun:stun.example.com:3478
#           turn:user%2Bid:hmac%2Bsig@turn.example.com:3478?transport=udp}
#     The list is empty when extdisco is unsupported by the server,
#     returns an error or no usable entries, or the request times out.

snit::type taco_extdisco {
    option -client -readonly yes

    typevariable NS         urn:xmpp:extdisco:2
    typevariable TIMEOUT_MS 8000

    variable client
    variable Pending        ;# id -> dict {cb timer}
    variable Counter 0

    constructor args {
        $self configurelist $args
        set client $options(-client)
        array set Pending {}
    }

    destructor {
        foreach id [array names Pending] {
            catch {after cancel [dict get $Pending($id) timer]}
        }
    }

    method fetch {args} {
        array set opts {-command ""}
        array set opts $args
        if {$opts(-command) eq ""} {
            error "extdisco fetch: -command required"
        }
        set id [incr Counter]
        set timer [after $TIMEOUT_MS [mymethod OnTimeout $id]]
        set Pending($id) [dict create cb $opts(-command) timer $timer]
        $client iq request -type get \
            -to [jid domain [$client cget -jid]] \
            -payload [j services -ns $NS] \
            -command [mymethod OnResult $id]
    }

    # iq response. The iq layer also routes timeouts at the stream level
    # (via cancelAll on reconnect), so this can fire late after our own
    # timer already resolved — the Pending guard absorbs that.
    method OnResult {id stanza} {
        if {![info exists Pending($id)]} return
        catch {after cancel [dict get $Pending($id) timer]}
        set type_ [xsearch $stanza -get @type]
        set servers [list]
        if {$type_ eq "result"} {
            xsearch $stanza services service -script svcNode {
                set url [$self BuildIceUrl $svcNode]
                if {$url ne ""} { lappend servers $url }
            }
            if {[llength $servers] == 0} {
                jlog info "extdisco: server advertised no STUN/TURN entries"
            }
        } else {
            jlog info "extdisco: server returned type=$type_; assuming unsupported"
        }
        $self Resolve $id $servers
    }

    method OnTimeout {id} {
        if {![info exists Pending($id)]} return
        jlog info "extdisco: no response after ${TIMEOUT_MS}ms"
        $self Resolve $id [list]
    }

    method Resolve {id servers} {
        set cb [dict get $Pending($id) cb]
        unset Pending($id)
        {*}$cb $servers
    }

    # Render one XEP-0215 <service> as a libdatachannel ICE URL.
    # Returns "" if type/host/port are missing or the type isn't an
    # ICE scheme we know how to feed into libdatachannel.
    method BuildIceUrl {svcNode} {
        set type_     [xsearch $svcNode -get @type]
        set host      [xsearch $svcNode -get @host]
        set port      [xsearch $svcNode -get @port]
        set transport [xsearch $svcNode -get @transport]
        set username  [xsearch $svcNode -get @username]
        set password  [xsearch $svcNode -get @password]
        if {$host eq "" || $port eq ""} { return "" }
        switch -- $type_ {
            stun - stuns - turn - turns {}
            default { return "" }
        }
        set userinfo ""
        if {$type_ in {turn turns} && $username ne ""} {
            set userinfo "[$self UrlEncode $username]:[$self UrlEncode $password]@"
        }
        set query ""
        if {$type_ in {turn turns} && $transport ne ""} {
            set query "?transport=[string tolower $transport]"
        }
        return "$type_:$userinfo$host:$port$query"
    }

    # Percent-encode per RFC 3986 unreserved set. TURN userinfo from
    # prosody's mod_turn_external is base64 (so / + =), which can't go
    # raw into the URL's userinfo segment without being interpreted.
    method UrlEncode {s} {
        set out ""
        foreach c [split $s ""] {
            if {[regexp {[A-Za-z0-9._~-]} $c]} {
                append out $c
            } else {
                append out [format "%%%02X" [scan $c %c]]
            }
        }
        return $out
    }
}
