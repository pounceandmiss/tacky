-- The ids of a correction (XEP-0308), kept as other names of the message
-- it corrected. Clients refer to a corrected message by its newest
-- correction's ids: a reaction or reply in a room by its stanza-id, a
-- chained correction by its origin-id. `kind` is 'server' (stanza-id) or
-- 'origin' (origin-id, else @id); `target_ts` is the corrected row's.
CREATE TABLE IF NOT EXISTS message_alias(
    chat_jid   TEXT NOT NULL,
    kind       TEXT NOT NULL,
    alias_id   TEXT NOT NULL,
    target_ts  INTEGER NOT NULL,
    PRIMARY KEY(chat_jid, kind, alias_id)
);
CREATE INDEX IF NOT EXISTS message_alias_target
    ON message_alias(chat_jid, target_ts);
