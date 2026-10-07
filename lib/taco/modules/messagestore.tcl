# Overview
#
# The local sparse cache, and we track which spans are
# known-contiguous and which are gaps (holes).  Server doesn't tell us
# what ids are assigned to outgoing messages and keeps us guessing, so
# the outgoing messages don't participate in contiguity logic until we
# happen to get them back in a mam page.

# Why the cache can have holes: if the user was away for a long time,
# they re-open the app, and instead of fetching all history ever we
# fetch it starting from latest, and we'll stop at a threshold to
# not fetch everything ever. Therefore there's a disconnect there - a
# hole, which we mark with a special message table entry with
# kind=hole. Also - we may jump to date in the past (the user may
# intentionally fetch a disconnected region). Also - we can do server
# search - and all results in it are sparse.

# === The three server-relationship fields ===
#
# Distinct, not redundant - each answers a different question:
#
#   kind           is this row a real message or a gap-marker?
#                  'message' | 'hole'. A hole carries only timestamp +
#                  chat_jid; see Holes.
#   server_id      XEP-0359 stanza-id - empty until the server
#                  hands us one.
#   server_status  does the server have this exact message?
#                  '' = yes (incoming, MAM, carbon, or a confirmed send);
#                  'pending'/'uploading'/'failed' = our outgoing message,
#                  server state not yet known.
#
# server_id != '' implies server_status == '', but not the reverse: a send
# confirmed by SM ack is on the server ('') with no archive id yet.
#
#   An outgoing message's server_status flips to "" by:
#     A. live echo / carbon
#     B. SM ack <a h='N'/>
#     C. MAM re-delivery

# === Contiguity ===
#
# Citizen predicate: kind='message' AND server_id != ''. Only citizens anchor
# holes and cursors; holes and pending sends (server_id='') are skipped by
# neighbour lookups, cursor selection, and dedup. A pending send still shows
# in `get` results; it joins contiguity once MAM gives it a server_id.
#
# === Holes ===
#
# A hole marks "unfetched history may exist here" - e.g. we page back from the
# newest message and stop at a threshold, leaving a gap below.
#   place:   `hole add $jid $direction $anchorTs`
#   remove:  `hole remove` (RSM-complete), `hole removeBetween` (post-MAM
#            sweep), or implicitly when `store` proves overlap with cache.
# Older/newer sense is positional, from where the hole's timestamp falls.
#
# === Pagination ===
#
# `get before`/`after`/`latest` return {messages bounded}; bounded=1 means a
# hole truncated the queried side, so fall through to MAM. `get around`
# returns {messages anchor bounded_before bounded_after}.
#


snit::type taco_messagestore {
    option -db -default ""
    # {*}joinedcmd $room -> 0|1: whether we are a member, for an invite's
    # state. Unset, no room counts as joined.
    option -joinedcmd -default ""
    # A call row's `active` and `live`: {*}incallcmd $room -> 0|1 (we are in
    # it), {*}livecmd $chat $ts $room -> 1|0|"" (anyone is; "" unknown).
    option -incallcmd -default ""
    option -livecmd -default ""
    # {*}deferredcmd $chat $patches, after a store inserted the target of
    # corrections/retractions held by `defer`. Each patch is
    # {kind K timestamp T patch P}, already removed from the table.
    option -deferredcmd -default ""

    # Columns every message read path returns, in one place so a new column
    # reaches all of them. Spliced in for the @cols@ placeholder by MsgSql.
    typevariable MsgCols {timestamp, chat_jid, from_jid, from_resource, body,
                          server_id, own_id, occupant_id, edited_ts, retracted,
                          reply_id, reply_to, server_status, remote_status,
                          encryption, sender_fp, fail_reason, attachments,
                          invite, invite_declined, call, call_state}
    # Deferred corrections/retractions kept per chat (see `defer`).
    typevariable MaxDeferred 500

    constructor args {
        $self configurelist $args
    }

    method MsgSql {sql} {
        return [string map [list @cols@ $MsgCols] $sql]
    }

    # --- Group call invites -------------------------------------------

    # One stored call invite as {call state}, or "" when the row at $ts in
    # $jid is not one.
    method callAt {jid ts} {
        set found ""
        $options(-db) eval {
            SELECT call, call_state FROM chat_message
            WHERE chat_jid=$jid AND timestamp=$ts AND kind='message'
              AND call_room != ''
        } r {
            set found [dict create call $r(call) state $r(call_state)]
        }
        return $found
    }

    method setCallState {jid ts state} {
        $options(-db) eval {
            UPDATE chat_message SET call_state=$state
            WHERE chat_jid=$jid AND timestamp=$ts AND call_room != ''
        }
    }

    # The rows in $jid holding the invite with id $id, as {ts state room}.
    method callsById {jid id} {
        set found {}
        $options(-db) eval {
            SELECT timestamp, call_state, call_room FROM chat_message
            WHERE chat_jid=$jid AND call_id=$id AND call_room != ''
              AND kind='message'
        } r {
            lappend found [list $r(timestamp) $r(call_state) $r(call_room)]
        }
        return $found
    }

    # The newest call invite in $jid, as {ts room}, or "".
    method newestCall {jid} {
        set found ""
        $options(-db) eval {
            SELECT timestamp, call_room FROM chat_message
            WHERE chat_jid=$jid AND call_room != '' AND kind='message'
            ORDER BY timestamp DESC LIMIT 1
        } r {
            set found [list $r(timestamp) $r(call_room)]
        }
        return $found
    }

    # Every stored invite to the call in $room, wherever it sits, as
    # {chat_jid ts}.
    method callsToRoom {room} {
        set found {}
        $options(-db) eval {
            SELECT chat_jid, timestamp FROM chat_message
            WHERE call_room=$room AND kind='message'
        } r {
            lappend found [list $r(chat_jid) $r(timestamp)]
        }
        return $found
    }

    # --- Invites ----------------------------------------------------

    # One stored invitation as {invite declined}, or "" when the row at $ts
    # in $jid is not one.
    method inviteAt {jid ts} {
        set found ""
        $options(-db) eval {
            SELECT invite, invite_declined FROM chat_message
            WHERE chat_jid=$jid AND timestamp=$ts AND kind='message'
              AND invite_room != ''
        } r {
            set found [dict create invite $r(invite) declined $r(invite_declined)]
        }
        return $found
    }

    method setInviteDeclined {jid ts declined} {
        $options(-db) eval {
            UPDATE chat_message SET invite_declined=$declined
            WHERE chat_jid=$jid AND timestamp=$ts AND invite_room != ''
        }
    }

    # Every stored invitation to $room, wherever it sits, as {chat_jid ts}.
    method invitesToRoom {room} {
        set found {}
        $options(-db) eval {
            SELECT chat_jid, timestamp FROM chat_message
            WHERE invite_room=$room AND kind='message'
        } r {
            lappend found [list $r(chat_jid) $r(timestamp)]
        }
        return $found
    }

    # Whether $jid holds an invitation not yet turned down.
    method pendingInvite {jid} {
        $options(-db) exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND invite_room != '' AND invite_declined=0
        }
    }

    # Whether $jid holds only declined invitations.
    method onlyDeclinedInvites {jid} {
        set db $options(-db)
        expr {[$db exists {
                  SELECT 1 FROM chat_message
                  WHERE chat_jid=$jid AND kind='message'}]
              && ![$db exists {
                  SELECT 1 FROM chat_message
                  WHERE chat_jid=$jid AND kind='message'
                    AND (invite_room = '' OR invite_declined=0)}]}
    }

    # Drop a chat's whole history, its holes and read mark with it.
    method forgetChat {jid} {
        $options(-db) eval {
            DELETE FROM chat_message WHERE chat_jid=$jid;
            DELETE FROM chat_own_read WHERE chat_jid=$jid;
        }
    }

    # --- Holes ------------------------------------------------------

    # Insert a hole in the gap immediately $direction of $anchorTs.
    # direction is `older` | `newer`. Enforces at-most-one-per-gap: if a
    # hole already lies between $anchorTs and the next citizen in
    # $direction (treating "no citizen on that side" as +/-inf), this is a
    # no-op. Synthetic ts derived via BumpTs one step off the anchor.
    method "hole add" {jid direction anchorTs} {
        lassign [$self GapBounds $jid $direction $anchorTs] lo hi
        set exists [$options(-db) onecolumn {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp > $lo AND timestamp < $hi
            LIMIT 1
        }]
        if {$exists ne ""} return
        set step [expr {$direction eq "older" ? -1 : 1}]
        set ts [$self BumpTs $jid [expr {$anchorTs + $step}] $step]
        # BumpTs walks until it finds a free microsecond, which can carry it
        # out of the gap entirely when the neighbouring one is taken - and
        # `store` packs colliding stamps into consecutive microseconds, so
        # that happens. Landing outside would mark a gap that isn't there and
        # leave the one we meant unmarked. Nowhere to land means the two
        # citizens came out of one contiguous batch, so there is no gap.
        if {$ts <= $lo || $ts >= $hi} return
        $options(-db) eval {
            INSERT INTO chat_message(timestamp, chat_jid, kind)
            VALUES($ts, $jid, 'hole')
        }
    }

    # Remove any hole(s) in the gap immediately $direction of
    # $anchorTs. Invariant says at most one; defensive plural costs the
    # same as a range delete.
    method "hole remove" {jid direction anchorTs} {
        lassign [$self GapBounds $jid $direction $anchorTs] lo hi
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp > $lo AND timestamp < $hi
        }
    }

    # Internal: delete holes strictly between $loTs and $hiTs.
    # Used by `store` overlap-proof and by post-MAM sweep in message.tcl.
    method "hole removeBetween" {jid loTs hiTs} {
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp > $loTs AND timestamp < $hiTs
        }
    }

    # Tests-only: ordered list of hole timestamps.
    method "hole list" {jid} {
        set rows {}
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
            ORDER BY timestamp ASC
        } row {
            lappend rows $row(timestamp)
        }
        return $rows
    }

    # Bounds of the gap immediately $direction of $anchorTs, inclusive
    # of $anchorTs on the anchor side. Returns {lo hi} with holes
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

    # Insert messages, skipping any already stored (by server_id/own_id, or
    # content for id-less ones), e.g. one repeated within a MAM page.
    # Confirming our own sends is `reconcile`'s job. Returns dict with
    # `inserted` (list of stored timestamps).
    method store {messages} {
        if {[llength $messages] == 0} { return {} }

        set jid [dict get [lindex $messages 0] chat_jid]
        set insertedTimestamps {}
        set deferred {}
        set prevTs -1

        $options(-db) transaction {
            foreach msg $messages {
                if {[$self IsDuplicate $jid $msg]} continue
                array unset m
                array set m $msg

                set ts $m(timestamp)
                if {$ts <= $prevTs} { set ts [expr {$prevTs + 1}] }
                set ts [$self BumpTs $jid $ts 1]

                set status [expr {[info exists m(server_status)] \
                    ? $m(server_status) : ""}]
                set fromRes [expr {[info exists m(from_resource)] \
                    ? $m(from_resource) : ""}]
                set enc [expr {[info exists m(encryption)] \
                    ? $m(encryption) : ""}]
                set senderFp [expr {[info exists m(sender_fp)] \
                    ? $m(sender_fp) : ""}]
                set failReason [expr {[info exists m(fail_reason)] \
                    ? $m(fail_reason) : ""}]
                set originId [expr {[info exists m(origin_id)] \
                    ? $m(origin_id) : ""}]
                set occId [expr {[info exists m(occupant_id)] \
                    ? $m(occupant_id) : ""}]
                set replyId [expr {[info exists m(reply_id)] \
                    ? $m(reply_id) : ""}]
                set replyTo [expr {[info exists m(reply_to)] \
                    ? $m(reply_to) : ""}]
                set attach [expr {[info exists m(attachments)] \
                    ? $m(attachments) : ""}]
                set mention [expr {[info exists m(mentions_me)] \
                    ? $m(mentions_me) : 0}]
                set invite [expr {[info exists m(invite)] ? $m(invite) : ""}]
                set inviteRoom [expr {[info exists m(invite_room)] \
                    ? $m(invite_room) : ""}]
                set call [expr {[info exists m(call)] ? $m(call) : ""}]
                set callRoom [expr {$call eq "" ? "" : [dict get $call room]}]
                set callId [expr {$call eq "" ? "" : [dict get $call id]}]
                set callState [expr {[info exists m(call_state)] \
                    ? $m(call_state) : ""}]
                $options(-db) eval {
                    INSERT INTO chat_message(timestamp, chat_jid, from_jid,
                        from_resource, body, server_id, own_id, origin_id,
                        occupant_id, reply_id, reply_to, raw_xml, server_status,
                        encryption, sender_fp, fail_reason, mentions_me,
                        attachments, invite, invite_room, call, call_room,
                        call_id, call_state)
                    VALUES($ts, $jid, $m(from_jid), $fromRes, $m(body),
                        $m(server_id), $m(own_id), $originId,
                        $occId, $replyId, $replyTo, $m(raw_xml), $status, $enc,
                        $senderFp, $failReason, $mention, $attach, $invite,
                        $inviteRoom, $call, $callRoom, $callId, $callState)
                    -- edited_ts/retracted take table defaults (only ever set
                    -- by applyEdit/applyRetract, never at insert time)
                }
                set prevTs $ts
                lappend insertedTimestamps $ts
                lappend deferred {*}[$self TakeDeferred $jid \
                    [list $m(server_id) $m(own_id) $originId]]
            }
        }
        if {[llength $deferred] && $options(-deferredcmd) ne ""} {
            {*}$options(-deferredcmd) $jid $deferred
        }
        return [dict create inserted $insertedTimestamps]
    }

    # --- Deferred corrections/retractions -------------------------------

    # Hold a correction/retraction whose target isn't stored yet. The most
    # recent MaxDeferred per chat are kept; older ones are presumed to
    # target messages that will never arrive.
    method defer {chatJid targetId kind ts patch} {
        $options(-db) eval {
            INSERT OR IGNORE INTO pending_patch(chat_jid, target_id, kind,
                timestamp, patch)
            VALUES($chatJid, $targetId, $kind, $ts, $patch);
            DELETE FROM pending_patch WHERE chat_jid=$chatJid AND rowid NOT IN (
                SELECT rowid FROM pending_patch WHERE chat_jid=$chatJid
                ORDER BY timestamp DESC LIMIT $MaxDeferred)
        }
    }

    # Remove and return the deferred patches aimed at any of $ids, oldest
    # first, so successive corrections land in the order they were made.
    method TakeDeferred {chatJid ids} {
        set out {}
        foreach id [lsort -unique $ids] {
            if {$id eq ""} continue
            $options(-db) eval {
                SELECT kind, timestamp, patch FROM pending_patch
                WHERE chat_jid=$chatJid AND target_id=$id
            } row {
                lappend out [dict create kind $row(kind) \
                    timestamp $row(timestamp) patch $row(patch)]
            }
            $options(-db) eval {
                DELETE FROM pending_patch
                WHERE chat_jid=$chatJid AND target_id=$id
            }
        }
        return [lsort -command [list apply {{a b} {
            expr {[dict get $a timestamp] - [dict get $b timestamp]}
        }}] $out]
    }

    # --- Get ------------------------------------------------------------

    # Messages older than cursor. Truncates at the nearest older
    # hole (cannot cross a gap). Returns {messages $list bounded $b}
    # where bounded=1 iff a hole exists older than cursor and we
    # didn't satisfy the limit (caller should fall through to MAM).
    method "get before" {jid cursor {limit 50}} {
        set sentTs [$options(-db) onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp < $cursor
        }]
        set rows {}
        if {$sentTs eq ""} {
            $options(-db) eval [$self MsgSql {
                SELECT * FROM (
                    SELECT @cols@
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND timestamp < $cursor
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            }] row {
                lappend rows [$self RowToDict [array get row]]
            }
            return [dict create messages $rows bounded 0]
        }
        $options(-db) eval [$self MsgSql {
            SELECT * FROM (
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp < $cursor AND timestamp > $sentTs
                ORDER BY timestamp DESC
                LIMIT $limit
            ) ORDER BY timestamp ASC
        }] row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {[llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Symmetric to `get before`. Truncates at the nearest newer hole.
    method "get after" {jid cursor {limit 50}} {
        set sentTs [$options(-db) onecolumn {
            SELECT MIN(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp > $cursor
        }]
        set rows {}
        if {$sentTs eq ""} {
            $options(-db) eval [$self MsgSql {
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp > $cursor
                ORDER BY timestamp ASC
                LIMIT $limit
            }] row {
                lappend rows [$self RowToDict [array get row]]
            }
            return [dict create messages $rows bounded 0]
        }
        $options(-db) eval [$self MsgSql {
            SELECT @cols@
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND timestamp > $cursor AND timestamp < $sentTs
            ORDER BY timestamp ASC
            LIMIT $limit
        }] row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {[llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Most recent messages, truncated so the result never spans a
    # hole that sits between citizens. A hole sitting newer
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
        # Truncation hole = latest hole strictly older than the
        # latest message. A hole sitting newer than all messages
        # never separates clusters, so it cannot truncate.
        set truncTs [$options(-db) onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp < $latestMsgTs
        }]
        set anyHole [$options(-db) exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
        }]
        set rows {}
        if {$truncTs eq ""} {
            $options(-db) eval [$self MsgSql {
                SELECT * FROM (
                    SELECT @cols@
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            }] row {
                lappend rows [$self RowToDict [array get row]]
            }
        } else {
            $options(-db) eval [$self MsgSql {
                SELECT * FROM (
                    SELECT @cols@
                    FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND timestamp > $truncTs
                    ORDER BY timestamp DESC
                    LIMIT $limit
                ) ORDER BY timestamp ASC
            }] row {
                lappend rows [$self RowToDict [array get row]]
            }
        }
        # bounded if any hole exists and we didn't satisfy the
        # limit — either a cluster-separating hole truncated us,
        # or a future-edge hole signals more may arrive.
        set bounded [expr {$anyHole && [llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Full-text search over the msg_fts index: each query word matches a word
    # of the body by prefix, and a body must match every word. Returns message
    # dicts (newest first, capped at -limit). Holes have NULL body so they're
    # naturally excluded. Retracted rows keep their body as a tombstone but
    # read back with no content, so they're excluded too. A query with no
    # indexable word matches nothing rather than everything.
    #
    # An empty jid searches every chat in the account. Equal timestamps in
    # different chats are common - MAM ingest derives them from second-
    # granularity delay stamps and BumpTs only keeps them unique within one
    # chat - so the unscoped order breaks ties on chat_jid and its -before is
    # the {timestamp chat_jid} pair rather than a bare timestamp. A scoped
    # search keeps the scalar cursor.
    method search {jid query args} {
        array set opts {-limit 500 -before ""}
        array set opts $args
        set limit $opts(-limit)
        set before $opts(-before)
        set match [fts_match_expr $query]
        if {$match eq ""} { return {} }
        set sql [$self MsgSql {SELECT @cols@
                 FROM chat_message
                 WHERE kind='message' AND retracted=0
                   AND rowid IN (SELECT rowid FROM msg_fts
                                 WHERE msg_fts MATCH $match)}]
        if {$jid ne ""} {
            append sql { AND chat_jid=$jid}
            if {$before ne ""} { append sql { AND timestamp < $before} }
            append sql { ORDER BY timestamp DESC}
        } else {
            if {$before ne ""} {
                lassign $before beforeTs beforeChat
                append sql { AND (timestamp < $beforeTs
                             OR (timestamp = $beforeTs AND chat_jid < $beforeChat))}
            }
            append sql { ORDER BY timestamp DESC, chat_jid DESC}
        }
        append sql { LIMIT $limit}
        set rows {}
        $options(-db) eval $sql row {
            lappend rows [$self RowToDict [array get row]]
        }
        return $rows
    }

    # Find the nearest message to timestamp and return context around
    # it (limit/2 before + target + limit/2 after). Each side is
    # truncated independently at the nearest hole.
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
        $options(-db) eval [$self MsgSql {
            SELECT @cols@
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message' AND timestamp=$nearestTs
        }] row {
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
            $options(-db) eval [$self MsgSql {
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message' AND timestamp=$ts
            }] row {
                lappend rows [$self RowToDict [array get row]]
            }
        }
        return $rows
    }

    # The newest message of one chat, or "" when it has none.
    method lastMessage {chatJid} {
        set result ""
        $options(-db) eval [$self MsgSql {
            SELECT @cols@ FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
            ORDER BY timestamp DESC LIMIT 1
        }] row {
            set result [$self RowToDict [array get row]]
        }
        return $result
    }

    # chat_jid -> newest message, for every chat with history, in one pass.
    # timestamp is unique within a chat, so the join picks one row per chat.
    method lastMessages {} {
        set out {}
        $options(-db) eval [$self MsgSql {
            SELECT @cols@ FROM chat_message
            JOIN (SELECT chat_jid AS tail_jid, MAX(timestamp) AS tail_ts
                  FROM chat_message WHERE kind='message'
                  GROUP BY chat_jid) tail
              ON chat_jid=tail_jid AND timestamp=tail_ts
            WHERE kind='message'
        }] row {
            dict set out $row(chat_jid) [$self RowToDict [array get row]]
        }
        return $out
    }

    # Resolve an XEP-0461 reply target to its stored timestamp, or "".
    #   server_id match  : authoritative (stanza-id is unique in the archive).
    #   origin_id/own_id : client-generated ids aren't unique *across*
    #                      senders, so a genuine collision (two candidate
    #                      rows) is disambiguated by author (replyTo). A
    #                      single candidate is accepted regardless of
    #                      replyTo, which peers get wrong in practice (e.g.
    #                      misattributing the author of an undecryptable
    #                      target) with no ambiguity for it to resolve.
    # MUC authors are compared full (room/nick); 1:1 by bare JID (the reply's
    # `to` is often a full JID while we store the bare author).
    method resolveReply {jid replyId {replyTo ""}} {
        if {$replyId eq ""} { return "" }
        set ts [$options(-db) onecolumn {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND server_id != '' AND server_id=$replyId
            LIMIT 1
        }]
        if {$ts ne ""} { return $ts }

        set isMuc [IsMucChatJid $jid]
        set candidates {}
        $options(-db) eval {
            SELECT timestamp, from_jid FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND ( (origin_id != '' AND origin_id=$replyId)
                 OR (own_id    != '' AND own_id=$replyId) )
        } row {
            lappend candidates [list $row(timestamp) $row(from_jid)]
        }
        # A lone 1:1 candidate is trusted even if the peer's reply-to
        # attribute names the wrong author (real clients get this wrong):
        # only two senders are possible for this chat_jid. In a MUC,
        # origin_id/own_id aren't guaranteed unique across the room's many
        # senders, so a lone candidate still needs the author to match.
        if {[llength $candidates] == 1 && !$isMuc} {
            return [lindex $candidates 0 0]
        }
        foreach candidate $candidates {
            lassign $candidate ts fromJid
            if {$replyTo eq ""
                || ($isMuc && $fromJid eq $replyTo)
                || (!$isMuc && [jid bare $fromJid] eq [jid bare $replyTo])} {
                return $ts
            }
        }
        return ""
    }

    # --- Outgoing upload lifecycle -------------------------------------
    # An attachment send is stored as server_status='uploading' before the
    # HTTP PUT runs, so it shows immediately. On success the same row is
    # promoted to 'pending' (body/url/raw_xml filled in) and rejoins the
    # normal pending -> '' (server-confirmed) flow; on failure it becomes
    # 'failed'. Matched by own_id, which is stable from store time.

    method markUploaded {jid ownId url rawXml attachments {encryption ""}} {
        $options(-db) eval {
            UPDATE chat_message
            SET body=$url, raw_xml=$rawXml, attachments=$attachments,
                server_status='pending', encryption=$encryption
            WHERE chat_jid=$jid AND own_id=$ownId
              AND server_status='uploading'
        }
    }

    method markUploadFailed {jid ownId} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='failed'
            WHERE chat_jid=$jid AND own_id=$ownId
              AND server_status='uploading'
        }
    }

    # Retry: flip a previously failed upload back to uploading.
    method markUploading {jid ownId} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='uploading'
            WHERE chat_jid=$jid AND own_id=$ownId
              AND server_status='failed'
        }
    }

    # Startup recovery: an 'uploading' row left over from a previous run
    # was never sent (HTTP PUT isn't resumable), so mark it failed.
    method failStaleUploads {} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='failed'
            WHERE kind='message' AND server_status='uploading'
        }
    }

    # Flip pending → '' (server-confirmed) for each own_id (SM ack path).
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
                    UPDATE chat_message SET server_status=''
                    WHERE own_id=$oid AND server_status='pending'
                }
            }
        }
        return $confirmed
    }

    # Rank of a remote_status value; higher is further along the
    # delivered/read progression. Unknown values sort as 'none'.
    proc RemoteStatusRank {status} {
        switch -- $status {
            read      { return 2 }
            delivered { return 1 }
            default   { return 0 }
        }
    }

    # Advance outgoing messages' remote_status from an incoming
    # XEP-0184/0333 marker. $targetId is the marker's referenced id,
    # matched against our own_id (fallback origin_id). Forward-only: a
    # lower or equal rank (duplicate / out-of-order marker) is a no-op.
    # 'read' is an XEP-0333 <displayed/>, which means all messages up to
    # this point, so it also covers earlier rows; 'delivered' is an
    # XEP-0184 receipt and covers only the row it names.
    # Returns a timestamp-ordered list of {chat_jid, timestamp,
    # remote_status}, one per changed row, empty if nothing moved.
    method markRemoteStatus {chatJid targetId status} {
        if {$targetId eq ""} { return {} }
        set changed {}
        $options(-db) transaction {
            set targetTs ""
            $options(-db) eval {
                SELECT timestamp FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message' AND own_id != ''
                  AND (own_id=$targetId OR origin_id=$targetId)
                LIMIT 1
            } row {
                set targetTs $row(timestamp)
            }
            if {$targetTs ne ""} {
                set from [expr {$status eq "read" ? 0 : $targetTs}]
                set rank [RemoteStatusRank $status]
                # Collected first; updating mid-eval would edit the table
                # being walked. A 'read' marker range-scans the chat back to
                # its start every time; the != can't narrow that scan, it
                # only keeps a repeat marker from re-UPDATEing every row.
                set stale {}
                $options(-db) eval {
                    SELECT timestamp, remote_status FROM chat_message
                    WHERE chat_jid=$chatJid AND kind='message' AND own_id != ''
                      AND timestamp BETWEEN $from AND $targetTs
                      AND remote_status != $status
                    ORDER BY timestamp
                } row {
                    if {$rank > [RemoteStatusRank $row(remote_status)]} {
                        lappend stale $row(timestamp)
                    }
                }
                foreach ts $stale {
                    $options(-db) eval {
                        UPDATE chat_message SET remote_status=$status
                        WHERE chat_jid=$chatJid AND timestamp=$ts
                    }
                    lappend changed [dict create \
                        chat_jid $chatJid timestamp $ts remote_status $status]
                }
            }
        }
        return $changed
    }

    # --- Own read watermark ----------------------------------------

    # {read_ts read_id}; a chat we have never read reads as {0 ""}.
    method ownRead {chatJid} {
        set res [dict create read_ts 0 read_id ""]
        $options(-db) eval {
            SELECT read_ts, read_id FROM chat_own_read WHERE chat_jid=$chatJid
        } row {
            dict set res read_ts $row(read_ts)
            dict set res read_id $row(read_id)
        }
        return $res
    }

    # Advance the watermark to $ts, forward-only: an older-or-equal stamp
    # (a replayed or out-of-order marker) is a no-op. read_id comes from
    # the row at $ts. Returns 1 if it moved.
    method markOwnRead {chatJid ts} {
        if {![string is entier -strict $ts] || $ts <= 0} { return 0 }
        set moved 0
        $options(-db) transaction {
            set prev [$options(-db) onecolumn {
                SELECT read_ts FROM chat_own_read WHERE chat_jid=$chatJid
            }]
            if {$prev eq "" || $ts > $prev} {
                set refId [$options(-db) onecolumn {
                    SELECT CASE WHEN COALESCE(server_id,'') != ''
                                THEN server_id ELSE COALESCE(origin_id,'') END
                    FROM chat_message
                    WHERE chat_jid=$chatJid AND timestamp=$ts
                }]
                $options(-db) eval {
                    INSERT OR REPLACE INTO
                        chat_own_read(chat_jid, read_ts, read_id)
                    VALUES($chatJid, $ts, $refId)
                }
                set moved 1
            }
        }
        return $moved
    }

    # The newest unread messages past $floorTs, newest first, as
    # {timestamp mention from_jid} triples. The catch-up sweep caps how many
    # it takes; `unreadCount` still reports the true total.
    method unreadTail {chatJid floorTs limit} {
        set rows {}
        $options(-db) eval {
            SELECT timestamp, mentions_me, from_jid, body, attachments
            FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
              AND COALESCE(own_id,'')='' AND retracted=0
              AND timestamp > $floorTs
              AND timestamp > COALESCE((SELECT read_ts FROM chat_own_read
                                        WHERE chat_jid=$chatJid), 0)
            ORDER BY timestamp DESC LIMIT $limit
        } row {
            lappend rows [list $row(timestamp) $row(mentions_me) \
                $row(from_jid) $row(body) $row(attachments)]
        }
        return $rows
    }

    # Unread = theirs (own_id empty), kind='message', not a tombstone, and
    # newer than the watermark. Mentions are the subset that named us, so
    # one scan answers both: {unread $n mentions $m}.
    method unreadTally {chatJid} {
        set tally {unread 0 mentions 0}
        $options(-db) eval {
            SELECT COUNT(*) AS n, COALESCE(SUM(mentions_me=1),0) AS mentions
            FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
              AND COALESCE(own_id,'')='' AND retracted=0
              AND timestamp > COALESCE((SELECT read_ts FROM chat_own_read
                                        WHERE chat_jid=$chatJid), 0)
        } row {
            set tally [list unread $row(n) mentions $row(mentions)]
        }
        return $tally
    }

    method unreadCount {chatJid} {
        return [dict get [$self unreadTally $chatJid] unread]
    }

    # chat_jid -> {unread $n mentions $m}, in one pass. Chats with nothing
    # unread are absent.
    method unreadTallies {} {
        set tallies {}
        $options(-db) eval {
            SELECT m.chat_jid AS jid, COUNT(*) AS n,
                   COALESCE(SUM(m.mentions_me=1),0) AS mentions
            FROM chat_message m
            LEFT JOIN chat_own_read r ON r.chat_jid=m.chat_jid
            WHERE m.kind='message' AND COALESCE(m.own_id,'')=''
              AND m.retracted=0
              AND m.timestamp > COALESCE(r.read_ts, 0)
            GROUP BY m.chat_jid
        } row {
            dict set tallies $row(jid) [list unread $row(n) \
                mentions $row(mentions)]
        }
        return $tallies
    }

    method unreadCounts {} {
        set counts {}
        dict for {jid tally} [$self unreadTallies] {
            dict set counts $jid [dict get $tally unread]
        }
        return $counts
    }

    # Did one stored message name us? Queried rather than carried on the
    # message dict, which keeps it out of every SELECT list.
    method mentionAt {chatJid ts} {
        set v [$options(-db) onecolumn {
            SELECT mentions_me FROM chat_message
            WHERE chat_jid=$chatJid AND timestamp=$ts
        }]
        return [expr {$v eq "" ? 0 : $v}]
    }

    method mentionCount {chatJid} {
        return [dict get [$self unreadTally $chatJid] mentions]
    }

    # chat_jid -> unread messages that named us. Absent when none.
    method mentionCounts {} {
        set counts {}
        dict for {jid tally} [$self unreadTallies] {
            set n [dict get $tally mentions]
            if {$n > 0} { dict set counts $jid $n }
        }
        return $counts
    }

    # --- Notification policy ---------------------------------------

    # {muted mentions} for a chat. With no stored override, rooms start
    # muted and 1:1 chats do not. `?join` is the room test, so a MUC PM
    # counts as a direct conversation and defaults unmuted.
    method notifyPolicy {chatJid} {
        set res [dict create \
            muted [expr {[string match {*\?join} $chatJid] ? 1 : 0}] \
            mentions 1]
        $options(-db) eval {
            SELECT muted, mentions FROM chat_notify WHERE chat_jid=$chatJid
        } row {
            dict set res muted $row(muted)
            dict set res mentions $row(mentions)
        }
        return $res
    }

    method setNotifyPolicy {chatJid muted mentions} {
        $options(-db) eval {
            INSERT OR REPLACE INTO chat_notify(chat_jid, muted, mentions)
            VALUES($chatJid, $muted, $mentions)
        }
    }

    # --- Reactions (XEP-0444) --------------------------------------

    # Apply a reactor's full emoji set. Last-writer-wins: a set with an
    # older-or-equal ts than the reactor's stored one is ignored. Returns
    # the target message's local timestamp (so the caller can <Reactions>), or
    # "" when LWW skipped it or the target message isn't stored yet.
    method applyReaction {chatJid targetId senderId senderLabel isOwn emojis ts} {
        if {$targetId eq "" || $senderId eq ""} { return "" }
        set prev [$options(-db) onecolumn {
            SELECT ts FROM message_reaction
            WHERE chat_jid=$chatJid AND target_id=$targetId
              AND sender_id=$senderId
        }]
        if {$prev ne "" && $ts <= $prev} { return "" }
        $options(-db) eval {
            INSERT OR REPLACE INTO message_reaction(chat_jid, target_id,
                    sender_id, sender_label, is_own, emojis, ts)
            VALUES($chatJid, $targetId, $senderId, $senderLabel, $isOwn,
                   $emojis, $ts)
        }
        return [$self resolveTargetTs $chatJid $targetId]
    }

    # My current emoji set for a target - the toggle source of truth.
    method ownReactions {chatJid targetId ownSenderId} {
        return [$options(-db) onecolumn {
            SELECT emojis FROM message_reaction
            WHERE chat_jid=$chatJid AND target_id=$targetId
              AND sender_id=$ownSenderId
        }]
    }

    # Local timestamp of a stored message matched by its wire id, against
    # the stored envelope ids (mirrors resolveReply's id match). "" if not
    # stored. Shared by reactions, edits, and retractions.
    method resolveTargetTs {chatJid targetId} {
        if {$targetId eq ""} { return "" }
        return [$options(-db) onecolumn {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
              AND ( (server_id != '' AND server_id=$targetId)
                 OR (origin_id != '' AND origin_id=$targetId)
                 OR (own_id    != '' AND own_id=$targetId) )
            LIMIT 1
        }]
    }

    # --- Corrections (XEP-0308) / retractions (XEP-0424/0425) ------

    # Replace a stored message's body with a correction. Last-writer-wins on
    # edited_ts; a retracted message is immutable. Returns the target's local
    # timestamp (so the caller can <Edited>), or "" when not stored or skipped.
    # `stamp` is the correction's own {encryption sender_fp}, so the row
    # tracks the body now displayed. No default: it would be a downgrade.
    method applyEdit {chatJid targetId newBody rawXml ts stamp} {
        set enc [dict get $stamp encryption]
        set senderFp [dict get $stamp sender_fp]
        set targetTs [$self resolveTargetTs $chatJid $targetId]
        if {$targetTs eq ""} { return "" }
        set prev 0
        set retracted 0
        $options(-db) eval {
            SELECT edited_ts, retracted FROM chat_message
            WHERE chat_jid=$chatJid AND timestamp=$targetTs
        } row {
            set prev $row(edited_ts)
            set retracted $row(retracted)
        }
        if {$retracted} { return "" }
        if {$ts <= $prev} { return "" }
        $options(-db) eval {
            UPDATE chat_message
            SET body=$newBody, raw_xml=$rawXml, edited_ts=$ts,
                encryption=$enc, sender_fp=$senderFp
            WHERE chat_jid=$chatJid AND timestamp=$targetTs
        }
        return $targetTs
    }

    # Tombstone a stored message. Sticky: once retracted, later edits no-op.
    # Returns the target's local timestamp, or "" when not stored.
    method applyRetract {chatJid targetId} {
        set targetTs [$self resolveTargetTs $chatJid $targetId]
        if {$targetTs eq ""} { return "" }
        $options(-db) eval {
            UPDATE chat_message SET retracted=1
            WHERE chat_jid=$chatJid AND timestamp=$targetTs
        }
        return $targetTs
    }

    # Per-emoji aggregation of reactions on a displayed message, for the
    # GUI. Joins reaction rows against the message's envelope ids so it
    # works whether reactors targeted the origin-id (1:1) or stanza-id
    # (MUC). Emoji order is first-seen; count is left to the GUI. Shape:
    #   {emoji {reactors {Alice Bob} mine 0|1} ...}
    method reactionsForMessage {chatJid ts} {
        set order {}
        array set reactors {}
        array set mine {}
        $options(-db) eval {
            SELECT r.sender_label AS label, r.is_own AS own,
                   r.emojis AS emojis
            FROM message_reaction r
            JOIN chat_message m
              ON m.chat_jid = r.chat_jid
             AND m.kind = 'message'
             AND ( (m.server_id != '' AND m.server_id = r.target_id)
                OR (m.origin_id != '' AND m.origin_id = r.target_id)
                OR (m.own_id    != '' AND m.own_id    = r.target_id) )
            WHERE m.chat_jid = $chatJid AND m.timestamp = $ts
        } r {
            foreach e $r(emojis) {
                if {![info exists reactors($e)]} {
                    set reactors($e) {}
                    set mine($e) 0
                    lappend order $e
                }
                lappend reactors($e) $r(label)
                if {$r(own)} { set mine($e) 1 }
            }
        }
        set agg [dict create]
        foreach e $order {
            dict set agg $e [dict create reactors $reactors($e) mine $mine($e)]
        }
        return $agg
    }

    # Dedup by server_id/own_id only, for the caller to act on before any
    # decrypt. An id-less stanza returns `new` and is content-deduped later
    # by `store`. Verdicts:
    #   confirmed - matched a pending send (or an SM-acked one still lacking
    #               a server_id this copy carries): flip to '', capture
    #               server_id, relocate to the server ts; returns old/new ts
    #               for the <Confirmed>.
    #   duplicate - matched any other row; returns its `stored_ts`.
    #   new       - no id match.
    method reconcile {jid serverId ownId originId timestamp {occupantId ""}} {
        if {$serverId eq "" && $ownId eq ""} {
            return [dict create verdict new]
        }
        set row ""
        $options(-db) eval {
            SELECT timestamp, server_status, server_id FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND ( ($serverId != '' AND server_id=$serverId)
                 OR ($ownId != '' AND own_id=$ownId) )
            LIMIT 1
        } r {
            set row [dict create timestamp $r(timestamp) \
                server_status $r(server_status) server_id $r(server_id)]
        }
        if {$row eq ""} {
            return [dict create verdict new]
        }
        set status [dict get $row server_status]
        if {!($status eq "pending"
              || ($status eq "" && [dict get $row server_id] eq ""
                  && $serverId ne ""))} {
            return [dict create verdict duplicate \
                stored_ts [dict get $row timestamp]]
        }
        set dupTs [dict get $row timestamp]
        if {$timestamp == $dupTs} {
            set newTs $dupTs
        } else {
            set newTs [$self BumpTs $jid $timestamp 1]
        }
        $options(-db) eval {
            UPDATE chat_message
            SET timestamp=$newTs,
                server_status='',
                server_id = CASE WHEN $serverId != ''
                    THEN $serverId ELSE server_id END,
                occupant_id = CASE WHEN $occupantId != ''
                    THEN $occupantId ELSE occupant_id END
            WHERE chat_jid=$jid AND timestamp=$dupTs
        }
        return [dict create verdict confirmed chat_jid $jid \
            timestamp $dupTs newtimestamp $newTs]
    }

    # Single enrichment point for DB rows -> message dicts.
    # All get methods funnel through here; event emitters (store,
    # send, search) read back via get ids so live messages are
    # enriched too.
    method RowToDict {row} {
        # sqlite3's `eval ... row {}` sets row(*) to the column list, which
        # `array get` hands us. Drop it before it reaches the wire.
        set d [messagestyling::enrich [dict remove $row *]]
        # Direction is a protocol fact, not a display concern: a message is
        # ours iff it carries an own_id, which ingest sets when it resolves
        # the sender as us (bare JID in 1:1, occupant-id in a MUC). The GUI
        # reads this flag rather than re-deriving it.
        dict set d is_outgoing [expr {[dict get $d own_id] ne ""}]
        # XEP-0308/0424 state as booleans for the GUI (edited_ts is also the
        # LWW guard, but the GUI only cares whether an edit happened).
        dict set d edited [expr {[dict get $d edited_ts] != 0}]
        dict set d retracted [expr {[dict get $d retracted] != 0}]
        if {[dict exists $d reply_id] && [dict get $d reply_id] ne ""} {
            set chatJid [dict get $d chat_jid]
            set targetTs [$self resolveReply $chatJid \
                [dict get $d reply_id] [dict get $d reply_to]]
            if {$targetTs ne ""} {
                dict set d reply_to_ts $targetTs
                # Trust the resolved row's own from_jid over the stanza's
                # reply-to attribute, which peer clients can get wrong.
                lassign [$options(-db) eval {
                    SELECT from_jid, body FROM chat_message
                    WHERE chat_jid=$chatJid AND timestamp=$targetTs
                }] targetFrom targetBody
                dict set d reply_author_jid \
                    [NormalizeAuthorJid $chatJid $targetFrom]
                if {$targetBody ne ""} {
                    dict set d reply_body [ReplyPreview $targetBody]
                }
            } else {
                dict set d reply_author_jid \
                    [NormalizeAuthorJid $chatJid [dict get $d reply_to]]
            }
        }
        # Fold the payload into a typed content union; a retracted row is a
        # tombstone with no content (its body/attachments never reach the wire).
        set fmt [expr {[dict exists $d formatting] ? [dict get $d formatting] : ""}]
        if {![dict get $d retracted]} {
            if {[dict exists $d attachments]
                && [llength [dict get $d attachments]] > 0} {
                # Rows outlive the shape they were written with.
                set atts [lmap a [dict get $d attachments] {
                    dict merge \
                        {url "" path "" type file name "" size "" mime ""} $a
                }]
                set content [dict create type media \
                    attachments $atts \
                    caption [attachment_caption [dict get $d body] $atts]]
            } elseif {[dict exists $d invite] && [dict get $d invite] ne ""} {
                set inv [dict merge {room "" inviter "" reason ""} \
                    [dict get $d invite]]
                set content [dict create type invite \
                    room [dict get $inv room] inviter [dict get $inv inviter] \
                    reason [dict get $inv reason] \
                    state [$self InviteState [dict get $inv room] \
                        [expr {[dict exists $d invite_declined]
                            && [dict get $d invite_declined]}]] \
                    body [dict get $d body]]
            } elseif {[dict exists $d call] && [dict get $d call] ne ""} {
                set call [dict merge {room "" id "" inviter "" video 0} \
                    [dict get $d call]]
                set room [dict get $call room]
                set content [dict create type call \
                    room $room id [dict get $call id] \
                    inviter [dict get $call inviter] \
                    video [dict get $call video] \
                    state [expr {[dict exists $d call_state]
                                 && [dict get $d call_state] ne ""
                                 ? [dict get $d call_state] : "pending"}] \
                    active [expr {$options(-incallcmd) ne "" && $room ne ""
                                  && [{*}$options(-incallcmd) $room] ? 1 : 0}] \
                    body [dict get $d body]]
                # Absent until the call's room has been asked.
                if {$options(-livecmd) ne "" && $room ne ""} {
                    set live [{*}$options(-livecmd) [dict get $d chat_jid] \
                        [dict get $d timestamp] $room]
                    if {$live ne ""} { dict set content live $live }
                }
            } else {
                set content [dict create type text body [dict get $d body]]
            }
            if {$fmt ne ""} { dict set content formatting $fmt }
            dict set d content $content
        }
        foreach k {body caption attachments formatting invite invite_declined
                   call call_state} {
            dict unset d $k
        }
        set reactions [$self reactionsForMessage \
            [dict get $d chat_jid] [dict get $d timestamp]]
        if {[dict size $reactions] > 0} {
            dict set d reactions $reactions
        }
        return $d
    }

    # joined outranks declined: declining and joining later is joining.
    method InviteState {room declined} {
        if {$options(-joinedcmd) ne "" && $room ne ""
                && [{*}$options(-joinedcmd) $room]} {
            return joined
        }
        return [expr {$declined ? "declined" : "pending"}]
    }

    method IsDuplicate {jid msg} {
        set sid [dict get $msg server_id]
        set oid [dict get $msg own_id]
        if {$sid ne "" || $oid ne ""} {
            return [$options(-db) exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND ( ($sid != '' AND server_id=$sid)
                     OR ($oid != '' AND own_id=$oid) )
            }]
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
            return [$options(-db) exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND timestamp BETWEEN $tsBase AND $tsEnd
                  AND from_jid=$from AND body=$body
            }]
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

# The words of a search query. A word with nothing alphanumeric in it indexes
# to no token, so it can only make the query unparseable.
proc search_query_words {query} {
    lmap w [regexp -all -inline {\S+} $query] {
        if {![regexp {[[:alnum:]]} $w]} continue
        set w
    }
}

# FTS5 expression matching every query word by prefix. Quoting each word (and
# doubling any quote of its own) is what keeps `AND`, a stray bracket and the
# rest of the query syntax as text to match rather than operators to obey.
proc fts_match_expr {query} {
    join [lmap w [search_query_words $query] {
        format {"%s"*} [string map {\" \"\"} $w]
    }] " "
}

proc ReplyPreview {body} {
    set line [lindex [split $body \n] 0]
    if {[string length $line] > 80} {
        set line "[string range $line 0 79]…"
    }
    return $line
}
