# taco_pubsub - dispatches XEP-0060 PubSub event stanzas to per-node handlers.
#
# Other modules register a handler for a node URI in their constructor:
#     $client pubsub handler urn:xmpp:avatar:metadata [mymethod OnNotification]
# and unregister in their destructor:
#     $client pubsub unhandler urn:xmpp:avatar:metadata
#
# Sits in the client.tcl message dispatch chain between muc and message:
# returns 1 if the stanza was a PubSub event with a registered handler
# (claiming the stanza), 0 otherwise.

snit::type taco_pubsub {
    option -client -readonly yes

    variable client
    variable PubSubHandlers

    constructor {args} {
        $self configurelist $args
        set client $options(-client)
        array set PubSubHandlers {}
    }

    method OnMessage {stanza} {
        set eventNodes [xsearch $stanza event -ns http://jabber.org/protocol/pubsub#event]
        if {[llength $eventNodes] == 0} { return 0 }
        set node [xsearch [lindex $eventNodes 0] items -get @node]
        if {$node eq "" || ![info exists PubSubHandlers($node)]} { return 0 }
        {*}$PubSubHandlers($node) $stanza
        return 1
    }

    method handler {node command} {
        set PubSubHandlers($node) $command
    }

    method unhandler {node} {
        unset -nocomplain PubSubHandlers($node)
    }
}
