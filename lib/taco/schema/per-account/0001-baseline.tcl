# The schema as it stood when migrations began.
#
# Builds before migrations left no version in <jid>.db, so a database at
# version 0 can have any older shape. That is why this step, unlike every
# later one, uses CREATE ... IF NOT EXISTS and checks each column before its
# ALTER TABLE: it keeps those databases working, whichever build made them.
# Later steps know what is there from the version and change it outright.
#
# Grouped by the module that uses each table.

# -- setting ---------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS setting(key PRIMARY KEY, value DEFAULT '');
}

# -- nick ------------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS pep_nick(
        jid TEXT PRIMARY KEY,
        nick TEXT NOT NULL DEFAULT ''
    );
}

# -- bookmarks -------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS bookmark(
        jid TEXT PRIMARY KEY,
        name TEXT,
        autojoin INTEGER DEFAULT 0,
        nick TEXT,
        password TEXT,
        extensions_xml TEXT
    );
    CREATE TABLE IF NOT EXISTS bookmark_config(
        key TEXT PRIMARY KEY,
        value TEXT
    );
}

# -- roster ----------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS roster_item(
        jid PRIMARY KEY,
        name,
        subscription,
        ask,
        approved
    );
    CREATE TABLE IF NOT EXISTS roster_item_group(
        group_name,
        roster_item_jid,
        PRIMARY KEY(group_name, roster_item_jid)
    );
    CREATE TABLE IF NOT EXISTS roster_ver(value);
}

# -- caps ------------------------------------------------------------------

# A pure cache: an older shape is dropped, not migrated.
set columns [$db eval {SELECT name FROM pragma_table_info('caps_cache')}]
if {"identities" ni $columns} {
    $db eval {DROP TABLE IF EXISTS caps_cache}
}
$db eval {
    CREATE TABLE IF NOT EXISTS caps_cache(
        ver TEXT PRIMARY KEY,
        node TEXT,
        identities TEXT,
        features TEXT
    );
}

# -- messagestore ----------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS chat_message(
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
        -- turned down with `muc declineInvite`.
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
        PRIMARY KEY(chat_jid, timestamp)
    );
    CREATE INDEX IF NOT EXISTS idx_chat_message_server_id
        ON chat_message(chat_jid, server_id) WHERE server_id != '';
    CREATE INDEX IF NOT EXISTS idx_chat_message_own_id
        ON chat_message(chat_jid, own_id) WHERE own_id != '';
    CREATE INDEX IF NOT EXISTS idx_chat_message_origin_id
        ON chat_message(chat_jid, origin_id) WHERE origin_id != '';
    CREATE INDEX IF NOT EXISTS idx_chat_message_hole
        ON chat_message(chat_jid, timestamp) WHERE kind='hole';

    -- Full-text index behind `search`. unicode61 folds case for every
    -- script, not just ASCII; the cost is that it indexes whole
    -- words, so only word prefixes are findable. The content stays in
    -- chat_message, indexed by rowid - stable, since nothing VACUUMs
    -- here. The triggers cover every writer.
    CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts USING fts5(
        body, content=chat_message, content_rowid=rowid,
        tokenize='unicode61');

    CREATE TRIGGER IF NOT EXISTS msg_fts_insert
    AFTER INSERT ON chat_message WHEN new.kind='message' BEGIN
        INSERT INTO msg_fts(rowid, body) VALUES(new.rowid, new.body);
    END;

    CREATE TRIGGER IF NOT EXISTS msg_fts_delete
    AFTER DELETE ON chat_message WHEN old.kind='message' BEGIN
        INSERT INTO msg_fts(msg_fts, rowid, body)
        VALUES('delete', old.rowid, old.body);
    END;

    CREATE TRIGGER IF NOT EXISTS msg_fts_update
    AFTER UPDATE OF body ON chat_message WHEN old.kind='message' BEGIN
        INSERT INTO msg_fts(msg_fts, rowid, body)
        VALUES('delete', old.rowid, old.body);
        INSERT INTO msg_fts(rowid, body) VALUES(new.rowid, new.body);
    END;

    -- XEP-0444 reactions. One row per (message, reactor); a
    -- reactor's full current emoji set is a Tcl list in `emojis`
    -- ('' = retracted). Keyed by the wire target_id (referenced
    -- stanza/origin id) so a reaction arriving before its target
    -- message is still stored and surfaced later.
    CREATE TABLE IF NOT EXISTS message_reaction(
        chat_jid     TEXT NOT NULL,
        target_id    TEXT NOT NULL,
        -- dedup key: bare jid (1:1), occupant-id (MUC, ours and
        -- peers'; nick fallback when the room has no XEP-0421).
        -- is_own distinguishes ours.
        sender_id    TEXT NOT NULL,
        -- display label: bare jid (1:1) / nick (MUC).
        sender_label TEXT,
        is_own       INTEGER NOT NULL DEFAULT 0,
        emojis       TEXT,
        -- last-writer-wins high-water mark per reactor.
        ts           INTEGER NOT NULL,
        PRIMARY KEY(chat_jid, target_id, sender_id)
    );

    -- How far we have read each chat ourselves. The peer's read
    -- state of our messages is chat_message.remote_status.
    CREATE TABLE IF NOT EXISTS chat_own_read(
        chat_jid  TEXT PRIMARY KEY,
        -- chat-local timestamp of the newest message we have read.
        read_ts   INTEGER NOT NULL DEFAULT 0,
        -- that row's server_id, else origin_id. Not a lookup key;
        -- carried for a future XEP-0490 publish.
        read_id   TEXT NOT NULL DEFAULT ''
    );

    -- Per-chat notification policy. A row exists only where the user
    -- overrode the derived default (see notifyPolicy); mentions
    -- bypass the mute rather than sharing one axis with it.
    CREATE TABLE IF NOT EXISTS chat_notify(
        chat_jid  TEXT PRIMARY KEY,
        muted     INTEGER NOT NULL DEFAULT 0,
        mentions  INTEGER NOT NULL DEFAULT 1
    );
}
set columns [$db eval {
    SELECT name FROM pragma_table_info('chat_message')
}]
if {"invite" ni $columns} {
    $db transaction {
        $db eval {ALTER TABLE chat_message ADD COLUMN invite TEXT}
        # Room-relayed invites and declines an older store filed as a 1:1
        # chat with the room, and that chat if nothing else is left.
        set phantom {
            kind='message' AND instr(chat_jid, '?') = 0
            AND instr(chat_jid, '/') = 0 AND from_jid = chat_jid
            AND raw_xml LIKE '%http://jabber.org/protocol/muc#user%'
            AND (raw_xml LIKE '%<invite%' OR raw_xml LIKE '%<decline%')
        }
        set jids [$db eval "SELECT DISTINCT chat_jid FROM chat_message
                            WHERE $phantom"]
        $db eval "DELETE FROM chat_message WHERE $phantom"
        foreach jid $jids {
            if {[$db exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
            }]} continue
            $db eval {
                DELETE FROM chat_message WHERE chat_jid=$jid;
                DELETE FROM chat_own_read WHERE chat_jid=$jid;
            }
        }
    }
}
if {"invite_room" ni $columns} {
    $db transaction {
        $db eval {
            ALTER TABLE chat_message
            ADD COLUMN invite_room TEXT NOT NULL DEFAULT ''
        }
        $db eval {
            SELECT chat_jid, timestamp, invite FROM chat_message
            WHERE kind='message' AND invite != ''
        } r {
            if {[catch {dict get $r(invite) room} room]} continue
            $db eval {
                UPDATE chat_message SET invite_room=$room
                WHERE chat_jid=$r(chat_jid) AND timestamp=$r(timestamp)
            }
        }
    }
}
if {"invite_declined" ni $columns} {
    $db eval {
        ALTER TABLE chat_message
        ADD COLUMN invite_declined INTEGER NOT NULL DEFAULT 0
    }
}
$db eval {
    CREATE INDEX IF NOT EXISTS idx_chat_message_invite_room
        ON chat_message(invite_room) WHERE invite_room != '';
}
foreach {col def} {
    call       {TEXT}
    call_room  {TEXT NOT NULL DEFAULT ''}
    call_id    {TEXT NOT NULL DEFAULT ''}
    call_state {TEXT NOT NULL DEFAULT ''}
} {
    if {$col ni $columns} {
        $db eval "ALTER TABLE chat_message ADD COLUMN $col $def"
    }
}
$db eval {
    CREATE INDEX IF NOT EXISTS idx_chat_message_call_room
        ON chat_message(call_room) WHERE call_room != '';
}

# -- avatar ----------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS avatar_metadata(
        jid TEXT PRIMARY KEY,
        hash TEXT NOT NULL,
        type TEXT NOT NULL,
        bytes INTEGER,
        width INTEGER,
        height INTEGER,
        source TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS avatar_data(
        hash TEXT PRIMARY KEY,
        data BLOB NOT NULL
    );
}

# -- omemo -----------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS omemo_store(
        account_jid TEXT PRIMARY KEY,
        device_id   INTEGER NOT NULL,
        blob        BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS omemo_sessions(
        account_jid TEXT NOT NULL,
        peer_jid    TEXT NOT NULL,
        peer_device INTEGER NOT NULL,
        blob        BLOB NOT NULL,
        PRIMARY KEY (account_jid, peer_jid, peer_device)
    );
    CREATE TABLE IF NOT EXISTS omemo_skipped(
        account_jid TEXT NOT NULL,
        peer_jid    TEXT NOT NULL,
        peer_device INTEGER NOT NULL,
        dh          BLOB NOT NULL,
        nr          INTEGER NOT NULL,
        mk          BLOB NOT NULL,
        PRIMARY KEY (account_jid, peer_jid, peer_device, dh, nr)
    );
    CREATE TABLE IF NOT EXISTS omemo_trust(
        account_jid     TEXT NOT NULL,
        peer_jid        TEXT NOT NULL,
        peer_device     INTEGER NOT NULL,
        identity_pk     BLOB NOT NULL,
        trust           TEXT NOT NULL
                        CHECK (trust IN
                            ('undecided','trusted','untrusted','compromised')),
        active          INTEGER NOT NULL DEFAULT 1,
        last_activation INTEGER NOT NULL,
        PRIMARY KEY (account_jid, peer_jid, peer_device)
    );
    CREATE TABLE IF NOT EXISTS omemo_spk(
        account_jid TEXT PRIMARY KEY,
        rotated_at  INTEGER NOT NULL
    );
}

# -- file ------------------------------------------------------------------

$db eval {
    CREATE TABLE IF NOT EXISTS attachment_key(
        hash TEXT PRIMARY KEY,
        iv   BLOB NOT NULL,
        key  BLOB NOT NULL
    )
}
