package provide tacky::mockconn 0.1
package require snit

snit::type mock_conn {
    variable written
    variable connected
    variable closed
    variable mockState disconnected
    variable mockLastError ""

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

    # Mirrors taco_connection pull. `tacky observe` calls it, so a widget that
    # observes conn cannot be built against the mock without this.
    method pull {args} {
        if {$options(-emit) eq ""} return
        array set opts $args
        switch -- $opts(-event) {
            <State> {
                {*}$options(-emit) conn <State> -state $mockState
            }
            <ConnError> {
                if {$mockLastError ne ""} {
                    {*}$options(-emit) conn <ConnError> -message $mockLastError
                }
            }
            default {
                return -code error \
                    "conn pull: event $opts(-event) is not pullable"
            }
        }
    }

    # -- Test helpers --

    method feed {stanza} {
        if {$options(-onstanza) ne ""} {
            {*}$options(-onstanza) $stanza
        }
    }

    method fire_state {s} {
        set mockState $s
        # Real conn drops the last error once it reaches connected.
        if {$s eq "connected"} { set mockLastError "" }
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <State> -state $s
        }
    }

    method fire_connerror {msg} {
        set mockLastError $msg
        if {$options(-emit) ne ""} {
            {*}$options(-emit) conn <ConnError> -message $msg
        }
    }

    method fire_ready {resumed} {
        $self fire_state connected
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

    method get_closed {} {
        return $closed
    }

    method clear {} {
        set written {}
    }
}

# Swapping the mock into place is a rename dance with an easy failure mode: a
# half-done swap leaves the real conn shadowed and every later test in the file
# builds against the wrong type. Keeping the pair here — the same shape as
# mockrtc::install/uninstall — gives the six call sites one thing to call.
#
# Idempotent on purpose. The unqualified `rename conn _real_conn` this replaces
# errored outright when a test-local swap nested inside tacky_env's ("command
# already exists"); a second install is now a no-op.
#
# Names are fully qualified because tcltest may run a setup body inside the
# test's own namespace, where `rename mock_conn conn` would install the mock as
# a namespace-local command and leave the real conn in place at global scope.
namespace eval mockconn {
    variable Installed 0
}

proc mockconn::install {} {
    variable Installed
    if {$Installed} return
    rename ::conn ::conn__real
    rename ::mock_conn ::conn
    set Installed 1
}

proc mockconn::uninstall {} {
    variable Installed
    if {!$Installed} return
    rename ::conn ::mock_conn
    rename ::conn__real ::conn
    set Installed 0
}
