# Stream Management (XEP-0198) with automatic negotiation
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

    # Stanza counters (active mode only)
    variable in 0       ;# How many stanzas we've received (our @h)
    variable out 0      ;# How many stanzas we've sent
    variable serverh 0  ;# Last @h we got from server (how many it received)

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

    # Ack request strategy
    variable ackRequestTimer ""
    variable unackedCount 0
    option -ack-frequency -default 5  ;# Request ack every N stanzas

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
            # No SM - just mark as running and flush queue
            set state running
            foreach stanza $queue {
                {*}$options(-write) $stanza
            }
            set queue {}
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
            return
        }

        # Keep streamId, queue, counters for potential resumption
        jlog debug "Disconnected: queue=[llength $queue], out=$out, serverh=$serverh, in=$in"
    }

    method inStanza {stanza} {
        if {$mode eq "passthrough"} {
            # Nothing to do
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
                set queue {}
                jlog inform "Stream management enabled: id=$streamId"
            }

            "resumed" {
                set previd [xsearch $stanza -get @previd]
                if {$previd ne $streamId} {
                    jlog error "Resume failed: previd mismatch (ours: $streamId, server: $previd)"
                    set streamId ""
                    set queue {}
                    set in 0
                    set out 0
                    set serverh 0
                    set state disconnected
                    return
                }

                set h [xsearch $stanza -get @h]
                jlog inform "Stream resumed: server received up to h=$h (we sent $out)"

                set ackedCount [$self Hdiff $h $serverh]
                if {$ackedCount > 0} {
                    set queue [lrange $queue $ackedCount end]
                    set serverh $h
                    jlog debug "Removed $ackedCount acked stanzas, queue size now: [llength $queue]"
                }

                set resumed 1
                set state running

                # Resend any unacknowledged stanzas
                if {[llength $queue] > 0} {
                    jlog inform "Resending [llength $queue] unacked stanzas"
                    foreach stanza $queue {
                        {*}$options(-write) $stanza
                    }
                }
            }

            "failed" {
                set resumed 0
                set h ""
                if {[dict exists $stanza attrs h]} {
                    set h [dict get $stanza attrs h]
                    set ackedCount [$self Hdiff $h $serverh]
                    if {$ackedCount > 0} {
                        set queue [lrange $queue $ackedCount end]
                    }
                }
                jlog warn "Stream management failed (h=$h), falling back to passthrough"

                set streamId ""
                set mode passthrough
                set state running

                # Resend remaining queued stanzas
                foreach stanza $queue {
                    {*}$options(-write) $stanza
                }
                set queue {}
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
                set h [xsearch $stanza -get @h]

                set diff [$self Hdiff $h $serverh]
                if {$diff > 0x7FFFFFFF} {
                    jlog warn "Server h went backwards: $serverh -> $h"
                    return
                }

                set ackedCount $diff
                if {$ackedCount > 0} {
                    set queue [lrange $queue $ackedCount end]
                    jlog debug "Server acked $ackedCount stanzas (was $serverh, now $h), queue: [llength $queue]"
                    set serverh $h
                }

                set unackedCount 0
            }

            default {
                jlog warn "Unknown SM stanza during running: $tag"
            }
        }
    }

    method outStanza {stanza} {
        if {$mode eq "passthrough"} {
            if {$state eq "running"} {
                {*}$options(-write) $stanza
            } else {
                lappend queue $stanza
            }
            return
        }

        # Active SM mode
        lappend queue $stanza
        $self Incr out

        switch -- $state {
            disconnected - connecting {
                jlog debug "Queued stanza (queue size: [llength $queue])"
            }

            running {
                {*}$options(-write) $stanza

                incr unackedCount

                if {$unackedCount >= $options(-ack-frequency)} {
                    jlog debug "Requesting ack after $unackedCount unacked stanzas"
                    {*}$options(-write) [j r -ns "urn:xmpp:sm:3"]
                    set unackedCount 0
                }
            }
        }
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
