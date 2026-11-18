# A chat's history cleared on this device: archived messages stamped at or
# before floor (µs) are not stored again. 0 = never cleared, or restored.
if {"floor" ni [$db eval {SELECT name FROM pragma_table_info('chat_archive_mark')}]} {
    $db eval {ALTER TABLE chat_archive_mark ADD COLUMN floor INTEGER NOT NULL DEFAULT 0}
}
