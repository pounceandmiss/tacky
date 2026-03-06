snit::type taco_pubsub {
    variable PubSubHandlers

    method OnMessage {stanza} {
	# Check for PubSub event → dispatch
	set eventNodes [xsearch $stanza event -ns http://jabber.org/protocol/pubsub#event]
	if {[llength $eventNodes] > 0} {
	    set node [xsearch [lindex $eventNodes 0] items -get @node]
	    if {$node ne "" && [info exists PubSubHandlers($node)]} {
		{*}$PubSubHandlers($node) $stanza
		return
	    }
	}
    }
    method handler {node command} {
	set PubSubHandlers($node) $command
    }

    method unhandler {node} {
	unset -nocomplain PubSubHandlers($node)
    }

}
