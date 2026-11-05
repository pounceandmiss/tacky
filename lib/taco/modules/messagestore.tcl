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
#   place:   `hole addAfter`/`addBefore $jid $pos` beside a row, `hole
#            append $jid` at a chat's end
#   remove:  `hole removeGap` (RSM-complete), `hole clearProven` (what a
#            MAM page proves contiguous), `hole drop` (one hole)
# A hole sits at a pos like any row: older/newer is where it sits among them.
#
# === Order ===
#
# Rows sort by pos (see poskey), the order the archive holds them in, which
# is not their timestamps': a live message carries our clock, an archived one
# the server's. A live message goes after the chat's last row; a page from
# the archive goes in the gap it was fetched for, between the rows either
# side of it (message.tcl decides which, StorePage). A row never moves once
# placed.
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
    # it), {*}livecmd $chat $id $room -> 1|0|"" (anyone is; "" unknown).
    option -incallcmd -default ""
    option -livecmd -default ""
    # {*}deferredcmd $chat $patches, after a store inserted the target of
    # corrections/retractions held by `defer`. Each patch is
    # {kind K timestamp T patch P}, already removed from the table.
    option -deferredcmd -default ""

    # Columns every message read path returns, in one place so a new column
    # reaches all of them. Spliced in for the @cols@ placeholder by MsgSql.
    typevariable MsgCols {id, pos, timestamp, chat_jid, from_jid, from_resource, body,
                          server_id, own_id, occupant_id, edited_ts, retracted,
                          reply_id, reply_to, server_status, remote_status,
                          encryption, sender_fp, fail_reason, attachments,
                          invite, invite_declined, call, call_state}
    # Deferred corrections/retractions kept per chat (see `defer`).
    typevariable MaxDeferred 500
    # Reactions whose target is not stored, kept for when it is: at most
    # this many per reactor in a chat, and in all per chat, the oldest
    # going first (CapOrphanReactions).
    typevariable MaxOrphanReactionsPerSender 100
    typevariable MaxOrphanReactions 500

    constructor args {
        $self configurelist $args
    }

    method MsgSql {sql} {
        return [string map [list @cols@ $MsgCols] $sql]
    }

    # SQL bounding $col by the caller's variable $var with $op, or nothing
    # when that is "" (an open end). Spelled out rather than `($v = '' OR
    # ...)`, which keeps SQLite off the index.
    proc Bound {col op var} {
        upvar 1 $var v
        if {$v eq ""} { return "" }
        return " AND $col $op \$$var"
    }

    # --- Group call invites -------------------------------------------

    # One stored call invite as {call state}, or "" when row $id in $jid is
    # not one.
    method callAt {jid id} {
        set found ""
        $options(-db) eval {
            SELECT call, call_state FROM chat_message
            WHERE chat_jid=$jid AND id=$id AND kind='message'
              AND call_room != ''
        } r {
            set found [dict create call $r(call) state $r(call_state)]
        }
        return $found
    }

    method setCallState {jid id state} {
        $options(-db) eval {
            UPDATE chat_message SET call_state=$state
            WHERE chat_jid=$jid AND id=$id AND call_room != ''
        }
    }

    # The rows in $jid holding the call invite $callId, as {id state room}.
    method callsById {jid callId} {
        set found {}
        $options(-db) eval {
            SELECT id, call_state, call_room FROM chat_message
            WHERE chat_jid=$jid AND call_id=$callId AND call_room != ''
              AND kind='message'
        } r {
            lappend found [list $r(id) $r(call_state) $r(call_room)]
        }
        return $found
    }

    # The last call invite in $jid, as {id room}, or "".
    method newestCall {jid} {
        set found ""
        $options(-db) eval {
            SELECT id, call_room FROM chat_message
            WHERE chat_jid=$jid AND call_room != '' AND kind='message'
            ORDER BY pos DESC LIMIT 1
        } r {
            set found [list $r(id) $r(call_room)]
        }
        return $found
    }

    # Every stored invite to the call in $room, wherever it sits, as
    # {chat_jid id}.
    method callsToRoom {room} {
        set found {}
        $options(-db) eval {
            SELECT chat_jid, id FROM chat_message
            WHERE call_room=$room AND kind='message'
        } r {
            lappend found [list $r(chat_jid) $r(id)]
        }
        return $found
    }

    # --- Invites ----------------------------------------------------

    # One stored invitation as {invite declined}, or "" when row $id in $jid
    # is not one.
    method inviteAt {jid id} {
        set found ""
        $options(-db) eval {
            SELECT invite, invite_declined FROM chat_message
            WHERE chat_jid=$jid AND id=$id AND kind='message'
              AND invite_room != ''
        } r {
            set found [dict create invite $r(invite) declined $r(invite_declined)]
        }
        return $found
    }

    method setInviteDeclined {jid id declined} {
        $options(-db) eval {
            UPDATE chat_message SET invite_declined=$declined
            WHERE chat_jid=$jid AND id=$id AND invite_room != ''
        }
    }

    # Every stored invitation to $room, wherever it sits, as {chat_jid id}.
    method invitesToRoom {room} {
        set found {}
        $options(-db) eval {
            SELECT chat_jid, id FROM chat_message
            WHERE invite_room != '' AND invite_room=$room AND kind='message'
        } r {
            lappend found [list $r(chat_jid) $r(id)]
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

    # Drop a chat's whole history, its holes, read mark and client data with it.
    method forgetChat {jid} {
        $options(-db) eval {
            DELETE FROM chat_message WHERE chat_jid=$jid;
            DELETE FROM chat_own_read WHERE chat_jid=$jid;
            DELETE FROM message_alias WHERE chat_jid=$jid;
            DELETE FROM chat_archive_mark WHERE chat_jid=$jid;
            DELETE FROM chat_client_data WHERE chat_jid=$jid;
        }
    }

    # --- Holes ------------------------------------------------------

    # A hole right after the row at $pos (the gap on its newer side), unless
    # one already marks that gap (at most one between two citizens). The
    # new hole's pos, or "" when none was needed.
    method "hole addAfter" {jid pos} {
        lassign [$self GapBounds $jid newer $pos] lo hi
        if {[$self HoleIn $jid $lo $hi]} return
        set next [$self PosNext $jid $pos]
        $self InsertHole $jid [poskey between $pos $next] [$self TsAt $jid $pos] 1
    }

    # A hole right before the row at $pos (the gap on its older side).
    method "hole addBefore" {jid pos} {
        lassign [$self GapBounds $jid older $pos] lo hi
        if {[$self HoleIn $jid $lo $hi]} return
        set prev [$self PosPrev $jid $pos]
        $self InsertHole $jid [poskey between $prev $pos] [$self TsAt $jid $pos] -1
    }

    # A hole after a chat's last row, unless that is one: whatever the
    # archive took in since. Its pos, or "" when none was added.
    method "hole append" {jid} {
        set last ""
        $options(-db) eval {
            SELECT pos, kind, timestamp FROM chat_message
            WHERE chat_jid=$jid ORDER BY pos DESC LIMIT 1
        } row {
            set last [list $row(pos) $row(kind) $row(timestamp)]
        }
        if {$last eq "" || [lindex $last 1] eq "hole"} return
        $self InsertHole $jid [poskey between [lindex $last 0] ""] \
            [lindex $last 2] 1
    }

    # Tests-only: by the timestamp of the row it goes beside, `newer` after
    # it, `older` before it. An anchor no row holds is placed by time.
    method "hole add" {jid direction anchorTs} {
        set pos [$self PosOfTs $jid $anchorTs]
        if {$pos eq ""} {
            set pos [$self PosForTs $jid $anchorTs]
            lassign [$self GapBounds $jid $direction $pos] lo hi
            if {[$self HoleIn $jid $lo $hi]} return
            $options(-db) eval {
                INSERT INTO chat_message(pos, timestamp, chat_jid, kind)
                VALUES($pos, $anchorTs, $jid, 'hole')
            }
            return $anchorTs
        }
        switch -- $direction {
            newer { set holePos [$self hole addAfter $jid $pos] }
            older { set holePos [$self hole addBefore $jid $pos] }
            default { error "direction must be older or newer, got: $direction" }
        }
        if {$holePos eq ""} return
        $self TsAt $jid $holePos
    }

    # Remove the hole(s) in the gap on the $direction side of the row at
    # $pos. Invariant says at most one; defensive plural costs the same.
    method "hole removeGap" {jid direction pos} {
        lassign [$self GapBounds $jid $direction $pos] lo hi
        $self hole clear $jid $lo $hi
    }

    # Tests-only: by the timestamp of the row the gap is beside.
    method "hole remove" {jid direction anchorTs} {
        set pos [$self PosOfTs $jid $anchorTs]
        if {$pos eq ""} return
        $self hole removeGap $jid $direction $pos
    }

    # Delete the holes a page proves false. $seq is the places of what the
    # page held, in the archive's order (with the row it continues after
    # first and the row it goes below last, when it has them): each pair next
    # to each other there has nothing between them in the archive. A hole
    # between such a pair goes, unless another citizen sits between them
    # here - one the page did not hold, placed where it came in (an offline
    # store's message), whose gap is its own. Sends of ours are no evidence
    # either way: they sit where they were written (PlaceOf).
    # $openTop: the page speaks for everything after its last row too.
    method "hole clearProven" {jid seq openTop} {
        foreach a [lrange $seq 0 end-1] b [lrange $seq 1 end] {
            if {[string compare $a $b] >= 0} continue
            if {[$options(-db) exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND kind='message' AND server_id != ''
                  AND COALESCE(own_id, '') = '' AND pos > $a AND pos < $b
            }]} continue
            $self hole clear $jid $a $b
        }
        set last [lindex $seq end]
        if {$openTop && $last ne "" && ![$options(-db) exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$jid AND kind='message' AND server_id != ''
                  AND COALESCE(own_id, '') = '' AND pos > $last
            }]} {
            $self hole clear $jid $last ""
        }
    }

    # Delete the hole at $pos.
    method "hole drop" {jid pos} {
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='hole' AND pos=$pos
        }
    }

    # Delete the holes strictly between $lo and $hi ("" for an open end).
    method "hole clear" {jid lo hi} {
        $options(-db) eval "
            DELETE FROM chat_message
            WHERE chat_jid=\$jid AND kind='hole' [Bound pos > lo] [Bound pos < hi]
        "
    }

    # Tests-only: delete the holes stamped strictly between $loTs and $hiTs.
    method "hole removeBetween" {jid loTs hiTs} {
        $options(-db) eval {
            DELETE FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
              AND timestamp > $loTs AND timestamp < $hiTs
        }
    }

    # Tests-only: the holes' timestamps, in the order they sit.
    method "hole list" {jid} {
        $options(-db) eval {
            SELECT timestamp FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
            ORDER BY pos ASC
        }
    }

    # The pos of each hole in $jid, in order.
    method "hole positions" {jid} {
        $options(-db) eval {
            SELECT pos FROM chat_message
            WHERE chat_jid=$jid AND kind='hole' ORDER BY pos ASC
        }
    }

    method HoleIn {jid lo hi} {
        $options(-db) exists "
            SELECT 1 FROM chat_message
            WHERE chat_jid=\$jid AND kind='hole' [Bound pos > lo] [Bound pos < hi]
        "
    }

    # A hole at $pos, stamped next to $nearTs ($step away); its pos.
    method InsertHole {jid pos nearTs step} {
        set ts [expr {$nearTs + $step}]
        $options(-db) eval {
            INSERT INTO chat_message(pos, timestamp, chat_jid, kind)
            VALUES($pos, $ts, $jid, 'hole')
        }
        return $pos
    }

    # Bounds of the gap immediately $direction of the row at $pos, as {lo
    # hi}: the nearest citizen's pos that way ("" for none) and $pos itself.
    method GapBounds {jid direction pos} {
        switch -- $direction {
            older {
                set lo [$options(-db) onecolumn {
                    SELECT MAX(pos) FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND server_id IS NOT NULL AND server_id != ''
                      AND pos < $pos
                }]
                return [list $lo $pos]
            }
            newer {
                set hi [$options(-db) onecolumn {
                    SELECT MIN(pos) FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND server_id IS NOT NULL AND server_id != ''
                      AND pos > $pos
                }]
                return [list $pos $hi]
            }
            default {
                error "direction must be older or newer, got: $direction"
            }
        }
    }

    # --- Places ---------------------------------------------------------

    # The pos of the row after/before $pos in $jid, of any kind; "" at
    # the end. With $pos "", the first/last row.
    method PosNext {jid pos} {
        $options(-db) onecolumn "
            SELECT MIN(pos) FROM chat_message
            WHERE chat_jid=\$jid [Bound pos > pos]
        "
    }

    method PosPrev {jid pos} {
        $options(-db) onecolumn "
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=\$jid [Bound pos < pos]
        "
    }

    # The pos of row $id in $jid, "" when there is none.
    method PosOf {jid id} {
        $options(-db) onecolumn {
            SELECT pos FROM chat_message WHERE chat_jid=$jid AND id=$id
        }
    }

    # The timestamp row $id in $jid shows, "" when there is no such row.
    method stampOf {jid id} {
        $options(-db) onecolumn {
            SELECT timestamp FROM chat_message WHERE chat_jid=$jid AND id=$id
        }
    }

    # The pos of row $id when it can stand for where the archive has it: ""
    # for a send of ours, which sits where it was written however much later
    # the archive took it in.
    method PlaceOf {jid id} {
        $options(-db) onecolumn {
            SELECT pos FROM chat_message
            WHERE chat_jid=$jid AND id=$id AND COALESCE(own_id, '') = ''
        }
    }

    # The id of the row at $pos in $jid, "" when there is none.
    method IdAt {jid pos} {
        $options(-db) onecolumn {
            SELECT id FROM chat_message WHERE chat_jid=$jid AND pos=$pos
        }
    }

    # Tests-only: the pos of the message stamped $ts, "" when none is.
    method PosOfTs {jid ts} {
        $options(-db) onecolumn {
            SELECT pos FROM chat_message
            WHERE chat_jid=$jid AND timestamp=$ts AND kind='message'
        }
    }

    method TsAt {jid pos} {
        $options(-db) onecolumn {
            SELECT timestamp FROM chat_message WHERE chat_jid=$jid AND pos=$pos
        }
    }


    # --- Store ----------------------------------------------------------

    # Insert messages, skipping any already stored (by server_id/own_id, or
    # content for id-less ones), e.g. one repeated within a MAM page.
    # Confirming our own sends is `reconcile`'s job. Where each goes: its
    # `pos` when it has one, else by $placement: `append` after the chat's
    # last row (a live message), `ts` among the rows by timestamp (one with
    # nothing better to go by; a batch keeps its own order). Returns dict
    # with `inserted` (the stored rows' ids) and `positions` (their pos).
    method store {messages {placement ts}} {
        if {[llength $messages] == 0} { return {} }

        set jid [dict get [lindex $messages 0] chat_jid]
        set inserted {}
        set positions {}
        set deferred {}
        set prev ""

        $options(-db) transaction {
            foreach msg $messages {
                if {[$self IsDuplicate $jid $msg]} continue
                array unset m
                array set m $msg

                set ts $m(timestamp)
                if {[info exists m(pos)] && $m(pos) ne ""} {
                    set pos $m(pos)
                } elseif {$placement eq "append"} {
                    set pos [poskey between [$self PosPrev $jid ""] ""]
                } elseif {$prev ne ""} {
                    set pos [poskey between $prev [$self PosNext $jid $prev]]
                } else {
                    set pos [$self PosForTs $jid $ts]
                }

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
                set undecrypted [expr {[info exists m(undecrypted)] \
                    ? $m(undecrypted) : 0}]
                $options(-db) eval {
                    INSERT INTO chat_message(pos, timestamp, chat_jid, from_jid,
                        from_resource, body, server_id, own_id, origin_id,
                        occupant_id, reply_id, reply_to, raw_xml, server_status,
                        encryption, sender_fp, fail_reason, mentions_me,
                        attachments, invite, invite_room, call, call_room,
                        call_id, call_state, undecrypted)
                    VALUES($pos, $ts, $jid, $m(from_jid), $fromRes, $m(body),
                        $m(server_id), $m(own_id), $originId,
                        $occId, $replyId, $replyTo, $m(raw_xml), $status, $enc,
                        $senderFp, $failReason, $mention, $attach, $invite,
                        $inviteRoom, $call, $callRoom, $callId, $callState,
                        $undecrypted)
                    -- edited_ts/retracted take table defaults (only ever set
                    -- by applyEdit/applyRetract, never at insert time)
                }
                set prev $pos
                lappend inserted [$options(-db) last_insert_rowid]
                lappend positions $pos
                lappend deferred {*}[$self TakeDeferred $jid \
                    [list $m(server_id) $m(own_id) $originId]]
            }
        }
        if {[llength $deferred] && $options(-deferredcmd) ne ""} {
            {*}$options(-deferredcmd) $jid $deferred
        }
        return [dict create inserted $inserted positions $positions]
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

    # Remove and return the deferred patches aimed at any of $ids in the
    # order they arrived, so successive corrections land in the order they
    # were made. Not by timestamp: those can be on two clocks (PatchWins).
    method TakeDeferred {chatJid ids} {
        set out {}
        foreach id [lsort -unique $ids] {
            if {$id eq ""} continue
            $options(-db) eval {
                SELECT rowid, kind, timestamp, patch FROM pending_patch
                WHERE chat_jid=$chatJid AND target_id=$id
            } row {
                lappend out [list $row(rowid) [dict create kind $row(kind) \
                    timestamp $row(timestamp) patch $row(patch)]]
            }
            $options(-db) eval {
                DELETE FROM pending_patch
                WHERE chat_jid=$chatJid AND target_id=$id
            }
        }
        return [lmap p [lsort -integer -index 0 $out] { lindex $p 1 }]
    }

    # --- Get ------------------------------------------------------------

    # Messages before row $cursor (an id). Truncates at the nearest hole
    # before it (cannot cross a gap). Returns {messages $list bounded $b}
    # where bounded=1 iff a hole exists before the cursor and we didn't
    # satisfy the limit (caller should fall through to MAM).
    method "get before" {jid cursor {limit 50}} {
        $self GetBeforePos $jid [$self PosOf $jid $cursor] $limit
    }

    method GetBeforePos {jid cursor limit} {
        set sentPos [$options(-db) onecolumn "
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=\$jid AND kind='hole' [Bound pos < cursor]
        "]
        set rows {}
        $options(-db) eval [$self MsgSql "
            SELECT * FROM (
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=\$jid AND kind='message'
                  [Bound pos < cursor] [Bound pos > sentPos]
                ORDER BY pos DESC
                LIMIT \$limit
            ) ORDER BY pos ASC
        "] row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {$sentPos ne "" && [llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Symmetric to `get before`. Truncates at the nearest newer hole.
    method "get after" {jid cursor {limit 50}} {
        $self GetAfterPos $jid [$self PosOf $jid $cursor] $limit
    }

    method GetAfterPos {jid cursor limit} {
        set sentPos [$options(-db) onecolumn "
            SELECT MIN(pos) FROM chat_message
            WHERE chat_jid=\$jid AND kind='hole' [Bound pos > cursor]
        "]
        set rows {}
        $options(-db) eval [$self MsgSql "
            SELECT @cols@
            FROM chat_message
            WHERE chat_jid=\$jid AND kind='message'
              [Bound pos > cursor] [Bound pos < sentPos]
            ORDER BY pos ASC
            LIMIT \$limit
        "] row {
            lappend rows [$self RowToDict [array get row]]
        }
        set bounded [expr {$sentPos ne "" && [llength $rows] < $limit}]
        return [dict create messages $rows bounded $bounded]
    }

    # Most recent messages, truncated so the result never spans a
    # hole that sits between citizens. A hole sitting newer
    # than every message (reconnect placement) does not truncate —
    # the existing citizens are still the latest cluster — but it
    # does flip bounded=1 to signal more might arrive via MAM.
    method "get latest" {jid {limit 50}} {
        set latestPos [$options(-db) onecolumn {
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
        }]
        if {$latestPos eq ""} {
            return [dict create messages {} bounded 0]
        }
        # Truncation hole = latest hole below the latest message. A hole
        # sitting above all messages never separates clusters, so it
        # cannot truncate.
        set truncPos [$options(-db) onecolumn {
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=$jid AND kind='hole' AND pos < $latestPos
        }]
        set anyHole [$options(-db) exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$jid AND kind='hole'
        }]
        set rows {}
        $options(-db) eval [$self MsgSql "
            SELECT * FROM (
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=\$jid AND kind='message' [Bound pos > truncPos]
                ORDER BY pos DESC
                LIMIT \$limit
            ) ORDER BY pos ASC
        "] row {
            lappend rows [$self RowToDict [array get row]]
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
    # An empty jid searches every chat in the account. Hits come newest
    # first by timestamp, ties broken by id, so -before is the {timestamp
    # id} of the last hit already had: stamps repeat (an archive stamping
    # whole seconds).
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
        if {$jid ne ""} { append sql { AND chat_jid=$jid} }
        if {$before ne ""} {
            lassign $before beforeTs beforeId
            append sql { AND (timestamp < $beforeTs
                         OR (timestamp = $beforeTs AND id < $beforeId))}
        }
        append sql { ORDER BY timestamp DESC, id DESC}
        append sql { LIMIT $limit}
        set rows {}
        $options(-db) eval $sql row {
            lappend rows [$self RowToDict [array get row]]
        }
        return $rows
    }

    # Find the message nearest in time to $timestamp and return context
    # around it (limit/2 before + target + limit/2 after). Each side is
    # truncated independently at the nearest hole.
    # Returns dict: {messages $list anchor $id
    #                bounded_before $b bounded_after $b}.
    method "get around" {jid timestamp limit} {
        set nearest [$options(-db) onecolumn {
            SELECT id FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
            ORDER BY ABS(timestamp - $timestamp) LIMIT 1
        }]
        if {$nearest eq ""} {
            return [dict create messages {} anchor "" \
                bounded_before 0 bounded_after 0]
        }
        $self around $jid $nearest $limit
    }

    # Context around row $id, as `get around` returns it.
    method around {jid id limit} {
        set halfLimit [expr {$limit / 2}]
        set before [$self get before $jid $id $halfLimit]
        set after  [$self get after  $jid $id $halfLimit]
        set target [$self get ids $jid [list $id]]
        return [dict create \
            messages [concat [dict get $before messages] $target \
                             [dict get $after messages]] \
            anchor $id \
            bounded_before [dict get $before bounded] \
            bounded_after  [dict get $after  bounded]]
    }

    # The messages with these ids, in the order given.
    method "get ids" {jid ids} {
        set rows {}
        foreach id $ids {
            $options(-db) eval [$self MsgSql {
                SELECT @cols@
                FROM chat_message
                WHERE chat_jid=$jid AND kind='message' AND id=$id
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
            ORDER BY pos DESC LIMIT 1
        }] row {
            set result [$self RowToDict [array get row]]
        }
        return $result
    }

    # chat_jid -> newest message, for every chat with history.
    # Chat by chat down the (chat_jid, pos) index, each chat's
    # newest message read from its newest end: a GROUP BY over the table
    # read every row of the account, every page decrypted again on an
    # encrypted store, at every `chatlist get`.
    method lastMessages {} {
        set out {}
        $options(-db) eval [$self MsgSql {
            WITH RECURSIVE chats(jid) AS (
                SELECT MIN(chat_jid) FROM chat_message
                UNION ALL
                SELECT (SELECT MIN(chat_jid) FROM chat_message
                        WHERE chat_jid > chats.jid)
                    FROM chats WHERE chats.jid IS NOT NULL)
            SELECT @cols@ FROM chat_message WHERE rowid IN (
                SELECT (SELECT rowid FROM chat_message
                        WHERE chat_jid=chats.jid AND kind='message'
                        ORDER BY pos DESC LIMIT 1)
                    FROM chats WHERE jid IS NOT NULL)
            ORDER BY chat_jid
        }] row {
            dict set out $row(chat_jid) [$self RowToDict [array get row]]
        }
        return $out
    }

    # Resolve an XEP-0461 reply target to its stored timestamp, or "".
    #   server_id match  : authoritative (stanza-id is unique in the archive),
    #                      and the only match in a room, where any occupant
    #                      can send an origin-id equal to another message's
    #                      stanza-id.
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
        set id [$options(-db) onecolumn {
            SELECT id FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND server_id != '' AND server_id=$replyId
            LIMIT 1
        }]
        if {$id eq ""} { set id [$self AliasTarget $jid server $replyId] }
        if {$id ne "" || [IsRoomChatJid $jid]} { return $id }

        set isMuc [IsMucChatJid $jid]
        set candidates {}
        # One arm per id, each by its own index (see resolveTargetId).
        $options(-db) eval {
            SELECT id, from_jid FROM chat_message
            WHERE +chat_jid=$jid AND id IN (
                SELECT id FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND origin_id != '' AND origin_id=$replyId
                UNION ALL
                SELECT id FROM chat_message
                WHERE chat_jid=$jid AND kind='message'
                  AND own_id != '' AND own_id=$replyId
                UNION ALL
                SELECT target_id FROM message_alias
                WHERE chat_jid=$jid AND kind='origin' AND alias_id=$replyId)
            ORDER BY +pos
        } row {
            lappend candidates [list $row(id) $row(from_jid)]
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
            lassign $candidate id fromJid
            if {$replyTo eq ""
                || ($isMuc && [jid equal $fromJid $replyTo])
                || (!$isMuc && [jid equal [jid bare $fromJid] [jid bare $replyTo]])} {
                return $id
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
            WHERE chat_jid=$jid AND own_id != '' AND own_id=$ownId
              AND server_status='uploading'
        }
    }

    method markUploadFailed {jid ownId} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='failed', fail_reason='upload'
            WHERE chat_jid=$jid AND own_id=$ownId
              AND server_status='uploading'
        }
    }

    # Retry: flip a previously failed upload back to uploading.
    method markUploading {jid ownId} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='uploading', fail_reason=''
            WHERE chat_jid=$jid AND own_id=$ownId
              AND server_status='failed'
        }
    }

    # Startup recovery: an 'uploading' row left over from a previous run
    # was never sent (HTTP PUT isn't resumable), so mark it failed.
    method failStaleUploads {} {
        $options(-db) eval {
            UPDATE chat_message SET server_status='failed', fail_reason='upload'
            WHERE kind='message' AND server_status='uploading'
        }
    }

    # Flip pending → '' (server-confirmed) for each own_id (SM ack path).
    # Returns list of {chat_jid, id} for confirmed messages.
    # With no chat to narrow by, the pending rows are the ones read
    # (idx_chat_message_pending); the + keeps the planner off the own_id
    # index, which would walk every send of ours in every chat.
    method confirmByOwnIds {ownIds} {
        set confirmed {}
        $options(-db) transaction {
            foreach oid $ownIds {
                if {$oid eq ""} continue
                $options(-db) eval {
                    SELECT chat_jid, id FROM chat_message
                    WHERE server_status='pending' AND +own_id=$oid
                } row {
                    lappend confirmed [dict create \
                        chat_jid $row(chat_jid) id $row(id)]
                }
                $options(-db) eval {
                    UPDATE chat_message SET server_status=''
                    WHERE server_status='pending' AND +own_id=$oid
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
    # Returns a list, in chat order, of {chat_jid, id, remote_status}, one
    # per changed row, empty if nothing moved.
    method markRemoteStatus {chatJid targetId status} {
        if {$targetId eq ""} { return {} }
        set changed {}
        $options(-db) transaction {
            # Ours by its own id, else by its origin-id, one indexed lookup
            # each (see resolveTargetId).
            set target [$options(-db) onecolumn {
                SELECT id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
                  AND own_id != '' AND own_id=$targetId
                ORDER BY +pos LIMIT 1
            }]
            if {$target eq ""} {
                set target [$options(-db) onecolumn {
                    SELECT id FROM chat_message
                    WHERE chat_jid=$chatJid AND kind='message'
                      AND origin_id != '' AND origin_id=$targetId
                      AND own_id != ''
                    ORDER BY +pos LIMIT 1
                }]
            }
            if {$target eq ""} {
                set target [$self AliasTarget $chatJid origin $targetId]
            }
            if {$target ne ""} {
                set targetPos [$self PosOf $chatJid $target]
                set from [expr {$status eq "read" ? "" : $targetPos}]
                set rank [RemoteStatusRank $status]
                # Collected first; updating mid-eval would edit the table
                # being walked. A 'read' marker range-scans the chat back to
                # its start every time; the != can't narrow that scan, it
                # only keeps a repeat marker from re-UPDATEing every row.
                set stale {}
                $options(-db) eval "
                    SELECT id, remote_status FROM chat_message
                    WHERE chat_jid=\$chatJid AND kind='message' AND own_id != ''
                      [Bound pos >= from] AND pos <= \$targetPos
                      AND remote_status != \$status
                    ORDER BY pos
                " row {
                    if {$rank > [RemoteStatusRank $row(remote_status)]} {
                        lappend stale $row(id)
                    }
                }
                foreach id $stale {
                    $options(-db) eval {
                        UPDATE chat_message SET remote_status=$status
                        WHERE chat_jid=$chatJid AND id=$id
                    }
                    lappend changed [dict create \
                        chat_jid $chatJid id $id remote_status $status]
                }
            }
        }
        return $changed
    }

    # --- Own read watermark ----------------------------------------

    # How far we have read $chatJid: {id I pos P ref R}, the last row read,
    # its place, and its archive (else origin) id; all "" for a chat never
    # read.
    method ownRead {chatJid} {
        set res [dict create id "" pos "" ref ""]
        $options(-db) eval {
            SELECT r.read_pos AS pos, r.read_id AS ref, m.id AS id
            FROM chat_own_read r
            LEFT JOIN chat_message m ON m.chat_jid=r.chat_jid AND m.pos=r.read_pos
            WHERE r.chat_jid=$chatJid
        } row {
            dict set res id $row(id)
            dict set res pos $row(pos)
            dict set res ref $row(ref)
        }
        return $res
    }

    # Advance the watermark to row $id, forward-only: one at or before the
    # mark (a replayed or out-of-order marker) is a no-op. read_id comes
    # from that row. Returns 1 if it moved.
    method markOwnRead {chatJid id} {
        if {$id eq ""} { return 0 }
        set at [$self PosOf $chatJid $id]
        if {$at eq ""} { return 0 }
        set moved 0
        $options(-db) transaction {
            set prev [$options(-db) onecolumn {
                SELECT read_pos FROM chat_own_read WHERE chat_jid=$chatJid
            }]
            if {$prev eq "" || [string compare $at $prev] > 0} {
                $options(-db) eval {
                    INSERT OR REPLACE INTO
                        chat_own_read(chat_jid, read_ts, read_id, read_pos)
                    SELECT chat_jid, timestamp,
                           CASE WHEN COALESCE(server_id,'') != ''
                                THEN server_id ELSE COALESCE(origin_id,'') END,
                           pos
                    FROM chat_message WHERE chat_jid=$chatJid AND id=$id
                }
                set moved 1
            }
        }
        return $moved
    }

    # The last unread messages stamped past $floorTs, last first, as {id
    # mention from_jid body attachments}. The catch-up sweep caps how many
    # it takes; `unreadCount` still reports the true total.
    method unreadTail {chatJid floorTs limit} {
        set rows {}
        $options(-db) eval {
            SELECT id, mentions_me, from_jid, body, attachments
            FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
              AND COALESCE(own_id,'')='' AND retracted=0
              AND timestamp > $floorTs
              AND pos > COALESCE((SELECT read_pos FROM chat_own_read
                                  WHERE chat_jid=$chatJid), '')
            ORDER BY pos DESC LIMIT $limit
        } row {
            lappend rows [list $row(id) $row(mentions_me) \
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
              AND pos > COALESCE((SELECT read_pos FROM chat_own_read
                                  WHERE chat_jid=$chatJid), '')
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
        # Chat by chat down the primary key (lastMessages' walk), each
        # chat's rows read from its read mark on, rather than every message
        # of the account joined to the read marks. CROSS JOIN keeps the
        # chats the outer loop.
        $options(-db) eval {
            WITH RECURSIVE chats(jid) AS (
                SELECT MIN(chat_jid) FROM chat_message
                UNION ALL
                SELECT (SELECT MIN(chat_jid) FROM chat_message
                        WHERE chat_jid > chats.jid)
                    FROM chats WHERE chats.jid IS NOT NULL)
            SELECT m.chat_jid AS jid, COUNT(*) AS n,
                   COALESCE(SUM(m.mentions_me=1),0) AS mentions
            FROM chats c CROSS JOIN chat_message m
            WHERE c.jid IS NOT NULL AND m.chat_jid=c.jid
              AND m.kind='message' AND COALESCE(m.own_id,'')=''
              AND m.retracted=0
              AND m.pos > COALESCE((SELECT read_pos FROM chat_own_read
                                    WHERE chat_jid=c.jid), '')
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
    method mentionAt {chatJid id} {
        set v [$options(-db) onecolumn {
            SELECT mentions_me FROM chat_message
            WHERE chat_jid=$chatJid AND id=$id
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

    # --- Client data ----------------------------------------------

    # The frontend's string for a chat, "" if none.
    method clientData {chatJid} {
        $options(-db) onecolumn {
            SELECT data FROM chat_client_data WHERE chat_jid=$chatJid
        }
    }

    # "" deletes the row.
    method setClientData {chatJid data} {
        if {$data eq ""} {
            $options(-db) eval {
                DELETE FROM chat_client_data WHERE chat_jid=$chatJid
            }
            return
        }
        $options(-db) eval {
            INSERT OR REPLACE INTO chat_client_data(chat_jid, data)
            VALUES($chatJid, $data)
        }
    }

    # --- Last writer wins, across two clocks ------------------------
    # A correction's or reaction's time is the server's (archive, trusted
    # <delay>) or ours (our own action, or a live stanza with no stamp), and
    # the two clocks can be minutes apart. So times are compared only on the
    # same clock. A local one arrived live, in the server's order, or is our
    # own doing: it is the newest. A server one against a local one is
    # newer only past the local one's `after`, the newest server stamp the
    # chat had shown when the local one was taken. That can let an older
    # archived patch through over a live one; the archive also holds the
    # newer, which comes later in the same forward walk and wins on stamps.

    # Whether a patch at $inTs on $inClock replaces one held at $heldTs
    # ("" or 0: none held).
    proc PatchWins {inTs inClock heldTs heldClock heldAfter} {
        if {$heldTs eq "" || $heldTs == 0} { return 1 }
        if {$inClock ne "server"} { return 1 }
        if {$heldClock eq "server"} { return [expr {$inTs > $heldTs}] }
        return [expr {$inTs > $heldAfter}]
    }

    # Note a server stamp seen in $chatJid; forward-only.
    method noteArchiveTs {chatJid ts} {
        if {![string is entier -strict $ts]} return
        $options(-db) eval {
            INSERT INTO chat_archive_mark(chat_jid, ts) VALUES($chatJid, $ts)
            ON CONFLICT(chat_jid) DO UPDATE SET ts=max(ts, excluded.ts)
        }
    }

    # The `after` a patch on $clock is stored with.
    method PatchAfter {chatJid clock} {
        if {$clock eq "server"} { return 0 }
        set mark [$options(-db) onecolumn {
            SELECT ts FROM chat_archive_mark WHERE chat_jid=$chatJid
        }]
        expr {$mark eq "" ? 0 : $mark}
    }

    # --- Reactions (XEP-0444) --------------------------------------

    # Apply a reactor's full emoji set. Last-writer-wins (PatchWins) against
    # the reactor's stored set; $clock is `server` or `local`, the clock $ts
    # is on. Returns the target message's id (so the caller can
    # <Reactions>), or "" when LWW skipped it or the target message isn't
    # stored yet.
    method applyReaction {chatJid targetId senderId senderLabel isOwn emojis ts
            {clock server}} {
        if {$targetId eq "" || $senderId eq ""} { return "" }
        set held {"" "" 0}
        $options(-db) eval {
            SELECT ts, clock, after_ts FROM message_reaction
            WHERE chat_jid=$chatJid AND target_id=$targetId
              AND sender_id=$senderId
        } row {
            set held [list $row(ts) $row(clock) $row(after_ts)]
        }
        if {![PatchWins $ts $clock {*}$held]} { return "" }
        set after [$self PatchAfter $chatJid $clock]
        $options(-db) eval {
            INSERT OR REPLACE INTO message_reaction(chat_jid, target_id,
                    sender_id, sender_label, is_own, emojis, ts, clock,
                    after_ts)
            VALUES($chatJid, $targetId, $senderId, $senderLabel, $isOwn,
                   $emojis, $ts, $clock, $after)
        }
        set target [$self resolveTargetId $chatJid $targetId]
        if {$target eq ""} { $self CapOrphanReactions $chatJid $senderId }
        return $target
    }

    # Keep a chat's orphan reactions (no stored message goes by their
    # target id) under the caps: a reactor naming fresh ids would add a
    # row each that only forgetting the chat removed.
    method CapOrphanReactions {chatJid senderId} {
        foreach who [list $senderId ""] \
                cap [list $MaxOrphanReactionsPerSender $MaxOrphanReactions] {
            $options(-db) eval {
                DELETE FROM message_reaction WHERE rowid IN (
                    SELECT r.rowid FROM message_reaction r
                    WHERE r.chat_jid=$chatJid
                      AND ($who = '' OR r.sender_id=$who)
                      AND NOT EXISTS (SELECT 1 FROM chat_message m
                          WHERE m.chat_jid=r.chat_jid AND m.server_id != ''
                            AND m.server_id=r.target_id)
                      AND NOT EXISTS (SELECT 1 FROM chat_message m
                          WHERE m.chat_jid=r.chat_jid AND m.origin_id != ''
                            AND m.origin_id=r.target_id)
                      AND NOT EXISTS (SELECT 1 FROM chat_message m
                          WHERE m.chat_jid=r.chat_jid AND m.own_id != ''
                            AND m.own_id=r.target_id)
                      AND NOT EXISTS (SELECT 1 FROM message_alias a
                          WHERE a.chat_jid=r.chat_jid AND a.alias_id=r.target_id)
                    ORDER BY r.ts DESC LIMIT -1 OFFSET $cap)
            }
        }
    }

    # My current emoji set for a target - the toggle source of truth.
    method ownReactions {chatJid targetId ownSenderId} {
        return [$options(-db) onecolumn {
            SELECT emojis FROM message_reaction
            WHERE chat_jid=$chatJid AND target_id=$targetId
              AND sender_id=$ownSenderId
        }]
    }

    # The id of a stored message matched by its wire id, against
    # the stored envelope ids (mirrors resolveReply's id match). In a room
    # only the room's stanza-id counts: an origin-id is the sender's choice.
    # "" if not stored. For reactions and markers; corrections and
    # retractions are matched with their author (message TargetCandidates).
    # A stanza-id match wins, then our own send's id (a peer may copy our
    # origin-id into a message of its own), then the oldest, so the answer
    # never rests on the order SQLite reads the rows in.
    method resolveTargetId {chatJid targetId} {
        if {$targetId eq ""} { return "" }
        set room [IsRoomChatJid $chatJid]
        set db $options(-db)
        # One lookup per id, in that order, each spelling its partial
        # index's condition (`server_id != ''` and so on): SQLite takes a
        # partial index only for a query that states it, and a statement
        # OR-ing the ids, or asking `server_id=$x` alone, walked every row
        # of the chat. `+pos`, not `pos`: ordered by the column, the
        # planner walks the (chat_jid, pos) index for the order instead.
        set id [$db onecolumn {
            SELECT id FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
              AND server_id != '' AND server_id=$targetId
            ORDER BY +pos LIMIT 1
        }]
        if {$id eq "" && !$room} {
            set id [$db onecolumn {
                SELECT id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
                  AND own_id != '' AND own_id=$targetId
                ORDER BY +pos LIMIT 1
            }]
        }
        if {$id eq "" && !$room} {
            set id [$db onecolumn {
                SELECT id FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
                  AND origin_id != '' AND origin_id=$targetId
                ORDER BY +pos LIMIT 1
            }]
        }
        if {$id eq ""} { set id [$self AliasTarget $chatJid server $targetId] }
        if {$id eq "" && !$room} {
            set id [$self AliasTarget $chatJid origin $targetId]
        }
        return $id
    }

    # --- Correction aliases ---------------------------------------------
    # A correction's own ids name the message it corrected (see the
    # message_alias schema step): clients refer to a corrected message by
    # its newest correction.

    # The row an alias of $kind (server|origin) names, or "".
    method AliasTarget {chatJid kind id} {
        if {$id eq ""} { return "" }
        return [$options(-db) onecolumn {
            SELECT target_id FROM message_alias
            WHERE chat_jid=$chatJid AND kind=$kind AND alias_id=$id
        }]
    }

    # Record a correction's {serverId originId} as names of row $targetId,
    # then hand any patch held for those ids to -deferredcmd, as `store`
    # does for a new row's own ids.
    method addAliases {chatJid targetId serverId originId} {
        set deferred {}
        $options(-db) transaction {
            foreach kind {server origin} id [list $serverId $originId] {
                if {$id eq "" || $targetId eq ""} continue
                $options(-db) eval {
                    INSERT OR IGNORE INTO message_alias(chat_jid, kind,
                        alias_id, target_id)
                    VALUES($chatJid, $kind, $id, $targetId)
                }
            }
            set deferred [$self TakeDeferred $chatJid \
                [list $serverId $originId]]
        }
        if {[llength $deferred] && $options(-deferredcmd) ne ""} {
            {*}$options(-deferredcmd) $chatJid $deferred
        }
    }

    # --- Corrections (XEP-0308) / retractions (XEP-0424/0425) ------

    # The target comes as its row's id: the caller picks it among the rows
    # carrying the referenced id by who wrote it.
    #
    # Replace a stored message's body with a correction. Last-writer-wins on
    # edited_ts (PatchWins; $clock as for applyReaction); a retracted
    # message is immutable. Returns the target's id (so the caller can
    # <Edited>), or "" when not stored or skipped.
    # `stamp` is the correction's own {encryption sender_fp}, so the row
    # tracks the body now displayed. No default: it would be a downgrade.
    method applyEdit {chatJid target newBody rawXml ts stamp {clock server}} {
        set enc [dict get $stamp encryption]
        set senderFp [dict get $stamp sender_fp]
        set found 0
        $options(-db) eval {
            SELECT edited_ts, edited_clock, edited_after, retracted
            FROM chat_message
            WHERE chat_jid=$chatJid AND id=$target AND kind='message'
        } row {
            set found 1
            set held [list $row(edited_ts) $row(edited_clock) \
                $row(edited_after)]
            set retracted $row(retracted)
        }
        if {!$found || $retracted} { return "" }
        if {![PatchWins $ts $clock {*}$held]} { return "" }
        set after [$self PatchAfter $chatJid $clock]
        $options(-db) eval {
            UPDATE chat_message
            SET body=$newBody, raw_xml=$rawXml, edited_ts=$ts,
                edited_clock=$clock, edited_after=$after,
                encryption=$enc, sender_fp=$senderFp
            WHERE chat_jid=$chatJid AND id=$target
        }
        return $target
    }

    # Tombstone a stored message. Sticky: once retracted, later edits no-op.
    # Returns the target's id, or "" when not stored.
    method applyRetract {chatJid target} {
        $options(-db) eval {
            UPDATE chat_message SET retracted=1
            WHERE chat_jid=$chatJid AND id=$target AND kind='message'
        }
        if {[$options(-db) changes] == 0} { return "" }
        return $target
    }

    # Per-emoji aggregation of reactions on a displayed message, for the
    # GUI. Joins reaction rows against the message's envelope ids so it
    # works whether reactors targeted the origin-id (1:1) or stanza-id
    # (MUC; only that one there). Emoji order is first-seen; count is left
    # to the GUI. Shape:
    #   {emoji {reactors {Alice Bob} mine 0|1} ...}
    method reactionsForMessage {chatJid id} {
        set room [IsRoomChatJid $chatJid]
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
                OR (NOT $room AND m.origin_id != ''
                    AND m.origin_id = r.target_id)
                OR (NOT $room AND m.own_id != ''
                    AND m.own_id = r.target_id)
                OR EXISTS (SELECT 1 FROM message_alias a
                    WHERE a.chat_jid = m.chat_jid
                      AND a.target_id = m.id
                      AND a.alias_id = r.target_id
                      AND (NOT $room OR a.kind = 'server')) )
            WHERE m.chat_jid = $chatJid AND m.id = $id
        } r {
            foreach e $r(emojis) {
                if {![info exists reactors($e)]} {
                    set reactors($e) {}
                    set mine($e) 0
                    lappend order $e
                }
                if {$r(label) ni $reactors($e)} {
                    lappend reactors($e) $r(label)
                }
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
    #               server_id, take the server's stamp; returns the row's
    #               `id` and that `timestamp` for the <Confirmed>.
    #   duplicate - matched any other row; returns its `stored_id`.
    #   new       - no id match.
    # The id of the row $jid holds under archive id $serverId, or "" when
    # there is none. A pending row is left out: reconcile confirms it.
    method archivedId {jid serverId} {
        $options(-db) onecolumn {
            SELECT id FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND server_id != '' AND server_id=$serverId
              AND server_status IS NOT 'pending' AND undecrypted != 1
            ORDER BY +pos LIMIT 1
        }
    }

    # A row stored undecrypted takes the message it turned out to be: its
    # text, files, reply, mention and the session that read it. 1 if a row
    # was put right.
    method repairUndecrypted {jid id msg} {
        set body [dict get $msg body]
        set attach [dict get $msg attachments]
        set senderFp [dict get $msg sender_fp]
        set enc [dict get $msg encryption]
        set mention [dict get $msg mentions_me]
        set replyId [dict get $msg reply_id]
        set replyTo [dict get $msg reply_to]
        $options(-db) eval {
            UPDATE chat_message
            SET body=$body, attachments=$attach, sender_fp=$senderFp,
                encryption=$enc, mentions_me=$mention,
                reply_id=$replyId, reply_to=$replyTo, undecrypted=0
            WHERE chat_jid=$jid AND id=$id AND undecrypted=1
        }
        expr {[$options(-db) changes] > 0}
    }

    # An undecrypted row a fill could not open in order: kept as it is,
    # never asked about again (undecrypted 2).
    method giveUpUndecrypted {jid id} {
        $options(-db) eval {
            UPDATE chat_message SET undecrypted=2
            WHERE chat_jid=$jid AND id=$id AND undecrypted=1
        }
    }

    method reconcile {jid serverId ownId originId timestamp {occupantId ""}} {
        if {$serverId eq "" && $ownId eq ""} {
            return [dict create verdict new]
        }
        # The first row with either id, each by its own index (see
        # resolveTargetId).
        set row ""
        $options(-db) eval {
            SELECT id, pos, server_status, server_id, undecrypted
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND server_id != '' AND server_id=$serverId
            ORDER BY +pos LIMIT 1
        } r {
            set row [dict create id $r(id) pos $r(pos) \
                server_status $r(server_status) server_id $r(server_id) \
                undecrypted $r(undecrypted)]
        }
        $options(-db) eval {
            SELECT id, pos, server_status, server_id, undecrypted
            FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
              AND own_id != '' AND own_id=$ownId
            ORDER BY +pos LIMIT 1
        } r {
            if {$row eq ""
                    || [string compare $r(pos) [dict get $row pos]] < 0} {
                set row [dict create id $r(id) pos $r(pos) \
                    server_status $r(server_status) server_id $r(server_id) \
                    undecrypted $r(undecrypted)]
            }
        }
        if {$row eq ""} {
            return [dict create verdict new]
        }
        set id [dict get $row id]
        set status [dict get $row server_status]
        if {!($status eq "pending"
              || ($status eq "" && [dict get $row server_id] eq ""
                  && $serverId ne ""))} {
            # Ours to decrypt again rather than to drop (message Redecrypt).
            if {[dict get $row undecrypted] == 1} {
                return [dict create verdict undecrypted stored_id $id]
            }
            return [dict create verdict duplicate stored_id $id]
        }
        # The row keeps its place; its stamp becomes the copy's.
        $options(-db) eval {
            UPDATE chat_message
            SET timestamp=$timestamp,
                server_status='',
                server_id = CASE WHEN $serverId != ''
                    THEN $serverId ELSE server_id END,
                occupant_id = CASE WHEN $occupantId != ''
                    THEN $occupantId ELSE occupant_id END
            WHERE chat_jid=$jid AND id=$id
        }
        return [dict create verdict confirmed chat_jid $jid id $id \
            timestamp $timestamp]
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
            set target [$self resolveReply $chatJid \
                [dict get $d reply_id] [dict get $d reply_to]]
            if {$target ne ""} {
                dict set d reply_to_id $target
                # Trust the resolved row's own from_jid over the stanza's
                # reply-to attribute, which peer clients can get wrong.
                lassign [$options(-db) eval {
                    SELECT from_jid, body FROM chat_message
                    WHERE chat_jid=$chatJid AND id=$target
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
                        [dict get $d id] $room]
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
            [dict get $d chat_jid] [dict get $d id]]
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
            # Each id by its own index (see resolveTargetId).
            return [expr {[$options(-db) exists {
                    SELECT 1 FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND server_id != '' AND server_id=$sid
                }] || [$options(-db) exists {
                    SELECT 1 FROM chat_message
                    WHERE chat_jid=$jid AND kind='message'
                      AND own_id != '' AND own_id=$oid
                }]}]
        } else {
            # Content-based fallback for messages without server_id/own_id
            # (e.g. IRC bridge messages). Match within the same second: a
            # copy may be stamped to the second where the first was not.
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

    # The pos for a row at $ts in $jid, by time, for one with nothing better
    # to go by: right after the row stamped last before $ts, else right
    # before the row stamped first after it.
    method PosForTs {jid ts} {
        set lo [$options(-db) onecolumn {
            SELECT pos FROM chat_message
            WHERE chat_jid=$jid AND timestamp < $ts
            ORDER BY timestamp DESC LIMIT 1
        }]
        if {$lo ne ""} {
            return [poskey between $lo [$self PosNext $jid $lo]]
        }
        set hi [$options(-db) onecolumn {
            SELECT pos FROM chat_message
            WHERE chat_jid=$jid AND timestamp > $ts
            ORDER BY timestamp ASC LIMIT 1
        }]
        poskey between [$self PosPrev $jid $hi] $hi
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
