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
# Nodes a contact publishes for us to show (an avatar's metadata, a nick)
# register with -contacts: their events are taken from our own account or
# from a JID in the roster, and dropped from anyone else. The server sends
# a contact's PEP to its subscribers, but nothing stops a stranger sending
# a message with an <event/> in it, and its name and picture would then be
# shown on its first message's chat row.
#
# Sits in the client.tcl message dispatch chain between muc and message:
# returns 1 if the stanza was a PubSub event with a registered handler
# (claiming the stanza), 0 otherwise.

snit::type taco_pubsub {
    option -client -readonly yes

    variable client
    variable PubSubHandlers
    # node -> whose events it takes: any, own (-own-only), contacts
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
        # The node is named on <items>, or on <purge>/<delete> when all
        # items were removed.
        set node ""
        foreach tag {items purge delete} {
            set node [xsearch [lindex $eventNodes 0] $tag -get @node]
            if {$node ne ""} break
        }
        if {$node eq "" || ![info exists PubSubHandlers($node)]} { return 0 }
        set from [xsearch $stanza -get @from]
        # Pubsub services are bare jids. An event from a full jid comes from a
        # client, e.g. a room occupant, and would be applied to the room's
        # bare jid (its avatar or name).
        if {[jid resource $from] ne ""} {
            jlog error "Dropping $node event from '$from'" -stanza $stanza
            return 1
        }
        if {$OwnOnly($node) ne "any" && ![jid fromMe $from [$client cget -jid]]} {
            if {$OwnOnly($node) eq "own"} {
                jlog error "Dropping $node event from '$from'" -stanza $stanza
                return 1
            }
            # Anything in the roster counts, a pending request included.
            if {[$client roster subscription -jid $from] eq ""} {
                jlog inform "Dropping $node event from '$from', not a contact"
                return 1
            }
        }
        {*}$PubSubHandlers($node) $stanza
        return 1
    }

    # handler $node ?-own-only|-contacts? $command
    method handler {node args} {
        set from any
        switch -- [lindex $args 0] {
            -own-only { set from own; set args [lrange $args 1 end] }
            -contacts { set from contacts; set args [lrange $args 1 end] }
        }
        set PubSubHandlers($node) [lindex $args 0]
        set OwnOnly($node) $from
    }

    method unhandler {node} {
        unset -nocomplain PubSubHandlers($node)
        unset -nocomplain OwnOnly($node)
    }
}
