# Which clock stamped a correction's or reaction's time: 'server' (the
# archive or a trusted <delay>) or 'local' (ours: our own action, or a live
# stanza with no stamp). '' is from before this was kept, read as 'local'.
# `after` is, for a local one, the newest server stamp the chat had shown
# when it was taken: it happened after that. See messagestore PatchWins.
foreach {table col def} {
    chat_message     edited_clock {TEXT NOT NULL DEFAULT ''}
    chat_message     edited_after {INTEGER NOT NULL DEFAULT 0}
    message_reaction clock        {TEXT NOT NULL DEFAULT ''}
    message_reaction after_ts     {INTEGER NOT NULL DEFAULT 0}
} {
    if {$col ni [$db eval "SELECT name FROM pragma_table_info('$table')"]} {
        $db eval "ALTER TABLE $table ADD COLUMN $col $def"
    }
}

# The newest server stamp seen in each chat, archive or delayed.
$db eval {
    CREATE TABLE IF NOT EXISTS chat_archive_mark(
        chat_jid  TEXT PRIMARY KEY,
        ts        INTEGER NOT NULL
    );
}
