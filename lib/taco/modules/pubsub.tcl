# taco_pubsub - dispatches XEP-0060 PubSub event stanzas to per-node handlers.
#
# Other modules register a handler for a node URI in their constructor:
#     $client pubsub handler urn:xmpp:avatar:metadata [mymethod OnNotification]
# and unregister in their destructor:
#     $client pubsub unhandler urn:xmpp:avatar:metadata
#
# Nodes whose events are only meaningful from the account's own PEP
# service (e.g. bookmarks) register with -own-only; events for them from
# any other sender are dropped before dispatch:
#     $client pubsub handler urn:xmpp:bookmarks:1 -own-only [mymethod OnNotification]
#
# Sits in the client.tcl message dispatch chain between muc and message:
# returns 1 if the stanza was a PubSub event with a registered handler
# (claiming the stanza), 0 otherwise.

snit::type taco_pubsub {
    option -client -readonly yes

    variable client
    variable PubSubHandlers
    variable OwnOnly

    constructor {args} {
        $self configurelist $args
        set client $options(-client)
        array set PubSubHandlers {}
        array set OwnOnly {}
    }

    method OnMessage {stanza} {
        set eventNodes [xsearch $stanza event -ns http://jabber.org/protocol/pubsub#event]
        if {[llength $eventNodes] == 0} { return 0 }
        set node [xsearch [lindex $eventNodes 0] items -get @node]
        if {$node eq "" || ![info exists PubSubHandlers($node)]} { return 0 }
        if {$OwnOnly($node)} {
            set from [xsearch $stanza -get @from]
            if {![jid fromMe $from [$client cget -jid]]} {
                jlog error "Dropping $node event from '$from'" -stanza $stanza
                return 1
            }
        }
        {*}$PubSubHandlers($node) $stanza
        return 1
    }

    # handler $node ?-own-only? $command
    method handler {node args} {
        set ownOnly 0
        if {[lindex $args 0] eq "-own-only"} {
            set ownOnly 1
            set args [lrange $args 1 end]
        }
        set PubSubHandlers($node) [lindex $args 0]
        set OwnOnly($node) $ownOnly
    }

    method unhandler {node} {
        unset -nocomplain PubSubHandlers($node)
        unset -nocomplain OwnOnly($node)
    }
}
