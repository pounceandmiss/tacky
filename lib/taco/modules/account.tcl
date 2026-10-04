# taco account list ?-command $cmd?
# taco account exists -acc $jid ?-command $cmd?
# taco account add -acc $jid ?-password ...? ?-domain ...? ?-username ...?
#                  ?-port ...? ?-websocket_url ...?
#   creates account if new; updates fields if it already exists
# taco account remove -acc $jid
#   error: account doesn't exist
# taco account get -acc $jid ?-field $name? ?-command $cmd?
#   error: account doesn't exist, invalid field
# taco account set -acc $jid ?-password ...? ?-domain ...? ?-username ...?
#                  ?-port ...? ?-websocket_url ...?
#   error: account doesn't exist, invalid field
#
# port: the tcp transport's port on domain. Ignored over websocket.
# websocket_url: where the websocket transport dials; "" means discover it
# (baseconn's ConnectWebsocket). Ignored over tcp.
# taco account enable -acc $jid
# taco account disable -acc $jid

snit::type taco_account {
    option -db -default ""
    option -taco -default ""
    option -data-dir -default ""

    variable valid_columns {username domain port password resource enabled websocket_url}
    # Added by the transport when a request carries a token, not fields.
    variable transport_opts {-command -onerror -tag}

    constructor args {
        $self configurelist $args
        $options(-db) eval {
            CREATE TABLE IF NOT EXISTS account(
                jid PRIMARY KEY,
                username,
                domain,
                port INTEGER NOT NULL DEFAULT 5222,
                password,
                resource,
                enabled INTEGER DEFAULT 0
            );
        }
        # Older accounts.db files lack these.
        set columns [$options(-db) eval {SELECT name FROM pragma_table_info('account')}]
        foreach {col def} {
            port          {INTEGER NOT NULL DEFAULT 5222}
            websocket_url {TEXT NOT NULL DEFAULT ''}
        } {
            if {$col ni $columns} {
                $options(-db) eval "ALTER TABLE account ADD COLUMN $col $def"
            }
        }
    }

    tackymethod exists {args} {
        set jid [dict get $args -acc]
        $options(-db) eval {SELECT EXISTS(SELECT 1 FROM account WHERE jid=$jid)}
    }

    tackymethod list {args} {
        if {[dict exists $args -enabled]} {
            set enabled [dict get $args -enabled]
            return [$options(-db) eval {SELECT jid FROM account WHERE enabled=$enabled}]
        }
        $options(-db) eval {SELECT jid FROM account}
    }

    method add {args} {
        set jid [dict get $args -acc]
        if {![jid valid-account $jid]} {
            error "Invalid JID: $jid"
        }
        set exists [$self exists -acc $jid]

        if {!$exists} {
            $options(-db) eval {INSERT INTO account(jid) VALUES($jid)}
        }

        set fields [dict remove $args -acc]
        if {!$exists} {
            if {![dict exists $fields -domain]} {
                dict set fields -domain [jid domain $jid]
            }
            if {![dict exists $fields -username]} {
                dict set fields -username [jid username $jid]
            }
        }
        if {[dict size $fields] > 0} {
            $self SetFields $jid $fields
        }

        if {!$exists} {
            $options(-taco) emit account <Added> -acc $jid
        }
    }

    tackymethod get {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }

        if {[dict exists $args -field]} {
            set field [dict get $args -field]
            if {$field ni $valid_columns} {
                error "Invalid field: $field"
            }
            return [$options(-db) onecolumn "SELECT \"$field\" FROM account WHERE jid=\$jid"]
        }

        $options(-db) eval {SELECT * FROM account WHERE jid=$jid} row {
            unset row(*)
            set result [array get row]
        }
        return $result
    }

    method set {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }
        $self SetFields $jid $args
        if {[dict exists $args -password]} {
            $self PushPassword $jid
        }
    }

    # add writes through here, skipping set's PushPassword: enabling the new
    # account connects anyway.
    method SetFields {jid fields} {
        dict for {key value} $fields {
            if {$key eq "-acc" || $key in $transport_opts} continue
            set field [string range $key 1 end]
            if {$field ni $valid_columns} {
                error "Invalid field: $field"
            }
            if {$field eq "websocket_url" && $value ne ""
                    && ![regexp -nocase {^wss?://[^/\s]} $value]} {
                error "Invalid websocket_url: $value"
            }
            if {$field eq "port" && !([string is entier -strict $value]
                    && $value >= 1 && $value <= 65535)} {
                error "Invalid port: $value"
            }
            if {$field eq "enabled"} {
                if {$value} { $self enable -acc $jid } else { $self disable -acc $jid }
            } else {
                $options(-db) eval "UPDATE account SET \"$field\"=\$value WHERE jid=\$jid"
            }
        }
    }

    # Hand a running client the stored password. An enabled account that is
    # offline (e.g. after an auth error) reconnects with it; an online one
    # keeps its session.
    method PushPassword {jid} {
        set client [$self liveClient -acc $jid]
        if {$client eq ""} return
        set pw [$options(-db) onecolumn {SELECT password FROM account WHERE jid=$jid}]
        $client configure -password $pw
        set enabled [$options(-db) onecolumn {SELECT enabled FROM account WHERE jid=$jid}]
        if {$enabled && [$client conn state] in {disconnected waiting}} {
            $client connect
        }
    }

    # Stable per-account resource (tacky.<hex>). Generated and persisted on
    # first use, reused across reconnects. See rerollResource for conflicts.
    tackymethod resource {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }
        set res [$options(-db) onecolumn {SELECT resource FROM account WHERE jid=$jid}]
        if {$res eq ""} {
            set res [GenResource]
            $options(-db) eval {UPDATE account SET resource=$res WHERE jid=$jid}
        }
        return $res
    }

    tackymethod rerollResource {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }
        set res [GenResource]
        $options(-db) eval {UPDATE account SET resource=$res WHERE jid=$jid}
        return $res
    }

    proc GenResource {} {
        return "tacky.[format %08x [expr {int(rand()*0x100000000)}]]"
    }

    method remove {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }

        $options(-taco) emit account <Removed> -acc $jid

        set client [$self liveClient -acc $jid]
        if {$client ne ""} {
            catch {$client disconnect}
            catch {$client destroy}
        }

        $options(-db) eval {DELETE FROM account WHERE jid = $jid}

        # Attachments are hash-keyed and shared across accounts, so they stay.
        if {$options(-data-dir) ne ""} {
            set base [file join $options(-data-dir) $jid.db]
            taco_dbfile delete $base $base-wal $base-shm
        }
    }

    method enable {args} {
        set jid [dict get $args -acc]
        set client [$options(-taco) client $jid]

        # Always propagate latest credentials from DB to client/conn
        lassign [$options(-db) eval {
            SELECT password, port, websocket_url FROM account WHERE jid=$jid
        }] pw port url
        $client configure -password $pw -port $port -ws-url $url

        $client connect

        set was_enabled [$options(-db) eval {SELECT enabled FROM account WHERE jid=$jid}]
        if {!$was_enabled} {
            $options(-db) eval {UPDATE account SET enabled=1 WHERE jid=$jid}
            $options(-taco) emit account <Enabled> -acc $jid
        }
    }

    # Server-side password change (XEP-0077), delegates to client.
    # tacky account changePassword -acc $jid -password $new ?-command $cb? ?-onerror $ecb?
    method changePassword {args} {
        set jid [dict get $args -acc]
        set client [$options(-taco) client $jid]
        $client changePassword {*}[dict remove $args -acc]
    }

    method disable {args} {
        set jid [dict get $args -acc]
        $options(-taco) emit account <Disabled> -acc $jid
        set client [$self liveClient -acc $jid]
        if {$client ne ""} {
            catch {$client disconnect}
        }
        $options(-db) eval {UPDATE account SET enabled=0 WHERE jid=$jid}
    }

    # The client object taco already built for an account, or "" when it has
    # none. Unlike `taco client`, this never constructs one: a dormant account
    # must stay dormant.
    method liveClient {args} {
        set client $options(-taco).client([dict get $args -acc])
        if {[info commands $client] eq ""} { return "" }
        return $client
    }
}
