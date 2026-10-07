# Stream Management (XEP-0198) with automatic negotiation
#
# Both modes keep written stanzas in one queue, count them in `out`, and ask
# for confirmation on the same schedule (-ack-frequency, -ack-delay). They
# differ only in how they ask and read the answer: active mode sends <r/>
# and reads h from <a/>; passthrough (no SM) sends a ping to the server, and
# its reply confirms everything written before it, since a server processes
# one stream's stanzas in order (RFC 6120 10.1). Either way the confirmed
# stanzas go to -ack-command.
#
# Usage:
#   install sm using sm ${self}::sm -write [mymethod DirectWrite]
#   $sm onFeatures $featuresStanza  ;# checks if server supports SM
#   $sm onConnect                    ;# enables SM if supported
#   $sm outStanza $stanza            ;# queue/send outgoing stanza
#   $sm inStanza $stanza             ;# process incoming stanza
#   $sm onDisconnect                 ;# handle disconnect

snit::type sm {
    # Mode: passthrough (no SM) or active (real SM)
    variable mode passthrough

    # Stanza counters. in is SM's only; out and serverh are kept in both
    # modes, serverh from <a h/> or from a ping's reply.
    variable in 0       ;# How many stanzas we've received (our @h)
    variable out 0      ;# How many stanzas we've sent
    variable serverh 0  ;# How many the server has confirmed

    # Passthrough: pings sent to confirm, id -> the out they cover.
    variable barriers {}
    variable barrierSeq 0

    # Outgoing stanza queue
    variable queue {}

    # State: disconnected | connecting | running
    variable state disconnected

    # Stream resumption ID from <enabled id='...'/>
    variable streamId ""

    # Whether the last connection was a resumption (1) or fresh (0)
    variable resumed 0

    # Configuration
    option -write
    option -ack-command -default ""

    # Ack request strategy: every N stanzas, plus a delayed ask for a burst
    # that stops short of N - otherwise a lone stanza waits for traffic that
    # may never come, and a durable send never leaves 'pending'.
    variable ackRequestTimer ""
    variable unackedCount 0
    option -ack-frequency -default 5  ;# Request ack every N stanzas
    option -ack-delay -default 1000   ;# ms before asking for a short burst
    # Max unacked stanzas before we force an error.  A half-open TCP
    # connection (network partition) can cause the queue to grow without
    # bound because the server never ACKs.  When exceeded, outStanza
    # raises "SM queue full"; the caller (conn) catches this and triggers
    # a disconnect/reconnect.  The overflowing stanza is already in the
    # queue at that point, so SM resumption will replay it.
    option -max-queue-size -default 5000
    # 0 leaves stream management off even when the server offers it.
    option -enabled -default 1
    # Our full JID, to tell our server's answer to a ping from anyone
    # else's: {*}$cmd -> jid.
    option -own-jid-command -default ""

    constructor {args} {
        $self configurelist $args
    }

    destructor {
        if {$ackRequestTimer ne ""} {
            after cancel $ackRequestTimer
        }
    }

    method onFeatures {featuresStanza} {
        if {[llength [xsearch $featuresStanza sm -ns "urn:xmpp:sm:3"]] > 0} {
            if {!$options(-enabled)} {
                set mode passthrough
                jlog inform "Server supports stream management; not enabling it"
                return 0
            }
            set mode active
            jlog inform "Server supports stream management"
            return 1
        }
        set mode passthrough
        jlog debug "Server does not support stream management"
        return 0
    }

    method onConnect {} {
        if {$mode eq "passthrough"} {
            $self StartPassthrough
            return
        }

        # Active SM mode
        set state connecting

        # Try to resume if we have a stream ID
        if {$streamId ne ""} {
            jlog inform "Attempting stream resumption (previd=$streamId, h=$in)"
            {*}$options(-write) [j resume \
                -ns "urn:xmpp:sm:3" \
                -previd $streamId \
                -h $in]
        } else {
            jlog inform "Enabling stream management"
            {*}$options(-write) [j enable \
                -ns "urn:xmpp:sm:3" \
                -resume true]
        }
    }

    method onDisconnect {} {
        if {$ackRequestTimer ne ""} {
            after cancel $ackRequestTimer
            set ackRequestTimer ""
        }

        set state disconnected

        if {$mode eq "passthrough"} {
            # Nothing to resume. What was written and not confirmed is
            # dropped here; a message among it is still pending in the store
            # and settled against the archive (message RetryPending).
            set queue {}
            set out 0
            set serverh 0
            set unackedCount 0
            set barriers {}
            return
        }

        # Keep streamId, queue, counters for potential resumption
        jlog debug "Disconnected: queue=[llength $queue], out=$out, serverh=$serverh, in=$in"
    }

    # Called after a graceful close (</stream:stream>), which ends the
    # session (XEP-0198 §5). The server has processed everything sent before
    # it, so there is nothing to resume or replay. If the socket was in fact
    # dead, unsent messages are still pending in the store and RetryPending
    # settles them against the archive.
    method reset {} {
        $self onDisconnect
        set streamId ""
        set queue {}
        set in 0
        set out 0
        set serverh 0
        set unackedCount 0
        set barriers {}
    }

    # Begin a stream without SM: what was queued for it goes out through
    # outStanza, counted and covered by the next ping like anything else.
    method StartPassthrough {} {
        set mode passthrough
        set state running
        set out 0
        set serverh 0
        set unackedCount 0
        set barriers {}
        set replay $queue
        set queue {}
        foreach stanza $replay {
            $self outStanza $stanza
        }
    }

    method inStanza {stanza} {
        if {$mode eq "passthrough"} {
            if {$state eq "running"} {
                $self BarrierAnswer $stanza
            }
            return
        }

        switch -- $state {
            disconnected {
                jlog warn "Received stanza while disconnected: [dict get $stanza tag]"
            }
            connecting {
                $self InStanzaConnecting $stanza
            }
            running {
                $self InStanzaRunning $stanza
            }
        }
    }

    method InStanzaConnecting {stanza} {
        set ns [dict get $stanza ns]

        # Count regular stanzas even during negotiation
        if {$ns eq "jabber:client"} {
            $self Incr in
            return
        }

        if {$ns ne "urn:xmpp:sm:3"} {
            return
        }

        set tag [dict get $stanza tag]

        switch -- $tag {
            "enabled" {
                set resumed 0
                set state running
                set streamId [xsearch $stanza -get @id]
                set serverh 0
                set in 0
                set out 0
                # Replay any stanzas surviving from a failed resume
                set replay $queue
                set queue {}
                if {[llength $replay] > 0} {
                    jlog inform "Replaying [llength $replay] stanzas from failed resume"
                    foreach s $replay {
                        $self outStanza $s
                    }
                }
                jlog inform "Stream management enabled: id=$streamId"
            }

            "resumed" {
                set previd [xsearch $stanza -get @previd]
                if {$previd ne $streamId} {
                    # Someone else's stream: fall back to a fresh one, as
                    # <failed/> does. Parking in 'disconnected' would strand
                    # the queue with conn stuck in sm-negotiating.
                    jlog error "Resume rejected: previd mismatch (ours: $streamId, server: $previd)"
                    $self ResumeFailed
                    return
                }

                set h [xsearch $stanza -get @h]
                jlog inform "Stream resumed: server received up to h=$h (we sent $out)"

                $self TakeAcked $h

                set resumed 1
                set state running

                # Resend any unacknowledged stanzas. These bypass the counter,
                # so ask for their ack here.
                if {[llength $queue] > 0} {
                    jlog inform "Resending [llength $queue] unacked stanzas"
                    foreach stanza $queue {
                        {*}$options(-write) $stanza
                    }
                    $self RequestAck
                }
            }

            "failed" {
                set resumed 0
                # <failed/> may report how far the old stream got.
                set h [xsearch $stanza -get @h]
                if {$h ne ""} {
                    $self TakeAcked $h
                }

                if {$streamId ne ""} {
                    # Resume failed: conn binds a resource and asks for a
                    # fresh stream. With h, the stanzas past it are replayed
                    # after <enabled/>. Without h we can't tell which ones
                    # arrived, and replaying them all could duplicate them,
                    # so the queue is dropped. Messages are still pending in
                    # the store and RetryPending resends any the archive
                    # doesn't have; the rest only mattered to the old
                    # session.
                    if {$h eq "" && [llength $queue]} {
                        jlog inform "Resume failed without h: dropping\
                            [llength $queue] unacked stanzas"
                        set queue {}
                    }
                    jlog inform "Resume failed (h=$h), binding for a fresh stream"
                    $self ResumeFailed
                } else {
                    # Enable failed, genuinely can't do SM
                    jlog warn "SM enable failed (h=$h), falling back to passthrough"
                    set streamId ""
                    $self StartPassthrough
                }
            }

            default {
                jlog warn "Unknown SM stanza during connecting: $tag"
            }
        }
    }

    method InStanzaRunning {stanza} {
        set ns [dict get $stanza ns]
        set tag [dict get $stanza tag]

        # Count regular stanzas
        if {$ns eq "jabber:client"} {
            $self Incr in
            return
        }

        # Handle SM protocol stanzas
        if {$ns ne "urn:xmpp:sm:3"} {
            return
        }

        switch -- $tag {
            "r" {
                jlog debug "Server requested ack, sending h=$in"
                {*}$options(-write) [j a -ns "urn:xmpp:sm:3" -h $in]
            }

            "a" {
                $self TakeAcked [xsearch $stanza -get @h]
                $self Answered
            }

            default {
                jlog warn "Unknown SM stanza during running: $tag"
            }
        }
    }

    method outStanza {stanza} {
        lappend queue $stanza
        $self Incr out

        # Guard against unbounded queue growth (e.g. half-open TCP).
        # The stanza is already queued above so it survives into the
        # reconnect → SM resumption replay.
        if {[llength $queue] > $options(-max-queue-size)} {
            error "SM queue full"
        }

        switch -- $state {
            disconnected - connecting {
                jlog debug "Queued stanza (queue size: [llength $queue])"
            }

            running {
                {*}$options(-write) $stanza

                incr unackedCount

                if {$unackedCount >= $options(-ack-frequency)} {
                    jlog debug "Requesting ack after $unackedCount unacked stanzas"
                    $self RequestAck
                } elseif {$ackRequestTimer eq ""} {
                    set ackRequestTimer \
                        [after $options(-ack-delay) [mymethod OnAckDelay]]
                }
            }
        }
    }

    # Ask the server how far it has got, dropping any pending delayed ask:
    # <r/> with SM, a ping without it.
    method RequestAck {} {
        if {$ackRequestTimer ne ""} {
            after cancel $ackRequestTimer
            set ackRequestTimer ""
        }
        if {$mode eq "active"} {
            {*}$options(-write) [j r -ns "urn:xmpp:sm:3"]
        } else {
            set id sm-barrier-[incr barrierSeq]
            dict set barriers $id $out
            {*}$options(-write) [j iq -type get -id $id {
                j ping -ns urn:xmpp:ping
            }]
        }
        set unackedCount 0
    }

    # An answer came in: what is still unconfirmed counts as unasked, so a
    # stanza written while the question was out is asked about too.
    method Answered {} {
        set unackedCount [$self Hdiff $out $serverh]
    }

    # Passthrough: the server's reply to one of our pings (a result, or an
    # error - either way it was processed in order) confirms what was written
    # before it, and the replies to any earlier pings with it.
    method BarrierAnswer {stanza} {
        if {[dict get $stanza tag] ne "iq"} return
        lassign [xsearch $stanza -get {@type @id @from}] type_ id from
        if {$type_ ni {result error} || ![dict exists $barriers $id]} return
        if {![$self FromOurServer $from]} {
            jlog warn "Ignoring a reply to $id from '$from'"
            return
        }
        set h [dict get $barriers $id]
        dict for {bid bh} $barriers {
            if {[$self Hdiff $h $bh] <= 0x7FFFFFFF} { dict unset barriers $bid }
        }
        $self TakeAcked $h
        $self Answered
    }

    # Whether $from is our server answering us (RFC 6120 8.1.2.1): no from,
    # our bare JID, or our domain.
    method FromOurServer {from} {
        if {$from eq ""} { return 1 }
        set own ""
        if {$options(-own-jid-command) ne ""} {
            set own [{*}$options(-own-jid-command)]
        }
        if {$own eq "" || ![jid valid $from]} { return 0 }
        set from [jid norm $from]
        expr {$from eq [jid norm [jid bare $own]] || $from eq [jid norm [jid domain $own]]}
    }

    method OnAckDelay {} {
        set ackRequestTimer ""
        # unackedCount 0 means an answer meanwhile confirmed everything.
        if {$state ne "running" || $unackedCount == 0} {
            return
        }
        jlog debug "Requesting ack for $unackedCount stanza(s) after the delay"
        $self RequestAck
    }

    method Incr {varName} {
        upvar $varName var
        # XEP-0198: counters wrap at 2^32 (valid range 0..4294967295)
        if {$var < 4294967295} {
            incr var
        } else {
            set var 0
        }
    }

    # Modular difference for 32-bit unsigned counters (a - b) mod 2^32
    method Hdiff {a b} {
        return [expr {($a - $b) & 0xFFFFFFFF}]
    }

    # Stanzas newly acked by a server h. A backwards h wraps to near 2^32,
    # which would flush the whole queue as delivered, so it acks nothing.
    method Acked {h} {
        set diff [$self Hdiff $h $serverh]
        if {$diff > 0x7FFFFFFF} {
            jlog warn "Server h went backwards: $serverh -> $h"
            return 0
        }
        return $diff
    }

    # The one path every server h goes through: trimming the queue anywhere
    # else drops stanzas without confirming them, leaving a durable send
    # 'pending' for the reconnect retry to deliver twice. -ack-command runs
    # before the trim so anything it writes back lands behind the removals.
    method TakeAcked {h} {
        set ackedCount [$self Acked $h]
        if {$ackedCount == 0} {
            return 0
        }
        if {$options(-ack-command) ne ""} {
            {*}$options(-ack-command) [lrange $queue 0 [expr {$ackedCount - 1}]]
        }
        set queue [lrange $queue $ackedCount end]
        set serverh $h
        jlog debug "Server acked $ackedCount stanzas (h=$h), queue: [llength $queue]"
        return $ackedCount
    }

    # A resume is tried instead of binding (XEP-0198 §5), so when it fails
    # nothing is bound yet: conn sees state resume-failed, binds, and calls
    # onConnect again, which enables a fresh stream. Counters restart with
    # it; the queue stays and is replayed after <enabled/>.
    method ResumeFailed {} {
        set streamId ""
        set in 0
        set out 0
        set serverh 0
        set state resume-failed
    }

    # Whether onConnect would resume rather than enable: the server offers
    # SM and we hold a stream to resume.
    method resumable {} {
        expr {$mode eq "active" && $streamId ne ""}
    }

    method getInfo {} {
        return [dict create \
            mode $mode \
            state $state \
            streamId $streamId \
            resumed $resumed \
            in $in \
            out $out \
            serverh $serverh \
            queueSize [llength $queue] \
            unacked [$self Hdiff $out $serverh]]
    }

}
