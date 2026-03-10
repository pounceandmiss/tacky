if 0 {
    XEP-0077 In-Band Registration — tacky module

    == Usage (via tacky API) ==

    tacky listen register <Form> $cmd
    tacky listen register <MediaReady> $cmd
    tacky listen register <Success> $cmd
    tacky listen register <Error> $cmd

    tacky register connect -host example.com
    # → <Form> fires
    # → set data [tacky register form]
    # → user fills in fields
    # → tacky register submit -values {username alice password secret}
    # → <Success> or <Error> fires

    Multiple concurrent sessions are supported via -token.

    == Methods ==

    tacky register connect -host $h ?-port $p? ?-token $tok?
        → Start registration handshake. Fires <Form> on success.

    tacky register form ?-token $tok?
        → Returns form data as flat array-get list (see formctrl).

    tacky register media ?-token $tok? -var $v
        → Returns raw media bytes for field $v, or "".

    tacky register submit ?-token $tok? -values {var val ...}
        → Submit filled form. Fires <Success> or <Error>.

    tacky register cancel ?-token $tok?
        → Destroy session and clean up.

    == Events ==

    <Form>       -token $tok                Form received, ready to query
    <MediaReady> -token $tok -var $v        Media data available for field
    <Success>    -token $tok                Registration succeeded
    <Error>      -token $tok -message $msg  Registration failed
}

# taco_register — tacky-facing module
#
# Manages token → session map. Delegates to session objects.
# Emits events via $options(-taco) emit register ...

snit::type taco_register {
    option -taco -default ""

    variable Sessions -array {}

    destructor {
	foreach {tok session} [array get Sessions] {
	    catch {$session destroy}
	}
    }

    method connect {args} {
	set host [dict get $args -host]
	set port [expr {[dict exists $args -port] ? [dict get $args -port] : 5222}]
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]

	if {[info exists Sessions($token)]} {
	    catch {$Sessions($token) destroy}
	}

	set Sessions($token) [taco_register_session $self.session-[clock microseconds] \
	    -host $host -port $port \
	    -callback [mymethod OnSessionEvent $token]]
	$Sessions($token) connect
    }

    tackymethod form {args} {
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]
	$self RequireSession $token
	$Sessions($token) form
    }

    tackymethod media {args} {
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]
	set var [dict get $args -var]
	$self RequireSession $token
	$Sessions($token) media -var $var
    }

    method submit {args} {
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]
	set values [dict get $args -values]
	$self RequireSession $token
	$Sessions($token) submit -values $values
    }

    method cancel {args} {
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]
	if {[info exists Sessions($token)]} {
	    $Sessions($token) destroy
	    unset Sessions($token)
	}
    }

    method RequireSession {token} {
	if {![info exists Sessions($token)]} {
	    error "No registration session for token \"$token\""
	}
    }

    method session {args} {
	set token [expr {[dict exists $args -token] ? [dict get $args -token] : ""}]
	$self RequireSession $token
	return $Sessions($token)
    }

    method OnSessionEvent {token event args} {
	$options(-taco) emit register $event -token $token {*}$args
    }
}

# taco_register_session — one registration session (internal)
#
# Owns one bareconn + one formctrl. Contains all the XMPP protocol
# logic for XEP-0077 in-band registration.

snit::type taco_register_session {
    component conn -public conn

    option -host -default ""
    option -port -default 5222
    option -callback -default ""

    variable idCounter 0
    variable headerSent 0
    variable currentForm ""
    variable submitting 0

    constructor {args} {
	$self configurelist $args
    }

    destructor {
	if {[info commands $self.conn] ne ""} {
	    $conn close
	    $conn destroy
	}
	if {$currentForm ne "" && [info commands $currentForm] ne ""} {
	    $currentForm destroy
	}
    }

    method connect {} {
	set headerSent 0
	install conn using bareconn $self.conn \
	    -onready [mymethod OnReady] \
	    -header-command [mymethod OnHeader] \
	    -onstanza [mymethod OnStanza] \
	    -ondisconnect [mymethod OnError]
	$conn connect $options(-host) $options(-port)
    }

    method form {} {
	if {$currentForm eq ""} {
	    error "No registration form available"
	}
	$currentForm dump
    }

    method media {args} {
	if {$currentForm eq ""} {
	    error "No registration form available"
	}
	set var [dict get $args -var]
	$currentForm media $var
    }

    method submit {args} {
	set values [dict get $args -values]
	if {$currentForm eq ""} {
	    error "No registration form available"
	}
	foreach {var val} $values {
	    $currentForm setValue $var $val
	}
	set submitting 1
	set id [incr idCounter]

	# Check whether the original form was XEP-0004 (has FORM_TYPE)
	array set form [$currentForm dump]
	set useDataForm 0
	if {[info exists form(fields)]} {
	    foreach f $form(fields) {
		if {$f eq "FORM_TYPE"} {
		    set useDataForm 1
		    break
		}
	    }
	}

	if {$useDataForm} {
	    set formNode [$currentForm tonode]
	    $conn writeStanza [j iq -type set -id reg-$id {
		j query -ns jabber:iq:register {
		    j /as-is $formNode
		}
	    }]
	} else {
	    # Legacy submission — emit plain field elements
	    $conn writeStanza [j iq -type set -id reg-$id {
		j query -ns jabber:iq:register {
		    foreach f $form(fields) {
			if {[info exists form(field,$f,value)]} {
			    j $f .body $form(field,$f,value)
			} else {
			    j $f
			}
		    }
		}
	    }]
	}
    }

    # --- Internal handlers ---

    method OnReady {} {
	$conn write [::jab::header "" to $options(-host)]
	set headerSent 1
    }

    method OnHeader {header} {
	# Stream header received; features stanza follows
    }

    method OnStanza {stanza} {
	set tag [dict get $stanza tag]
	switch -- $tag {
	    features {
		$self HandleFeatures $stanza
	    }
	    default {
		$self HandleIqResponse $stanza
	    }
	}
    }

    method HandleFeatures {stanza} {
	set regFeature [xsearch $stanza register -get node]
	if {$regFeature eq ""} {
	    $self FireEvent <Error> -message "Server does not support in-band registration"
	    return
	}
	set id [incr idCounter]
	$conn writeStanza [j iq -type get -id reg-$id {
	    j query -ns jabber:iq:register
	}]
    }

    method HandleIqResponse {stanza} {
	if {[dict get $stanza tag] ne "iq"} return
	set type [xsearch $stanza -get @type]

	switch -- $type {
	    result {
		if {$submitting} {
		    set submitting 0
		    $self FireEvent <Success>
		    return
		}
		set query [xsearch $stanza query -get node]
		if {$query eq ""} {
		    return
		}
		$self HandleRegForm $query
	    }
	    error {
		set errText [xsearch $stanza error text -get body]
		if {$errText eq ""} {
		    set errChild [xsearch $stanza error 0 -get node]
		    if {$errChild ne ""} {
			set errText [dict get $errChild tag]
		    } else {
			set errText "Registration failed"
		    }
		}
		$self FireEvent <Error> -message $errText
	    }
	}
    }

    method HandleRegForm {queryNode} {
	# Prefer XEP-0004 data form if present
	set xForm [xsearch $queryNode x -get node]
	if {$xForm ne ""} {
	    set formList [::tacky::forms::tolist $xForm]
	} else {
	    # Legacy fields — synthesise a forms-compatible list
	    set formList [::tacky::forms::tolist [$self LegacyToForm $queryNode]]
	}

	set oldForm $currentForm
	set currentForm [formctrl $self.form-[clock microseconds] $formList]
	if {$oldForm ne ""} {
	    $currentForm restore $oldForm
	    catch {$oldForm destroy}
	}

	# Extract inline BOB <data> elements and push media data.
	# Collect media vars first, then emit <Form> before <MediaReady>
	# so the GUI creates the form widget before requesting media data
	# via async callbacks.
	set mediaFields [$currentForm mediaFields]
	set readyVars {}
	foreach dataNode [xsearch $queryNode data -ns urn:xmpp:bob] {
	    set cid [xsearch $dataNode -get @cid]
	    if {[dict exists $mediaFields $cid]} {
		set var [dict get $mediaFields $cid]
		set base64data [string trim [dict get $dataNode body]]
		$currentForm setMedia $var $base64data
		lappend readyVars $var
	    }
	}

	$self FireEvent <Form>

	foreach var $readyVars {
	    $self FireEvent <MediaReady> -var $var
	}
    }

    method LegacyToForm {queryNode} {
	set fields {}
	set instructions ""
	if {[xsearch $queryNode instructions -get node] ne ""} {
	    set instructions [xsearch $queryNode instructions -get body]
	}

	foreach child [dict get $queryNode children] {
	    set ctag [dict get $child tag]
	    if {$ctag in {instructions x}} continue
	    lappend fields $child
	}

	j x -ns jabber:x:data -type form {
	    if {$instructions ne ""} {
		j instructions .body $instructions
	    }
	    foreach child $fields {
		set ctag [dict get $child tag]
		set ftype [expr {$ctag eq "password" ? "text-private" : "text-single"}]
		set val [dict get $child body]
		j field -var $ctag -type $ftype -label $ctag {
		    if {$val ne ""} {
			j value .body $val
		    }
		}
	    }
	}
    }

    method OnError {msg} {
	$self FireEvent <Error> -message $msg
    }

    method FireEvent {event args} {
	if {$options(-callback) ne ""} {
	    {*}$options(-callback) $event {*}$args
	}
    }
}
