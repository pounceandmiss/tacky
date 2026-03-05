if 0 {
    Messages are known adjacent when:
    1. Same MAM page — server guarantees sequential results
    2. Consecutive pages of the same MAM query — pagination continues where the last page ended
    3. Consecutive live messages on the same connection — nothing skipped while connected
    4. MAM catchup reaching live data — the caller knows the two ranges meet

    We can never rely on timestamps to tell adjacency!

    The store can't determine this — only the caller knows, from protocol semantics and connection state. That's exactly what begin/end/bridge encode: the
    caller declares "these messages are contiguous" and "these two ranges now meet."

    Hole deletion via server_id overlap:

    `store batch` never trusts timestamp ranges to decide whether a batch
    connects to existing data. Instead it looks for a concrete server_id
    duplicate: a message already in the DB whose server_id matches one in
    the incoming batch.

    - No duplicate found: the batch is an isolated island. A hole is placed
      just before it (first batch of the span only), and no holes are deleted.
    - Duplicate found: proven overlap. The duplicate's timestamp is added to
      `reachedTs`; inserted messages go into `insertedTs`. All holes in
      [min(insertedTs + reachedTs), max(insertedTs + reachedTs)] are deleted,
      because the batch and the existing data are now known contiguous.

    All messages go through `store batch`, which uses `IsDuplicate`
    (server_id OR origin_id) for every message. It records the existing
    timestamp of each duplicate in `reachedTs` because a batch is an
    ordered sequence that can prove range contiguity. A live message is
    just a single-message batch — it typically won't hit a server_id
    duplicate on its own, so holes in the live span get resolved by a
    MAM `store batch` overlapping into it, or by `bridge`.

    `bridge` is still needed when MAM finishes just short of the live range —
    the last MAM page contained no server_id already in the DB (e.g. the live
    span hadn't stored any of those messages yet), so `store batch` can't
    delete the hole on its own. The caller knows the two ranges meet from
    protocol state (MAM said "complete") and calls `bridge` to remove the
    remaining holes between them.

    Concurrent catchup and live messages:

    On reconnect, a MAM catchup span and a live span start at the same time.
    Live messages arrive immediately; MAM pages trickle in going forward
    through history. Each gets its own span with its own initial hole.

    Three outcomes for the MAM span:
    1. MAM reaches a message already stored by the live span (server_id
       match) — `store batch` deletes holes in the overlap range
       automatically.
    2. MAM reaches previously-stored old data (server_id match from a prior
       session) — same mechanism, holes deleted.
    3. MAM completes (`<fin complete='true'>`) but the last page didn't
       overlap the live span — the caller calls `bridge` to declare the two
       ranges meet, removing any holes between the end of the MAM range and
       the start of the live range.

    In all three cases the live span's initial hole is removed once
    contiguity is established, and the timeline becomes seamless.

    Theoretically we can end up with collisions when bumping hole or
    message timestamps - idk what happens then. We can try guarding
    against that by making the timestamp finer than milliseconds I
    guess, but later - I doubt it'll be a problem in practice.
}

snit::type taco_messagestore {
    option -db -default ""

    variable Sessions
    variable SidCounter 0

    constructor args {
	$self configurelist $args
	$self Migrate
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
		hole           INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY(chat_jid, timestamp)
	    );
	    CREATE INDEX IF NOT EXISTS idx_chat_message_server_id
		ON chat_message(chat_jid, server_id) WHERE server_id != '';
	    CREATE INDEX IF NOT EXISTS idx_chat_message_origin_id
		ON chat_message(chat_jid, origin_id) WHERE origin_id != '';
	    CREATE INDEX IF NOT EXISTS idx_chat_message_holes
		ON chat_message(chat_jid, timestamp) WHERE hole = 1;
	}
    }

    method "span begin" {jid} {
	set sid [incr SidCounter]
	dict set Sessions $sid [dict create chat_jid $jid hole_ts ""]
	return $sid
    }

    method "span end" {sid} {
	dict unset Sessions $sid
    }

    method "store batch" {messages args} {
	if {[llength $messages] == 0} { return }

	set sid [dict get $args -span]
	set sess [dict get $Sessions $sid]
	set jid [dict get $sess chat_jid]

	# Compute minTs from original timestamps (for hole placement)
	set minTs [dict get [lindex $messages 0] timestamp]
	foreach msg $messages {
	    set t [dict get $msg timestamp]
	    if {$t < $minTs} { set minTs $t }
	}

	set insertedTs {}
	set reachedTs {}
	set prevTs -1

	$options(-db) transaction {
	    # Insert messages in caller order, bumping timestamps to enforce it
	    foreach msg $messages {
		array unset m
		array set m $msg
		set existingTs [$self IsDuplicate $jid $msg]
		if {$existingTs ne ""} {
		    lappend reachedTs $existingTs
		    continue
		}
		set ts $m(timestamp)
		if {$ts <= $prevTs} { set ts [expr {$prevTs + 1}] }
		set ts [$self BumpTs $jid $ts 1]
		$options(-db) eval {
		    INSERT INTO chat_message(timestamp, chat_jid, from_jid, body, server_id, origin_id, raw_xml)
		    VALUES($ts, $jid, $m(from_jid), $m(body), $m(server_id), $m(origin_id), $m(raw_xml))
		}
		lappend insertedTs $ts
		set prevTs $ts
	    }

	    # Place or move the span's hole to track the lowest edge
	    set anyInserted [expr {[llength $insertedTs] > 0}]
	    if {$anyInserted} {
		set holeTs [dict get $sess hole_ts]

		if {$holeTs eq "" || $minTs <= $holeTs} {
		    if {$holeTs ne ""} {
			$options(-db) eval {
			    DELETE FROM chat_message
			    WHERE chat_jid=$jid AND timestamp=$holeTs AND hole=1
			}
		    }
		    set newHoleTs [$self BumpTs $jid [expr {$minTs - 1}] -1]
		    $options(-db) eval {
			INSERT INTO chat_message(timestamp, chat_jid, from_jid, body, server_id, origin_id, raw_xml, hole)
			VALUES($newHoleTs, $jid, '', '', '', '', '', 1)
		    }
		    dict set sess hole_ts $newHoleTs
		    dict set Sessions $sid $sess
		}
	    }

	    # Delete holes only when a duplicate proves
	    # the batch reached existing data
	    if {[llength $reachedTs] > 0} {
		set allTs [concat $insertedTs $reachedTs]
		set rangeMin [::tcl::mathfunc::min {*}$allTs]
		set rangeMax [::tcl::mathfunc::max {*}$allTs]
		$options(-db) eval {
		    DELETE FROM chat_message
		    WHERE chat_jid=$jid AND hole=1
		      AND timestamp >= $rangeMin AND timestamp <= $rangeMax
		}
		# Clear hole_ts if overlap deleted our span's hole
		set holeTs [dict get $sess hole_ts]
		if {$holeTs ne "" && $holeTs >= $rangeMin && $holeTs <= $rangeMax} {
		    dict set sess hole_ts ""
		    dict set Sessions $sid $sess
		}
	    }
	}
    }

    method bridge {args} {
	set jid [dict get $args -chat]
	set from [dict get $args -from-ts]
	set to [dict get $args -to-ts]
	$options(-db) eval {
	    DELETE FROM chat_message
	    WHERE chat_jid=$jid AND hole=1
	      AND timestamp >= $from AND timestamp <= $to
	}
    }

    method get {args} {
	set jid [dict get $args -chat]
	set limit [expr {[dict exists $args -limit] ? [dict get $args -limit] : 50}]
	set hasBefore [dict exists $args -before]
	set hasAfter [dict exists $args -after]

	if {$hasBefore && $hasAfter} {
	    error "-before and -after are mutually exclusive"
	}

	if {$hasAfter} {
	    return [$self GetAfter $jid [dict get $args -after] $limit]
	}

	set cursor [expr {$hasBefore ? [dict get $args -before] : 9223372036854775807}]
	return [$self GetBefore $jid $cursor $limit]
    }

    method GetBefore {jid cursor limit} {
	set rows {}
	$options(-db) eval {
	    SELECT * FROM (
		SELECT timestamp, chat_jid, from_jid, body, server_id, origin_id, raw_xml
		FROM chat_message
		WHERE chat_jid=$jid AND timestamp < $cursor AND hole=0
		  AND timestamp > COALESCE(
		    (SELECT timestamp FROM chat_message
		     WHERE chat_jid=$jid AND timestamp < $cursor AND hole=1
		     ORDER BY timestamp DESC LIMIT 1),
		    -1)
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
	    SELECT timestamp, chat_jid, from_jid, body, server_id, origin_id, raw_xml
	    FROM chat_message
	    WHERE chat_jid=$jid AND timestamp > $cursor AND hole=0
	      AND timestamp < COALESCE(
		(SELECT timestamp FROM chat_message
		 WHERE chat_jid=$jid AND timestamp > $cursor AND hole=1
		 ORDER BY timestamp ASC LIMIT 1),
		9223372036854775807)
	    ORDER BY timestamp ASC
	    LIMIT $limit
	} row {
	    lappend rows [$self RowToDict [array get row]]
	}
	return $rows
    }

    method RowToDict {row} {
	set row
    }

    method IsDuplicate {jid msg} {
	set sid [dict get $msg server_id]
	set oid [dict get $msg origin_id]
	if {$sid eq "" && $oid eq ""} { return "" }
	$options(-db) eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid=$jid AND hole=0
	      AND ( ($sid != '' AND server_id=$sid)
		 OR ($oid != '' AND origin_id=$oid) )
	    LIMIT 1
	}
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
