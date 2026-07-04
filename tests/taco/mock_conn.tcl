package provide tacky::mockconn 0.1
package require snit

snit::type mock_conn {
    variable written
    variable connected
    variable closed
    variable mockState disconnected

    # Connection options (stored, not used)
    option -host -default ""
    option -port -default 5222
    option -username -default ""
    option -password -default ""
    option -resource -default ""
    option -autoreconnect -default 0

    # Event callback
    option -emit -default ""

    # Callbacks
    option -onready -default ""
    option -onbound -default ""
    option -onautherror -default ""
    option -onresourceconflict -default ""
    option -ondisconnect -default ""
    option -onstanza -default ""
    option -ondebugstanza -default ""

    # Read-only state
    option -bound-jid -default ""

    constructor {args} {
        $self configurelist $args
        set written {}
        set connected 0
        set closed 0
    }

    # -- Real interface (as called by client) --

    method state {args} {
        return $mockState
    }

    method connect {} {
        set connected 1
    }

    method close {} {
        set closed 1
    }

    method write {stanza} {
        lappend written $stanza
    }

    method writeImmediate {stanza} {
        lappend written $stanza
    }

    # -- Test helpers --

    method feed {stanza} {
        if {$options(-onstanza) ne ""} {
            {*}$options(-onstanza) $stanza
        }
    }

    method fire_state {s} {
        set mockState $s
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <State> -state $s
        }
    }

    method fire_ready {resumed} {
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <Ready> -resumed $resumed
        }
        if {$options(-onready) ne ""} {
            {*}$options(-onready) $resumed
        }
    }

    method fire_autherror {msg} {
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <AuthError> -message $msg
        }
        if {$options(-onautherror) ne ""} {
            {*}$options(-onautherror) $msg
        }
    }

    method fire_disconnect {msg} {
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <Disconnected> -message $msg
        }
        if {$options(-ondisconnect) ne ""} {
            {*}$options(-ondisconnect) $msg
        }
    }

    method get_written {} {
        return $written
    }

    method clear {} {
        set written {}
    }
}
