if 0 {
    tacky message history get ?-before $ts? ?-after $ts?
    Will decide automatically when to fetch more:
    if `-local yes` is supplied, will only return local history and will stop at hole. I think the nonlocal version can make use of the local version under the hood to make the code DRY
}
snit::type taco_message {
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
    method "pubsub handler" {node command} {
	set PubSubHandlers($node) $command
    }

    method "pubsub unhandler" {node} {
	unset -nocomplain PubSubHandlers($node)
    }

}
