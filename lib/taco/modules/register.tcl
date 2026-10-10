if 0 {
    XEP-0077 In-Band Registration — tacky module

    == Usage (via tacky API) ==

    tacky listen register <Form> $cmd
    tacky listen register <MediaReady> $cmd
    tacky listen register <Success> $cmd
    tacky listen register <Error> $cmd

    tacky register connect -domain example.com
    # → <Form> fires
    # → set data [tacky register form]
    # → user fills in fields
    # → tacky register submit -values {username alice password secret}
    # → <Success> or <Error> fires

    Multiple concurrent sessions are supported via -token.

    == Methods ==

    tacky register connect -domain $d ?-host $h? ?-port $p? ?-tls $t? ?-srv $s?
                           ?-websocket_url $u? ?-token $tok?
        → Start registration handshake. Fires <Form> on success.
          The other options work as an account's do.

    tacky register form ?-token $tok?
        → Returns the form as a dict (see lib/taco/modules/form.tcl).

    tacky register media ?-token $tok? -var $v
        → Returns raw media bytes for field $v, or "".

    tacky register submit ?-token $tok? -values {var val ...}
        → Submit filled form. Fires <Success> or <Error>. If the server
          closed the stream while the form was open (its idle timeout),
          dials again first and fetches the form again; the values go in
          the new one, with no new <Form> unless it needs the user.

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

    tackymethod -noreturn connect {args} {
        array set opts {-host "" -port 0 -tls auto -srv 1 -nameservers ""
                        -token "" -websocket_url ""}
        array set opts $args
        if {![info exists opts(-domain)] || $opts(-domain) eq ""} {
            error "missing -domain"
        }
        set transport tcp
        catch {set transport [$options(-taco) cget -transport]}

        if {[info exists Sessions($opts(-token))]} {
            catch {$Sessions($opts(-token)) destroy}
        }

        set Sessions($opts(-token)) [taco_register_session $self.session-[clock microseconds] \
            -domain $opts(-domain) -host $opts(-host) -port $opts(-port) \
            -tls $opts(-tls) -srv $opts(-srv) -nameservers $opts(-nameservers) \
            -transport $transport -ws-url $opts(-websocket_url) \
            -callback [mymethod OnSessionEvent $opts(-token)]]
        $Sessions($opts(-token)) connect
    }

    tackymethod form {args} {
        array set opts {-token ""}
        array set opts $args
        $self RequireSession $opts(-token)
        $Sessions($opts(-token)) form
    }

    tackymethod media {args} {
        array set opts {-token ""}
        array set opts $args
        $self RequireSession $opts(-token)
        $Sessions($opts(-token)) media -var $opts(-var)
    }

    tackymethod -noreturn submit {args} {
        array set opts {-token ""}
        array set opts $args
        $self RequireSession $opts(-token)
        $Sessions($opts(-token)) submit -values $opts(-values)
    }

    tackymethod -noreturn cancel {args} {
        array set opts {-token ""}
        array set opts $args
        if {[info exists Sessions($opts(-token))]} {
            $Sessions($opts(-token)) destroy
            unset Sessions($opts(-token))
        }
    }

    method RequireSession {token} {
        if {![info exists Sessions($token)]} {
            error "No registration session for token \"$token\""
        }
    }

    method session {args} {
        array set opts {-token ""}
        array set opts $args
        $self RequireSession $opts(-token)
        return $Sessions($opts(-token))
    }

    method OnSessionEvent {token event args} {
        $options(-taco) emit register $event -token $token {*}$args
    }
}

# taco_register_session — one registration session (internal)
#
# Owns one bareconn and the current form (a dict) plus its media bytes.
# Contains all the XMPP protocol logic for XEP-0077 in-band registration.

snit::type taco_register_session {
    component conn -public conn

    # As conn's options of the same names
    option -domain -default ""
    option -host -default ""
    option -port -default 0
    option -tls -default auto
    option -srv -default 1
    option -nameservers -default ""
    # Passed to the bareconn; see baseconn.
    option -transport -default tcp
    option -ws-url -default ""
    option -callback -default ""

    variable idCounter 0
    variable headerSent 0
    variable currentForm ""
    variable mediaBytes {}
    variable submitting 0
    variable dialId ""

    # A server closes an unauthenticated stream after a while (ejabberd's
    # negotiation_timeout, 120 s), and nothing goes on the wire between the
    # form and the submit. That close is no error: FormLive says the
    # current stream brought the form, Lost that it has ended since, and
    # the submit dials again, fetches the form again and sends the values
    # held in Resubmit while Redialling. A close before the submit is
    # answered, or a dial again that fails, is the <Error> ClosedText.
    variable FormLive 0
    variable Lost 0
    variable Redialling 0
    variable Resubmit {}
    typevariable ClosedText "The server closed the connection, try again"

    # The legacy branch turns a field's var into an element name, so only
    # the XEP-0077 set is allowed through; the server picks these strings.
    typevariable LegacyFields {
        username password nick name first last email address city state
        zip phone url date misc text key
    }

    constructor {args} {
        $self configurelist $args
    }

    destructor {
        if {$dialId ne ""} { dial::cancel $dialId }
        if {[info commands $self.conn] ne ""} {
            $conn close
            $conn destroy
        }
    }

    method connect {} {
        set headerSent 0
        set FormLive 0
        set Lost 0
        if {$dialId ne ""} {
            dial::cancel $dialId
            set dialId ""
        }
        if {[info commands $self.conn] ne ""} {
            $conn close
            $conn destroy
        }
        install conn using bareconn $self.conn \
            -transport $options(-transport) \
            -ws-url $options(-ws-url) \
            -onready [mymethod OnReady] \
            -header-command [mymethod OnHeader] \
            -onstanza [mymethod OnStanza] \
            -ondisconnect [mymethod OnError] \
            -domain $options(-domain)
        if {$options(-transport) eq "websocket"} {
            $conn connectTargets {}
            return
        }
        set dialId [dial::targets -domain $options(-domain) \
            -host $options(-host) -port $options(-port) -tls $options(-tls) \
            -srv $options(-srv) -nameservers $options(-nameservers) \
            -command [mymethod OnTargets]]
    }

    method OnTargets {targets} {
        set dialId ""
        $conn connectTargets $targets
    }

    method form {} {
        if {$currentForm eq ""} {
            error "No registration form available"
        }
        return $currentForm
    }

    method media {args} {
        if {$currentForm eq ""} {
            error "No registration form available"
        }
        set var [dict get $args -var]
        if {[dict exists $mediaBytes $var]} {
            return [dict get $mediaBytes $var]
        }
        return ""
    }

    method submit {args} {
        set values [dict get $args -values]
        if {$currentForm eq ""} {
            error "No registration form available"
        }
        if {$Redialling} {
            # Already dialling again for an earlier submit: these values
            # go instead, once the form is back.
            set Resubmit $values
            return
        }
        if {$Lost} {
            jlog debug "register: the server closed the stream; dialling again to send the form"
            set Resubmit $values
            set Redialling 1
            $self connect
            return
        }
        $self Submit $values
    }

    # The values to send in the form fetched again, or "" when it needs the
    # user: a captcha to read, or a required field the values leave empty.
    # Its hidden and fixed fields are the server's (a new challenge among
    # them), so whatever the values held for those is dropped.
    method Resendable {values} {
        if {[llength [::tacky::forms::mediaMap $currentForm]]} { return "" }
        set out {}
        foreach field [dict get $currentForm fields] {
            set var [dict get $field var]
            if {[dict get $field type] in {hidden fixed} || ![dict exists $values $var]} continue
            dict set out $var [dict get $values $var]
        }
        foreach field [dict get [::tacky::forms::apply $currentForm $out] fields] {
            if {[dict get $field required] && [join [dict get $field value] ""] eq ""} {
                return ""
            }
        }
        return [list ok $out]
    }

    method Submit {values} {
        set filled [::tacky::forms::apply $currentForm $values]
        set submitting 1
        set id [incr idCounter]

        # Check whether the original form was XEP-0004 (has FORM_TYPE)
        set useDataForm 0
        foreach field [dict get $filled fields] {
            if {[dict get $field var] eq "FORM_TYPE"} {
                set useDataForm 1
                break
            }
        }

        if {$useDataForm} {
            set formNode [::tacky::forms::serialize $filled]
            $conn writeStanza [j iq -type set -id reg-$id {
                j query -ns jabber:iq:register {
                    j #as-is $formNode
                }
            }]
        } else {
            # Legacy submission - emit plain field elements
            $conn writeStanza [j iq -type set -id reg-$id {
                j query -ns jabber:iq:register {
                    foreach field [dict get $filled fields] {
                        set var [dict get $field var]
                        if {$var ni $LegacyFields} {
                            jlog warn "register: skipping field '$var'"
                            continue
                        }
                        set vals [dict get $field value]
                        if {[llength $vals] > 0} {
                            j $var -body [lindex $vals 0]
                        } else {
                            j $var
                        }
                    }
                }
            }]
        }
    }

    # --- Internal handlers ---

    method OnReady {} {
        $conn write [::jab::header "" to $options(-domain)]
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
                set err [stanza_error $stanza]
                set errText [dict get $err text]
                if {$errText eq ""} {
                    set errText [dict get $err condition]
                    if {$errText eq "unknown"} {
                        set errText "Registration failed"
                    }
                }
                set submitting 0
                $self FireEvent <Error> -message $errText
            }
        }
    }

    method HandleRegForm {queryNode} {
        # Match the data-form namespace, not any <x> (could be an OOB redirect)
        set xForm [xsearch $queryNode x -ns jabber:x:data -get node]
        if {$xForm ne ""} {
            set form [::tacky::forms::parse $xForm]
        } else {
            # Legacy fields — synthesise a forms-compatible node
            set form [::tacky::forms::parse [$self LegacyToForm $queryNode]]
        }

        if {[llength [dict get $form fields]] == 0} {
            # No in-band fields; server may redirect to a web page via OOB
            set url [string trim [xsearch $queryNode x -ns jabber:x:oob url -get body]]
            if {$url ne ""} {
                $self FireEvent <Error> -message "This server requires web registration at $url"
            } else {
                set instr [string trim [xsearch $queryNode instructions -get body]]
                $self FireEvent <Error> -message [expr {$instr ne "" ? $instr : "Server offered no registration fields"}]
            }
            return
        }

        if {$currentForm ne ""} {
            set old $currentForm
            if {$Redialling} {
                # What the user typed, but for what only the old form's
                # captcha or the server could say.
                set typed {}
                foreach field [dict get $old fields] {
                    set var [dict get $field var]
                    if {[dict get $field type] in {hidden fixed} || [dict exists $field media]
                            || ![dict exists $Resubmit $var]} continue
                    dict set typed $var [dict get $Resubmit $var]
                }
                set old [::tacky::forms::apply $old $typed]
            }
            set form [::tacky::forms::restore $old $form]
        }
        set currentForm $form
        set mediaBytes {}
        set FormLive 1

        if {$Redialling} {
            set Redialling 0
            set resend [$self Resendable $Resubmit]
            set Resubmit {}
            if {$resend ne ""} {
                $self Submit [lindex $resend 1]
                return
            }
            jlog debug "register: the form fetched again asks the user again"
        }

        # Extract inline BOB <data> elements and push media data.
        # Collect media vars first, then emit <Form> before <MediaReady>
        # so the GUI creates the form widget before requesting media data
        # via async callbacks.
        set mediaFields [::tacky::forms::mediaMap $currentForm]
        set readyVars {}
        foreach dataNode [xsearch $queryNode data -ns urn:xmpp:bob] {
            set cid [xsearch $dataNode -get @cid]
            if {[dict exists $mediaFields $cid]} {
                set var [dict get $mediaFields $cid]
                # Decoded here: callers get image bytes, and the JSON wire
                # re-encodes them once.
                set b64 [string map {\n "" \r "" " " "" \t ""} \
                    [dict get $dataNode body]]
                dict set mediaBytes $var [::base64::decode $b64]
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
                j instructions -body $instructions
            }
            foreach child $fields {
                set ctag [dict get $child tag]
                set ftype [expr {$ctag eq "password" ? "text-private" : "text-single"}]
                set val [dict get $child body]
                j field -var $ctag -type $ftype -label $ctag {
                    if {$val ne ""} {
                        j value -body $val
                    }
                }
            }
        }
    }

    # The stream ended: an error before the form, as the transport said
    # it; nothing while the form is merely open (the submit dials again);
    # ClosedText when the submit's answer, or the form fetched again, can
    # no longer come.
    method OnError {msg} {
        if {$Redialling} {
            jlog warn "register: dialling again failed: $msg"
            set Lost 1
            $self FireEvent <Error> -message $ClosedText
            return
        }
        if {!$FormLive} {
            $self FireEvent <Error> -message $msg
            return
        }
        set FormLive 0
        set Lost 1
        if {$submitting} {
            set submitting 0
            jlog warn "register: the server closed the stream before answering the submit: $msg"
            $self FireEvent <Error> -message $ClosedText
            return
        }
        jlog debug "register: the server closed the stream while the form is open ($msg)"
    }

    method FireEvent {event args} {
        if {$event eq "<Error>"} {
            set Redialling 0
            set Resubmit {}
        }
        if {$options(-callback) ne ""} {
            {*}$options(-callback) $event {*}$args
        }
    }
}
