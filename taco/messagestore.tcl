if 0 {
    Contiguity is tracked via a `region` column on every message row.
    Messages sharing a region are known contiguous (no gaps between them).
    Different regions within the same chat_jid may have gaps.

    The store can't determine contiguity — only the caller knows, from
    protocol semantics and connection state. The caller allocates regions
    via `region new` and passes them to `store batch`.

    Region merging via server_id overlap:

    `store batch` checks every message for a server_id/origin_id duplicate
    already in the DB. When a duplicate is found in a different region, the
    batch proves overlap — the old region is merged into the caller's region
    via UPDATE. The caller's region variable is passed by name (upvar) so
    it stays current after merges.

    `bridge` is still needed when MAM finishes just short of the live range —
    the last MAM page contained no server_id already in the DB, so
    `store batch` can't merge on its own. The caller knows the two ranges
    meet from protocol state (MAM said "complete") and calls `bridge` to
    merge the two regions.

    Concurrent catchup and live messages:

    On reconnect, MAM catchup and live messages each get their own region.
    Three outcomes:
    1. MAM reaches a live message (server_id match) — `store batch` merges
       regions automatically.
    2. MAM reaches previously-stored old data — same mechanism.
    3. MAM completes without overlap — caller calls `bridge` to merge.

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
		-- client-assigned, for dedup and receipt matching;
		-- <origin-id id='...'/>
		origin_id      TEXT,
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
	    CREATE INDEX IF NOT EXISTS idx_chat_message_origin_id
		ON chat_message(chat_jid, origin_id) WHERE origin_id != '';
	    CREATE INDEX IF NOT EXISTS idx_chat_message_region
		ON chat_message(chat_jid, region, timestamp);
	}
	catch {
	    $options(-db) eval {
		ALTER TABLE chat_message ADD COLUMN server_status TEXT
	    }
	}
    }

    method "region new" {varName} {
	upvar $varName v
	set v [incr RegionCounter]
    }

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
			    origin_id $m(origin_id) timestamp $dupTs]
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
			server_id, origin_id, raw_xml, region, server_status)
		    VALUES($ts, $jid, $m(from_jid), $m(body),
			$m(server_id), $m(origin_id), $m(raw_xml), $region,
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

    method bridge {jid r1Var r2Var} {
	upvar $r1Var r1
	upvar $r2Var r2
	if {$r1 == $r2} { return }
	$options(-db) eval {
	    UPDATE chat_message SET region = $r1
	    WHERE chat_jid = $jid AND region = $r2
	}
	set r2 $r1
    }

    # Returns messages from a single region only. GetBefore/GetAfter use
    # a strict match (message at cursor) to pin the region, so gaps
    # between regions are never bridged. GetLatest handles the no-cursor
    # case by fetching from the most recent region.
    method get {jid args} {
	set limit [expr {[dict exists $args -limit] ? [dict get $args -limit] : 50}]
	set hasBefore [dict exists $args -before]
	set hasAfter [dict exists $args -after]

	set hasAround [dict exists $args -around]

	if {($hasBefore + $hasAfter + $hasAround) > 1} {
	    error "-before, -after and -around are mutually exclusive"
	}

	if {$hasAround} {
	    return [$self GetAround $jid [dict get $args -around] $limit]
	} elseif {$hasAfter} {
	    return [$self GetAfter $jid [dict get $args -after] $limit]
	} elseif {$hasBefore} {
	    return [$self GetBefore $jid [dict get $args -before] $limit]
	} else {
	    return [$self GetLatest $jid $limit]
	}
    }

    method GetBefore {jid cursor limit} {
	set rows {}
	$options(-db) eval {
	    SELECT * FROM (
		SELECT timestamp, chat_jid, from_jid, body, server_id,
		       origin_id, raw_xml, server_status
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
	return $rows
    }

    method GetAfter {jid cursor limit} {
	set rows {}
	$options(-db) eval {
	    SELECT timestamp, chat_jid, from_jid, body, server_id,
		   origin_id, raw_xml, server_status
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
	return $rows
    }

    method GetLatest {jid limit} {
	set rows {}
	$options(-db) eval {
	    SELECT * FROM (
		SELECT timestamp, chat_jid, from_jid, body, server_id,
		       origin_id, raw_xml, server_status
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
	return $rows
    }

    method GetAround {jid timestamp limit} {
	if {![$options(-db) exists {
	    SELECT 1 FROM chat_message
	    WHERE chat_jid=$jid AND timestamp=$timestamp
	}]} {
	    return {}
	}
	set halfLimit [expr {$limit / 2}]
	set before [$self GetBefore $jid $timestamp $halfLimit]
	set after [$self GetAfter $jid $timestamp $halfLimit]
	set target {}
	$options(-db) eval {
	    SELECT timestamp, chat_jid, from_jid, body, server_id,
		   origin_id, raw_xml, server_status
	    FROM chat_message
	    WHERE chat_jid=$jid AND timestamp=$timestamp
	} row {
	    set target [list [$self RowToDict [array get row]]]
	}
	return [concat $before $target $after]
    }

    method confirmByOriginIds {originIds} {
	set confirmed {}
	$options(-db) transaction {
	    foreach oid $originIds {
		if {$oid eq ""} continue
		$options(-db) eval {
		    SELECT chat_jid, timestamp FROM chat_message
		    WHERE origin_id=$oid AND server_status='pending'
		} row {
		    lappend confirmed [dict create \
			chat_jid $row(chat_jid) timestamp $row(timestamp)]
		}
		$options(-db) eval {
		    UPDATE chat_message SET server_status='received'
		    WHERE origin_id=$oid AND server_status='pending'
		}
	    }
	}
	return $confirmed
    }

    method RowToDict {row} {
	set row
    }

    method IsDuplicate {jid msg} {
	set sid [dict get $msg server_id]
	set oid [dict get $msg origin_id]
	set result ""
	if {$sid ne "" || $oid ne ""} {
	    $options(-db) eval {
		SELECT timestamp, region, server_status FROM chat_message
		WHERE chat_jid=$jid
		  AND ( ($sid != '' AND server_id=$sid)
		     OR ($oid != '' AND origin_id=$oid) )
		LIMIT 1
	    } row {
		set result [dict create timestamp $row(timestamp) \
		    region $row(region) server_status $row(server_status)]
	    }
	} else {
	    # Content-based fallback for messages without server/origin IDs
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
