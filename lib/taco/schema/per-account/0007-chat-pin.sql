-- Pinned chats, local to this device. No row when not pinned; a higher
-- ord sits nearer the top.
CREATE TABLE IF NOT EXISTS chat_pin(
    chat_jid  TEXT PRIMARY KEY,
    ord       INTEGER NOT NULL
);
