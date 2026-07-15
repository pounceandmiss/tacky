snit::type taco_client {
    taco_modules message pubsub mam roster caps bookmarks presence avatar muc vcard nick chats chatlist author extdisco calls omemo file

    component conn -public conn
    component iq -public iq
    component bus -public bus

    # Per-account settings - the taco-level store is shared by all accounts
    component setting -public setting

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
            -onresourceconflict [mymethod OnResourceConflict] \
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

        install setting using taco_setting $self.setting -db $db -taco $self

        # Create IQ handler
        install iq using iq $self.iq -send-command [mymethod write] \
            -own-jid-command [mymethod cget -jid]

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
            # XEP-0280: ask the server to carbon-copy messages sent and
            # received by our other resources. Stream resumption preserves
            # carbons state, so only enable on a fresh session.
            $iq request -type set \
                -payload [j enable -ns urn:xmpp:carbons:2]
            $bus publish <Ready>
        }
    }

    method OnDisconnect {msg} {
        $bus publish <Disconnect>
    }

    method OnAuthError {msg} {
    }

    # Server rejected the bind with <conflict/> (our resource is already in
    # use): mint a fresh one, persist it, and reconnect with it.
    method OnResourceConflict {} {
        set acc [jid bare $options(-jid)]
        set new [$options(-taco) account rerollResource -acc $acc]
        $conn configure -resource $new
        $conn connect
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

    # RFC 6121 §8.1.1.2: an inbound stanza with no 'to' is addressed
    # to our bare JID. Fill it in at ingress so downstream consumers
    # can read @to without special-casing the empty case.
    method ensureTo {stanza} {
        if {![dict exists $stanza attrs to]
            || [dict get $stanza attrs to] eq ""} {
            dict set stanza attrs to [jid bare $options(-jid)]
        }
        return $stanza
    }

    # XEP-0280 carbon unwrap. Returns the forwarded inner <message> if
    # $stanza is a <sent> or <received> carbon from our own bare JID;
    # empty string otherwise (not a carbon, or a forged one from a
    # foreign JID we must ignore per §11).
    method UnwrapCarbon {stanza} {
        set ns urn:xmpp:carbons:2
        foreach kind {sent received} {
            set wrap [xsearch $stanza $kind -ns $ns -get node]
            if {$wrap eq ""} continue
            set from [xsearch $stanza -get @from]
            if {![jid fromMe $from $options(-jid)]} return
            set fwd [xsearch $wrap forwarded \
                -ns urn:xmpp:forward:0 -get node]
            if {$fwd eq ""} return
            set inner [xsearch $fwd message -get node]
            if {$inner eq ""} return
            return [$self ensureTo $inner]
        }
        return
    }

    method OnStanza {stanza} {
        set tag [dict get $stanza tag]
        if {$tag in {message iq presence}} {
            set stanza [$self ensureTo $stanza]
        }
        switch -- $tag {
            iq       { $iq feed $stanza }
            message  {
                # Replace carbon wrappers with their inner forwarded
                # message so the rest of the chain sees one shape.
                set unwrapped [$self UnwrapCarbon $stanza]
                if {$unwrapped ne ""} { set stanza $unwrapped }

                # Handler chain — first claimer wins:
                #   mam:     MAM result stanzas → message.tcl backfill path
                #   muc:     groupchat → store under room@muc?join
                #            MUC PM    → store under room@muc/nick
                #            invites, declines, voice requests, config changes
                #   pubsub:  XEP-0060 event stanzas → per-node handler
                #   calls:   XEP-0353 JMI propose/proceed/reject/retract
                #   omemo:   XEP-0384 <encrypted> → decrypts and re-injects
                #            a synthesised plaintext <message> back into
                #            the chain (claims the encrypted original).
                #   message: DM        → store under user@domain
                if {[$mam onResultMessage $stanza]} return
                if {[$muc OnMessage $stanza]} return
                if {[$pubsub OnMessage $stanza]} return
                if {[$calls OnMessage $stanza]} return
                if {[$omemo OnMessage $stanza]} return
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
        catch {$setting destroy}
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
