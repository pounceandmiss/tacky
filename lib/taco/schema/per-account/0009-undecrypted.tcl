# An incoming OMEMO message we could not decrypt yet: stored with a
# placeholder body, and decrypted again (the row put right in place) when its
# archive copy comes round once more.
if {"undecrypted" ni [$db eval {SELECT name FROM pragma_table_info('chat_message')}]} {
    $db eval {ALTER TABLE chat_message ADD COLUMN undecrypted INTEGER NOT NULL DEFAULT 0}
}
$db eval {
    CREATE INDEX IF NOT EXISTS idx_chat_message_undecrypted
        ON chat_message(chat_jid, timestamp) WHERE undecrypted=1;
}
