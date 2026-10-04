# The schema as it stood when migrations began.
#
# Builds before migrations left no version in accounts.db, so a database at
# version 0 can have any older shape. That is why this step, unlike every
# later one, uses CREATE ... IF NOT EXISTS and checks each column before its
# ALTER TABLE: it keeps those databases working, whichever build made them.
# Later steps know what is there from the version and change it outright.

$db eval {
    CREATE TABLE IF NOT EXISTS account(
        jid PRIMARY KEY,
        username,
        domain,
        port INTEGER NOT NULL DEFAULT 5222,
        password,
        resource,
        enabled INTEGER DEFAULT 0,
        websocket_url TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS setting(key PRIMARY KEY, value DEFAULT '');
}

set columns [$db eval {SELECT name FROM pragma_table_info('account')}]
foreach {col def} {
    port          {INTEGER NOT NULL DEFAULT 5222}
    websocket_url {TEXT NOT NULL DEFAULT ''}
} {
    if {$col ni $columns} {
        $db eval "ALTER TABLE account ADD COLUMN $col $def"
    }
}
