-- XEP-0308 corrections and XEP-0424/0425 retractions whose target message
-- is not stored yet. An archive is walked newest first, so a correction
-- or retraction routinely arrives before its target; it waits here and is
-- applied when a message with that id is stored. `patch` is the parsed
-- verdict as a Tcl dict, authorized again against the target on arrival.
CREATE TABLE IF NOT EXISTS pending_patch(
    chat_jid   TEXT NOT NULL,
    target_id  TEXT NOT NULL,
    kind       TEXT NOT NULL,
    timestamp  INTEGER NOT NULL,
    patch      TEXT NOT NULL,
    PRIMARY KEY(chat_jid, target_id, kind, timestamp)
);
