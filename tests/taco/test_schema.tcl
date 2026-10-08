package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# Every table's columns (name, type, notnull, default, pk - not position,
# which ALTER changes), and the names of the indexes and triggers. Two
# databases with the same shape answer the same.
proc schema_shape {db} {
    set shape {}
    foreach {type name} [$db eval {
        SELECT type, name FROM sqlite_schema
        WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
    }] {
        if {$type ne "table"} {
            lappend shape [list $type $name]
            continue
        }
        set cols [$db eval {
            SELECT name, type, "notnull", dflt_value, pk
            FROM pragma_table_info($name) ORDER BY name
        }]
        lappend shape [list table $name $cols]
    }
    return $shape
}

proc schema_fresh_shape {which} {
    sqlite3 ::_freshdb :memory:
    taco_schema_migrate ::_freshdb $which
    set shape [schema_shape ::_freshdb]
    ::_freshdb close
    return $shape
}

proc schema_newest {which} {
    lindex [::taco_schema::Steps [file join $::taco_schema::dir $which]] end 0
}

# A step directory of its own: {name body name body ...}.
proc schema_step_dir {files} {
    set dir [file tempdir tacky-schema-test]
    foreach {name body} $files {
        set f [open [file join $dir $name] w]
        puts -nonewline $f $body
        close $f
    }
    return $dir
}

foreach which {accounts per-account} {
    test schema-fresh-$which "a fresh $which db reaches the newest step, and a second run does nothing" \
        -setup {
            sqlite3 ::_db :memory:
        } -cleanup {
            ::_db close
        } -body {
            taco_schema_migrate ::_db $which
            set first [list [::_db onecolumn {PRAGMA user_version}] [schema_shape ::_db]]
            taco_schema_migrate ::_db $which
            set second [list [::_db onecolumn {PRAGMA user_version}] [schema_shape ::_db]]
            list [expr {[lindex $first 0] == [schema_newest $which]}] \
                 [expr {$first eq $second}]
        } -result {1 1}

    test schema-newer-$which "a $which db from a newer Tacky is refused" \
        -setup {
            sqlite3 ::_db :memory:
            taco_schema_migrate ::_db $which
            ::_db eval "PRAGMA user_version = [expr {[schema_newest $which] + 1}]"
        } -cleanup {
            ::_db close
        } -body {
            list [catch {taco_schema_migrate ::_db $which} msg] \
                 [string match {database is at schema *, newer than*} $msg]
        } -result {1 1}
}

test schema-accounts-upgrade {an accounts.db from before port and websocket_url gains them and the connection columns, rows intact} \
    -setup {
        sqlite3 ::_db :memory:
        ::_db eval {
            CREATE TABLE account(jid PRIMARY KEY, username, domain, password,
                                 resource, enabled INTEGER DEFAULT 0);
            INSERT INTO account(jid, username, domain, password, enabled)
                VALUES('old@example.com', 'old', 'example.com', 'secret', 1);
        }
    } -cleanup {
        ::_db close
    } -body {
        taco_schema_migrate ::_db accounts
        list [::_db eval {SELECT password, enabled, port, websocket_url,
                                 host, tls, srv FROM account}] \
             [expr {[schema_shape ::_db] eq [schema_fresh_shape accounts]}]
    } -result {{secret 1 0 {} {} auto 1} 1}

test schema-accounts-port-becomes-automatic {the old default 5222 becomes automatic; a chosen port stays} \
    -setup {
        sqlite3 ::_db :memory:
        # Only up to the baseline
        set dir [file tempdir tacky-schema-test]
        file copy [file join $::taco_schema::dir accounts 0001-baseline.tcl] $dir
        taco_schema_migrate ::_db accounts -dir $dir
        file delete -force $dir
        ::_db eval {
            INSERT INTO account(jid, username, domain, port)
                VALUES('a@example.com', 'a', 'example.com', 5222),
                      ('b@example.com', 'b', 'example.com', 5300);
        }
    } -cleanup {
        ::_db close
    } -body {
        taco_schema_migrate ::_db accounts
        ::_db eval {SELECT jid, port FROM account ORDER BY jid}
    } -result {a@example.com 0 b@example.com 5300}

# The column checks the baseline took over from the modules, all at once:
# chat_message without its invite and call columns, caps_cache from before
# identities.
test schema-per-account-upgrade {a <jid>.db from before migrations reaches the fresh shape} \
    -setup {
        sqlite3 ::_db :memory:
        taco_schema_migrate ::_db per-account
        ::_db eval {
            DROP INDEX idx_chat_message_invite_room;
            DROP INDEX idx_chat_message_call_room;
            ALTER TABLE chat_message DROP COLUMN invite;
            ALTER TABLE chat_message DROP COLUMN invite_room;
            ALTER TABLE chat_message DROP COLUMN invite_declined;
            ALTER TABLE chat_message DROP COLUMN call;
            ALTER TABLE chat_message DROP COLUMN call_room;
            ALTER TABLE chat_message DROP COLUMN call_id;
            ALTER TABLE chat_message DROP COLUMN call_state;
            DROP TABLE caps_cache;
            CREATE TABLE caps_cache(ver TEXT PRIMARY KEY, features TEXT);
            INSERT INTO caps_cache VALUES('v1', 'urn:x');
            INSERT INTO chat_message(timestamp, chat_jid, from_jid, body)
                VALUES(10, 'alice@example.com', 'alice@example.com', 'hello');
            PRAGMA user_version = 0;
        }
    } -cleanup {
        ::_db close
    } -body {
        taco_schema_migrate ::_db per-account
        list [::_db onecolumn {PRAGMA user_version}] \
             [::_db eval {SELECT body FROM chat_message}] \
             [::_db eval {SELECT count(*) FROM caps_cache}] \
             [expr {[schema_shape ::_db] eq [schema_fresh_shape per-account]}]
    } -result {4 hello 0 1}

test schema-step-kinds {.sql and .tcl steps run in number order} \
    -setup {
        set dir [schema_step_dir {
            0001-table.sql  {CREATE TABLE t(x); INSERT INTO t VALUES(1);}
            0002-row.tcl    {$db eval {INSERT INTO t VALUES(2)}}
            0010-row.sql    {INSERT INTO t VALUES(10);}
        }]
        sqlite3 ::_db :memory:
    } -cleanup {
        ::_db close
        file delete -force $dir
    } -body {
        taco_schema_migrate ::_db test -dir $dir
        list [::_db onecolumn {PRAGMA user_version}] [::_db eval {SELECT x FROM t}]
    } -result {10 {1 2 10}}

test schema-step-atomic {a step that fails leaves the db where it was} \
    -setup {
        set dir [schema_step_dir {
            0001-table.sql  {CREATE TABLE t(x);}
            0002-broken.tcl {$db eval {CREATE TABLE u(y)}; error broken}
        }]
        sqlite3 ::_db :memory:
    } -cleanup {
        ::_db close
        file delete -force $dir
    } -body {
        list [catch {taco_schema_migrate ::_db test -dir $dir} msg] $msg \
             [::_db onecolumn {PRAGMA user_version}] \
             [::_db eval {SELECT name FROM sqlite_schema ORDER BY name}]
    } -result {1 broken 1 t}

test schema-step-twice {two steps with one number is an error} \
    -setup {
        set dir [schema_step_dir {
            0001-a.sql {CREATE TABLE t(x);}
            0001-b.tcl {}
        }]
        sqlite3 ::_db :memory:
    } -cleanup {
        ::_db close
        file delete -force $dir
    } -body {
        list [catch {taco_schema_migrate ::_db test -dir $dir} msg] \
             [string match {schema step 1 used twice:*} $msg] \
             [::_db onecolumn {PRAGMA user_version}]
    } -result {1 1 0}
