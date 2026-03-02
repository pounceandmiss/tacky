snit::type taco_client {
    taco_modules roster bookmarks caps presence avatar

    component conn -public conn
    component iq -public iq
    component message -public message

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

        # Create message router
        install message using taco_message $self.message

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
        $presence OnDisconnect
    }

    method OnAuthError {msg} {
    }

    method OnStanza {stanza} {
        set tag [dict get $stanza tag]
        switch -- $tag {
            iq       { $iq feed $stanza }
            message  { $message OnMessage $stanza }
            presence {
                $caps OnPresence $stanza
                set type_ [xsearch $stanza -get @type]
                if {$type_ in {subscribe subscribed unsubscribe unsubscribed}} {
                    $roster OnSubscription $stanza
                } else {
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
        catch {$message destroy}
        # Only destroy db if we created it
        if {[info commands $self.db] ne ""} {
            catch {$self.db close}
        }
    }
}
