-- Opaque per-chat frontend data. No row when empty.
CREATE TABLE IF NOT EXISTS chat_client_data(
    chat_jid  TEXT PRIMARY KEY,
    data      TEXT NOT NULL
);
