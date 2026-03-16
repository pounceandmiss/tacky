# -command callback signature: $cmd $status $result
#   $status is "ok" or "error"
#
# taco account list ?-command $cmd?
# taco account exists -acc $jid ?-command $cmd?
# taco account add -acc $jid ?-password ...? ?-domain ...? ?-username ...?
#   creates account if new; updates fields if it already exists
# taco account remove -acc $jid
#   error: account doesn't exist
# taco account get -acc $jid ?-field $name? ?-command $cmd?
#   error: account doesn't exist, invalid field
# taco account set -acc $jid ?-password ...? ?-domain ...? ?-username ...?
#   error: account doesn't exist, invalid field
# taco account enable -acc $jid
# taco account disable -acc $jid

snit::type taco_account {
    option -db -default ""
    option -taco -default ""
    option -cache-dir -default ""

    variable valid_columns {username domain password enabled}

    constructor args {
        $self configurelist $args
        $options(-db) eval {
            CREATE TABLE IF NOT EXISTS account(
                jid PRIMARY KEY,
                username,
                domain,
                password,
                enabled INTEGER DEFAULT 0
            );
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
            $self set -acc $jid {*}$fields
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

        dict for {key value} $args {
            if {$key eq "-acc"} continue
            set field [string range $key 1 end]
            if {$field ni $valid_columns} {
                error "Invalid field: $field"
            }
            if {$field eq "enabled"} {
                if {$value} { $self enable -acc $jid } else { $self disable -acc $jid }
            } else {
                $options(-db) eval "UPDATE account SET \"$field\"=\$value WHERE jid=\$jid"
            }
        }
    }

    method remove {args} {
        set jid [dict get $args -acc]
        if {![$self exists -acc $jid]} {
            error "Account doesn't exist: $jid"
        }

        $options(-taco) emit account <Removed> -acc $jid

        # Clean up client object if it exists
        set client $options(-taco).client-$jid
        if {[info commands $client] ne ""} {
            catch {$client disconnect}
            catch {$client destroy}
        }

        $options(-db) eval {DELETE FROM account WHERE jid = $jid}

        # Remove per-account cache database file
        if {$options(-cache-dir) ne ""} {
            file delete [file join $options(-cache-dir) $jid.db]
        }
    }

    method enable {args} {
        set jid [dict get $args -acc]
        set client [$options(-taco) client $jid]

        # Always propagate latest credentials from DB to client/conn
        set pw [$options(-db) onecolumn {SELECT password FROM account WHERE jid=$jid}]
        $client configure -password $pw

        $client connect

        set was_enabled [$options(-db) eval {SELECT enabled FROM account WHERE jid=$jid}]
        if {!$was_enabled} {
            $options(-db) eval {UPDATE account SET enabled=1 WHERE jid=$jid}
            $options(-taco) emit account <Enabled> -acc $jid
        }
    }

    # Server-side password change (XEP-0077), delegates to client.
    # tacky account changePassword -acc $jid -password $new -command $cb
    method changePassword {args} {
	set jid [dict get $args -acc]
	set client [$options(-taco) client $jid]
	$client changePassword {*}[dict remove $args -acc]
    }

    method disable {args} {
        set jid [dict get $args -acc]
        $options(-taco) emit account <Disabled> -acc $jid
        set client $options(-taco).client-$jid
        if {[info commands $client] ne ""} {
            catch {$client disconnect}
        }
        $options(-db) eval {UPDATE account SET enabled=0 WHERE jid=$jid}
    }
}
