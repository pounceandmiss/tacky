if 0 {
    Contiguity is tracked via a `region` column on every message row.
    Messages sharing a region are known contiguous (no gaps between them).
    Different regions within the same chat_jid may have gaps.

    The store can't determine contiguity — only the caller knows, from
    protocol semantics and connection state. The caller allocates regions
    via `region new` and passes them to `store batch`.

    Region merging via server_id overlap:

    `store batch` checks every message for a server_id/own_id duplicate
    already in the DB. When a duplicate is found in a different region, the
    batch proves overlap — the old region is merged into the caller's region
    via UPDATE. The caller's region variable is passed by name (upvar) so
    it stays current after merges.

    `region bridge` is still needed when MAM finishes just short of the
    live range — the last MAM page contained no server_id already in the
    DB, so `store batch` can't merge on its own. The caller knows the two
    ranges meet from protocol state (MAM said "complete") and calls
    `region bridge` to merge the two regions.

    Concurrent catchup and live messages:

    On reconnect, MAM catchup and live messages each get their own region.
    Three outcomes:
    1. MAM reaches a live message (server_id match) — `store batch` merges
       regions automatically.
    2. MAM reaches previously-stored old data — same mechanism.
    3. MAM completes without overlap — caller calls `region bridge` to merge.

    In all cases the caller's region variables are updated via upvar,
    so subsequent inserts use the surviving region.

    Initially I thought of other approaches, such as sentinel rows
    indicating a hole or a separate table maintaining region ranges -
    those proved to be much more complex to implement properly, with
    this region token approach by far the most robust out of the ideas
    tried.
}

snit::type taco_messagestore {
    option -db -default ""

    variable RegionCounter 0

    constructor args {
        $self configurelist $args
        $self Migrate
        set RegionCounter [lindex [$options(-db) eval {
            SELECT COALESCE(MAX(region), 0) FROM chat_message
        }] 0]
    }

    method Migrate {} {
        $options(-db) eval {
            CREATE TABLE IF NOT EXISTS chat_message(
                timestamp      INTEGER NOT NULL,
                chat_jid       TEXT NOT NULL,
                from_jid       TEXT NOT NULL,
                body           TEXT,
                -- server-assigned, for MAM pagination;
                -- <stanza-id id='...' by='server.example.com'/>
                server_id      TEXT,
                -- set only for outgoing messages; = <message id="...">
                -- incoming messages have own_id=""
                own_id      TEXT,
                raw_xml        TEXT,
                region         INTEGER NOT NULL,
                -- NULL/empty = incoming (already received);
                -- 'pending' = stored, awaiting server confirmation;
                -- 'received' = server confirmed via echo or SM ack
                server_status  TEXT,
                PRIMARY KEY(chat_jid, timestamp)
            );
            CREATE INDEX IF NOT EXISTS idx_chat_message_server_id
                ON chat_message(chat_jid, server_id) WHERE server_id != '';
            CREATE INDEX IF NOT EXISTS idx_chat_message_own_id
                ON chat_message(chat_jid, own_id) WHERE own_id != '';
            CREATE INDEX IF NOT EXISTS idx_chat_message_region
                ON chat_message(chat_jid, region, timestamp);
        }
        catch {
            $options(-db) eval {
                ALTER TABLE chat_message ADD COLUMN server_status TEXT
            }
        }
    }

    # Allocate a fresh region token and store it in the caller's variable.
    method "region new" {varName} {
        upvar $varName v
        set v [incr RegionCounter]
    }

    # Insert messages into the DB under regionVar's region. Deduplicates
    # by server_id/own_id (or content fallback), merges regions on
    # overlap, and confirms pending messages on echo. Returns dict with
    # `confirmed` (list of {own_id, timestamp}) and `inserted` count.
    method "store batch" {messages regionVar} {
        if {[llength $messages] == 0} { return {} }

        upvar $regionVar region
        set jid [dict get [lindex $messages 0] chat_jid]

        set mergedRegions {}
        set confirmed {}
        set inserted 0
        set prevTs -1

        $options(-db) transaction {
            foreach msg $messages {
                array unset m
                array set m $msg

                set dup [$self IsDuplicate $jid $msg]
                if {$dup ne ""} {
                    set dupRegion [dict get $dup region]
                    if {$dupRegion != $region} {
                        dict set mergedRegions $dupRegion 1
                    }
                    # Confirm pending messages on server echo
                    if {[dict get $dup server_status] eq "pending"} {
                        set dupTs [dict get $dup timestamp]
                        set sid $m(server_id)
                        $options(-db) eval {
                            UPDATE chat_message
                            SET server_status='received',
                                server_id = CASE WHEN $sid != ''
                                    THEN $sid ELSE server_id END
                            WHERE chat_jid=$jid AND timestamp=$dupTs
                        }
                        lappend confirmed [dict create \
                            own_id $m(own_id) timestamp $dupTs]
                    }
                    continue
                }
                # Skip past slots this batch already filled
                set ts $m(timestamp)
                if {$ts <= $prevTs} { set ts [expr {$prevTs + 1}] }
                set ts [$self BumpTs $jid $ts 1]

                set status [expr {[info exists m(server_status)] \
                    ? $m(server_status) : ""}]
                $options(-db) eval {
                    INSERT INTO chat_message(timestamp, chat_jid, from_jid, body,
                        server_id, own_id, raw_xml, region, server_status)
                    VALUES($ts, $jid, $m(from_jid), $m(body),
                        $m(server_id), $m(own_id), $m(raw_xml), $region,
                        $status)
                }
                set prevTs $ts
                incr inserted
            }

            dict for {oldRegion _} $mergedRegions {
                $options(-db) eval {
                    UPDATE chat_message SET region = $region
                    WHERE chat_jid = $jid AND region = $oldRegion
                }
            }
        }
        return [dict create confirmed $confirmed inserted $inserted]
    }

    # Merge r2's region into r1's region for jid. Updates the caller's
    # r2 variable to match r1. No-op if already the same region.
    method "region bridge" {jid r1Var r2Var} {
        upvar $r1Var r1
        upvar $r2Var r2
        if {$r1 == $r2} { return }
        $options(-db) eval {
            UPDATE chat_message SET region = $r1
            WHERE chat_jid = $jid AND region = $r2
        }
        set r2 $r1
    }

    

    # Messages older than cursor (an existing message's timestamp).
    # The region is pinned by exact match on cursor, so a nonexistent
    # cursor returns empty.
    # returns a list of message dicts (keys: timestamp,
    # chat_jid, from_jid, body, server_id, own_id, raw_xml,
    # server_status), chronological order, from a single region
    method "get before" {jid cursor {limit 50}} {
        set rows {}
        $options(-db) eval {
            SELECT * FROM (
                SELECT timestamp, chat_jid, from_jid, body, server_id,
                       own_id, raw_xml, server_status
                FROM chat_message
                WHERE chat_jid=$jid AND timestamp < $cursor
                  AND region = (
                    SELECT region FROM chat_message
                    WHERE chat_jid=$jid AND timestamp = $cursor
                    LIMIT 1
                  )
                ORDER BY timestamp DESC
                LIMIT $limit
            ) ORDER BY timestamp ASC
        } row {
            lappend rows [$self RowToDict [array get row]]
        }
        return [$self AnnotatePrev $jid $rows]
    }

    # Messages newer than cursor (an existing message's timestamp),
    # chronological order. Otherwise same as "get before".
    method "get after" {jid cursor {limit 50}} {
        set rows {}
        $options(-db) eval {
            SELECT timestamp, chat_jid, from_jid, body, server_id,
                   own_id, raw_xml, server_status
            FROM chat_message
            WHERE chat_jid=$jid AND timestamp > $cursor
              AND region = (
                SELECT region FROM chat_message
                WHERE chat_jid=$jid AND timestamp = $cursor
                LIMIT 1
              )
            ORDER BY timestamp ASC
            LIMIT $limit
        } row {
            lappend rows [$self RowToDict [array get row]]
        }
        return [$self AnnotatePrev $jid $rows]
    }

    # Most recent messages from the latest region. Otherwise same as
    # "get before"
    method "get latest" {jid {limit 50}} {
        set rows {}
        $options(-db) eval {
            SELECT * FROM (
                SELECT timestamp, chat_jid, from_jid, body, server_id,
                       own_id, raw_xml, server_status
                FROM chat_message
                WHERE chat_jid=$jid
                  AND region = (
                    SELECT region FROM chat_message
                    WHERE chat_jid=$jid
                    ORDER BY timestamp DESC LIMIT 1
                  )
                ORDER BY timestamp DESC
                LIMIT $limit
            ) ORDER BY timestamp ASC
        } row {
            lappend rows [$self RowToDict [array get row]]
        }
        return [$self AnnotatePrev $jid $rows]
    }

    # Full-text search by LIKE match on body. Returns list of timestamps
    # (newest first, capped at -limit).
    method search {jid query args} {
        array set opts {-limit 500}
        array set opts $args
        set limit $opts(-limit)
        set pattern "%${query}%"
        set timestamps {}
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND body LIKE $pattern
            ORDER BY timestamp DESC LIMIT $limit
        } row {
            lappend timestamps $row(timestamp)
        }
        return $timestamps
    }

    # Find the nearest message to timestamp and return context around
    # it (limit/2 before + target + limit/2 after), region-scoped.
    # Returns dict: {messages $list anchor $nearestTs}.
    method "get around" {jid timestamp limit} {
        set nearestTs ""
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid
            ORDER BY ABS(timestamp - $timestamp) LIMIT 1
        } row {
            set nearestTs $row(timestamp)
        }
        if {$nearestTs eq ""} {
            return {messages {} anchor ""}
        }
        set halfLimit [expr {$limit / 2}]
        set before [$self get before $jid $nearestTs $halfLimit]
        set after [$self get after $jid $nearestTs $halfLimit]
        set target {}
        $options(-db) eval {
            SELECT timestamp, chat_jid, from_jid, body, server_id,
                   own_id, raw_xml, server_status
            FROM chat_message
            WHERE chat_jid=$jid AND timestamp=$nearestTs
        } row {
            set target [list [$self RowToDict [array get row]]]
        }
        set all [$self AnnotatePrev $jid [concat $before $target $after]]
        return [list messages $all anchor $nearestTs]
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

    method RowToDict {row} {
        set row
    }

    # Annotate each message in a chronological list with {prev $ts},
    # the timestamp of the immediately preceding message.  The first
    # message's predecessor is looked up in the DB (same region);
    # subsequent messages chain from the previous element in the list.
    method AnnotatePrev {jid messages} {
        if {[llength $messages] == 0} { return {} }
        set firstTs [dict get [lindex $messages 0] timestamp]
        set prevTs [$options(-db) onecolumn {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND timestamp < $firstTs
              AND region = (
                SELECT region FROM chat_message
                WHERE chat_jid=$jid AND timestamp=$firstTs
              )
            ORDER BY timestamp DESC LIMIT 1
        }]
        set result {}
        foreach msg $messages {
            dict set msg prev $prevTs
            set prevTs [dict get $msg timestamp]
            lappend result $msg
        }
        return $result
    }

    method IsDuplicate {jid msg} {
        set sid [dict get $msg server_id]
        set oid [dict get $msg own_id]
        set result ""
        if {$sid ne "" || $oid ne ""} {
            $options(-db) eval {
                SELECT timestamp, region, server_status FROM chat_message
                WHERE chat_jid=$jid
                  AND ( ($sid != '' AND server_id=$sid)
                     OR ($oid != '' AND own_id=$oid) )
                LIMIT 1
            } row {
                set result [dict create timestamp $row(timestamp) \
                    region $row(region) server_status $row(server_status)]
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
                SELECT timestamp, region, server_status FROM chat_message
                WHERE chat_jid=$jid
                  AND timestamp BETWEEN $tsBase AND $tsEnd
                  AND from_jid=$from AND body=$body
                LIMIT 1
            } row {
                set result [dict create timestamp $row(timestamp) \
                    region $row(region) server_status $row(server_status)]
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
