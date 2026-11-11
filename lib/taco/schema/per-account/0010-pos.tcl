# A message gets an id of its own and a place in its chat (pos), apart from
# its timestamp. The timestamp had been all three, and two clocks stamp
# messages (ours on live ones, the server's on archived ones), so ordering by
# it put messages, and the gaps between them, in the wrong places. pos is an
# order key (see poskey): where a message sits among the others, which a page
# fetched into a gap goes between without anything moving.
#
# SQLite cannot change a primary key in place, so chat_message is built anew.
# Each row keeps its rowid as its id, which keeps msg_fts (indexed by rowid)
# valid, and its pos counts up in the order the timestamps gave. Ids count up
# and are never given out twice (AUTOINCREMENT).

$db function poskey_nth -deterministic {poskey nth}

set columns [list apply {{db table} {
    $db eval "SELECT name FROM pragma_table_info('$table')"
}} $db]

# Each part looks before it changes anything, as the earlier steps do, so a
# database already in this shape passes through unchanged.
if {"pos" ni [{*}$columns chat_message]} {
$db eval {
    CREATE TABLE chat_message_new(
        -- never reused: a frontend may still hold one whose row is gone,
        -- and "stored before" is told by comparing them.
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        -- where the row sits in its chat (see poskey); unique per chat.
        pos            TEXT NOT NULL,
        -- when it was sent, as its source stamped it: the server for
        -- archived and delayed messages, our clock for live ones. For
        -- display; not an identity or an order.
        timestamp      INTEGER NOT NULL,
        chat_jid       TEXT NOT NULL,
        from_jid       TEXT,
        -- Stanza @from resource for 1:1 chats (the sending
        -- client tag — debug metadata, not identity). Empty
        -- for MUC, where the resource is the nick and lives
        -- in from_jid.
        from_resource  TEXT,
        body           TEXT,
        -- server-assigned, for MAM pagination;
        -- <stanza-id id='...' by='server.example.com'/>
        server_id      TEXT,
        -- set only for outgoing messages sent from this client; = <message id="...">
        -- incoming messages have own_id=""
        own_id         TEXT,
        -- this message's own id: <origin-id> if present else @id.
        -- reply-target lookup key; NOT used for dedup.
        origin_id      TEXT,
        -- XEP-0421 sender occupant-id (MUC only, "" for 1:1 and
        -- rooms without 0421). Stable identity for authorizing
        -- edits/retractions and attribution across nick changes.
        occupant_id    TEXT,
        -- XEP-0308 correction: timestamp of the applied edit
        -- (0 = not edited). Doubles as the last-writer-wins guard.
        edited_ts      INTEGER NOT NULL DEFAULT 0,
        -- XEP-0424/0425 retraction tombstone (sticky once set).
        retracted      INTEGER NOT NULL DEFAULT 0,
        -- XEP-0461 reply: target message id + addressed author.
        -- reply_id resolves against server_id/origin_id/own_id;
        -- reply_to disambiguates client-generated id matches.
        reply_id       TEXT,
        reply_to       TEXT,
        -- debug-only readable record of the stanza
        raw_xml        TEXT,
        -- 'message' (default) | 'hole'
        kind           TEXT NOT NULL DEFAULT 'message',
        -- '' = the server has this exact message (incoming, MAM,
        --   carbon, or a confirmed send - all the same situation);
        -- 'pending'/'uploading'/'failed' = our outgoing message
        --   whose server storage state we don't (yet) know.
        server_status  TEXT,
        -- far-side delivery/read progress from XEP-0184/0333
        -- markers, distinct from server_status (the send pipeline).
        -- 'none' (default) | 'delivered' | 'read'. Forward-only.
        -- Meaningful for outgoing rows only.
        remote_status  TEXT NOT NULL DEFAULT 'none',
        -- intended outgoing encryption, stamped at send time:
        -- '' = plaintext, 'omemo' = OMEMO. Automatic retries
        -- honor this so a later toggle change can't silently
        -- downgrade a pending encrypted send; only an explicit
        -- user resend rewrites it.
        encryption     TEXT NOT NULL DEFAULT '',
        -- fingerprint of the OMEMO session that decrypted this
        -- message; '' for cleartext and for our own sends. A
        -- correction must come from the same identity to rewrite it.
        sender_fp      TEXT NOT NULL DEFAULT '',
        -- why a send failed (set with server_status='failed',
        -- '' otherwise). Distinct from `encryption`, which is
        -- intent not outcome. Categories: 'encrypt' (OMEMO
        -- couldn't produce ciphertext - no usable recipients).
        -- Reserved for a future delivery-failure path: 'send'.
        fail_reason    TEXT NOT NULL DEFAULT '',
        -- the body named our MUC nick (room messages only; 1:1 has
        -- nothing to mention). Stamped at ingest, so the live and
        -- MAM paths agree and counts stay in SQL.
        mentions_me    INTEGER NOT NULL DEFAULT 0,
        -- Tcl list of attachment dicts {url type name size mime};
        -- derived from XEP-0066 OOB / URL bodies on store. Empty
        -- for plain text messages.
        attachments    TEXT,
        -- room invitation dict {room inviter reason password}
        -- (see ParseInvite); empty for anything else.
        invite         TEXT,
        -- the invite's room, to find a room's invites; '' else.
        invite_room    TEXT NOT NULL DEFAULT '',
        -- turned down with `muc decline_invite`.
        invite_declined INTEGER NOT NULL DEFAULT 0,
        -- XEP-0482 group call invite {room id inviter video}
        -- (see ParseCallInvite); empty for anything else.
        call           TEXT,
        -- the call's room and invite id, to find its rows; '' else.
        call_room      TEXT NOT NULL DEFAULT '',
        call_id        TEXT NOT NULL DEFAULT '',
        -- what became of it for us: '' (pending), joined, declined,
        -- missed, elsewhere (another device of ours), ended.
        call_state     TEXT NOT NULL DEFAULT '',
        -- which clock stamped edited_ts, and for a local one the
        -- newest server stamp the chat had shown (see PatchWins).
        edited_clock   TEXT NOT NULL DEFAULT '',
        edited_after   INTEGER NOT NULL DEFAULT 0,
        -- an OMEMO message not decrypted yet: 1 to retry when its
        -- archive copy comes round, 2 given up.
        undecrypted    INTEGER NOT NULL DEFAULT 0,
        UNIQUE(chat_jid, pos)
    );
}

set cols {timestamp chat_jid from_jid from_resource body server_id own_id
          origin_id occupant_id edited_ts retracted reply_id reply_to raw_xml
          kind server_status remote_status encryption sender_fp fail_reason
          mentions_me attachments invite invite_room invite_declined call
          call_room call_id call_state edited_clock edited_after undecrypted}
set list [join $cols ", "]
$db eval "
    INSERT INTO chat_message_new(id, pos, $list)
    SELECT rowid,
           poskey_nth(ROW_NUMBER() OVER (PARTITION BY chat_jid
                                         ORDER BY timestamp) - 1),
           $list
    FROM chat_message
"
}

# A correction's aliases name the row they corrected by its id now, and our
# read mark carries the place it reached.
if {"target_ts" in [{*}$columns message_alias]} {
$db eval {
    CREATE TABLE message_alias_new(
        chat_jid   TEXT NOT NULL,
        kind       TEXT NOT NULL,
        alias_id   TEXT NOT NULL,
        target_id  INTEGER NOT NULL,
        PRIMARY KEY(chat_jid, kind, alias_id)
    );
    INSERT INTO message_alias_new(chat_jid, kind, alias_id, target_id)
    SELECT a.chat_jid, a.kind, a.alias_id, m.id
    FROM message_alias a JOIN chat_message_new m
      ON m.chat_jid=a.chat_jid AND m.timestamp=a.target_ts;
    DROP TABLE message_alias;
    ALTER TABLE message_alias_new RENAME TO message_alias;
    CREATE INDEX message_alias_target ON message_alias(chat_jid, target_id);
}
}

set rows [expr {[$db exists {SELECT 1 FROM sqlite_master
                              WHERE name='chat_message_new'}]
               ? "chat_message_new" : "chat_message"}]
if {"read_pos" ni [{*}$columns chat_own_read]} {
$db eval "
    ALTER TABLE chat_own_read ADD COLUMN read_pos TEXT NOT NULL DEFAULT '';
    UPDATE chat_own_read SET read_pos = COALESCE((
        SELECT m.pos FROM $rows m
        WHERE m.chat_jid=chat_own_read.chat_jid
          AND m.timestamp <= chat_own_read.read_ts
        ORDER BY m.timestamp DESC LIMIT 1), '');
"
}

if {$rows eq "chat_message_new"} {
$db eval {
    DROP TABLE chat_message;
    ALTER TABLE chat_message_new RENAME TO chat_message;

    CREATE INDEX idx_chat_message_ts ON chat_message(chat_jid, timestamp);
    CREATE INDEX idx_chat_message_server_id
        ON chat_message(chat_jid, server_id) WHERE server_id != '';
    CREATE INDEX idx_chat_message_own_id
        ON chat_message(chat_jid, own_id) WHERE own_id != '';
    CREATE INDEX idx_chat_message_origin_id
        ON chat_message(chat_jid, origin_id) WHERE origin_id != '';
    CREATE INDEX idx_chat_message_hole
        ON chat_message(chat_jid, pos) WHERE kind='hole';
    CREATE INDEX idx_chat_message_invite_room
        ON chat_message(invite_room) WHERE invite_room != '';
    CREATE INDEX idx_chat_message_call_room
        ON chat_message(call_room) WHERE call_room != '';
    CREATE INDEX idx_chat_message_pending
        ON chat_message(id) WHERE server_status='pending';
    CREATE INDEX idx_chat_message_undecrypted
        ON chat_message(chat_jid, pos) WHERE undecrypted=1;

    CREATE TRIGGER msg_fts_insert
    AFTER INSERT ON chat_message WHEN new.kind='message' BEGIN
        INSERT INTO msg_fts(rowid, body) VALUES(new.id, new.body);
    END;
    CREATE TRIGGER msg_fts_delete
    AFTER DELETE ON chat_message WHEN old.kind='message' BEGIN
        INSERT INTO msg_fts(msg_fts, rowid, body)
        VALUES('delete', old.id, old.body);
    END;
    CREATE TRIGGER msg_fts_update
    AFTER UPDATE OF body ON chat_message WHEN old.kind='message' BEGIN
        INSERT INTO msg_fts(msg_fts, rowid, body)
        VALUES('delete', old.id, old.body);
        INSERT INTO msg_fts(rowid, body) VALUES(new.id, new.body);
    END;
}
}
