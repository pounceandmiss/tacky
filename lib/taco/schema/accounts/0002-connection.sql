-- host, tls, srv; port becomes 0 (automatic). SQLite can't change a
-- default in place, hence the rebuild. A stored 5222 was the old default,
-- and automatic dials the same.
CREATE TABLE account_new(
    jid PRIMARY KEY,
    username,
    domain,
    host TEXT NOT NULL DEFAULT '',
    port INTEGER NOT NULL DEFAULT 0,
    tls TEXT NOT NULL DEFAULT 'auto',
    srv INTEGER NOT NULL DEFAULT 1,
    password,
    resource,
    enabled INTEGER DEFAULT 0,
    websocket_url TEXT NOT NULL DEFAULT ''
);
INSERT INTO account_new(jid, username, domain, port, password, resource,
                        enabled, websocket_url)
    SELECT jid, username, domain,
           CASE WHEN port = 5222 THEN 0 ELSE port END,
           password, resource, enabled, websocket_url
    FROM account;
DROP TABLE account;
ALTER TABLE account_new RENAME TO account;
