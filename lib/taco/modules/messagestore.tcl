if 0 {
    Contiguity is implicit: two adjacent stored messages with no
    sentinel between them are trusted to have no gap.

    chat_message holds two row kinds, discriminated by `kind`:

    - kind='message'  a real message (incoming, outgoing pending, or
                      outgoing confirmed). server_id is set once the
                      server has acknowledged it.
    - kind='sentinel' a gap marker placed at moments of doubt
                      (reconnect, initial chat open). chat_jid and
                      timestamp are set; all other columns NULL.

    The "contiguity citizen" predicate is uniform across all queries:

        kind='message' AND server_id != ''

    Sentinels and pending outgoings (server_id='') both fail it and
    are transparently skipped by neighbour lookups, cursor selection,
    and dedup.

    Sentinels are placed by `sentinel add $jid $direction $anchorTs`
    and removed either explicitly (`sentinel remove` on RSM-complete,
    `sentinel removeBetween` for the post-MAM sweep) or implicitly
    when `store` proves overlap against pre-existing cache (the
    batch's bracket span is swept).

    Pagination queries (`get before` / `get after` / `get latest`)
    return `{messages bounded}`. `bounded=1` signals "a sentinel
    truncated the result on the queried side; if you want more in
    this direction, fall through to MAM."

    Outgoing messages stored with server_id="" show up in `get`
    results (so the UI sees them) but fail the citizen check, so
    they don't anchor sentinels or bound queries. On confirmation
    (MUC echo or own MAM result) they gain a server_id and join
    contiguity normally.
}

snit::type taco_messagestore {
    option -db -default ""

    constructor args {
        $self configurelist $args
        $self Migrate
    }

    method Migrate {} {
        $options(-db) eval {
            CREATE TABLE IF NOT EXISTS chat_message(
                timestamp      INTEGER NOT NULL,
                chat_jid       TEXT NOT NULL,
                from_jid       TEXT,
                -- Stanza @from resource for 1:1 chats (the sending
                -- client tag — debug metadata, not identity). Empty
                -- for MUC, where the resource is the nick and lives
                -- in from_jid. raw_xml has the wire-original either way.
                from_resource  TEXT,
                body           TEXT,
                -- server-assigned, for MAM pagination;
                -- <stanza-id id='...' by='server.example.com'/>
                server_id      TEXT,
                -- set only for outgoing messages; = <message id="...">
                -- incoming messages have own_id=""
                own_id         TEXT,
                raw_xml        TEXT,
                -- 'message' (default) | 'sentinel'
                kind           TEXT NOT NULL DEFAULT 'message',
                -- NULL/empty = incoming (already received);
                -- 'pending'   = stored, awaiting server confirmation;
                -- 'received'  = server confirmed via echo or SM ack
                server_status  TEXT,
                PRIMARY KEY(chat_jid, timestamp)
            );
            CREATE INDEX IF NOT EXISTS idx_chat_message_server_id
                ON chat_message(chat_jid, server_id) WHERE server_id != '';
            CREATE INDEX IF NOT EXISTS idx_chat_message_own_id
                ON chat_message(chat_jid, own_id) WHERE own_id != '';
            CREATE INDEX IF NOT EXISTS idx_chat_message_sentinel
                ON chat_message(chat_jid, timestamp) WHERE kind='sentinel';
        }
    }

    # --- Sentinels ------------------------------------------------------

    # Insert a sentinel in the gap immediately $direction of $anchorTs.
    # direction is `older` | `newer`. Enforces at-most-one-per-gap: if a
    # sentinel already lies between $anchorTs and the next citizen in
    # $direction (treating "no citizen on that side" as +/-inf), this is a
    # no-op. Synthetic ts derived via BumpTs one step off the anchor.
    method "sentinel add" {jid direction anchorTs} {
        lassign [$self GapBounds $jid $direction $anchorTs] lo hi
        set exists [$options(-db) onecolumn {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp > $lo AND timestamp < $hi
            LIMIT 1
        }]
        if {$exists ne ""} return
        set step [expr {$direction eq "older" ? -1 : 1}]
        set ts [$self BumpTs $jid [expr {$anchorTs + $step}] $step]
        $options(-db) eval {
            INSERT INTO chat_message(timestamp, chat_jid, kind)
            VALUES($ts, $jid, 'sentinel')
        }
    }

    # Remove any sentinel(s) in the gap immediately $direction of
    # $anchorTs. Invariant says at most one; defensive plural costs the
    # same as a range delete.
    method "sentinel remove" {jid direction anchorTs} {
        lassign [$self GapBounds $jid $direction $anchorTs] lo hi
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp > $lo AND timestamp < $hi
        }
    }

    # Internal: delete sentinels strictly between $loTs and $hiTs.
    # Used by `store` overlap-proof and by post-MAM sweep in message.tcl.
    method "sentinel removeBetween" {jid loTs hiTs} {
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp > $loTs AND timestamp < $hiTs
        }
    }

    # Tests-only: ordered list of sentinel timestamps.
    method "sentinel list" {jid} {
        set rows {}
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
            ORDER BY timestamp ASC
        } row {
            lappend rows $row(timestamp)
        }
        return $rows
    }

    # Bounds of the gap immediately $direction of $anchorTs, inclusive
    # of $anchorTs on the anchor side. Returns {lo hi} with sentinels
    # found via `timestamp > lo AND timestamp < hi`.
    method GapBounds {jid direction anchorTs} {
        switch -- $direction {
            older {
                set bound [$options(-db) onecolumn {
                    SELECT MAX(timestamp) FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND server_id IS NOT NULL AND server_id != ''
                      AND timestamp < $anchorTs
                }]
                set lo [expr {$bound eq "" ? -9223372036854775807 : $bound}]
                set hi $anchorTs
            }
            newer {
                set bound [$options(-db) onecolumn {
                    SELECT MIN(timestamp) FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND server_id IS NOT NULL AND server_id != ''
                      AND timestamp > $anchorTs
                }]
                set lo $anchorTs
                set hi [expr {$bound eq "" ? 9223372036854775807 : $bound}]
            }
            default {
                error "direction must be older or newer, got: $direction"
            }
        }
        return [list $lo $hi]
    }

    # --- Store ----------------------------------------------------------

    # Insert messages. Deduplicates by server_id/own_id (or content
    # fallback). Pending outgoings matched by own_id are confirmed
    # (server_id captured, timestamp adjusted to server's value).
    # When the batch contains at least one real-overlap dup hit (a
    # row that already had a server_id), the entire batch's bracket
    # is swept of sentinels — RSM guarantees the batch is server-
    # contiguous, so any sentinel inside the bracket marked a gap
    # we've now proven empty.
    # Returns dict with `confirmed` (list of {own_id, timestamp,
    # newtimestamp}) and `inserted` (list of stored timestamps).
    method store {messages} {
        if {[llength $messages] == 0} { return {} }

        set jid [dict get [lindex $messages 0] chat_jid]

        # Bracket: input timestamps from the server tell us the
        # contiguous range. BumpTs may shift stored ts by a microsecond
        # on collision, but the input range is what RSM guarantees.
        set batchMinTs ""
        set batchMaxTs ""
        foreach msg $messages {
            set t [dict get $msg timestamp]
            if {$batchMinTs eq "" || $t < $batchMinTs} { set batchMinTs $t }
            if {$batchMaxTs eq "" || $t > $batchMaxTs} { set batchMaxTs $t }
        }

        set hadRealOverlap 0
        set confirmed {}
        set insertedTimestamps {}
        set prevTs -1

        $options(-db) transaction {
            foreach msg $messages {
                array unset m
                array set m $msg

                set dup [$self IsDuplicate $jid $msg]
                if {$dup ne ""} {
                    if {[dict get $dup server_status] eq "pending"} {
                        # Pending outgoing confirmed by server echo or
                        # MAM result. Move timestamp to server's value
                        # and set server_id. Not an overlap proof —
                        # the pending row was server-invisible until
                        # now, so it didn't bound any sentinel.
                        set dupTs [dict get $dup timestamp]
                        set sid $m(server_id)
                        if {$m(timestamp) == $dupTs} {
                            set newTs $dupTs
                        } else {
                            set newTs [$self BumpTs $jid $m(timestamp) 1]
                        }
                        $options(-db) eval {
                            UPDATE chat_message
                            SET timestamp=$newTs,
                                server_status='received',
                                server_id = CASE WHEN $sid != ''
                                    THEN $sid ELSE server_id END
                            WHERE chat_jid=$jid AND timestamp=$dupTs
                        }
                        lappend confirmed [dict create \
                            own_id $m(own_id) timestamp $dupTs \
                            newtimestamp $newTs]
                    } else {
                        # Real overlap: matched row already has a
                        # server_id. The bracket sweep below proves
                        # the gap empty.
                        set hadRealOverlap 1
                    }
                    continue
                }
                set ts $m(timestamp)
                if {$ts <= $prevTs} { set ts [expr {$prevTs + 1}] }
                set ts [$self BumpTs $jid $ts 1]

                set status [expr {[info exists m(server_status)] \
                    ? $m(server_status) : ""}]
                set fromRes [expr {[info exists m(from_resource)] \
                    ? $m(from_resource) : ""}]
                $options(-db) eval {
                    INSERT INTO chat_message(timestamp, chat_jid, from_jid,
                        from_resource, body, server_id, own_id, raw_xml,
                        server_status)
                    VALUES($ts, $jid, $m(from_jid), $fromRes, $m(body),
                        $m(server_id), $m(own_id), $m(raw_xml), $status)
                }
                set prevTs $ts
                lappend insertedTimestamps $ts
            }

            if {$hadRealOverlap} {
                $self sentinel removeBetween $jid \
                    $batchMinTs $batchMaxTs
            }
        }
        return [dict create confirmed $confirmed \
            inserted $insertedTimestamps]
    }

    # --- Get ------------------------------------------------------------

    # Messages older than cursor. Truncates at the nearest older
    # sentinel (cannot cross a gap). Returns {messages $list bounded $b}
    # where bounded=1 iff a sentinel exists older than cursor and we
    # didn't satisfy the limit (caller should fall through to MAM).
    method "get before" {jid cursor {limit 50}} {
        set sentTs [$options(-db) onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp < $cursor
        }]
        set rows {}
        if {$sentTs eq ""} {
            $options(-db) eval {
                SELECT * FROM (
                    SELECT timestamp, chat_jid, from_jid, from_resource, body,
                           server_id, own_id, raw_xml, server_status
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND timestamp < $cursor
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            } row {
                lappend rows [$self RowToDict [array get row]]
            }
            return [dict create messages $rows bounded 0]
        }
        $options(-db) eval {
            SELECT * FROM (
                SELECT timestamp, chat_jid, from_jid, from_resource, body,
                       server_id, own_id, raw_xml, server_status
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp < $cursor AND timestamp > $sentTs
                ORDER BY timestamp DESC
                LIMIT $limit
            ) ORDER BY timestamp ASC
        } row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {[llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Symmetric to `get before`. Truncates at the nearest newer sentinel.
    method "get after" {jid cursor {limit 50}} {
        set sentTs [$options(-db) onecolumn {
            SELECT MIN(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp > $cursor
        }]
        set rows {}
        if {$sentTs eq ""} {
            $options(-db) eval {
                SELECT timestamp, chat_jid, from_jid, from_resource, body,
                       server_id, own_id, raw_xml, server_status
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp > $cursor
                ORDER BY timestamp ASC
                LIMIT $limit
            } row {
                lappend rows [$self RowToDict [array get row]]
            }
            return [dict create messages $rows bounded 0]
        }
        $options(-db) eval {
            SELECT timestamp, chat_jid, from_jid, from_resource, body,
                   server_id, own_id, raw_xml, server_status
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND timestamp > $cursor AND timestamp < $sentTs
            ORDER BY timestamp ASC
            LIMIT $limit
        } row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {[llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Most recent messages, truncated so the result never spans a
    # sentinel that sits between citizens. A sentinel sitting newer
    # than every message (reconnect placement) does not truncate —
    # the existing citizens are still the latest cluster — but it
    # does flip bounded=1 to signal more might arrive via MAM.
    method "get latest" {jid {limit 50}} {
        set latestMsgTs [$options(-db) onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
        }]
        if {$latestMsgTs eq ""} {
            return [dict create messages {} bounded 0]
        }
        # Truncation sentinel = latest sentinel strictly older than the
        # latest message. A sentinel sitting newer than all messages
        # never separates clusters, so it cannot truncate.
        set truncTs [$options(-db) onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
              AND timestamp < $latestMsgTs
        }]
        set anySentinel [$options(-db) exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='sentinel'
        }]
        set rows {}
        if {$truncTs eq ""} {
            $options(-db) eval {
                SELECT * FROM (
                    SELECT timestamp, chat_jid, from_jid, from_resource, body,
                           server_id, own_id, raw_xml, server_status
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            } row {
                lappend rows [$self RowToDict [array get row]]
            }
        } else {
            $options(-db) eval {
                SELECT * FROM (
                    SELECT timestamp, chat_jid, from_jid, from_resource, body,
                           server_id, own_id, raw_xml, server_status
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND timestamp > $truncTs
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            } row {
                lappend rows [$self RowToDict [array get row]]
            }
        }
        # bounded if any sentinel exists and we didn't satisfy the
        # limit — either a cluster-separating sentinel truncated us,
        # or a future-edge sentinel signals more may arrive.
        set bounded [expr {$anySentinel && [llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Full-text search by LIKE match on body. Returns list of timestamps
    # (newest first, capped at -limit). Sentinels have NULL body so
    # they're naturally excluded.
    method search {jid query args} {
        array set opts {-limit 500}
        array set opts $args
        set limit $opts(-limit)
        set pattern "%${query}%"
        set timestamps {}
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='message' AND body LIKE $pattern
            ORDER BY timestamp DESC LIMIT $limit
        } row {
            lappend timestamps $row(timestamp)
        }
        return $timestamps
    }

    # Find the nearest message to timestamp and return context around
    # it (limit/2 before + target + limit/2 after). Each side is
    # truncated independently at the nearest sentinel.
    # Returns dict: {messages $list anchor $nearestTs
    #                bounded_before $b bounded_after $b}.
    method "get around" {jid timestamp limit} {
        set nearestTs ""
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
            ORDER BY ABS(timestamp - $timestamp) LIMIT 1
        } row {
            set nearestTs $row(timestamp)
        }
        if {$nearestTs eq ""} {
            return [dict create messages {} anchor "" \
                bounded_before 0 bounded_after 0]
        }
        set halfLimit [expr {$limit / 2}]
        set before [$self get before $jid $nearestTs $halfLimit]
        set after  [$self get after  $jid $nearestTs $halfLimit]
        set target {}
        $options(-db) eval {
            SELECT timestamp, chat_jid, from_jid, from_resource, body,
                   server_id, own_id, raw_xml, server_status
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message' AND timestamp=$nearestTs
        } row {
            set target [list [$self RowToDict [array get row]]]
        }
        return [dict create \
            messages [concat [dict get $before messages] $target \
                             [dict get $after messages]] \
            anchor $nearestTs \
            bounded_before [dict get $before bounded] \
            bounded_after  [dict get $after  bounded]]
    }

    # Fetch rows by exact timestamps.
    method "get ids" {jid timestamps} {
        set rows {}
        foreach ts $timestamps {
            $options(-db) eval {
                SELECT timestamp, chat_jid, from_jid, from_resource, body,
                       server_id, own_id, raw_xml, server_status
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message' AND timestamp=$ts
            } row {
                lappend rows [$self RowToDict [array get row]]
            }
        }
        return $rows
    }

    # Flip pending → received for each own_id (SM ack path).
    # Returns list of {chat_jid, timestamp} for confirmed messages.
    method confirmByOwnIds {ownIds} {
        set confirmed {}
        $options(-db) transaction {
            foreach oid $ownIds {
                if {$oid eq ""} continue
                $options(-db) eval {
                    SELECT chat_jid, timestamp FROM chat_message
                    WHERE own_id=$oid AND server_status='pending'
                } row {
                    lappend confirmed [dict create \
                        chat_jid $row(chat_jid) timestamp $row(timestamp)]
                }
                $options(-db) eval {
                    UPDATE chat_message SET server_status='received'
                    WHERE own_id=$oid AND server_status='pending'
                }
            }
        }
        return $confirmed
    }

    # Single enrichment point for DB rows → message dicts.
    # All get methods funnel through here; event emitters (store,
    # send, search) read back via get ids so live messages are
    # enriched too.
    method RowToDict {row} {
        messagestyling::enrich $row
    }

    method IsDuplicate {jid msg} {
        set sid [dict get $msg server_id]
        set oid [dict get $msg own_id]
        set result ""
        if {$sid ne "" || $oid ne ""} {
            $options(-db) eval {
                SELECT timestamp, server_status FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND ( ($sid != '' AND server_id=$sid)
                     OR ($oid != '' AND own_id=$oid) )
                LIMIT 1
            } row {
                set result [dict create timestamp $row(timestamp) \
                    server_status $row(server_status)]
            }
        } else {
            # Content-based fallback for messages without server_id/own_id
            # (e.g. IRC bridge messages). Match within the same second —
            # BumpTs may have shifted the stored timestamp by a few
            # microseconds, so an exact match would miss it.
            # Tradeoff: identical sender+body within the same second is
            # treated as a duplicate (false positive), but that's rare
            # and far better than the alternative of unbounded duplicates
            # on every reconnect.
            set ts   [dict get $msg timestamp]
            set from [dict get $msg from_jid]
            set body [dict get $msg body]
            set tsBase [expr {$ts / 1000000 * 1000000}]
            set tsEnd  [expr {$tsBase + 999999}]
            $options(-db) eval {
                SELECT timestamp, server_status FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp BETWEEN $tsBase AND $tsEnd
                  AND from_jid=$from AND body=$body
                LIMIT 1
            } row {
                set result [dict create timestamp $row(timestamp) \
                    server_status $row(server_status)]
            }
        }
        return $result
    }

    method BumpTs {jid ts step} {
        while {1} {
            if {![$options(-db) exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND timestamp=$ts
            }]} {
                return $ts
            }
            incr ts $step
        }
    }
}
