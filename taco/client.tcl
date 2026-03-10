snit::type taco_client {
    taco_modules message mam roster bookmarks caps presence avatar muc

    component conn -public conn
    component iq -public iq

    # Database handle (exposed as component for direct access: $client db eval {...})
    component db -public db

    # Connection options
    option -host -default ""
    option -port -default 5222
    option -username -default ""
    option -password -default ""
    option -resource -default "tacky"

    # Tacky singleton for account persistence
    option -taco -default ::taco

    # Full JID assigned by the server after binding
    option -jid -default ""

    # Database or database path - if neither provided, creates in-memory db
    option -db -default "" -readonly yes
    option -db-path -default ":memory:" -readonly yes

    delegate method connect to conn

    constructor args {
        $self configurelist $args

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

        # Create connection
        install conn using conn $self.conn \
            -host $options(-host) \
            -port $options(-port) \
            -username $options(-username) \
            -password $options(-password) \
            -resource $options(-resource) \
            -autoreconnect 1 \
            -emit [mymethod emit] \
            -onbound [mymethod OnBound] \
            -onready [mymethod OnReady] \
            -onautherror [mymethod OnAuthError] \
            -ondisconnect [mymethod OnDisconnect] \
            -onstanza [mymethod OnStanza]

        # Create IQ handler
        install iq using iq $self.iq -send-command [mymethod write]

        # Create modules
        $self InitModules
    }

    method InitModules {} {
        foreach mod $_modules {
            install $mod using taco_$mod $self.$mod -client $self
        }
    }

    method NotifyModules {method args} {
        foreach mod $_modules {
            $self.$mod $method {*}$args
        }
    }

    method disconnect {} {
        $conn close
    }

    method write {stanza} {
        $conn write $stanza
    }

    method emit {module event args} {
        if {$module eq "sm" && $event eq "<Ack>"} {
            $message OnSmAck [dict get $args -stanzas]
        }
        if {$module eq "muc" && $event eq "<Joined>"} {
            $message OnMucJoined [dict get $args -jid]
        }
        set acc $options(-jid)
        if {$acc eq ""} {
            set acc "$options(-username)@$options(-host)"
        }
        tacky emit $module $event -acc [jid bare $acc] {*}$args
    }

    method OnBound {} {
        $conn writeImmediate [j presence {j /as-is [$caps cNode]}]
    }

    method OnReady {resumed} {
        set options(-jid) [$conn cget -bound-jid]
        if {!$resumed} {
            $self NotifyModules OnReady
        }
    }

    method OnDisconnect {msg} {
        $self NotifyModules OnDisconnect
    }

    method OnAuthError {msg} {
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
        catch {$conn destroy}
        catch {$iq destroy}
        # Only destroy db if we created it
        if {[info commands $self.db] ne ""} {
            catch {$self.db close}
        }
    }
}
