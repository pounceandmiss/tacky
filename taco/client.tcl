snit::type taco_client {
    taco_modules message mam roster caps bookmarks presence avatar muc vcard nick chats

    component conn -public conn
    component iq -public iq
    component bus -public bus

    # Database handle (exposed as component for direct access: $client db eval {...})
    component db -public db

    # Connection options (delegated to conn)
    delegate option -host to conn
    delegate option -port to conn
    delegate option -username to conn
    delegate option -password to conn
    delegate option -resource to conn

    # Tacky singleton for account persistence
    option -taco -default ::taco

    # Full JID assigned by the server after binding
    option -jid -default ""

    # Database or database path - if neither provided, creates in-memory db
    option -db -default "" -readonly yes
    option -db-path -default ":memory:" -readonly yes

    delegate method connect to conn

    constructor args {
        # Install conn first so delegated options (-host, -port, etc.) have a target
        install conn using conn $self.conn \
            -autoreconnect 1 \
            -emit [mymethod emit] \
            -onbound [mymethod OnBound] \
            -onready [mymethod OnReady] \
            -onautherror [mymethod OnAuthError] \
            -ondisconnect [mymethod OnDisconnect] \
            -onstanza [mymethod OnStanza]

        $self configurelist $args
        set options(-jid) "[$conn cget -username]@[$conn cget -host]"

        # Initialize database if not provided externally
        if {$options(-db) ne ""} {
            set db $options(-db)
        } else {
            sqlite3 $self.db $options(-db-path)
            set db $self.db
            set options(-db) $self.db
            $db eval {
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
            }
        }

        # Create IQ handler
        install iq using iq $self.iq -send-command [mymethod write]

        # Create internal pub/sub bus
        install bus using taco_client_bus $self.bus

        # Create modules
        $self InitModules
    }

    method InitModules {} {
        foreach mod $_modules {
            install $mod using taco_$mod $self.$mod -client $self
        }
    }

    method disconnect {} {
        $conn close
    }

    method write {stanza} {
        $conn write $stanza
    }

    method emit {module event args} {
        $bus publish ${module}:${event} {*}$args
        tacky emit $module $event -acc [jid bare $options(-jid)] {*}$args
    }

    method OnBound {} {
        set options(-jid) [$conn cget -bound-jid]
        $conn writeImmediate [j presence {j /as-is [$caps cNode]}]
    }

    method OnReady {resumed} {
        set options(-jid) [$conn cget -bound-jid]
        if {!$resumed} {
            $bus publish <Ready>
        }
    }

    method OnDisconnect {msg} {
        $bus publish <Disconnect>
    }

    method OnAuthError {msg} {
    }

    # XEP-0077 password change.
    # -command callback: {*}$cmd ok "" | {*}$cmd error $msg
    method changePassword {args} {
	array set opts {-command ""}
	array set opts $args

	set payload [j query -ns jabber:iq:register {
	    j username #body [$conn cget -username]
	    j password #body $opts(-password)
	}]
	$iq request -type set -to [$conn cget -host] \
	    -payload $payload \
	    -command [mymethod OnPasswordChanged $opts(-password) $opts(-command)]
    }

    method OnPasswordChanged {newPassword command stanza} {
	if {$command eq ""} return
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "result"} {
	    $conn configure -password $newPassword
	    set acc [jid bare $options(-jid)]
	    $options(-taco) account set -acc $acc -password $newPassword
	    {*}$command ok ""
	} else {
	    set errText [xsearch $stanza error text -get body]
	    if {$errText eq ""} {
		set errChild [xsearch $stanza error 0 -get node]
		if {$errChild ne ""} {
		    set errText [dict get $errChild tag]
		} else {
		    set errText "Password change failed"
		}
	    }
	    {*}$command error $errText
	}
    }

    method OnStanza {stanza} {
        set tag [dict get $stanza tag]
        switch -- $tag {
            iq       { $iq feed $stanza }
            message  {
                # Handler chain — first claimer wins:
                #   mam:     MAM result stanzas → message.tcl backfill path
                #   muc:     groupchat → store under room@muc?join
                #            MUC PM    → store under room@muc/nick
                #            invites, declines, voice requests, config changes
                #   message: DM        → store under user@domain
                #            PubSub event dispatch
                if {[$mam onResultMessage $stanza]} return
                if {[$muc OnMessage $stanza]} return
                $message OnMessage $stanza
            }
            presence {
                $caps OnPresence $stanza
                set type_ [xsearch $stanza -get @type]
                if {$type_ in {subscribe subscribed unsubscribe unsubscribed}} {
                    $roster OnSubscription $stanza
                } else {
                    $muc OnPresence $stanza
                    $presence OnPresence $stanza
                }
            }
        }
    }

    destructor {
        foreach mod $_modules {
            catch {$self.$mod destroy}
        }
        catch {$bus destroy}
        catch {$conn destroy}
        catch {$iq destroy}
        # Only destroy db if we created it
        if {[info commands $self.db] ne ""} {
            catch {$self.db close}
        }
    }
}

# Internal pub/sub bus for backend module communication.
# Modules subscribe in their constructors, unsubscribe in destructors.
# Can't use the tacky event system here as it may be sending events
# to another thread.
snit::type taco_client_bus {
    variable Subs       ;# dict: event -> list of {tag command}

    constructor args {
	set Subs [dict create]
    }

    method subscribe {tag event cmd} {
	dict lappend Subs $event [list $tag $cmd]
    }

    method unsubscribe {tag} {
	dict for {event entries} $Subs {
	    set filtered {}
	    foreach entry $entries {
		if {[lindex $entry 0] ne $tag} {
		    lappend filtered $entry
		}
	    }
	    if {[llength $filtered] == 0} {
		dict unset Subs $event
	    } else {
		dict set Subs $event $filtered
	    }
	}
    }

    method publish {event args} {
	if {![dict exists $Subs $event]} return
	foreach entry [dict get $Subs $event] {
	    {*}[lindex $entry 1] {*}$args
	}
    }
}
