# Overview: see messagestore.tcl for the sparse-cache complexities.

# Message dict keys: id, pos, timestamp, chat_jid, from_jid, from_resource,
#   body, server_id, own_id, origin_id, reply_id, reply_to, raw_xml (debug),
#   server_status, encryption, fail_reason, attachments.
#
# A message is named by its id (the row's, stable, unique in the account);
# pos is where it sits in its chat, a string that sorts in the chat's order
# (see messagestore); timestamp is when it was sent, for display. Commands
# take -id; events that change a message carry -id; a message dict, as <New>
# and every read return it, carries all three.

# chat_jid: MUC groupchat - room@muc?join; MUC PM - room@muc/nick;
#   1:1 - bare JID.

# server_status answers one question - "does the server have this exact
# message?" - and nothing else (direction is is_outgoing, from own_id):
#   ""          the server has it: incoming, MAM, carbon, or a confirmed
#               send - all the same situation
#   "pending"   ours, sent, not yet confirmed on the server
#   "uploading" ours, attachment HTTP PUT in flight (XEP-0363)
#   "failed"    ours, didn't reach the server (retryable)
#
# Incoming stanzas: live (OnMessage/ingestLive) and archived
# (ParseResultNode) stanzas share one ingestion core, Classify:
#   1. Dedup on the envelope ids (server stanza-id / @id), before
#      anything else:
#      1.1 an outgoing message may be confirmed - it takes the incoming
#          copy's stamp (MAM archive delay or MUC echo arrival time) and
#          keeps its place
#      1.2 a match against an existing non-outgoing -> discard as duplicate
#      1.3 no id match -> new, carry on
#   2. Decrypt OMEMO
#   3. Classify the contents: a real body is stored and surfaced
#      (<New>); a control stanza (receipt, chat marker, chat state)
#      or other bodyless payload is currently discarded.
# === GUI events ===
#
#   <New>       insert a newly-persisted message; direction (outgoing vs
#               incoming) and checkmark derive from the message dict
#               (is_outgoing / server_status), not the event name
#   <Status>    update a displayed entry's send/receipt state in place
#   <Confirmed> a pending send was acknowledged (-timestamp: its stamp now)
#   <Reactions> replace a displayed entry's aggregated reaction map
#   <Edited>    re-send a full row to redraw an edited message in place
#   <Retracted> flip a displayed entry to a tombstone (jid + id only)
#   <OwnRead>   our own read watermark moved (this device or another one)
#
snit::type taco_message {
    option -client -readonly yes

    component messagestore -public messagestore

    variable client
    variable PendingRetry
    variable ActiveTags
    # Tagged requests not yet answered: id -> {tag command onerror}.
    variable TagPending -array {}
    variable TagSeq 0

    # Syncs that have emitted <CatchupStarted> and still owe a
    # <CatchupDone>, keyed by room chat jid or "" for the account archive.
    variable CatchupInFlight

    # The highest chat_message rowid when the account catchup started, ""
    # outside one. A result the store already holds in a row at or below it
    # was there before this connection, so the walk has reached history we
    # had: proof it can stop. A row above it came in during this connection
    # (live, or from the server's offline store at our presence) and proves
    # nothing about what the archive holds below it.
    variable CatchupRowidFloor ""
    # The account catchup's accumulator so far, "" outside a run: a drop
    # that cuts the walk short bounds what it covered (OnDisconnect).
    variable CatchupAcc ""
    # The holes this connect's PlaceReconnectHoles put after each chat's
    # last row, as {chatJid pos ...}: they mark what may have come since
    # the previous session, and a walk that reaches history we had has read
    # all of that, for every chat.
    variable ReconnectHoles {}
    # The first message to arrive live, undelayed, in each chat while its
    # catchup runs: chat -> pos. The archive took it in after the catchup
    # asked, so what the catchup fetches goes below it (CatchupTop).
    variable LiveTop {}
    # The lowest row each chat's catchup stored or met this connection:
    # chat -> pos. A message the server held for us that its pages did not
    # have is older than everything they did, so it goes right below this.
    variable WalkBottom {}

    # Pages the account catchup will walk back before giving up on reaching
    # the previous session. Deep enough that an ordinary absence lands whole
    # - a shallow floor over-reports pending sends as undelivered - without
    # turning a first login on a busy account into a full archive pull.
    typevariable MaxCatchupPages 5

    # Forward fills (FillChat): chats waiting for one, the one running as
    # {run chatJid}, and a count that tells a fill's late answer from the
    # current run's once a drop has dropped it.
    variable FillQueue {}
    variable FillBusy ""
    variable FillRun 0
    # 1 while a fill's page is processed (Redecrypt).
    variable InFill 0
    # Pages one fill walks per connect; the hole it leaves where it stopped
    # is where the next connect's goes on.
    typevariable MaxForwardFillPages 200
    # Ids below a fill's gap it tries when the archive no longer has the
    # one it continues after, before it walks the archive from its start.
    typevariable MaxFillRetries 5

    # The earliest stamp our server or account may put on a live 1:1
    # stanza this session (TrustedStamp), "" for none: what the server held
    # for us while we were offline postdates our previous session.
    variable OfflineFloorUs ""
    # When our previous session in this run ended: the link's last moment
    # (LinkHeardUs), not when the drop was noticed.
    variable LastOnlineUs ""
    # Room for the server's clock running behind ours.
    typevariable OfflineSkewUs [expr {5 * 60 * 1000000}]
    # How far back a first session, with nothing stored, takes the floor.
    typevariable OfflineFloorBoundUs [expr {30 * 86400 * 1000000}]
    # How long after a send a bounce still fails the row once our server
    # has acked it (MarkBounced).
    typevariable BounceWindowUs [expr {10 * 60 * 1000000}]

    constructor {args} {
        $self configurelist $args
        set client $options(-client)
        install messagestore using taco_messagestore $self.messagestore \
            -db [$client cget -db] -joinedcmd [mymethod RoomJoined] \
            -incallcmd [mymethod InCall] -livecmd [mymethod CallLive] \
            -deferredcmd [mymethod ApplyDeferred]
        array set PendingRetry {}
        array set ActiveTags {}
        set CatchupInFlight [dict create]
        $client bus subscribe $self sm:<Ack>     [mymethod OnSmAck]
        $client bus subscribe $self muc:<Joined> [mymethod OnMucJoined]
        $client bus subscribe $self muc:<Left>   [mymethod OnMucLeft]
        $client bus subscribe $self bookmarks:<Changed> \
            [mymethod OnBookmarkChanged]
        $client bus subscribe $self omemo:<SessionReady> \
            [mymethod OnOmemoSessionReady]
        # A peer's devicelist resolving (to devices or empty) also wakes
        # a blocked send: re-running encrypt either warms further, or
        # TERMINAL-fails on an empty list so the message stops hanging.
        $client bus subscribe $self omemo:<DevicelistResolved> \
            [mymethod OnOmemoSessionReady]
        # omemo's account-level prerequisites (store, own devicelist) may
        # land either side of the catchup that drives RetryPending, so
        # retry pending OMEMO sends once they do.
        $client bus subscribe $self omemo:<SelfReady> \
            [mymethod OnOmemoSelfReady]
        $client bus subscribe $self <SessionStart> [mymethod OnReady]
        $client bus subscribe $self <SessionEnd>   [mymethod OnDisconnect]
        set WiredNow [dict create]
        # An 'uploading' row from a previous run was never sent (PUT isn't
        # resumable); reconcile it to 'failed' so the user can retry.
        $messagestore failStaleUploads
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$messagestore destroy}
    }

    method OnReady {args} {
        # A fresh stream: nothing we wrote to the old one is in flight any
        # more. <SessionStart> fires only on a fresh session (not on
        # resumption), which is exactly right - across a resume SM still holds
        # those stanzas, so the set must survive.
        set WiredNow [dict create]
        $self SetOfflineFloor
        $self PlaceReconnectHoles
        # RetryPending runs from OnCatchup, not here. Catchup confirms
        # whatever the server actually archived, so the retry only has to
        # deal with what genuinely never landed - and by then omemo's
        # store and devicelists have had a full MAM round-trip to warm,
        # where a retry at <SessionStart> is guaranteed to hit NOT_READY (the
        # message module is constructed before omemo, so its <SessionStart>
        # handler runs first).
        $self DoCatchup
    }

    # Our previous session ended when this run saw it end or, on the run's
    # first, no earlier than the newest message stored.
    method SetOfflineFloor {} {
        set now [clock microseconds]
        set last $LastOnlineUs
        if {$last eq ""} {
            set last [$client db onecolumn {
                SELECT MAX(timestamp) FROM chat_message WHERE kind='message'
            }]
        }
        if {$last eq "" || $last > $now} {
            set last [expr {$now - $OfflineFloorBoundUs}]
        }
        set OfflineFloorUs [expr {$last - $OfflineSkewUs}]
    }

    # Bracket any history that arrived during the disconnect window: a hole
    # after each chat's last row. The catchup's pages go in above it, and
    # clear it once they reach history we had; otherwise it remains and
    # bounds future pagination.
    method PlaceReconnectHoles {} {
        # Collected before any insert: `hole append` writes to the table this
        # cursor is reading.
        set chats [$client db eval {
            SELECT DISTINCT chat_jid FROM chat_message
            WHERE kind='message' AND server_id IS NOT NULL
              AND server_id != ''
        }]
        set ReconnectHoles {}
        foreach jid $chats {
            set pos [$messagestore hole append $jid]
            if {$pos ne ""} { lappend ReconnectHoles $jid $pos }
        }
    }

    # Put out of a room, we missed whatever it broadcast while we were gone.
    # DoMucCatchup fetches one page on the way back in, so a longer absence
    # still leaves a gap: bracket it with a `newer` hole as a reconnect does,
    # and pagination reaches the rest. A voluntary leave has no gap to record.
    method OnMucLeft {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc is_hidden -jid [dict get $args -jid]]} return
        array set opts {-jid "" -involuntary 0}
        array set opts $args
        if {!$opts(-involuntary)} return
        set chatJid $opts(-jid)?join
        if {![$client db exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
        }]} return
        $messagestore hole append $chatJid
    }

    # False when a sync is already running for this key, so a rejoin can't
    # double-query a room.
    method CatchupStart {jid} {
        if {[dict exists $CatchupInFlight $jid]} { return 0 }
        dict set CatchupInFlight $jid 1
        $client emit message <CatchupStarted> -jid $jid
        return 1
    }

    # Settled twice when a drop closes the bracket and the query it was
    # waiting on answers later; whichever gets here first wins.
    method CatchupSettled {jid count} {
        if {![dict exists $CatchupInFlight $jid]} return
        dict unset CatchupInFlight $jid
        $client emit message <CatchupDone> -jid $jid -count $count
        if {[string match {*\?join} $jid]} { $self FlushRoomRetry $jid }
    }

    method DoCatchup {} {
        if {![$self CatchupStart ""]} return
        set CatchupRowidFloor [$client db onecolumn {
            SELECT COALESCE(MAX(rowid), 0) FROM chat_message
        }]
        foreach var {LiveTop WalkBottom} {
            dict for {jid _} [set $var] {
                if {![IsRoomChatJid $jid]} { dict unset $var $jid }
            }
        }
        $client mam query -before {} -max 50 \
            -command [mymethod OnCatchup \
                [dict create counts {} mins {} floor "" overlap 0] 1]
    }

    method NoteWalkBottom {chatJid pos} {
        if {![dict exists $WalkBottom $chatJid]
                || [string compare $pos [dict get $WalkBottom $chatJid]] < 0} {
            dict set WalkBottom $chatJid $pos
        }
    }

    # Where a catchup page goes in $chatJid when the walk has stored nothing
    # there yet: below the first message that arrived live since it asked,
    # else at the chat's end.
    method CatchupTop {chatJid} {
        dict getdef $LiveTop $chatJid ""
    }

    # One page of the account catchup. $acc carries what the earlier pages of
    # this run established (per-chat counts, the lowest place the walk has
    # stored in each chat, the run's floor, and how many results matched
    # history we already had); $page is this page's number. A single page
    # only reaches back 50 messages, which on an account that was away a
    # while leaves the other chats untouched and the floor high enough that
    # RetryPending condemns delivered sends. The walk stops at the first page
    # that reaches history we already had: below it, everything was read
    # before this connection.
    method OnCatchup {acc page mamResult} {
        if {[dict exists $mamResult error]} {
            # Whatever earlier pages established still stands; only this
            # page's range is unknown. An error on the first page leaves no
            # evidence at all, so RetryPending judges nothing.
            $self SettleCatchup $acc 0
            return
        }

        # Each page goes in right below what the walk has stored above it.
        set ctx [dict create dir down above [dict get $acc mins] \
            topcmd [mymethod CatchupTop]]
        set acc [$self MergeCatchupPage $acc \
            [$self CatchupPage $mamResult "" $ctx]]
        set CatchupAcc $acc
        dict for {jid pos} [dict get $acc mins] {
            $self NoteWalkBottom $jid $pos
        }

        if {![$self CatchupIsLast $acc $mamResult $page]} {
            $client mam query -before [dict get $mamResult first] -max 50 \
                -command [mymethod OnCatchup $acc [expr {$page + 1}]]
            return
        }

        $self SettleCatchup $acc [dict get $mamResult complete]
    }

    # False while the archive says more history exists, we have a cursor to
    # ask from, we haven't walked back far enough already, and we haven't yet
    # reached history we had. Reaching it is enough only once the run's floor
    # is below every send still pending from an earlier stream: until then
    # the archive copy that would confirm one may lie further back, and
    # RetryPending fails what predates the floor.
    method CatchupIsLast {acc mamResult page} {
        if {[dict get $mamResult complete]} { return 1 }
        if {$page >= $MaxCatchupPages} { return 1 }
        if {[dict getdef $acc overlap 0] > 0
                && ![$self PendingBelow [dict get $acc floor]]} {
            return 1
        }
        return [expr {![dict exists $mamResult first]
            || [dict get $mamResult first] eq ""}]
    }

    # Whether a 1:1 send still pending from an earlier stream is older than
    # $floor. A room's sends wait for the room's own walk, and one written to
    # this stream is SM's to settle; RetryPending judges neither by the floor.
    method PendingBelow {floor} {
        if {$floor eq ""} { return 0 }
        foreach msg [$self PendingSends all] {
            if {[string match {*\?join} [dict get $msg chat_jid]]} continue
            if {[$self IsWired [dict get $msg own_id]]} continue
            set ts [dict get $msg timestamp]
            if {$ts ne "" && $ts < $floor} { return 1 }
        }
        return 0
    }

    method MergeCatchupPage {acc pageResult} {
        dict set acc overlap [expr {[dict getdef $acc overlap 0]
            + [dict get $pageResult overlap]}]
        set counts [dict get $acc counts]
        dict for {jid n} [dict get $pageResult counts] {
            dict incr counts $jid $n
        }
        dict set acc counts $counts
        set mins [dict get $acc mins]
        dict for {jid pos} [dict get $pageResult min] {
            if {![dict exists $mins $jid]
                    || [string compare $pos [dict get $mins $jid]] < 0} {
                dict set mins $jid $pos
            }
        }
        dict set acc mins $mins
        set floor [dict get $acc floor]
        set pageFloor [dict get $pageResult floor]
        if {$pageFloor ne "" && ($floor eq "" || $pageFloor < $floor)} {
            dict set acc floor $pageFloor
        }
        return $acc
    }

    # Close the whole run at once: one <CatchupDone> per chat carrying every
    # page's share, so notify doesn't alert per page and re-alert on the next.
    # A run that reached history we had leaves no floor holes: the archive is
    # one timeline, so from that point up it is contiguous for every chat.
    method SettleCatchup {acc complete} {
        set CatchupRowidFloor ""
        set CatchupAcc ""
        if {$complete || [dict getdef $acc overlap 0] > 0} {
            foreach {jid pos} $ReconnectHoles {
                $messagestore hole drop $jid $pos
            }
        }
        set ReconnectHoles {}
        if {!$complete && [dict getdef $acc overlap 0] == 0} {
            $self PlaceCatchupFloorHoles [dict get $acc mins]
        }
        set totalCount 0
        dict for {jid n} [dict get $acc counts] {
            $client emit message <CatchupDone> -jid $jid -count $n
            incr totalCount $n
        }
        $self CatchupSettled "" $totalCount
        # Anything still pending after the archive has had its say either
        # never reached the server or predates what the archive covered.
        $self RetryPending [dict get $acc floor] $complete
        $self QueueOmemoFills [dict keys [dict get $acc mins]]
    }

    # Fills for the chats whose OMEMO messages a backward walk may have left
    # behind: a contact with a device whose skipped keys we hold has messages
    # we have not read in their chat; one of our own devices could have
    # written in any, so for those the chats this catchup reached.
    method QueueOmemoFills {runChats} {
        foreach chatJid [$client db eval {
            SELECT DISTINCT chat_jid FROM chat_message WHERE undecrypted=1
        }] {
            $self QueueFill $chatJid
        }
        if {[catch {$client omemo sendersWithSavedKeys} senders]} return
        set me [jid norm [jid bare [$client cget -jid]]]
        foreach sender $senders {
            set sender [jid norm $sender]
            if {$sender eq $me} {
                foreach chatJid $runChats {
                    if {![IsMucChatJid $chatJid]} { $self QueueFill $chatJid }
                }
            } else {
                $self QueueFill $sender
            }
        }
    }

    # Bound the older edge of what a run that stopped short actually fetched:
    # a hole below the lowest row it stored in each chat ($mins: chat -> pos).
    # Belongs to the run, not a page: an intermediate page's lowest sits inside
    # the range the next page goes on to prove contiguous.
    method PlaceCatchupFloorHoles {mins} {
        dict for {jid pos} $mins {
            $messagestore hole addBefore $jid $pos
        }
    }

    # Fetch a joined room's own archive - the account archive holds no
    # groupchat, so nothing else syncs a room.
    method DoMucCatchup {roomChatJid} {
        if {![$self CatchupStart $roomChatJid]} return
        dict unset LiveTop $roomChatJid
        dict unset WalkBottom $roomChatJid
        $client mam queryChat $roomChatJid -before {} -max 50 \
            -command [mymethod OnMucCatchup $roomChatJid]
    }

    method OnMucCatchup {roomChatJid mamResult} {
        regsub {\?join$} $roomChatJid {} roomJid
        if {[dict exists $mamResult error]} {
            # A room without an archive says so; a timeout says nothing.
            set cond [dict getdef $mamResult error_condition ""]
            if {$cond in {feature-not-implemented service-unavailable}} {
                $client muc noteArchive $roomJid 0
            }
            $self CatchupSettled $roomChatJid 0
            return
        }
        $client muc noteArchive $roomJid 1
        set page [$self CatchupPage $mamResult $roomChatJid \
            [dict create dir down above {} topcmd [mymethod CatchupTop]]]
        if {![dict get $mamResult complete]} {
            $self PlaceCatchupFloorHoles [dict get $page min]
        }
        dict for {jid pos} [dict get $page min] { $self NoteWalkBottom $jid $pos }
        set n [dict getdef [dict get $page counts] $roomChatJid 0]
        $self CatchupSettled $roomChatJid $n
        # One page reaches back 50 messages; an OMEMO room fills the rest
        # forward (FillChat).
        if {[dict get $page omemo] > 0 && ![dict get $mamResult complete]} {
            $self QueueFill $roomChatJid
        }
    }

    # =====================================================================
    # Forward fill
    # =====================================================================
    #
    # The catchup walks back from the newest message and stops short after a
    # long absence, leaving a hole. For plain text that is fine: the hole
    # fills when the user scrolls into it. OMEMO is not: a session reads its
    # chain forward, so a message a backward walk opened first left the keys
    # of everything before it saved (omemo_skipped), and those are spent or
    # dropped long before anyone scrolls. A fill walks one chat's newest hole
    # forward instead, from the message below it to the one above, oldest
    # first, so each message opens on the key saved for it.
    #
    # After each page the hole moves up to sit right above the last message
    # stored, so a fill a drop cuts short (or MaxFillPages stops) is taken up
    # where it stopped, by the next connect's.

    # Ask for a fill of $chatJid's newest hole; fills run one at a time.
    method QueueFill {chatJid} {
        if {$chatJid in $FillQueue} return
        if {$FillBusy ne "" && [lindex $FillBusy 1] eq $chatJid} return
        lappend FillQueue $chatJid
        if {$FillBusy eq ""} { $self NextFill }
    }

    method NextFill {} {
        set FillBusy ""
        if {![llength $FillQueue]} {
            # What no fill could read gets the heal it was spared (omemo).
            catch {$client omemo fillsSettled}
            return
        }
        while {[llength $FillQueue]} {
            set chatJid [lindex $FillQueue 0]
            set FillQueue [lrange $FillQueue 1 end]
            set target [$self FillTarget $chatJid]
            if {$target eq ""} continue
            set FillBusy [list [incr FillRun] $chatJid]
            dict set target pages 0
            dict set target count 0
            $self FillQuery $chatJid $target [list -after [dict get $target loSid]]
            return
        }
        catch {$client omemo fillsSettled}
    }

    # What a fill of $chatJid walks, as a dict: from the message below the
    # chat's last hole - the last below its first undecrypted message, when
    # it has one (loPos, and loSid, the archive id it continues after)
    # to the one above it (gapTop, its pos; "" when nothing
    # is above), and on through the last row still undecrypted (hiPos), so
    # those are read again in order too. A chat with no hole but rows
    # undecrypted is walked from the message below the first of them, with
    # no gapTop. "" when there is nothing to walk, or no message below to
    # start from.
    method FillTarget {chatJid} {
        set undecLast [$client db onecolumn {
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=$chatJid AND undecrypted=1
        }]
        # Messages not read yet: the gap below the first of them is where
        # their chain goes on from, whatever holes sit above.
        set undecFirst [$client db onecolumn {
            SELECT MIN(pos) FROM chat_message
            WHERE chat_jid=$chatJid AND undecrypted=1
        }]
        set holePos ""
        if {$undecFirst ne ""} {
            set holePos [$client db onecolumn {
                SELECT MAX(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND kind='hole' AND pos < $undecFirst
            }]
        }
        if {$holePos eq ""} {
            set holePos [$client db onecolumn {
                SELECT MAX(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND kind='hole'
            }]
        }
        if {$holePos ne ""} {
            set below $holePos
            set gapTop [$client db onecolumn {
                SELECT MIN(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
                  AND pos > $holePos
            }]
            set hiPos $gapTop
            if {$hiPos ne "" && $undecLast ne ""
                    && [string compare $undecLast $hiPos] > 0} {
                set hiPos $undecLast
            }
        } elseif {$undecLast ne ""} {
            set below [$client db onecolumn {
                SELECT MIN(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND undecrypted=1
            }]
            set gapTop ""
            set hiPos $undecLast
        } else {
            return ""
        }
        # Not one of our own sends: placed when written, it may have
        # reached the archive much later (written offline, sent on a retry),
        # and what follows it there is not what the gap is missing.
        set lo [$client db eval {
            SELECT pos, server_id FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
              AND COALESCE(own_id, '') = '' AND pos < $below
            ORDER BY pos DESC LIMIT 1
        }]
        if {$lo eq ""} { return "" }
        dict create loPos [lindex $lo 0] loSid [lindex $lo 1] hiPos $hiPos \
            gapTop $gapTop
    }

    method FillQuery {chatJid target cursor} {
        set run [lindex $FillBusy 0]
        set cmd [mymethod OnFill $run $chatJid $target $cursor]
        if {[IsRoomChatJid $chatJid]} {
            $client mam queryChat $chatJid {*}$cursor -max 50 -command $cmd
        } else {
            $client mam query -with $chatJid {*}$cursor -max 50 -command $cmd
        }
    }

    method OnFill {run chatJid target cursor mamResult} {
        if {$FillBusy eq "" || [lindex $FillBusy 0] != $run} return
        if {[dict exists $mamResult error]} {
            # The archive no longer knows the id below the hole (trimmed,
            # or another archive's): go on after the message below that
            # one. An archive trims its oldest first, so once none of ours
            # is left in it, all it holds came after them: walk it from its
            # start. Not from a time: the stamp we hold may be our clock's.
            if {[dict getdef $mamResult error_condition ""] eq "item-not-found"
                    && [lindex $cursor 0] eq "-after"} {
                set from [lindex $cursor 1]
                set older [$client db eval {
                    SELECT server_id FROM chat_message
                    WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
                      AND pos < (SELECT pos FROM chat_message
                                 WHERE chat_jid=$chatJid AND kind='message'
                                   AND server_id=$from ORDER BY pos LIMIT 1)
                    ORDER BY pos DESC LIMIT 1
                }]
                dict incr target tries
                if {$older ne "" && [dict get $target tries] <= $MaxFillRetries} {
                    $self FillQuery $chatJid $target [list -after $older]
                } else {
                    $self FillQuery $chatJid $target {}
                }
                return
            }
            # Anything else leaves the hole for the next connect.
            $self FinishFill $chatJid $target
            return
        }
        set loPos [dict get $target loPos]
        # The page goes on right after the message below the gap, under the
        # hole, which stays above it until the walk reaches the gap's top.
        set InFill 1
        try {
            set page [$self CatchupPage $mamResult \
                [expr {[IsRoomChatJid $chatJid] ? $chatJid : ""}] \
                [dict create dir up below [dict create $chatJid $loPos]]]
        } finally {
            set InFill 0
        }
        dict incr target count [dict getdef [dict get $page counts] $chatJid 0]
        dict incr target pages
        set gapTop [dict get $target gapTop]
        set top [dict getdef [dict get $page max] $chatJid ""]
        set last [dict get $mamResult last]
        set ended [expr {[dict get $mamResult complete] || $last eq ""}]
        set hiPos [dict get $target hiPos]
        set reached [expr {$top ne "" && $hiPos ne ""
            && [string compare $top $hiPos] >= 0}]
        # Nothing after the page's last message, when the archive says it
        # has nothing more: the gap above it is none.
        if {$ended} {
            $messagestore hole removeGap $chatJid newer \
                [expr {$top ne "" ? $top : $loPos}]
        }
        # The gap is closed once the walk has reached the row above it and
        # the pages' sweeps left no hole below that.
        if {$gapTop ne "" && ($ended
                || ($top ne "" && [string compare $top $gapTop] >= 0))} {
            if {![$messagestore HoleIn $chatJid $loPos $gapTop]} {
                dict set target closed 1
            }
            dict set target gapTop ""
        }
        # A message that came in undecrypted while the fill ran is read in
        # order too: the walk goes on through it.
        if {$reached && !$ended} {
            set undecLast [$client db onecolumn {
                SELECT MAX(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND undecrypted=1
            }]
            if {$undecLast ne "" && [string compare $undecLast $top] > 0} {
                dict set target hiPos $undecLast
                set reached 0
            }
        }
        if {$ended || $reached} {
            $self FinishFill $chatJid $target
            return
        }
        # The next page goes on after the last message this one stored.
        if {$top ne ""} { dict set target loPos $top }
        if {[dict get $target pages] >= $MaxForwardFillPages} {
            $self FinishFill $chatJid $target
            return
        }
        $self FillQuery $chatJid $target [list -after $last]
    }

    # A contact whose saved keys outlast the hole just closed has messages
    # in an older one: that is filled next.
    method FinishFill {chatJid target} {
        set n [dict get $target count]
        if {$n > 0} {
            $client emit message <CatchupDone> -jid $chatJid -count $n
        }
        if {[dict getdef $target closed 0] && ![IsMucChatJid $chatJid]
                && ![catch {$client omemo sendersWithSavedKeys} senders]
                && $chatJid in [lmap s $senders {jid norm $s}]} {
            lappend FillQueue $chatJid
        }
        $self NextFill
    }

    # One page from the archive, oldest result first. Every result is routed
    # to its chat and classified first, in order (Classify decrypts, and an
    # OMEMO chain reads forward), then each chat's new messages are placed
    # among the rows the page already held and stored (StorePage), without
    # <New> (backfill is not an arrival); the in-place patch verdicts still
    # fire, since they correct rows that may already be on screen.
    #
    # $fixedChatJid keys every message to one chat, for a room page whose
    # stanzas carry the room in `from` and can't be routed by envelope.
    # Empty routes per message off the envelope.
    #
    # $ctx says where the page goes in each chat:
    #   dir     down: a walk back, the next page goes below this one; up: a
    #           walk forward, the next goes above; none: no walk, the page
    #           is placed by timestamp (an island: a jump, a search)
    #   below   chat -> pos of the row the page continues after
    #   above   chat -> pos of the row the page goes below
    #   topcmd  for a chat `above` does not name: {*}topcmd chat gives the
    #           pos the page goes below, "" for the chat's end. The page is
    #           the archive's newest then (or right below what was): nothing
    #           stands between it and that row.
    #   tail    0: emit no <Tail> (default 1)
    #
    # One archive answered this page, so RSM makes it contiguous from its
    # oldest result to its newest for every chat it covers - and from the
    # row it continues after, or up to the row it goes below. Any hole a
    # covered chat holds in that span is a proven false positive and is
    # swept. Bounding the far edge is the caller's job, once its whole run
    # has stopped.
    #
    # Returns a dict:
    #   counts   chat -> messages stored
    #   floor    the oldest server stamp on the page, over every result
    #   min/max  chat -> lowest/highest pos the page's messages hold
    #   overlap  results matching a row stored before the account catchup
    #            started (CatchupRowidFloor)
    #   omemo    a room page's OMEMO results
    method CatchupPage {mamResult fixedChatJid ctx} {
        set myBareJid [jid bare [$client cget -jid]]
        set dir [dict getdef $ctx dir none]
        # Oldest timestamp this page returned: the floor of the range the
        # archive just spoke for. Taken over EVERY result node, including
        # the drop/reaction/edit verdicts that skip the citizen loop below
        # - they still bound the page, and a citizen-only minimum would
        # sit above the true floor and over-report non-delivery.
        set archiveFloor ""
        set overlap 0
        set omemo 0
        # chat -> the page's results for it, in order: {fixed pos} for one
        # the store already held, {new msg} for one to store.
        set entries [dict create]

        foreach resultNode [dict get $mamResult messages] {
            if {$fixedChatJid ne ""} {
                set fwdMsg [lindex [xsearch [lindex [xsearch $resultNode \
                    forwarded -ns urn:xmpp:forward:0] 0] message] 0]
                if {[llength [xsearch $fwdMsg encrypted \
                        -ns eu.siacs.conversations.axolotl]]} {
                    incr omemo
                }
                set chatJid $fixedChatJid
            } else {
                set fwdNode [lindex [xsearch $resultNode forwarded \
                                        -ns urn:xmpp:forward:0] 0]
                set msgNode [$client ingressAddresses \
                    [lindex [xsearch $fwdNode message] 0]]
                if {$msgNode eq ""} {
                    jlog warn "MAM: skipping result with unroutable address" \
                        -stanza $resultNode
                    continue
                }

                set fromBare [jid norm [jid bare [xsearch $msgNode -get @from]]]
                set toBare   [jid norm [jid bare [xsearch $msgNode -get @to]]]

                if {[string equal -nocase $fromBare $myBareJid]} {
                    set chatJid $toBare
                    set peer [xsearch $msgNode -get @to]
                } else {
                    set chatJid $fromBare
                    set peer [xsearch $msgNode -get @from]
                }
                set pmChat [$self PmChat $msgNode $peer]
                if {$pmChat ne ""} { set chatJid $pmChat }
                set inviteChat [$self inviteChat $msgNode]
                if {$inviteChat ne ""} { set chatJid $inviteChat }
            }

            set r [$self ParseResultNode $resultNode $chatJid \
                [expr {$fixedChatJid eq ""}]]
            set verdict [dict get $r verdict]
            if {[dict exists $r timestamp]} {
                set rts [dict get $r timestamp]
                if {$rts ne "" && ($archiveFloor eq "" || $rts < $archiveFloor)} {
                    set archiveFloor $rts
                }
            }
            # A reaction/edit/retract updates a stored message's display; it
            # isn't a row and doesn't bound a hole (like drop).
            if {[$self ApplyPatchVerdict $chatJid $r]} continue
            if {$verdict eq "drop"} continue

            switch $verdict {
                confirmed {
                    # pending->"" echo; not an overlap proof. Nor a place:
                    # a send of ours sits where it was written, which is not
                    # where the archive took it in if that was later.
                    $self HandleConfirmation $chatJid \
                        [list [dict get $r reconciled]]
                }
                duplicate {
                    set storedId [dict get $r stored_id]
                    set pos [$messagestore PlaceOf $chatJid $storedId]
                    if {$pos ne ""} { dict lappend entries $chatJid [list fixed $pos] }
                    # Stored before the catchup started: history we had.
                    if {$CatchupRowidFloor ne "" && $storedId <= $CatchupRowidFloor} {
                        incr overlap
                    }
                }
                new {
                    dict lappend entries $chatJid [list new [dict get $r msg]]
                }
            }
        }

        set counts [dict create]
        set mins [dict create]
        set maxs [dict create]
        dict for {chatJid list} $entries {
            set placed [$self StorePage $chatJid $list $ctx]
            if {[dict get $placed count] > 0} {
                dict set counts $chatJid [dict get $placed count]
            }
            set lo [dict get $placed min]
            set hi [dict get $placed max]
            if {$lo eq ""} continue
            dict set mins $chatJid $lo
            dict set maxs $chatJid $hi
            # Swept along the page in the archive's order, from the row it
            # continues after to the row it goes below; with neither above
            # it, the newest page speaks up to the chat's end.
            set seq [dict get $placed rows]
            set below [dict getdef [dict getdef $ctx below {}] $chatJid ""]
            if {$below ne ""} { set seq [linsert $seq 0 $below] }
            set openTop 0
            if {[dict exists [dict getdef $ctx above {}] $chatJid]} {
                lappend seq [dict get $ctx above $chatJid]
            } elseif {[dict exists $ctx topcmd]} {
                set to [{*}[dict get $ctx topcmd] $chatJid]
                if {$to eq ""} { set openTop 1 } else { lappend seq $to }
            }
            $messagestore hole clearProven $chatJid $seq $openTop
        }

        if {[dict getdef $ctx tail 1]} {
            dict for {chatJid _} $maxs {
                $self EmitTail $chatJid
            }
        }
        dict create counts $counts floor $archiveFloor min $mins max $maxs \
            overlap $overlap omemo $omemo
    }

    # Store one chat's share of a page ($entries, from CatchupPage) where it
    # goes, and return {count n min pos max pos rows {pos ...}}: the page's
    # rows there, rows in the page's (the archive's) order.
    # A run of new messages goes right after the row before it on the page
    # (or the row the page continues after) and before whatever followed
    # that; a run with nothing before it goes right below the row after it
    # (or the row the page goes below, or the chat's end). Either way it
    # stays below the next row the page held: nothing the archive held
    # between them is missing, or the page would have had it.
    method StorePage {chatJid entries ctx} {
        set dir [dict getdef $ctx dir none]
        set prev [dict getdef [dict getdef $ctx below {}] $chatJid ""]
        if {[dict exists [dict getdef $ctx above {}] $chatJid]} {
            set end [dict get $ctx above $chatJid]
        } elseif {[dict exists $ctx topcmd]} {
            set end [{*}[dict get $ctx topcmd] $chatJid]
        } else {
            set end ""
        }
        set count 0
        set held {}
        set n [llength $entries]
        set i 0
        while {$i < $n} {
            lassign [lindex $entries $i] kind value
            if {$kind eq "fixed"} {
                set prev $value
                lappend held $value
                incr i
                continue
            }
            # The run of new messages from here to the next row held.
            set run {}
            set j $i
            while {$j < $n && [lindex $entries $j 0] eq "new"} {
                lappend run [lindex $entries $j 1]
                incr j
            }
            set next [expr {$j < $n ? [lindex $entries $j 1] : $end}]
            if {$dir eq "none"} {
                set keys [lrepeat [llength $run] ""]
            } elseif {$prev ne ""} {
                set lo $prev
                set hi [$messagestore PosNext $chatJid $prev]
                if {$next ne "" && [string compare $next $lo] > 0
                        && ($hi eq "" || [string compare $next $hi] < 0)} {
                    set hi $next
                }
                set keys [expr {$j == $n && $dir eq "up"
                    ? [poskey page $lo $hi [llength $run] up]
                    : [poskey nBetween $lo $hi [llength $run]]}]
            } else {
                set hi $next
                set lo [$messagestore PosPrev $chatJid $hi]
                set keys [expr {$dir eq "down"
                    ? [poskey page $lo $hi [llength $run] down]
                    : [poskey nBetween $lo $hi [llength $run]]}]
            }
            foreach msg $run key $keys {
                if {$key ne ""} { dict set msg pos $key }
                set result [$messagestore store [list $msg]]
                set got [dict getdef $result positions {}]
                if {[llength $got]} {
                    incr count
                    set prev [lindex $got 0]
                    lappend held $prev
                } elseif {$key ne ""} {
                    # Already stored after all (repeated on the page): what
                    # follows goes after where it would have been.
                    set prev $key
                }
            }
            set i $j
        }
        if {[llength $held]} {
            set sorted [lsort $held]
            return [dict create count $count min [lindex $sorted 0] \
                max [lindex $sorted end] rows $held]
        }
        return [dict create count $count min "" max "" rows {}]
    }

    method OnDisconnect {args} {
        set LastOnlineUs [$self LinkHeardUs]
        # A walk the drop cut short leaves its floor bounded as a finished
        # one would: below what it reached is unknown. Unbounded, what it
        # stored would pass for history we had at the next connect.
        if {$CatchupAcc ne ""} {
            if {[dict getdef $CatchupAcc overlap 0] == 0} {
                $self PlaceCatchupFloorHoles [dict get $CatchupAcc mins]
            }
            set CatchupAcc ""
        }
        # A fill cut short leaves its hole where its last page put it; the
        # next connect's catchup asks for it again.
        set FillQueue {}
        set FillBusy ""
        array unset PendingRetry
        # The query settles these itself, but not until the session is back -
        # too long to leave a sync showing as running.
        set open $CatchupInFlight
        dict for {jid _} $open {
            $self CatchupSettled $jid 0
        }
    }

    # When the link was last known alive, in microseconds. A phone that
    # slept notices the drop at its wake, hours after the link died under
    # it, and a floor written then refuses every stamp of the flush the
    # next session brings (TrustedStamp): each would get its arrival
    # time. Only while the process slept is the link's last read (conn
    # lastHeard) earlier than the drop; else, and when conn cannot say,
    # it is now.
    method LinkHeardUs {} {
        set now [clock microseconds]
        if {[catch {$client conn lastHeard} heard]
                || [llength $heard] != 2} { return $now }
        lassign $heard ms slept
        if {![string is true -strict $slept] || ![string is wide -strict $ms]
                || $ms <= 0} { return $now }
        expr {min($ms * 1000, $now)}
    }

    # A call row's `active`: whether we are in the call held in $room.
    method InCall {room} {
        if {[catch {$client groupcall in_call -jid $room} in]} { return 0 }
        return $in
    }

    # Re-send a call's rows after its `active` or state moved.
    method PatchCallRows {room} {
        foreach row [$messagestore callsToRoom [jid norm $room]] {
            $self EmitMessagePatch {*}$row
        }
    }

    # A call row's `live`: whether anyone is in the call. Only a chat's
    # newest call is asked about; older ones read as over.
    method CallLive {chat id room} {
        set newest [$messagestore newestCall $chat]
        if {$newest eq "" || [lindex $newest 0] != $id} { return 0 }
        if {[catch {$client groupcall Liveness $room} live]} { return "" }
        return $live
    }

    # Move every pending invite to the call in $room to $state (joined,
    # ended).
    method SettleCall {room state} {
        foreach row [$messagestore callsToRoom [jid norm $room]] {
            lassign $row chat id
            set at [$messagestore callAt $chat $id]
            if {$at eq "" || [dict get $at state] ne ""} continue
            $messagestore setCallState $chat $id $state
            $self EmitMessagePatch $chat $id
        }
    }

    # Membership, as an invite's state reads it: bookmarked with autojoin.
    method RoomJoined {room} {
        if {[catch {$client bookmarks autojoin -jid $room} on]} { return 0 }
        return [expr {$on in {1 true}}]
    }

    # Membership moved: re-send every invite to that room. A cleared list
    # touches every room.
    method OnBookmarkChanged {args} {
        array set opts {-action "" -jid ""}
        array set opts $args
        if {$opts(-jid) ne ""} {
            set rows [$messagestore invitesToRoom [jid norm $opts(-jid)]]
        } else {
            set rows [$client db eval {
                SELECT chat_jid, id FROM chat_message
                WHERE invite_room != '' AND kind='message'
            }]
            set rows [lmap {c i} $rows {list $c $i}]
        }
        foreach row $rows {
            $self EmitMessagePatch {*}$row
        }
    }

    # The chat a room-relayed (mediated) invite is filed in: the room's own,
    # since who asked is only the room's word. "" for any other stanza. Live
    # (muc OnInvite) and catchup both use this so the per-chat dedup keeps
    # one row.
    method inviteChat {msgNode} {
        if {[llength [xsearch $msgNode x \
                -ns http://jabber.org/protocol/muc#user invite]] == 0} {
            return ""
        }
        set invite [ParseInvite $msgNode]
        if {$invite eq ""} { return "" }
        return "[dict get $invite room]?join"
    }

    # The chat (room/nick) for a MUC private message (XEP-0045 §7.5) with
    # $peer, or "". PMs carry an empty muc#user <x/>: rooms add it when
    # relaying and senders add it (XEP-0280 §6), which is how a carbon of a
    # PM is told apart from a chat with the room. Anyone can add the
    # element, so $peer must also be a known room; otherwise a contact could
    # create a room PM chat for one of its resources.
    method PmChat {msgNode peer} {
        if {$peer eq "" || [jid resource $peer] eq ""} { return "" }
        set x [lindex [xsearch $msgNode x \
            -ns http://jabber.org/protocol/muc#user] 0]
        if {$x eq ""} { return "" }
        if {[llength [xsearch $x invite]] || [llength [xsearch $x decline]]} {
            return ""
        }
        if {![$client muc is_known_room -jid $peer]} { return "" }
        return "[jid norm [jid bare $peer]]/[jid resource $peer]"
    }

    # Called on message stanzas that haven't been intercepted by other
    # modules. These are supposed to be 1-1 messages.
    method OnMessage {stanza} {
        set fromBare [jid norm [jid bare [xsearch $stanza -get @from]]]
        if {[xsearch $stanza -get @type] eq "error"} {
            # A bounce of something we sent to $fromBare: its id is our
            # own_id. Never content (see Classify), and no receipt.
            $self MarkBounced $fromBare [xsearch $stanza -get @id]
            return
        }
        set myBare [jid bare [$client cget -jid]]
        set isOwn [expr {$fromBare eq $myBare}]
        set peer [xsearch $stanza -get [expr {$isOwn ? "@to" : "@from"}]]
        set chatJid [$self PmChat $stanza $peer]
        if {$chatJid ne ""} {
            # muc handles PMs from joined rooms. This is a PM from a room
            # this device hasn't joined, or a carbon of one we sent.
        } elseif {$isOwn} {
            set chatJid [jid norm [jid bare [xsearch $stanza -get @to]]]
        } else {
            set chatJid $fromBare
        }
        if {$isOwn} {
            if {[$self HandleOwnMarker $chatJid $stanza]} return
        } elseif {[$self HandleMarker $chatJid $stanza]} {
            return
        }
        $self ingestLive $chatJid $stanza $isOwn
        if {!$isOwn} {
            $self AutoReceipt $chatJid $stanza
        }
    }

    # The account's send_chat_markers setting; unset means on. Gates all
    # outgoing markers.
    method MarkersEnabled {} {
        expr {[client_setting_get $client send_chat_markers 1] ne "0"}
    }

    # Send a bodyless receipt/marker stanza referencing $refId. Not stored
    # (ClassifyMessage drops bodyless control stanzas).
    method SendMarker {toJid element ns refId} {
        $client write [j message -to $toJid -type chat -id [clock microseconds] {
            j $element -ns $ns -id $refId
        }]
    }

    # A receipt or marker says we are online and reading, so it goes only to
    # who may see our presence anyway: a subscription from us, or both ways.
    method MaySeePresence {chatJid} {
        if {[catch {$client roster subscription -jid $chatJid} sub]} {
            return 0
        }
        return [expr {$sub in {from both}}]
    }

    # Reply with a `received` marker if a live 1:1 message asked for one
    # (XEP-0184 <request> / XEP-0333 <markable>). Read is GUI-driven.
    method AutoReceipt {chatJid stanza} {
        if {![$self MarkersEnabled]} return
        # A carbon is a copy: the device it was addressed to answers it,
        # not every one of ours.
        if {[$client inCarbon]} return
        if {![$self MaySeePresence $chatJid]} return
        set refId [xsearch $stanza -get @id]
        if {$refId eq ""} return
        if {[llength [xsearch $stanza request -ns urn:xmpp:receipts]] > 0} {
            $self SendMarker $chatJid received urn:xmpp:receipts $refId
        }
        if {[llength [xsearch $stanza markable -ns urn:xmpp:chat-markers:0]] > 0} {
            $self SendMarker $chatJid received urn:xmpp:chat-markers:0 $refId
        }
    }

    # A bodyless XEP-0184 receipt / XEP-0333 chat marker from the peer
    # advances outgoing messages' remote_status (delivered/read), one
    # <Status> per row that moved. Returns 1 if the stanza was a marker
    # (consumed here), else 0 so OnMessage falls through to ingestLive.
    # A 'displayed' outranks a co-present 'received', and covers every
    # message up to its target rather than just the one it names.
    method HandleMarker {chatJid stanza} {
        set targetId [xsearch $stanza displayed \
            -ns urn:xmpp:chat-markers:0 -get @id]
        if {$targetId ne ""} {
            set tier read
        } else {
            set tier ""
            foreach ns {urn:xmpp:receipts urn:xmpp:chat-markers:0} {
                set targetId [xsearch $stanza received -ns $ns -get @id]
                if {$targetId ne ""} {
                    set tier delivered
                    break
                }
            }
        }
        if {$tier eq ""} { return 0 }
        foreach row [$messagestore markRemoteStatus $chatJid $targetId $tier] {
            $client emit message <Status> -jid $chatJid \
                -id [dict get $row id] \
                -remote_status [dict get $row remote_status]
        }
        return 1
    }

    # A `displayed` marker from our own bare jid is another of our devices
    # reporting how far it has read, so it moves our watermark rather than
    # the peer's remote_status. Returns 1 if the stanza was such a marker
    # (consumed here), else 0 so OnMessage falls through to ingestLive.
    # An unresolvable target id is a message we don't have: no-op.
    method HandleOwnMarker {chatJid stanza} {
        set targetId [xsearch $stanza displayed \
            -ns urn:xmpp:chat-markers:0 -get @id]
        if {$targetId eq ""} { return 0 }
        set id [$messagestore resolveTargetId $chatJid $targetId]
        if {$id ne ""} { $self AdvanceOwnRead $chatJid $id }
        return 1
    }

    # Live-stanza entry point. Called from OnMessage (1:1 DMs) and from the
    # MUC module (groupchat with room@muc?join, PMs with room@muc/nick).
    # Builds the {serverId ownId originId} triple off the stanza (live
    # messages carry their own stanza-id; an own echo's @id is passed
    # explicitly via isOwn) then funnels into the shared Classify core.
    method ingestLive {chatJid stanza {isOwn 0}} {
        set stamp [$self TrustedStamp $chatJid $stanza]
        # A stamp we cannot parse is no stamp: the store does arithmetic
        # on what it gets, so hand it now rather than ParseTimestamp's "".
        set ts [ParseTimestamp $stamp]
        set now [clock microseconds]
        # A stamped stanza is on the server's clock even when that runs
        # ahead of ours: room history replayed on join must not count as
        # news to a correction's last-writer-wins.
        if {$ts eq ""} {
            set tsClock local
        } else {
            set tsClock server
            $messagestore noteArchiveTs $chatJid $ts
        }
        if {$ts eq "" || $ts > $now} { set ts $now }
        set idArgs {}
        if {$isOwn} {
            # Prefer origin-id: some rooms rewrite @id.
            set ownId [xsearch $stanza origin-id -ns urn:xmpp:sid:0 -get @id]
            if {$ownId eq ""} { set ownId [xsearch $stanza -get @id] }
            set idArgs [list -own_id $ownId]
        }
        set ids [$self ExtractEnvelopeIds $stanza $chatJid {*}$idArgs]
        set verdict [$self Classify $chatJid $stanza $ts $ids $tsClock]
        # History a room replays on join is not news: nothing rings for it.
        dict set verdict delayed [expr {$stamp ne ""}]
        # Held for us by the server (its offline store, a room's history),
        # whether or not its stamp is one we take: archived before anything
        # we asked since, so not news to the archive's order either.
        dict set verdict held [expr {[llength [xsearch $stanza delay \
            -ns urn:xmpp:delay]] > 0}]
        set placed [$self DispatchLive $chatJid $verdict]
        # A message the server held for us (its offline store, a room's
        # history on join) is from the past: what came after it is unknown
        # until a catchup or a fill reaches it, so a hole marks that.
        if {[dict get $verdict verdict] eq "new" && [dict get $verdict held]
                && [dict get [dict get $verdict msg] server_id] ne ""} {
            foreach pos $placed { $messagestore hole addAfter $chatJid $pos }
        }
        # One our session could not open yet: what it is ahead of is in the
        # archive, and a fill reads it in order (FillTarget).
        if {[dict get $verdict verdict] eq "new"
                && [dict getdef [dict get $verdict msg] undecrypted 0]} {
            $self QueueFill $chatJid
        }
    }

    # The <delay> stamp of a live message, if one comes from who may set it:
    # our server (offline storage), our own account, or the room for its
    # history. Anyone else's would let a sender date a message as it likes
    # (2099 pins it as the chat's newest and moves the read point past
    # everything after it). "" when there is none.
    # A peer can write our server's or account's name on a delay too, so
    # those stamps count only from OfflineFloorUs on: the server held
    # nothing for us from before our previous session.
    method TrustedStamp {chatJid stanza} {
        set me [jid bare [$client cget -jid]]
        jid explode $me e
        set ours [list [jid norm $e(domain)] [jid norm $me]]
        set room ""
        if {[string match *?join $chatJid]} {
            set room [jid norm [string range $chatJid 0 end-5]]
        }
        foreach d [xsearch $stanza delay -ns urn:xmpp:delay] {
            set from [xsearch $d -get @from]
            if {$from eq "" || [catch {jid norm $from} from]} continue
            set stamp [xsearch $d -get @stamp]
            if {$from eq $room} { return $stamp }
            if {$from ni $ours} continue
            set ts [ParseTimestamp $stamp]
            if {$OfflineFloorUs ne "" && $ts ne "" && $ts < $OfflineFloorUs} {
                continue
            }
            return $stamp
        }
        return ""
    }

    # Act on one live message's verdict (from Classify):
    #   confirmed → echo of one of our own pending sends → <Confirmed>
    #   new       → store, then surface (store skips a copy already held).
    #   duplicate → already a citizen; nothing to show.
    #   drop      → displayless (control type / keytransport); nothing.
    # reaction/edit/retract patch a message already stored rather than adding
    # one. 1 when the verdict was one of those and has been applied.
    method ApplyPatchVerdict {chatJid r} {
        switch [dict get $r verdict] {
            reaction { $self ApplyReactionVerdict $chatJid $r }
            edit     { $self ApplyEditVerdict $chatJid $r }
            retract  -
            tombstone { $self ApplyRetractVerdict $chatJid $r }
            call     { $self ApplyCallVerdict $chatJid $r }
            defer    {
                set patch [dict get $r patch]
                $messagestore defer $chatJid [dict get $patch target_id] \
                    [dict get $r kind] [dict get $r timestamp] $patch
            }
            default  { return 0 }
        }
        return 1
    }

    # The pos of what it stored, if anything.
    # Returns the pos of what it stored, if anything.
    method DispatchLive {chatJid verdict} {
        if {[$self ApplyPatchVerdict $chatJid $verdict]} return
        set stored {}
        switch [dict get $verdict verdict] {
            confirmed {
                $self HandleConfirmation $chatJid \
                    [list [dict get $verdict reconciled]]
            }
            new {
                set msg [dict get $verdict msg]
                # Held for us and not on the catchup's pages: older than all
                # they stored, so below the lowest of it.
                if {[dict getdef $verdict held 0]
                        && [dict exists $WalkBottom $chatJid]} {
                    set bottom [dict get $WalkBottom $chatJid]
                    dict set msg pos [poskey between \
                        [$messagestore PosPrev $chatJid $bottom] $bottom]
                }
                set result [$messagestore store [list $msg] append]
                set positions [dict getdef $result positions {}]
                # The first to come in undelayed while the chat's catchup
                # runs: the archive took it after the catchup asked.
                if {[llength $positions] && ![dict getdef $verdict held 0]
                        && ![dict exists $LiveTop $chatJid]
                        && [dict exists $CatchupInFlight [expr {
                            [IsRoomChatJid $chatJid] ? $chatJid : ""}]]} {
                    dict set LiveTop $chatJid [lindex $positions 0]
                }
                $self HandleInsertion $chatJid [dict get $result inserted]
                set stored $positions
                # Someone else's group call invite, arriving now: a ring.
                if {[dict exists $msg call] && [dict get $msg call] ne ""
                        && [dict get $msg call_state] eq ""
                        && !([dict exists $verdict delayed] && [dict get $verdict delayed])
                        && [llength [dict get $result inserted]]} {
                    $client groupcall OnInvited $chatJid \
                        [lindex [dict get $result inserted] 0]
                }
            }
        }
        return $stored
    }

    # An XEP-0482 accept/reject/retract/left for a stored call invite.
    # accept/left/retract mean someone went in or out, so liveness is asked
    # again. A pending row moves on: a peer's retract is a missed call, our
    # other device's accept/reject answered it for us.
    method ApplyCallVerdict {chatJid r} {
        set tag [dict get $r tag]
        set own [dict get $r is_own]
        set to [switch -- $tag {
            retract { expr {$own ? "" : "missed"} }
            accept  { expr {$own ? "elsewhere" : ""} }
            reject  { expr {$own ? "declined" : ""} }
            default { format "" }
        }]
        foreach row [$messagestore callsById $chatJid [dict get $r id]] {
            lassign $row id state room
            set moved [expr {$tag in {accept left retract}}]
            if {$moved} { catch {$client groupcall ForgetLiveness $room} }
            if {$to ne "" && $state eq ""} {
                $messagestore setCallState $chatJid $id $to
                set moved 1
            }
            if {$moved} { $self EmitMessagePatch $chatJid $id }
        }
    }

    # Echo of a pending outgoing message: messagestore has already flipped
    # server_status pending → '' (server has it), captured server_id and
    # taken the copy's stamp. The row keeps its place: <Confirmed> carries
    # the stamp it shows now.
    method HandleConfirmation {chatJid confirmed} {
        foreach c $confirmed {
            $client emit message <Confirmed> -jid $chatJid \
                -id [dict get $c id] -timestamp [dict get $c timestamp] \
                -server_status ""
        }
        $self EmitTail $chatJid
    }

    method HandleInsertion {chatJid inserted} {
        if {[llength $inserted] == 0} return
        set dbMsg [lindex [$messagestore get ids $chatJid $inserted] 0]
        # A carbon or MUC echo of our own send from another device: we were
        # reading there. Catchup pages don't come through here, so paging
        # history can't move the watermark.
        if {[dict get $dbMsg is_outgoing]} {
            $self AdvanceOwnRead $chatJid [dict get $dbMsg id]
        }
        $client emit message <New> -jid $chatJid -message $dbMsg
        $self EmitTail $chatJid
    }

    # Move the watermark, emitting only on a real move.
    method AdvanceOwnRead {chatJid id} {
        if {![$messagestore markOwnRead $chatJid $id]} return
        $client emit message <OwnRead> -jid $chatJid -id $id
    }

    # own_id -> 1 for sends written to the CURRENT stream, i.e. the ones
    # SM is holding for ack or replay. Deliberately memory-only: this is
    # per-connection truth, so a restart starts empty and a stale row can
    # never look in flight. Cleared on a fresh <SessionStart>, pruned as rows
    # settle.
    variable WiredNow

    method MarkWired {oid} { dict set WiredNow $oid 1 }
    method ClearWired {oid} { dict unset WiredNow $oid }
    method IsWired {oid} { return [dict exists $WiredNow $oid] }

    # Pages one history fill will walk while nothing displayable turns up.
    typevariable MaxFillPages 20

    # Compute (msgType, toJid, fromJid, fromRes) from a chat jid.
    # MUC chats use the `?join` suffix tacky uses internally for the
    # "self as room member" identity.
    method DeriveAddressing {chatJid} {
        if {[string match {*\?join} $chatJid]} {
            set msgType groupchat
            regsub {\?join$} $chatJid {} toJid
            set nick [$client muc my_nick -jid $toJid]
            return [list $msgType $toJid $toJid/$nick ""]
        }
        return [list chat $chatJid \
            [jid bare [$client cget -jid]] \
            [jid resource [$client cget -jid]]]
    }

    # Build a <message> for an outbound message, in one of two forms:
    #   wire      what goes on the network. OMEMO body is the <encrypted>
    #             payload + EME marker + a warning body; the <fallback> is
    #             dropped (its offsets index the cleartext body, which isn't
    #             on the wire). Encrypting can throw TACO_OMEMO_NOT_READY
    #             (transient - leave pending, retry on <SessionReady>) or
    #             TACO_OMEMO_TERMINAL (don't retry).
    #   readable  the cleartext record stored in raw_xml (debug). OMEMO keeps
    #             the real body + EME marker and the fallback; never encrypts,
    #             never throws.
    # Plaintext is identical in both modes.
    #
    #   chatJid  destination chat (peer to OMEMO-encrypt for; wire only)
    #   body     readable text; for a reply, includes the `> quoted` prefix
    #   oid      origin id (= row's own_id); matches the echo/ack back
    #   msgType  'chat' or 'groupchat'
    #   toJid    address the stanza is sent to
    #   encMode  'omemo' or '' for plaintext (caller decides)
    #   replyId  XEP-0461 reply target id, or '' when not a reply
    #   replyTo  author of the replied-to message
    #   fbEnd    length of the quote prefix in $body (XEP-0428 fallback span)
    #   oobUrl   XEP-0066 <x> share url, or '' for no attachment. Cleartext,
    #            so an OMEMO send keeps the url in the encrypted body instead.
    #
    # OMEMO fail-closed: the wire form encrypts or throws, never cleartext.
    # See security invariant #2 in lib/taco/modules/omemo.tcl.
    method BuildMessageStanza {mode chatJid body oid msgType toJid encMode \
            {replyId ""} {replyTo ""} {fbEnd 0} {replaceId ""} {oobUrl ""}} {
        set omemo   [expr {$encMode eq "omemo"}]
        set encWire [expr {$omemo && $mode eq "wire"}]
        return [j message -to $toJid -type $msgType -id $oid {
            # XEP-0359 origin-id: unlike @id, servers and rooms don't rewrite
            # it, so it identifies the message in a room archive and for
            # peers that reference it.
            j origin-id -ns urn:xmpp:sid:0 -id $oid
            # XEP-0308 correction hint: plaintext even when the body is
            # OMEMO-encrypted, so a peer can match it to the original.
            if {$replaceId ne ""} {
                j replace -ns urn:xmpp:message-correct:0 -id $replaceId
            }
            if {$omemo} {
                if {$encWire} {
                    j #as-is [$client omemo encrypt $chatJid $body]
                }
                j encryption -ns urn:xmpp:eme:0 \
                    -namespace eu.siacs.conversations.axolotl \
                    -name OMEMO
            }
            if {$encWire} {
                j body -body \
                    "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            } else {
                j body -body $body
            }
            if {$replyId ne ""} {
                j reply -ns urn:xmpp:reply:0 -to $replyTo -id $replyId
                if {$fbEnd > 0 && !$encWire} {
                    j fallback -ns urn:xmpp:fallback:0 -for urn:xmpp:reply:0 {
                        j body -start 0 -end $fbEnd
                    }
                }
            }
            if {$oobUrl ne ""} {
                j x -ns jabber:x:oob { j url -body $oobUrl }
            }
            # Mark MUC PMs (XEP-0045 §7.5) so our other devices can file
            # their carbons correctly (XEP-0280 §6).
            if {[IsMucChatJid $chatJid] && ![IsRoomChatJid $chatJid]} {
                j x -ns http://jabber.org/protocol/muc#user
            }
            # Ask 1:1 peers for delivery/read markers (XEP-0184/0333).
            if {$msgType eq "chat"} {
                j request -ns urn:xmpp:receipts
                j markable -ns urn:xmpp:chat-markers:0
            }
        }]
    }

    # Intended encryption for a fresh outbound message to $chatJid:
    # 'omemo' when OMEMO is enabled for that 1:1 chat or room, else ''
    # (plaintext). The omemo module owns the per-chat toggle; for a room it
    # stays on even if the room stops qualifying, and encrypting then fails
    # the send rather than sending in the clear.
    method OutgoingEncMode {chatJid msgType} {
        if {$msgType in {chat groupchat} && [$client omemo IsEnabled $chatJid]} {
            return omemo
        }
        return ""
    }

    # Durable message send — store before transmit, confirm on echo/ack.
    #
    # 1. Generate a unique ID, build the stanza (may need OMEMO).
    # 2. Persist to DB. server_status='pending' if we wrote to the wire
    #    or expect to retry; 'failed' if the build said TERMINAL.
    # 3. Emit <New> so the GUI can display immediately (optimistic).
    # 4. Write stanza to server if one exists.
    #
    # OMEMO cold-cache path: encrypt throws TACO_OMEMO_NOT_READY,
    # message persists pending without going on the wire, warming runs
    # in the background, OnOmemoSessionReady drives a retry. Reuses
    # the existing pending-row machinery rather than a separate
    # outbox/queue.
    #
    # Confirmation (pending → "", server has it) happens via two paths:
    #   MUC:  server echoes the message back with our id; the echo hits
    #         `ingestLive`, where `reconcile` finds the pending row and
    #         flips it to ''.
    #   1:1:  SM ack confirms the server received the stanza; `OnSmAck`
    #         calls `confirmByOwnIds` on the messagestore.
    # Both paths emit <Status> so the GUI can show the checkmark.
    #
    # On reconnect, `RetryPending` resends any still-pending messages
    # with the same id, so the echo/ack cycle can complete.
    # Returns the stored row's timestamp.
    tackymethod send {args} {
        array set opts $args

        set ts [clock microseconds]
        set oid $ts

        lassign [$self DeriveAddressing $opts(-chat)] \
            msgType toJid fromJid fromRes

        set replyId ""
        set replyTo ""
        set wireBody $opts(-body)
        set fbEnd 0
        set encMode [$self OutgoingEncMode $opts(-chat) $msgType]
        if {[info exists opts(-reply_to_id)] && $opts(-reply_to_id) ne ""} {
            lassign [$self BuildReplyTarget $opts(-chat) $opts(-reply_to_id)] \
                replyId replyTo quoteBody quoteEnc
            # An OMEMO-encrypted body is only visible after decryption, by
            # which point a peer's XEP-0428 fallback-stripping has already
            # run against the (unrelated) cleartext warning body -- there's
            # no valid offset to publish. Skip quoting; <reply> alone
            # covers context there instead of a doubled-up quote.
            #
            # TODO: XEP-0420 (SCE) could carry the fallback inside the
            # encrypted envelope instead; needs an envelope builder/parser
            # on both send and receive, plus OMEMO 2 (SCE is specified
            # against urn:xmpp:omemo:2, not our current legacy namespace).
            #
            # Also skip quoting an encrypted target in a cleartext reply: its
            # body is stored decrypted, so the quote would leak it.
            if {$replyId ne "" && $encMode ne "omemo" && $quoteEnc eq ""} {
                lassign [reply::quote $quoteBody] quote fbEnd
                set wireBody $quote$opts(-body)
            }
        }
        set stanza ""
        set status "pending"
        set failReason ""
        try {
            set stanza [$self BuildMessageStanza wire \
                $opts(-chat) $wireBody $oid $msgType $toJid $encMode \
                $replyId $replyTo $fbEnd]
        } trap TACO_OMEMO_NOT_READY {emsg} {
            # Stays pending; warming kicks via encrypt side effect.
            jlog debug "send $opts(-chat): OMEMO not ready ($emsg), parking pending oid=$oid"
        } trap TACO_OMEMO_TERMINAL {emsg} {
            jlog debug "send $opts(-chat): OMEMO terminal ($emsg), marking failed oid=$oid"
            set status "failed"
            set failReason "encrypt"
        }

        set msg [dict create \
            timestamp $ts \
            chat_jid $opts(-chat) \
            from_jid $fromJid \
            from_resource $fromRes \
            body $opts(-body) \
            server_id "" \
            own_id $oid \
            origin_id $oid \
            reply_id $replyId \
            reply_to $replyTo \
            raw_xml [expr {$stanza eq "" ? "" \
                : [jwrite [$self BuildMessageStanza readable $opts(-chat) \
                    $wireBody $oid $msgType $toJid $encMode \
                    $replyId $replyTo $fbEnd]]}] \
            server_status $status \
            encryption $encMode \
            fail_reason $failReason]

        set result [$messagestore store [list $msg] append]
        set inserted [dict get $result inserted]
        set dbMsg [lindex [$messagestore get ids $opts(-chat) $inserted] 0]

        $client emit message <New> \
            -jid $opts(-chat) -message $dbMsg
        $self EmitTail $opts(-chat)
        # Writing here means we have read what was above.
        $self AdvanceOwnRead $opts(-chat) [dict get $dbMsg id]

        if {$stanza ne ""} {
            $self MarkWired $oid
            $self WriteOrFail $opts(-chat) $oid $stanza
        }
        return [dict get $dbMsg id]
    }

    # Look up the replied-to row and resolve its reply id (reply::pick_id).
    # Returns {replyId author fullBody encryption}; the body is used for the
    # wire quote unless the target was encrypted.
    method BuildReplyTarget {chatJid id} {
        set found 0
        $client db eval {
            SELECT server_id, origin_id, own_id, from_jid, body, encryption
            FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND id=$id
            LIMIT 1
        } row { set found 1 }
        if {!$found} { return [list "" "" "" ""] }
        set replyId [reply::pick_id [IsRoomChatJid $chatJid] \
            $row(server_id) $row(origin_id) $row(own_id)]
        return [list $replyId $row(from_jid) $row(body) $row(encryption)]
    }

    # Attachment send (XEP-0363 + XEP-0066), optimistic + progress:
    #   1. store now as 'uploading' (attachment path = local file, url still
    #      empty) and emit <New> so it shows immediately;
    #   2. hand the file to the file module, which PUTs it and reports bytes
    #      via `file <Update>` (keyed by the message id);
    #   3. on success promote to 'pending' with the public URL + OOB stanza and
    #      transmit (echo/ack then confirms);
    #   4. on failure mark 'failed' (the file module's <Update> shows it).
    tackymethod send_file {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set path $opts(-path)
        set oid [clock microseconds]
        lassign [$self DeriveAddressing $chatJid] msgType toJid fromJid fromRes
        set encMode [$self OutgoingEncMode $chatJid $msgType]
        set msg [dict create \
            timestamp $oid chat_jid $chatJid \
            from_jid $fromJid from_resource $fromRes \
            body "" server_id "" own_id $oid origin_id $oid raw_xml "" \
            encryption $encMode \
            attachments [OutgoingAttachment "" $path] \
            server_status uploading]
        set inserted [dict get [$messagestore store [list $msg] append] inserted]
        set id [lindex $inserted 0]
        set dbMsg [lindex [$messagestore get ids $chatJid $inserted] 0]
        $client emit message <New> -jid $chatJid -message $dbMsg
        $self EmitTail $chatJid
        $self AdvanceOwnRead $chatJid $id
        $self StartUpload $chatJid $oid $id $path $encMode
        return $id
    }

    # The transfer id is the message's row id, so the GUI, which keys an
    # outgoing attachment by its message, correlates upload progress without
    # a handshake. Progress/terminal state reach the GUI via the file
    # module's `file <Update>` event; OnUploaded is the internal completion
    # that turns the GET URL into the actual outgoing stanza.
    method StartUpload {chatJid oid id path encMode} {
        $client file upload -id $id -path $path \
            -encrypt [expr {$encMode eq "omemo"}] \
            -command [mymethod OnUploaded $chatJid $oid $id $path $encMode]
    }

    method OnUploaded {chatJid oid id path encMode url} {
        if {$url eq ""} {
            $messagestore markUploadFailed $chatJid $oid
            $client emit message <Status> -jid $chatJid \
                -id $id -server_status failed -fail_reason upload
            return
        }
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        # OMEMO: the aesgcm:// fragment carries the media key, so the URL must
        # ride inside the OMEMO body, never a cleartext OOB. RetrySend encrypts
        # it and parks the row pending if the session isn't ready yet.
        if {$encMode eq "omemo"} {
            $messagestore markUploaded $chatJid $oid $url \
                [jwrite [$self BuildMessageStanza readable $chatJid $url $oid \
                    $msgType $toJid omemo]] \
                [OutgoingAttachment $url $path] omemo
            $client emit message <Status> -jid $chatJid \
                -id $id -server_status pending
            $self RetrySend [dict create chat_jid $chatJid body $url \
                own_id $oid encryption omemo reply_id "" reply_to ""]
            return
        }
        # Plaintext share: the url is both the body and the XEP-0066 <x>.
        set stanza [$self BuildMessageStanza wire $chatJid $url $oid \
            $msgType $toJid "" "" "" 0 "" $url]
        $messagestore markUploaded $chatJid $oid $url [jwrite $stanza] \
            [OutgoingAttachment $url $path] ""
        $client emit message <Status> -jid $chatJid \
            -id $id -server_status pending
        # In flight from here, so RetryPending doesn't send it twice.
        $self MarkWired $oid
        $self WriteOrFail $chatJid $oid $stanza
    }

    # Re-attempt a failed upload using the local file recorded on the row. A
    # missing source surfaces as a `file <Update>` failed (file upload checks
    # readability), so no separate guard is needed here.
    tackymethod -noreturn retry_upload {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set id $opts(-id)
        set row [lindex [$messagestore get ids $chatJid [list $id]] 0]
        if {$row eq "" || ![dict exists $row content] \
            || [dict get $row content type] ne "media"} return
        set atts [dict get $row content attachments]
        set path [dict get [lindex $atts 0] path]
        set oid [dict get $row own_id]
        set encMode [expr {[dict exists $row encryption] \
            ? [dict get $row encryption] : ""}]
        $messagestore markUploading $chatJid $oid
        $client emit message <Status> -jid $chatJid \
            -id $id -server_status uploading -fail_reason ""
        $self StartUpload $chatJid $oid $id $path $encMode
    }

    method OnSmAck {args} {
        set stanzas [dict get $args -stanzas]
        set ownIds {}
        foreach stanza $stanzas {
            if {[dict get $stanza tag] ne "message"} continue
            set oid [xsearch $stanza -get @id]
            if {$oid ne ""} {
                lappend ownIds $oid
            }
        }
        if {[llength $ownIds] == 0} return
        # Acked means SM has let go of it: no longer in flight, whether or
        # not it turns out to match a row we were tracking.
        foreach oid $ownIds {
            $self ClearWired $oid
        }
        set confirmed [$messagestore confirmByOwnIds $ownIds]
        foreach c $confirmed {
            # An SM ack carries no stamp: the row keeps the one it has.
            $client emit message <Confirmed> -jid [dict get $c chat_jid] \
                -id [dict get $c id] -server_status ""
        }
    }

    # Pending sends as RetrySend-shaped dicts, by scope:
    #   all          every pending row (reconnect retry)
    #   parked-omemo pending OMEMO not currently in flight
    #   peer-omemo   parked-omemo narrowed to $peerJid
    # The omemo scopes drop rows SM is still holding: re-sending one would
    # duplicate it. That's a WiredNow lookup rather than a WHERE clause -
    # in-flight is per-connection state, so it isn't in the table.
    method PendingSends {scope {peerJid ""}} {
        set sql {SELECT chat_jid, body, own_id, encryption, reply_id, reply_to,
                        timestamp, id
                 FROM chat_message
                 WHERE kind='message' AND server_status='pending'}
        switch $scope {
            all {}
            parked-omemo { append sql { AND encryption='omemo'} }
            peer-omemo   { append sql \
                { AND +chat_jid=$peerJid AND encryption='omemo'} }
        }
        # Read through idx_chat_message_pending, which the literal
        # server_status='pending' selects; the + keeps peer-omemo off the
        # primary key, which would walk the peer's whole chat.
        append sql { ORDER BY id}
        set pending {}
        $client db eval $sql row {
            if {$scope ne "all" && [$self IsWired $row(own_id)]} continue
            lappend pending [dict create \
                chat_jid $row(chat_jid) body $row(body) \
                own_id $row(own_id) encryption $row(encryption) \
                reply_id $row(reply_id) reply_to $row(reply_to) \
                timestamp $row(timestamp) id $row(id)]
        }
        return $pending
    }

    # Decide what to do with each still-pending send, now that catchup has
    # confirmed everything the server actually archived.
    #
    # $archiveFloor is the oldest timestamp that catchup returned ("" if it
    # returned nothing or errored); $complete is its RSM complete flag. The
    # page covers [archiveFloor, now] contiguously, so:
    #   inside that range  - the archive would have shown the message and
    #                        didn't, so the server never got it: re-send.
    #   older than it      - outside the evidence. We can't tell whether it
    #                        was delivered, so stop guessing and mark it
    #                        failed for the user to judge.
    #   complete archive   - nothing is outside the evidence; never fail.
    #   no floor at all    - no evidence; retry as before, fail nothing.
    method RetryPending {{archiveFloor ""} {complete 0}} {
        set joinedNow {}
        foreach msg [$self PendingSends all] {
            set chatJid [dict get $msg chat_jid]
            # MUC messages must wait for room join. The account archive
            # holds no room traffic, so the floor can't speak to them; the
            # room's own walk (DoMucCatchup) confirms what the room has. A
            # room already joined whose walk has settled takes them now;
            # any other is marked, and what is still pending once its walk
            # settles is sent then (FlushRoomRetry).
            if {[string match {*\?join} $chatJid]} {
                regsub {\?join$} $chatJid {} roomJid
                if {[$client muc is_joined -jid $roomJid]
                        && ![dict exists $CatchupInFlight $chatJid]} {
                    lappend joinedNow $roomJid
                } else {
                    set PendingRetry($roomJid) 1
                }
                continue
            }
            # Written to the current stream: SM owns it for ack or replay,
            # so it isn't ours to re-send or judge.
            if {[$self IsWired [dict get $msg own_id]]} continue
            set ts [expr {[dict exists $msg timestamp] \
                ? [dict get $msg timestamp] : 0}]
            if {!$complete && $archiveFloor ne "" && $ts < $archiveFloor} {
                jlog debug "RetryPending $chatJid oid=[dict get $msg own_id]:\
                    predates archive floor, marking delivery-failed"
                $self MarkOutgoingFailed $chatJid [dict get $msg own_id] delivery
                continue
            }
            $self RetrySend $msg
        }
        foreach roomJid [lsort -unique $joinedNow] {
            $self RetryRoom $roomJid
        }
    }

    # Re-send what is still pending for a joined room, read now rather than
    # when the retry was decided: a message the room confirmed meanwhile is
    # no longer pending, and one on the current stream is SM's to replay.
    method RetryRoom {roomJid} {
        foreach msg [$self PendingSends all] {
            if {[dict get $msg chat_jid] ne "${roomJid}?join"} continue
            if {[$self IsWired [dict get $msg own_id]]} continue
            $self RetrySend $msg
        }
    }

    # Bus callback for omemo:<SessionReady>/<DevicelistResolved> on
    # $peerJid. Retries pending OMEMO sends to $peerJid still parked off
    # the wire: re-running encrypt either succeeds, stays pending (still
    # warming), or TERMINAL-fails (empty devicelist).
    method OnOmemoSessionReady {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set pending [$self PendingSends peer-omemo $peerJid]
        jlog debug "omemo:<SessionReady> $peerJid: [llength $pending] pending omemo send(s) to retry"
        foreach msg $pending {
            $self RetrySend $msg
        }
    }

    # Called via bus when omemo's account-level state (store + own
    # devicelist) is ready. Unlike OnOmemoSessionReady this isn't tied
    # to one peer: retry every pending OMEMO send that never reached the
    # wire, since they were all blocked on the same account prerequisite.
    method OnOmemoSelfReady {args} {
        set pending [$self PendingSends parked-omemo]
        jlog debug "omemo:<SelfReady>: [llength $pending] pending omemo send(s) to retry"
        foreach msg $pending {
            $self RetrySend $msg
        }
    }

    # Called via bus when a MUC room is joined - sync its archive; the
    # pending retries RetryPending marked for the room go out once that
    # walk settles (FlushRoomRetry), so a send the room already has is
    # confirmed by its copy rather than sent twice. <Joined> fires on the
    # first self-presence, so the archive page races the room's own
    # replay; whichever lands second dedups.
    method OnMucJoined {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc is_hidden -jid [dict get $args -jid]]} return
        set roomJid [dict get $args -jid]
        $self DoMucCatchup ${roomJid}?join
    }

    # The room's walk settled, read or failed: what RetryPending marked for
    # it and is still pending goes out now, if we are in the room.
    method FlushRoomRetry {roomChatJid} {
        regsub {\?join$} $roomChatJid {} roomJid
        if {![info exists PendingRetry($roomJid)]} return
        if {![$client muc is_joined -jid $roomJid]} return
        unset PendingRetry($roomJid)
        $self RetryRoom $roomJid
    }

    # Retry a still-pending message. Uses BuildMessageStanza so OMEMO
    # chats get re-encrypted against the current devicelist (the
    # devicelist may have changed since the original send; replaying a
    # stored stanza would either leak cleartext or send to a
    # stale recipient set). Honors the row's stamped `encryption` —
    # automatic retries never downgrade an OMEMO message to plaintext
    # even if the per-chat toggle was flipped off in the meantime.
    method RetrySend {msg} {
        set chatJid [dict get $msg chat_jid]
        set body    [dict get $msg body]
        set oid     [dict get $msg own_id]
        # double check encryption desire
        set dbEnc [$client db onecolumn {
            SELECT encryption FROM chat_message
            WHERE chat_jid=$chatJid AND own_id != '' AND own_id=$oid
              AND kind='message'
        }]
        set dictEnc [expr {[dict exists $msg encryption] \
            ? [dict get $msg encryption] : ""}]
        set encMode [expr {($dbEnc eq "omemo" || $dictEnc eq "omemo") \
            ? "omemo" : ""}]
        # Preserve the reply linkage across retries. The textual quote
        # fallback isn't reconstructed (the stored body is the clean,
        # unquoted text), so fbEnd stays 0 - 0461-aware peers still see
        # the <reply> reference.
        set replyId [expr {[dict exists $msg reply_id] \
            ? [dict get $msg reply_id] : ""}]
        set replyTo [expr {[dict exists $msg reply_to] \
            ? [dict get $msg reply_to] : ""}]
        lassign [$self DeriveAddressing $chatJid] msgType toJid _ _

        jlog debug "RetrySend $chatJid oid=$oid encMode=$encMode"
        try {
            set stanza [$self BuildMessageStanza wire \
                $chatJid $body $oid $msgType $toJid $encMode \
                $replyId $replyTo]
        } trap TACO_OMEMO_NOT_READY {} {
            # Warming still in flight; the row stays pending and waits for
            # the next tick. Warming is bounded by omemo's own per-device
            # deadline, and a row that never gets out is failed by the
            # archive-floor rule on the next connect - so there's no
            # attempt counter here.
            jlog debug "RetrySend $chatJid oid=$oid: still NOT_READY, staying pending"
            return
        } trap TACO_OMEMO_TERMINAL {} {
            jlog debug "RetrySend $chatJid oid=$oid: TERMINAL, marking failed"
            $self MarkOutgoingFailed $chatJid $oid encrypt
            return
        }

        jlog debug "RetrySend $chatJid oid=$oid: built stanza, writing to wire"
        # raw_xml is refreshed only as a debug record (readable form, not
        # the wire ciphertext).
        set xml [jwrite [$self BuildMessageStanza readable \
            $chatJid $body $oid $msgType $toJid $encMode \
            $replyId $replyTo]]
        $client db eval {
            UPDATE chat_message SET raw_xml=$xml
            WHERE chat_jid=$chatJid AND own_id != '' AND own_id=$oid
        }
        # Marks it in flight, so a later warm tick won't re-send it.
        $self MarkWired $oid
        $self WriteOrFail $chatJid $oid $stanza
    }

    # Write an outgoing message's stanza. One past the server's stanza limit
    # (XEP-0478; conn refuses it) would be refused on every retry, so the
    # row fails with fail_reason too-large instead of staying pending.
    method WriteOrFail {chatJid oid stanza} {
        try {
            $client write $stanza
        } trap TACO_STANZA_TOO_LARGE {emsg} {
            jlog warn "message to $chatJid not sent: too large for the server ($emsg)"
            $self MarkOutgoingFailed $chatJid $oid too-large
        }
    }

    # resend -chat X -id I ?-plaintext 0|1?
    #
    # User-driven resend of a pending/failed outgoing message, row $I. Default honors the
    # row's stamped `encryption` — "try again, same way". `-plaintext 1`
    # rewrites the stamp to '' and is the ONLY path allowed to downgrade
    # an OMEMO message to cleartext, so a stuck encrypted message can be
    # sent in clear once the user learns the peer can't do OMEMO.
    #
    # Does NOT touch the chat toggle: downgrading one message leaves the
    # chat's default encryption for future messages unchanged. Fire-and-
    # forget; the outcome surfaces via <Status> like any other send.
    tackymethod -noreturn resend {args} {
        array set opts {-plaintext 0}
        array set opts $args
        set chatJid $opts(-chat)
        set id      $opts(-id)

        set row [$client db eval {
            SELECT own_id, body, encryption, reply_id, reply_to
            FROM chat_message
            WHERE chat_jid=$chatJid AND id=$id AND kind='message'
        }]
        if {[llength $row] == 0} return
        lassign $row oid body enc replyId replyTo

        # The downgrade rides the <Status> too: the row's padlock is drawn
        # from the stamp, so a silent rewrite leaves it displayed as
        # encrypted while the body goes out in clear.
        set stamp {}
        if {$opts(-plaintext)} {
            set enc ""
            $client db eval {
                UPDATE chat_message SET encryption=''
                WHERE chat_jid=$chatJid AND id=$id
            }
            set stamp [list -encryption ""]
        }

        # Fresh attempt: drop any in-flight marker (RetrySend re-adds it on
        # write; a still-parked OMEMO retry must stay eligible for
        # <SessionReady>), flip back to pending and clear the prior failure
        # so the GUI shows it in flight; MarkOutgoingFailed re-stamps
        # fail_reason if it fails again.
        $self ClearWired $oid
        $client db eval {
            UPDATE chat_message
            SET server_status='pending', fail_reason=''
            WHERE chat_jid=$chatJid AND id=$id
        }
        $client emit message <Status> -jid $chatJid \
            -id $id -server_status pending -fail_reason "" {*}$stamp

        $self RetrySend [dict create \
            chat_jid $chatJid body $body own_id $oid encryption $enc \
            reply_id $replyId reply_to $replyTo]
    }

    # Flip a pending row to failed with a fail_reason category and notify
    # the GUI. `reason` is a category ('encrypt' = OMEMO couldn't produce
    # ciphertext, 'delivery' = the archive says it never landed, 'too-large'
    # = past the stanza size the server takes); persisted
    # on the row and carried in the <Status> so the GUI picks the right
    # affordance (e.g. resend-as-plaintext).
    method MarkOutgoingFailed {chatJid oid reason} {
        $client db eval {
            UPDATE chat_message
            SET server_status='failed', fail_reason=$reason
            WHERE chat_jid=$chatJid AND own_id=$oid
              AND server_status='pending'
        }
        set id [$client db onecolumn {
            SELECT id FROM chat_message
            WHERE chat_jid=$chatJid AND own_id=$oid
        }]
        if {$id eq ""} return
        $self ClearWired $oid
        $client emit message <Status> -jid $chatJid \
            -id $id -server_status failed -fail_reason $reason
    }

    # The peer's side refused a message we sent. Unlike MarkOutgoingFailed
    # this also turns a message the server already acked: the ack was our
    # server's, the refusal comes after it -- but only within BounceWindowUs
    # of the send: every recipient knows our id, and a bounce of theirs much
    # later must not fail a message long delivered.
    method MarkBounced {chatJid oid} {
        if {$oid eq ""} return
        lassign [$client db eval {
            SELECT id, timestamp FROM chat_message
            WHERE chat_jid=$chatJid AND own_id=$oid
              AND server_status IN ('pending', '')
        }] id ts
        if {$id eq ""} return
        if {$ts < [clock microseconds] - $BounceWindowUs && [$client db onecolumn {
                SELECT server_status FROM chat_message
                WHERE chat_jid=$chatJid AND own_id=$oid
            }] eq ""} {
            jlog debug "message: a late bounce of $oid in $chatJid ignored"
            return
        }
        $client db eval {
            UPDATE chat_message
            SET server_status='failed', fail_reason='delivery'
            WHERE chat_jid=$chatJid AND own_id=$oid
        }
        $self ClearWired $oid
        $client emit message <Status> -jid $chatJid \
            -id $id -server_status failed -fail_reason delivery
    }

    # raw_xml -chat $chatJid -id $id -command $cb
    tackymethod raw_xml {args} {
        array set opts $args
        $client db onecolumn {
            SELECT raw_xml FROM chat_message
            WHERE chat_jid=$opts(-chat) AND id=$opts(-id)
        }
    }

    # The chat's last message as {id timestamp}, {"" ""} for none: what
    # EmitTail pushes in the message <Tail> event.
    method Tail {chatJid} {
        set tail [$client db eval {
            SELECT id, timestamp FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message'
            ORDER BY pos DESC LIMIT 1
        }]
        expr {[llength $tail] ? $tail : {"" ""}}
    }

    # Push the chat's last message so the GUI tracks the tail without
    # polling. Emitted wherever it can change: new inserts and a
    # confirmation (which restamps it).
    method EmitTail {chatJid} {
        lassign [$self Tail $chatJid] id ts
        $client emit message <Tail> -jid $chatJid -id $id -timestamp $ts
    }

    # observe hook: re-emit the current tail so a fresh listener seeds.
    tackymethod pull {args} {
        array set opts $args
        switch -- $opts(-event) {
            <Tail>  { $self EmitTail $opts(-jid) }
            default {
                return -code error \
                    "message pull: event $opts(-event) is not pullable"
            }
        }
    }

    # mark_displayed -chat $chatJid -id $id ?-after $afterId?
    # Send a `displayed` marker for the last of the peer's messages up to
    # row $id and past row $afterId, which marks everything up to it read.
    # A marker for a message of our own means nothing, so with ours on
    # screen below theirs it is theirs that is named. No-op for MUC, when
    # disabled, to who may not see our presence, or when there is no such
    # message with an origin id to reference.
    tackymethod mark_displayed {args} {
        set opts(-after) ""
        array set opts $args
        if {![$self MarkersEnabled]} return
        if {[string match {*\?join} $opts(-chat)]} return
        if {![$self MaySeePresence $opts(-chat)]} return
        set upTo [$messagestore PosOf $opts(-chat) $opts(-id)]
        if {$upTo eq ""} return
        set from [expr {$opts(-after) eq "" ? ""
            : [$messagestore PosOf $opts(-chat) $opts(-after)]}]
        set chat $opts(-chat)
        set originId [$client db onecolumn "
            SELECT origin_id FROM chat_message
            WHERE chat_jid=\$chat AND kind='message'
              [expr {$from eq "" ? "" : {AND pos > $from}}] AND pos <= \$upTo
              AND (own_id IS NULL OR own_id = '') AND origin_id != ''
            ORDER BY pos DESC LIMIT 1
        "]
        if {$originId eq ""} return
        $self SendMarker $opts(-chat) displayed urn:xmpp:chat-markers:0 $originId
    }

    # mark_own_read -chat $chatJid -id $id
    # Record that we have read this chat up to row $id. Local state only (the
    # wire marker is mark_displayed's job), and applies to MUC as well.
    # Forward-only, so it is safe to call on every focus and scroll.
    tackymethod mark_own_read {args} {
        array set opts $args
        $self AdvanceOwnRead $opts(-chat) $opts(-id)
    }

    # own_read -chat $chatJid
    # Our read watermark for one chat (the id of the last row read, "" for
    # none) and what is still unread past it.
    tackymethod own_read {args} {
        array set opts $args
        return [dict create \
            id [dict get [$messagestore ownRead $opts(-chat)] id] \
            unread [$messagestore unreadCount $opts(-chat)]]
    }

    # react -chat $chatJid -id $id -emoji $emoji
    # Toggle one emoji in our XEP-0444 reaction set for a message. The set
    # is recomputed and sent whole (the protocol sends the complete set, not
    # a delta); toggling off the last emoji sends an empty <reactions/>.
    tackymethod react {args} {
        array set opts $args
        set target $opts(-id)
        set targetId [$self ReferenceId $opts(-chat) $target]
        if {$targetId eq ""} return
        set ownId [$self OwnReactionSenderId $opts(-chat)]
        set current [$messagestore ownReactions $opts(-chat) $targetId $ownId]
        set idx [lsearch -exact $current $opts(-emoji)]
        if {$idx >= 0} {
            set current [lreplace $current $idx $idx]
        } else {
            lappend current $opts(-emoji)
        }
        $self SetReactions $opts(-chat) $target $current
    }

    # clear_reactions -chat $chatJid -id $id — drop all our reactions.
    tackymethod clear_reactions {args} {
        array set opts $args
        $self SetReactions $opts(-chat) $opts(-id) {}
    }

    # edit -chat $chatJid -id $id -body $newText
    # XEP-0308 correction of our own message: send a fresh message carrying
    # <replace id=original> + the new body, then optimistically swap the
    # stored body and <Edited>. The MUC echo / 1:1 carbon re-applies
    # idempotently. Build first so an OMEMO failure aborts before we mutate.
    tackymethod edit {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set targetId [$self CorrectionAnchorId $chatJid $opts(-id)]
        if {$targetId eq ""} return
        set newBody $opts(-body)
        set oid [clock microseconds]
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        set encMode [$self OutgoingEncMode $chatJid $msgType]
        try {
            set stanza [$self BuildMessageStanza wire $chatJid $newBody \
                $oid $msgType $toJid $encMode "" "" 0 $targetId]
        } trap TACO_OMEMO_NOT_READY {emsg} {
            jlog debug "edit $chatJid: OMEMO not ready ($emsg), aborting edit"
            return
        } trap TACO_OMEMO_TERMINAL {emsg} {
            jlog debug "edit $chatJid: OMEMO terminal ($emsg), aborting edit"
            return
        }
        $client write $stanza
        set readable [jwrite [$self BuildMessageStanza readable $chatJid \
            $newBody $oid $msgType $toJid $encMode "" "" 0 $targetId]]
        # No sender_fp on our own rows: we never decrypt our own sends, and
        # is_own already authorizes correcting them from any of our devices.
        $messagestore addAliases $chatJid $opts(-id) "" $oid
        set target [$messagestore applyEdit $chatJid $opts(-id) \
            $newBody $readable [clock microseconds] \
            [dict create encryption $encMode sender_fp ""] local]
        if {$target ne ""} { $self EmitMessagePatch $chatJid $target }
    }

    # retract -chat $chatJid -id $id
    # XEP-0424 self-retraction of our own 1:1 message (MUC retraction is
    # moderation - see `moderate`). Sends a <retract> with a 0428 fallback
    # body + 0334 store hint, then tombstones locally.
    tackymethod retract {args} {
        array set opts $args
        set chatJid $opts(-chat)
        if {[IsRoomChatJid $chatJid]} return
        set targetId [$self CorrectionAnchorId $chatJid $opts(-id)]
        if {$targetId eq ""} return
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        $client write [j message -to $toJid -type $msgType \
                -id [clock microseconds] {
            j retract -ns urn:xmpp:message-retract:1 -id $targetId
            j body -body "This message was retracted."
            j fallback -ns urn:xmpp:fallback:0 -for urn:xmpp:message-retract:1
            j store -ns urn:xmpp:hints
        }]
        set target [$self Retract $chatJid $opts(-id)]
        if {$target ne ""} { $self EmitRetracted $chatJid $target }
    }

    # Tombstone row $target and drop the downloaded files of its attachments
    # with their at-rest keys (file uncache), so a retracted picture is not
    # left on disk, readable with its key. The row's id, or "" when there
    # is no such message.
    method Retract {chatJid target} {
        set atts [$client db onecolumn {
            SELECT attachments FROM chat_message
            WHERE chat_jid=$chatJid AND id=$target AND kind='message'
        }]
        set target [$messagestore applyRetract $chatJid $target]
        if {$target eq ""} { return "" }
        foreach att $atts {
            if {[catch {dict get $att url} url] || $url eq ""} continue
            if {[catch {$client file uncache -url $url} err]} {
                jlog warn "message: a retracted message's file stays: $err"
            }
        }
        return $target
    }

    # moderate -chat $chatJid -id $id ?-reason $text? ?-onerror $cb?
    # XEP-0425 moderated retraction: a moderator asks the room (IQ set) to
    # retract a message. We do NOT tombstone here - the room's broadcast
    # drives it through the receive path, so a rejected request leaves the
    # message intact. Role is enforced by the service (and gated in the GUI).
    tackymethod -async moderate {args} {
        array set opts {-reason "" -command "" -onerror ""}
        array set opts $args
        set chatJid $opts(-chat)
        set targetId [$self ReferenceId $chatJid $opts(-id)]
        if {$targetId eq ""} {
            if {$opts(-onerror) ne ""} {
                {*}$opts(-onerror) "That message hasn't reached the room yet"
            }
            return
        }
        regsub {\?join$} $chatJid {} roomJid
        set roomJid [jid bare $roomJid]
        set reason $opts(-reason)
        $client iq request -type set -to $roomJid \
            -command [mymethod OnModerateResult $opts(-command) $opts(-onerror)] \
            -payload [j moderate -ns urn:xmpp:message-moderate:1 -id $targetId {
                j retract -ns urn:xmpp:message-retract:1
                if {$reason ne ""} { j reason -body $reason }
            }]
    }

    # The room's broadcast does the tombstoning; success just answers.
    method OnModerateResult {command onerror stanza} {
        if {[xsearch $stanza -get @type] ne "error"} {
            if {$command ne ""} { {*}$command "" }
            return
        }
        set condition [dict get [stanza_error $stanza] condition]
        jlog debug "moderate rejected: $condition"
        if {$onerror ne ""} {
            {*}$onerror [$self ModerateErrorText $condition]
        }
    }

    method ArchiveErrorText {condition} {
        switch -- $condition {
            remote-server-timeout   { return "The message archive did not respond" }
            service-unavailable     -
            feature-not-implemented { return "This server keeps no message archive" }
            forbidden               { return "You do not have access to that archive" }
            default                 { return "Couldn't reach the message archive" }
        }
    }

    method ModerateErrorText {condition} {
        switch -- $condition {
            forbidden      { return "You do not have permission to delete messages in this room" }
            not-allowed    { return "This room does not allow deleting messages" }
            not-acceptable { return "The room rejected that deletion" }
            item-not-found { return "That message is no longer in the room's archive" }
            default        { return "The message could not be deleted" }
        }
    }

    # Persist our full reaction set for a message (optimistic, is_own=1),
    # patch the local view, and put the set on the wire. In a MUC the room
    # reflects it back, re-applying idempotently to the same own-keyed row.
    method SetReactions {chatJid target emojis} {
        set targetId [$self ReferenceId $chatJid $target]
        if {$targetId eq ""} return
        set ownId [$self OwnReactionSenderId $chatJid]
        set ownLabel [$self OwnReactionLabel $chatJid]
        $messagestore applyReaction $chatJid $targetId $ownId $ownLabel 1 \
            $emojis [clock microseconds] local
        $self EmitReactionPatch $chatJid $target
        lassign [$self DeriveAddressing $chatJid] msgType toJid
        $self SendReactions $toJid $msgType $targetId $emojis
    }

    # Wire id an XEP-0308 correction / XEP-0424 retraction must reference:
    # the target's origin-id (its @id when no origin-id was stored), NEVER the
    # MUC stanza-id. Peers (Conversations, Dino) correlate a <replace>/<retract>
    # against the reflected origin-id/id, so a stanza-id here makes every edit
    # render as a fresh message on their side. Contrast ReferenceId, whose
    # MUC-uses-the-stanza-id rule is right for replies (0461), reactions (0444),
    # and moderation (0425). "" if the target is not stored.
    method CorrectionAnchorId {chatJid target} {
        set found 0
        $client db eval {
            SELECT origin_id, own_id FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND id=$target
            LIMIT 1
        } row { set found 1 }
        if {!$found} { return "" }
        if {$row(origin_id) ne ""} { return $row(origin_id) }
        return $row(own_id)
    }

    # Wire id that references a stored message: MUC stanza-id, else 1:1
    # origin/own (reply::pick_id). "" if unresolved. Shared by reactions,
    # replies, and moderation; corrections/retractions use CorrectionAnchorId.
    method ReferenceId {chatJid target} {
        set found 0
        $client db eval {
            SELECT server_id, origin_id, own_id FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND id=$target
            LIMIT 1
        } row { set found 1 }
        if {!$found} { return "" }
        return [reply::pick_id [IsRoomChatJid $chatJid] \
            $row(server_id) $row(origin_id) $row(own_id)]
    }

    # Our stable reactor key for a chat: own occupant-id in a MUC (nick
    # fallback when the room has no XEP-0421), bare jid in 1:1. Must agree
    # with resolveSender's own sender_id so the optimistic local row and the
    # reflected echo land on the same key.
    method OwnReactionSenderId {chatJid} {
        if {[IsMucChatJid $chatJid]} {
            regsub {\?join$} $chatJid {} roomJid
            set roomJid [jid bare $roomJid]
            set myOcc [$client muc my_occupant_id -jid $roomJid]
            if {$myOcc ne ""} { return $myOcc }
            return [$client muc my_nick -jid $roomJid]
        }
        return [jid bare [$client cget -jid]]
    }

    # Display label for our own reaction row: our nick in a MUC, bare jid in
    # 1:1. Separate from the sender key, which is the opaque occupant-id.
    method OwnReactionLabel {chatJid} {
        if {[IsMucChatJid $chatJid]} {
            regsub {\?join$} $chatJid {} roomJid
            return [$client muc my_nick -jid [jid bare $roomJid]]
        }
        return [jid bare [$client cget -jid]]
    }

    # Send our current reaction set for $targetId. An empty set sends an
    # empty <reactions/> (retract all). <store/> asks the server to archive
    # it so the set reconstructs from MAM.
    method SendReactions {toJid msgType targetId emojis} {
        $client write [j message -to $toJid -type $msgType \
                -id [clock microseconds] {
            j reactions -ns urn:xmpp:reactions:0 -id $targetId {
                foreach e $emojis { j reaction -body $e }
            }
            j store -ns urn:xmpp:hints
        }]
    }

    # history -chat $chatJid ?-before $ts? ?-after $ts? ?-limit 50?
    #         ?-tag $tag? -command $cb
    # Always async — calls -command with result list.
    # -tag: if given, the callback can be cancelled via `cancel -tag $tag`.
    #
    # Local-first: tries the local store before the server. messagestore
    # get methods truncate at holes and signal `bounded=1` when a
    # hole forced truncation and the limit wasn't satisfied; the
    # MAM fill kicks in to fetch what's on the far side of the gap.

    # Shared local-store query: dispatches to get before/after/latest.
    # Returns dict {messages bounded} (forwarded from messagestore.get).
    method GetLocal {chatJid before after limit} {
        if {$before ne ""} {
            return [$messagestore get before $chatJid $before $limit]
        } elseif {$after ne ""} {
            return [$messagestore get after $chatJid $after $limit]
        } else {
            return [$messagestore get latest $chatJid $limit]
        }
    }

    tackymethod -async history {args} {
        set defaults [dict create -before "" -after "" -limit 50 \
            -command "" -onerror "" -tag ""]
        set opts [dict merge $defaults $args]

        set chatJid [dict get $opts -chat]
        set limit   [dict get $opts -limit]
        set callback [dict get $opts -command]
        set onerror [dict get $opts -onerror]
        set before [dict get $opts -before]
        set after [dict get $opts -after]
        set tag [dict get $opts -tag]

        if {$tag ne ""} {
            lassign [$self TagWrap $tag $callback $onerror] callback onerror
        }

        set local [$self GetLocal $chatJid $before $after $limit]
        set localMessages [dict get $local messages]
        set bounded [dict get $local bounded]
        set hasCursor [expr {$before ne "" || $after ne ""}]

        # Return local immediately when it satisfies the request. Trigger
        # MAM only when there's a cursor to anchor the fill - initial
        # loads with some local data show what they have; the user
        # scrolls into the hole later to trigger fill. Empty local is the
        # exception: a cursorless load with nothing stored falls through
        # to a cursorless MAM fetch (first open of a chat pulls its
        # newest archive page).
        # A hole above the chat's newest message (left by a catchup that
        # did not reach the chat) is no older page to scroll into: a fill
        # walks it forward, and <CatchupDone> tells when it has.
        if {!$hasCursor && [$self TopHole $chatJid]} {
            $self QueueFill $chatJid
        }
        if {[llength $localMessages] >= $limit
            || ([llength $localMessages] > 0
                && (!$bounded || !$hasCursor))} {
            {*}$callback $localMessages
            return
        }

        # For -after queries with no hole ahead, skip MAM when
        # cursor is at or past the latest stored message — there's
        # nothing newer in the archive.
        if {$after ne "" && !$bounded} {
            set last [$client db onecolumn {
                SELECT MAX(pos) FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
            }]
            set at [$messagestore PosOf $chatJid $after]
            if {$last eq "" || ($at ne "" && [string compare $at $last] >= 0)} {
                {*}$callback $localMessages
                return
            }
        }

        $self QueryServer $chatJid $before $after $limit $callback $onerror \
            $tag $bounded 0
    }

    # Whether a hole sits above $chatJid's newest message.
    method TopHole {chatJid} {
        set top [$client db onecolumn {
            SELECT MAX(pos) FROM chat_message
            WHERE chat_jid=$chatJid AND kind='message' AND server_id != ''
        }]
        if {$top eq ""} { return 0 }
        $client db exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid=$chatJid AND kind='hole' AND pos > $top
        }
    }

    # Fire one MAM page anchored on the nearest citizen in the queried
    # direction (oldest at-or-after $before, newest at-or-before $after), or
    # cursorless when none exists. With no anchor, or `byTime` set, page by
    # time: -end plus an empty <before/> is the newest page at-or-before the
    # bound, -start the oldest at-or-after it. A bare query (no <before/>)
    # would return the archive's oldest page.
    method QueryServer {chatJid before after limit callback onerror tag \
                        wasBounded byTime} {
        set direction [expr {$after ne "" ? "newer" : "older"}]
        set mamArgs [list -max $limit]
        set cursor ""
        if {$byTime} {
            # No cursor: page by time below.
        } elseif {$before ne ""} {
            set at [$messagestore PosOf $chatJid $before]
            if {$at ne ""} {
                set cursor [$self CursorRow $chatJid "pos >= \$at" ASC]
            }
        } elseif {$after ne ""} {
            set at [$messagestore PosOf $chatJid $after]
            if {$at ne ""} {
                set cursor [$self CursorRow $chatJid "pos <= \$at" DESC]
            }
        } else {
            set cursor [$self CursorRow $chatJid 1 ASC]
        }
        lassign $cursor cursorId anchor

        if {$cursorId ne ""} {
            lappend mamArgs [expr {$after ne "" ? "-after" : "-before"}] $cursorId
        } elseif {$before ne ""} {
            lappend mamArgs -end [FormatTimestampISO \
                [$self RowStamp $chatJid $before]] -before ""
        } elseif {$after ne ""} {
            lappend mamArgs -start [FormatTimestampISO \
                [$self RowStamp $chatJid $after]]
        } else {
            lappend mamArgs -before ""
        }
        # Where the page goes: next to the cursor's row; at the chat's end
        # for its newest page; by time when the query was by time.
        if {$cursorId ne ""} {
            set place [list $direction $anchor]
        } elseif {$before eq "" && $after eq ""} {
            set place {tail ""}
        } else {
            set place {time ""}
        }

        lappend mamArgs -command [mymethod OnFetch $chatJid $before $after \
            $limit $callback $onerror $tag $direction $wasBounded $cursorId \
            $place 1]

        $client mam queryChat $chatJid {*}$mamArgs
    }

    # {server_id pos} of the first citizen meeting $cond in $order: one
    # not ours if there is one (a send of ours sits where it was written,
    # perhaps long before the archive took it in), else ours. The caller's
    # variables are in scope for $cond.
    method CursorRow {chatJid cond order} {
        upvar 1 at at
        foreach own {{AND COALESCE(own_id, '') = ''} {}} {
            set row [$client db eval "
                SELECT server_id, pos FROM chat_message
                WHERE chat_jid=\$chatJid AND kind='message' AND server_id != ''
                  AND $cond $own
                ORDER BY pos $order LIMIT 1
            "]
            if {[llength $row]} { return $row }
        }
        return {}
    }

    # The timestamp row $id shows, for asking the archive by time.
    method RowStamp {chatJid id} {
        $messagestore stampOf $chatJid $id
    }

    # The CatchupPage context for a history page placed as $place says
    # ({older|newer pos}: beside that row; {tail ""}: the chat's newest
    # page; {time ""}: by timestamp).
    method FetchContext {chatJid place} {
        lassign $place how anchor
        switch -- $how {
            older { dict create dir down above [dict create $chatJid $anchor] tail 0 }
            newer { dict create dir up below [dict create $chatJid $anchor] tail 0 }
            tail  { dict create dir down topcmd [list apply {{jid} {}}] tail 0 }
            default { dict create dir none tail 0 }
        }
    }

    method OnFetch {chatJid before after limit callback onerror tag direction \
                    wasBounded cursorId place page mamResult} {
        if {[dict exists $mamResult error]} {
            if {$tag ne "" && ![info exists ActiveTags($tag)]} return
            # item-not-found: the cursor left the archive; retry once by
            # time. Other errors fall back to local.
            set cond [expr {[dict exists $mamResult error_condition]
                ? [dict get $mamResult error_condition] : ""}]
            if {$cond eq "item-not-found" && $cursorId ne ""} {
                $self QueryServer $chatJid $before $after $limit $callback \
                    $onerror $tag $wasBounded 1
                return
            }
            set local [$self GetLocal $chatJid $before $after $limit]
            # A short page is an ordinary answer; an empty one reads as "the
            # archive ends here", and callers stop paging for good on it.
            if {$onerror ne "" && [llength [dict get $local messages]] == 0} {
                {*}$onerror [$self ArchiveErrorText $cond]
                return
            }
            {*}$callback [dict get $local messages]
            return
        }

        # Store the new batch (even if cancelled - data is useful), placed
        # next to the cursor's row and swept between them.
        set got [$self CatchupPage $mamResult $chatJid \
            [$self FetchContext $chatJid $place]]
        set lo [dict getdef [dict get $got min] $chatJid ""]
        set hi [dict getdef [dict get $got max] $chatJid ""]
        # The next page, and the far edge's hole, go on from this page's edge.
        lassign $place how anchor
        if {$how eq "tail"} { set how older }
        if {$how eq "older" && $lo ne ""} { set place [list older $lo] }
        if {$how eq "newer" && $hi ne ""} { set place [list newer $hi] }

        set cancelled [expr {$tag ne "" && ![info exists ActiveTags($tag)]}]
        set local [$self GetLocal $chatJid $before $after $limit]
        set complete [dict get $mamResult complete]
        set pageSize [llength [dict get $mamResult messages]]

        # A page can be entirely empty-body stanzas (receipts, chatstates).
        # Responding with nothing displayable would strand the GUI: its
        # scroll-back cursor only advances on displayed messages, so it
        # would re-issue the same query forever. Page on by this page's far
        # edge only while the local read still has nothing; short pages are
        # returned immediately and the GUI's thirst loop drives further
        # fetching. The pageSize>0 guard stops a complete=false empty
        # response from spinning, and MaxFillPages stops a long stretch of
        # archived receipts or reactions from walking the whole archive
        # while one caller waits on it - the thirst loop asks again.
        if {!$cancelled
            && [llength [dict get $local messages]] == 0
            && !$complete && $pageSize > 0 && $page < $MaxFillPages
            && [lindex $place 0] in {older newer tail}} {
            set nextCursor [expr {$direction eq "older"
                ? [dict get $mamResult first] : [dict get $mamResult last]}]
            if {$nextCursor ne ""} {
                set rsmFlag [expr {$direction eq "older" ? "-before" : "-after"}]
                $client mam queryChat $chatJid -max $limit $rsmFlag $nextCursor \
                    -command [mymethod OnFetch $chatJid $before $after $limit \
                        $callback $onerror $tag $direction $wasBounded "" \
                        $place [expr {$page + 1}]]
                return
            }
        }

        # Terminal page (enough collected, archive exhausted, no cursor to
        # advance, or cancelled): finalise the queried-direction boundary.
        lassign $place how edge
        if {$complete} {
            # Nothing past the page's edge (or the cursor, for an empty
            # page) that way: the hole there was a false positive.
            if {$wasBounded && $how in {older newer} && $edge ne ""} {
                $messagestore hole removeGap $chatJid $how $edge
            }
            # Rows the archive no longer has (wiped, expired) were behind
            # that hole; return them rather than an empty page.
            set local [$self GetLocal $chatJid $before $after $limit]
        } elseif {$direction eq "older" && $lo ne ""} {
            $messagestore hole addBefore $chatJid $lo
        } elseif {$direction eq "newer" && $hi ne ""} {
            $messagestore hole addAfter $chatJid $hi
        }

        if {$cancelled} return
        {*}$callback [dict get $local messages]
    }

    tackymethod -noreturn cancel {args} {
        set tag [dict get $args -tag]
        unset -nocomplain ActiveTags($tag)
        foreach id [lsort -integer [array names TagPending]] {
            lassign $TagPending($id) t _ onerror
            if {$t ne $tag} continue
            unset TagPending($id)
            if {$onerror ne ""} { {*}$onerror cancelled }
        }
    }

    # Wraps a tagged request's callbacks so that it, or `cancel`, answers
    # once. An empty callback stays empty. ActiveTags($tag) counts the
    # tag's requests in flight, and goes with the last one's answer.
    method TagWrap {tag command onerror} {
        if {$command eq "" && $onerror eq ""} { return {{} {}} }
        set id [incr TagSeq]
        set TagPending($id) [list $tag $command $onerror]
        incr ActiveTags($tag)
        list [expr {$command eq "" ? "" : [mymethod TagSettle $id 1]}] \
             [expr {$onerror eq "" ? "" : [mymethod TagSettle $id 2]}]
    }

    method TagSettle {id which value} {
        if {![info exists TagPending($id)]} return
        set tag [lindex $TagPending($id) 0]
        set cb [lindex $TagPending($id) $which]
        unset TagPending($id)
        if {[info exists ActiveTags($tag)] && [incr ActiveTags($tag) -1] <= 0} {
            unset ActiveTags($tag)
        }
        {*}$cb $value
    }

    # goto -chat $jid -date $ts -source local|remote -limit 50
    #      ?-tag $tag? -command $cb
    # goto -chat $jid -id $id -limit 50 ?-tag $tag? -command $cb
    # Jump to a point in time, or to a stored message. Returns {messages
    # $list anchor $id}.
    #   local:  get around from local store
    #   remote: MAM fetch from -start $date, store, then get around
    tackymethod -async goto {args} {
        set defaults [dict create -source local -limit 50 -tag "" -onerror ""]
        set opts [dict merge $defaults $args]

        set chatJid  [dict get $opts -chat]
        set date     [dict getdef $opts -date ""]
        set source   [dict get $opts -source]
        set limit    [dict get $opts -limit]
        set tag      [dict get $opts -tag]
        set callback [dict get $opts -command]
        set onerror  [dict get $opts -onerror]

        if {$tag ne ""} {
            lassign [$self TagWrap $tag $callback $onerror] callback onerror
        }

        if {[dict exists $opts -id]} {
            {*}$callback [$messagestore around $chatJid [dict get $opts -id] $limit]
            return
        }
        if {$source eq "local"} {
            set result [$messagestore get around $chatJid $date $limit]
            {*}$callback $result
            return
        }

        # remote: fetch from server first, then get around
        $client mam queryChat $chatJid \
            -start [FormatTimestampISO $date] -max $limit \
            -command [mymethod OnGoto $chatJid $date $limit $callback $onerror \
                $tag]
    }

    method OnGoto {chatJid date limit callback onerror tag mamResult} {
        if {[dict exists $mamResult error]} {
            # Fall back to local
            if {$tag ne "" && ![info exists ActiveTags($tag)]} return
            set result [$messagestore get around $chatJid $date $limit]
            # Nothing local to land on either, so the jump did not happen.
            if {$onerror ne "" && [llength [dict get $result messages]] == 0} {
                set cond [expr {[dict exists $mamResult error_condition]
                    ? [dict get $mamResult error_condition] : ""}]
                {*}$onerror [$self ArchiveErrorText $cond]
                return
            }
            {*}$callback $result
            return
        }

        # The page is an island: placed by time, contiguous within itself
        # (CatchupPage sweeps it), unfetched on both edges - `-start $date`
        # covers nothing older, a short page leaves archive above.
        set got [$self CatchupPage $mamResult $chatJid \
            [dict create dir none tail 0]]
        set lo [dict getdef [dict get $got min] $chatJid ""]
        set hi [dict getdef [dict get $got max] $chatJid ""]
        if {$lo ne ""} { $messagestore hole addBefore $chatJid $lo }
        if {$hi ne "" && ![dict get $mamResult complete]} {
            $messagestore hole addAfter $chatJid $hi
        }

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set result [$messagestore get around $chatJid $date $limit]
        {*}$callback $result
    }

    # goto_reply -chat $jid -reply_id $rid ?-reply_to $jid? ?-limit 50?
    #           ?-tag $tag? -command $cb
    # Resolve an XEP-0461 reply target in the local store and jump to it
    # via `goto`. An uncached target yields an empty result; remote fetch
    # by stanza-id is not implemented.
    tackymethod -async goto_reply {args} {
        set defaults [dict create -limit 50 -tag "" -reply_to ""]
        set opts [dict merge $defaults $args]

        set chatJid  [dict get $opts -chat]
        set replyId  [dict get $opts -reply_id]
        set replyTo  [dict get $opts -reply_to]
        set limit    [dict get $opts -limit]
        set tag      [dict get $opts -tag]
        set callback [dict get $opts -command]

        set id [$messagestore resolveReply $chatJid $replyId $replyTo]
        if {$id eq ""} {
            {*}$callback [dict create messages {} anchor ""]
            return
        }
        if {$tag ne ""} {
            lassign [$self TagWrap $tag $callback ""] callback
        }
        {*}$callback [$messagestore around $chatJid $id $limit]
    }

    # search ?-chat $jid? -query "text" ?-source local|remote|both?
    #        ?-before $id | -before_archive $archiveId?
    #        ?-limit 20? ?-field $var? ?-tag $tag? -command $cb
    #
    # Omitting -chat searches every chat in the account. That is local-only -
    # MAM queries one archive - so it rejects a remote source rather than
    # quietly downgrading.
    #
    # Full text search. -source local (the default) matches already-stored
    # bodies, newest first, and pages with -before: the id of the last hit
    # had. It is the only source that sees OMEMO bodies, which reach the
    # store decrypted but sit on the server as ciphertext.
    # -source remote queries MAM and pages with -before_archive, the archive
    # id of the last hit had; new hits are stored to the local cache and
    # wrapped with holes on each side - a hit is an isolated island whose
    # surroundings we know nothing about, so future pagination across it must
    # fall through to MAM. A hit already cached is returned from the store as
    # it stands: its place is known, so it neither stores nor holes. An
    # archive advertising no fulltext field answers `unsupported` rather than
    # running the query without the term.
    # -source both runs the remote leg for its cache-filling effect and then
    # answers from the store, so one matching rule covers the whole result. It
    # falls back to the store alone when the archive can't run the search, and
    # pages locally: a -before cursor means the caller is walking a result set
    # already fetched, so it skips the remote leg.
    # Callback receives dict: messages, complete, last (the last hit's id,
    # local), last_archive (its archive id, remote)
    tackymethod -async search {args} {
        array set opts {-limit 20 -tag "" -field "" -source local -chat "" \
            -before "" -before_archive ""}
        array set opts $args

        set chatJid $opts(-chat)
        set source $opts(-source)
        if {$chatJid eq "" && $source ne "local"} {
            error "search: -source \"$source\" needs a -chat"
        }
        set callback $opts(-command)
        set onerror [expr {[info exists opts(-onerror)] ? $opts(-onerror) : ""}]
        set tag $opts(-tag)
        set query $opts(-query)
        set limit $opts(-limit)
        set before $opts(-before)
        set beforeArchive $opts(-before_archive)

        if {$source eq "remote" && $before ne ""} {
            error "search: -source \"remote\" pages with -before_archive"
        }
        if {$source ne "remote" && $beforeArchive ne ""} {
            error "search: -before_archive needs -source \"remote\""
        }
        if {$before ne "" && ![string is entier -strict $before]} {
            error "search: -before is a message id, got \"$before\""
        }

        if {$tag ne ""} {
            lassign [$self TagWrap $tag $callback $onerror] callback onerror
        }

        switch -exact -- $source {
            local {
                $self LocalSearch $chatJid $query $limit $before $callback
            }
            both {
                if {$before ne ""} {
                    $self LocalSearch $chatJid $query $limit $before $callback
                    return
                }
                $self MamSearch $chatJid $query $limit "" $opts(-field) \
                    [mymethod OnSearchBoth $chatJid $query $limit $tag $callback]
            }
            remote {
                $self MamSearch $chatJid $query $limit $beforeArchive \
                    $opts(-field) \
                    [mymethod OnSearch $chatJid $query $callback $onerror $tag]
            }
            default {
                error "search: unknown -source \"$source\""
            }
        }
    }

    method LocalSearch {chatJid query limit before callback} {
        set cursor ""
        if {$before ne ""} {
            set cursor [list [$client db onecolumn {
                SELECT timestamp FROM chat_message WHERE id=$before
            }] $before]
        }
        set rows [$messagestore search $chatJid $query -limit $limit -before $cursor]
        set complete [expr {[llength $rows] < $limit}]
        set last [expr {[llength $rows] ? [dict get [lindex $rows end] id] : ""}]
        {*}$callback [dict create messages [$self AnnotateMatches $rows $query] \
            complete $complete last $last last_archive ""]
    }

    # Say where each hit matched, so the caller highlights it instead of
    # running a second match of its own. Offsets index the rendered string, so
    # a match on text that isn't drawn - an attachment URL, a styling
    # delimiter, a stem the archive matched remotely - reports no range at all
    # rather than a wrong one.
    method AnnotateMatches {rows query} {
        lmap row $rows {
            if {[dict exists $row content]} {
                set content [dict get $row content]
                set shown [expr {[dict get $content type] eq "media"
                    ? "caption" : "body"}]
                dict set content matches \
                    [search_match_ranges [dict get $content $shown] $query]
                dict set row content $content
            }
            set row
        }
    }

    method MamSearch {chatJid query limit before field callback} {
        # An empty -before is RSM's "newest page" marker, not an absent cursor.
        set mamArgs [list -fulltext $query -max $limit -before $before]
        if {$field ne ""} {
            lappend mamArgs -field-var $field
        }
        lappend mamArgs -command $callback
        $client mam queryChat $chatJid {*}$mamArgs
    }

    # The remote page is ingested for what it adds to the store, never
    # reported: the answer is read back locally so one rule matched it all.
    method OnSearchBoth {chatJid query limit tag callback mamResult} {
        if {$tag ne "" && ![info exists ActiveTags($tag)]} return
        if {![dict exists $mamResult error]} {
            $self SearchIngest $chatJid $mamResult
        }
        $self LocalSearch $chatJid $query $limit "" $callback
    }

    method OnSearch {chatJid query callback onerror tag mamResult} {
        if {[dict exists $mamResult error]} {
            set cond [dict getdef $mamResult error_condition ""]
            if {$onerror ne ""} {
                {*}$onerror [expr {$cond eq "fulltext-unsupported"
                    ? "This server can't search its archive"
                    : [$self ArchiveErrorText $cond]}]
            }
            return
        }

        if {$tag ne "" && ![info exists ActiveTags($tag)]} return

        set messages [$self SearchIngest $chatJid $mamResult]

        {*}$callback [dict create \
            messages [$self AnnotateMatches $messages $query] \
            complete [dict get $mamResult complete] \
            last "" last_archive [dict get $mamResult last]]
    }

    method SearchIngest {chatJid mamResult} {
        set messages {}
        foreach resultNode [dict get $mamResult messages] {
            set r [$self ParseResultNode $resultNode $chatJid]
            set verdict [dict get $r verdict]
            if {[$self ApplyPatchVerdict $chatJid $r]} continue
            if {$verdict eq "confirmed"} {
                set rec [dict get $r reconciled]
                $self HandleConfirmation $chatJid [list $rec]
                lappend messages {*}[$messagestore get ids $chatJid \
                    [list [dict get $rec id]]]
                continue
            }
            if {$verdict eq "duplicate"} {
                lappend messages {*}[$messagestore get ids $chatJid \
                    [list [dict get $r stored_id]]]
                continue
            }
            if {$verdict ne "new"} continue
            set result [$messagestore store [list [dict get $r msg]]]
            set ins [dict get $result inserted]
            if {[llength $ins] > 0} {
                set pos [lindex [dict get $result positions] 0]
                $messagestore hole addBefore $chatJid $pos
                $messagestore hole addAfter $chatJid $pos
                lappend messages [lindex [$messagestore get ids $chatJid $ins] 0]
            }
        }
        return $messages
    }

    # MAM preamble: pull the envelope (archive id, server stamp, ids) off one
    # <result>/<forwarded> wrapper, then hand to the shared Classify core.
    # $accountArchive is 1 when the result came from our own archive, where
    # a room chat is routed by envelope (a relayed invite); otherwise a
    # room chat's result came from the room's archive.
    method ParseResultNode {resultNode chatJid {accountArchive 0}} {
        set serverId [xsearch $resultNode -get @id]
        set fwdNode [lindex [xsearch $resultNode forwarded -ns urn:xmpp:forward:0] 0]
        set ts [ParseTimestamp \
            [xsearch $fwdNode delay -ns urn:xmpp:delay -get @stamp]]
        if {$ts eq ""} {
            set ts [clock microseconds]
            set tsClock local
        } else {
            set tsClock server
            $messagestore noteArchiveTs $chatJid $ts
        }
        # A result this chat already holds under its archive id is a
        # duplicate before anything else is read: a reconnect gets the
        # archive's newest page again, and routing, id extraction and the
        # patch parsers cost as much for it as for a new message. A
        # tombstone comes back under the id of the message it retracted, so
        # it goes the whole way.
        set fwdMsg [lindex [xsearch $fwdNode message] 0]
        if {$serverId ne "" && ![IsTombstone $fwdMsg]} {
            set storedId [$messagestore archivedId $chatJid $serverId]
            if {$storedId ne ""} {
                return [dict create verdict duplicate timestamp $ts \
                    stored_id $storedId]
            }
        }
        set msgNode [$client ingressAddresses $fwdMsg]
        if {$msgNode eq ""} {
            jlog warn "MAM: skipping result with unroutable address" \
                -stanza $resultNode
            return [dict create verdict drop timestamp $ts]
        }
        # A room's archive speaks for the room and its occupants only. A
        # result from anyone else (a chat message "from" a contact, a
        # groupchat from another room) is the room service putting words
        # in their mouth: never filed, nor decrypted under their identity.
        if {!$accountArchive && [IsRoomChatJid $chatJid]} {
            set room [jid norm [string range $chatJid 0 end-5]]
            set from [xsearch $msgNode -get @from]
            if {![jid valid $from] || [jid norm [jid bare $from]] ne $room} {
                jlog warn "MAM: $room's archive holds a message from '$from'; dropped"
                return [dict create verdict drop timestamp $ts]
            }
        }
        # A message retracted or moderated after archiving comes back as a
        # tombstone under its archive id; it's the only notice a client that
        # was offline gets. The archive is the one we queried (mam checks the
        # sender), so it is trusted.
        if {$serverId ne "" && [IsTombstone $msgNode]} {
            return [dict create verdict tombstone timestamp $ts \
                target_id $serverId]
        }
        set idArgs [list -server_id $serverId]
        # The room's copy of a send of ours still pending (the last run's,
        # never echoed): it comes from the room, and without an occupant-id
        # nothing else names it ours, so it would be filed beside the
        # pending row, which the retry then sent again. Its origin-id (or
        # id) naming that pending row confirms it, as the room's echo does.
        if {!$accountArchive && [IsRoomChatJid $chatJid]} {
            set ownId [$self PendingOwnIdOf $chatJid $msgNode]
            if {$ownId ne ""} { lappend idArgs -own_id $ownId }
        }
        set ids [$self ExtractEnvelopeIds $msgNode $chatJid {*}$idArgs]
        # History, not live traffic (NickIsOurs).
        dict set msgNode archived 1
        return [$self Classify $chatJid $msgNode $ts $ids $tsClock]
    }

    # The own_id of the send of ours still pending in $chatJid that the
    # stanza's origin-id, or else its id, names; "" when it names none.
    method PendingOwnIdOf {chatJid msgNode} {
        foreach id [list \
                [xsearch $msgNode origin-id -ns urn:xmpp:sid:0 -get @id] \
                [xsearch $msgNode -get @id]] {
            if {$id eq ""} continue
            if {[$client db exists {
                SELECT 1 FROM chat_message
                WHERE chat_jid=$chatJid AND kind='message'
                  AND own_id != '' AND own_id=$id AND server_status='pending'
            }]} { return $id }
        }
        return ""
    }

    # The single ingestion core, shared by the live path (ingestLive) and
    # every MAM path (via ParseResultNode). Envelope-first: reconcile on the
    # ids BEFORE decrypting, so a known send is confirmed and a known citizen
    # flagged duplicate without a decrypt; only a genuinely new message is
    # decrypted and parsed. `ids` is the {serverId ownId originId} triple the
    # caller extracted (the sources differ in where each id comes from).
    # Returns one verdict; `timestamp` (server stamp) rides every verdict
    # so the MAM loops can reason over the true archive span:
    #   {verdict confirmed timestamp T reconciled V}  pending send echoed
    #   {verdict duplicate timestamp T stored_id I}   already a citizen, row I
    #   {verdict drop      timestamp T}               new but displayless
    #   {verdict new       timestamp T msg M}         new, store M
    #   {verdict reaction  timestamp T ...}           XEP-0444 reaction
    #   {verdict edit|retract timestamp T ...}        XEP-0308/0424/0425
    #   {verdict tombstone timestamp T target_id I}   (MAM only) archived
    #                                                 message I was retracted
    #   {verdict defer timestamp T kind K patch P}    edit/retract, target
    #                                                 not stored yet
    method Classify {chatJid msgNode ts ids clock} {
        # An error stanza reports a failed delivery; it is never content.
        # What it echoes back describes the original message, so storing any
        # of it files another author's text into this chat. Above the patch
        # branches: an echoed <reactions> or <replace> would otherwise
        # rewrite a message already stored.
        if {[xsearch $msgNode -get @type] eq "error"} {
            return [dict create verdict drop timestamp $ts]
        }
        # A room relaying a decline of our invite (live, muc claims it first;
        # from the archive it would become a 1:1 chat with the room).
        if {[llength [xsearch $msgNode x \
                -ns http://jabber.org/protocol/muc#user decline]] > 0} {
            return [dict create verdict drop timestamp $ts]
        }
        set reaction [$self ParseReaction $chatJid $msgNode]
        if {$reaction ne ""} {
            # `timestamp` keeps the reaction verdict uniform with the
            # others so a MAM page's floor counts it (CatchupPage); it's
            # also the LWW ts, on $clock.
            return [dict create verdict reaction timestamp $ts clock $clock \
                {*}$reaction]
        }
        # Corrections/retractions mutate an existing stored row, so - like
        # reactions - they short-circuit before reconcile/ParseMessage
        # (a <replace> carries a body and a <retract> may carry a fallback
        # body, either of which would otherwise store as a fresh message).
        # A correction or retraction whose target isn't stored yet is
        # deferred. An unauthorized retraction is dropped, as is a room
        # correction with no occupant-id; any other unauthorized correction
        # falls through and is stored as a separate message, without the
        # target's encryption status.
        set edit [$self ParseCorrection $chatJid $msgNode]
        if {$edit ne ""} {
            dict set edit ids [list [lindex $ids 0] [lindex $ids 2]]
            dict set edit clock $clock
            set v [$self PatchVerdict $chatJid edit $edit $ts]
            if {$v ne ""} { return $v }
        }
        set retract [$self ParseRetraction $chatJid $msgNode]
        if {$retract ne ""} {
            return [$self PatchVerdict $chatJid retract $retract $ts]
        }
        # XEP-0482 answers to a call invite patch that invite's row.
        foreach tag {accept reject retract left} {
            set node [xsearch $msgNode $tag -ns urn:xmpp:call-invites:0 -get node]
            if {$node eq ""} continue
            set id [xsearch $node -get @id]
            if {$id eq ""} { return [dict create verdict drop timestamp $ts] }
            return [dict create verdict call timestamp $ts tag $tag id $id \
                is_own [dict get [$self resolveSender $chatJid $msgNode] is_own]]
        }
        lassign $ids serverId ownId originId
        # Pass the echo's occupant-id so confirming our own send backfills it
        # (the original send stored occupant_id empty).
        set occ [xsearch $msgNode occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        set v [$messagestore reconcile $chatJid $serverId $ownId $originId $ts $occ]
        switch [dict get $v verdict] {
            confirmed {
                return [dict create verdict confirmed \
                    timestamp $ts reconciled $v]
            }
            duplicate {
                return [dict create verdict duplicate timestamp $ts \
                    stored_id [dict get $v stored_id]]
            }
            undecrypted {
                # Stored before with a placeholder: read it again, and put
                # the row right if it opens now. Either way it is no news.
                set storedId [dict get $v stored_id]
                $self Redecrypt $chatJid $msgNode $storedId $serverId $ownId $originId
                return [dict create verdict duplicate timestamp $ts \
                    stored_id $storedId]
            }
        }

        # decryptForwarded yields a synthesised plaintext stanza, or the
        # original on failure / when already plaintext (the live path is
        # decrypted upstream, so this is a no-op there); ParseMessage returns
        # "" for a displayless one.
        set msgNode [$client omemo decryptForwarded $msgNode]
        set msg [$self ParseMessage $msgNode \
            -chat_jid $chatJid -timestamp $ts \
            -server_id $serverId -own_id $ownId -origin_id $originId]
        if {$msg eq ""} {
            return [dict create verdict drop timestamp $ts]
        }
        return [dict create verdict new timestamp $ts msg $msg]
    }

    # Extract an XEP-0444 reaction from a <message> node into a descriptor,
    # or "" when the stanza carries no reactions. Resolves reactor identity
    # per chat kind: 1:1 uses the bare sender jid; MUC uses the XEP-0421
    # occupant-id (fail-closed - a groupchat reaction with no occupant-id
    # that isn't our own is dropped). Own-detection: bare jid in 1:1, nick
    # in a MUC (own reactions are keyed by nick, since we don't track our
    # own occupant-id). `emojis` is the reactor's full set ('' = retracted).
    method ParseReaction {chatJid msgNode} {
        set rxNode [lindex [xsearch $msgNode reactions -ns urn:xmpp:reactions:0] 0]
        if {$rxNode eq ""} { return "" }
        set targetId [xsearch $rxNode -get @id]
        if {$targetId eq ""} { return "" }
        set emojis [xsearch $rxNode reaction -gather body]
        set sender [$self resolveSender $chatJid $msgNode]
        set senderId [dict get $sender sender_id]
        set isOwn [dict get $sender is_own]
        # Fail-closed: a remote MUC reaction with no occupant-id has no
        # stable identity to attribute it to, so drop it.
        if {!$isOwn && $senderId eq ""} { return "" }
        if {[IsMucChatJid $chatJid]} {
            set senderLabel [jid resource [xsearch $msgNode -get @from]]
        } else {
            set senderLabel $senderId
        }
        return [dict create target_id $targetId sender_id $senderId \
            sender_label $senderLabel is_own $isOwn emojis $emojis]
    }

    # Resolve who sent a stanza into {sender_id is_own}. sender_id is the
    # stable identity to key/compare on: bare jid in 1:1, XEP-0421
    # occupant-id in a MUC. is_own carries the fail-open-to-nick policy, so
    # it is not derivable from sender_id alone (in a non-0421 room every
    # occupant-id is "", including ours). The display label is a per-feature
    # concern the caller attaches from the nick it already holds.
    method resolveSender {chatJid msgNode} {
        set rawFrom [xsearch $msgNode -get @from]
        if {![IsMucChatJid $chatJid]} {
            set bare [jid norm [jid bare $rawFrom]]
            return [dict create sender_id $bare \
                is_own [expr {$bare eq [jid bare [$client cget -jid]]}]]
        }
        regsub {\?join$} $chatJid {} roomJid
        set roomJid [jid bare $roomJid]
        set occ [xsearch $msgNode occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        set myOcc [$client muc my_occupant_id -jid $roomJid]
        set nick [jid resource $rawFrom]
        # Compare by occupant-id only when both ours and the stanza's are
        # known; otherwise fall back to nick equality.
        if {$occ ne "" && $myOcc ne ""} {
            set isOwn [expr {$occ eq $myOcc}]
        } else {
            set isOwn [expr {$nick eq [$client muc my_nick -jid $roomJid]
                && [$self NickIsOurs $chatJid $msgNode]}]
        }
        # Key on the occupant-id whenever the stanza carries one (stable, ours
        # and peers'); else our nick for our own row (fail-open); else "" -
        # a remote sender with no stable identity, which the caller drops.
        if {$occ ne ""} {
            set senderId $occ
        } elseif {$isOwn} {
            set senderId $nick
        } else {
            set senderId ""
        }
        return [dict create sender_id $senderId is_own $isOwn]
    }

    # Whether a room stanza from the nick we hold, with no occupant-id to go
    # by, is ours. Live it is: nicks are unique among those present. History
    # (a join replay with <delay/>, or the archive's, marked `archived`) may
    # be whoever held the nick before us, and is ours only when its
    # origin-id or id names a send of ours stored in the chat.
    method NickIsOurs {chatJid msgNode} {
        if {![dict exists $msgNode archived]
                && ![llength [xsearch $msgNode delay -ns urn:xmpp:delay]]} {
            return 1
        }
        foreach id [list \
                [xsearch $msgNode origin-id -ns urn:xmpp:sid:0 -get @id] \
                [xsearch $msgNode -get @id]] {
            if {$id ne "" && [$client db exists {
                    SELECT 1 FROM chat_message
                    WHERE chat_jid=$chatJid AND own_id != ''
                      AND own_id=$id}]} {
                return 1
            }
        }
        return 0
    }

    # The stored messages a correction or retraction may target, matched by
    # any of their wire ids (the id-triple) or an earlier correction's
    # (message_alias), oldest first. Several can match: origin-ids are the
    # sender's choice, so the caller picks by author. Each is a dict
    # {id occ from own enc fp by_server}, where own is whether it is our
    # own send (own_id set) and by_server whether a stanza-id matched.
    method TargetCandidates {chatJid targetId} {
        set out {}
        $client db eval {
            SELECT m.id AS id, m.occupant_id AS occ, m.from_jid AS fr,
                   m.own_id AS own, m.encryption AS enc, m.sender_fp AS fp,
                   (m.server_id = $targetId OR EXISTS (
                       SELECT 1 FROM message_alias a
                       WHERE a.chat_jid = m.chat_jid
                         AND a.target_id = m.id
                         AND a.kind = 'server' AND a.alias_id = $targetId))
                       AS by_server
            FROM chat_message m
            WHERE m.chat_jid=$chatJid AND m.kind='message'
              AND m.id IN (
                  -- One arm per id, each by its own partial index, which
                  -- an OR of the ids never took (messagestore
                  -- resolveTargetId).
                  SELECT id FROM chat_message
                  WHERE chat_jid=$chatJid
                    AND server_id != '' AND server_id=$targetId
                  UNION ALL
                  SELECT id FROM chat_message
                  WHERE chat_jid=$chatJid
                    AND origin_id != '' AND origin_id=$targetId
                  UNION ALL
                  SELECT id FROM chat_message
                  WHERE chat_jid=$chatJid AND own_id != '' AND own_id=$targetId
                  UNION ALL
                  SELECT target_id FROM message_alias
                  WHERE chat_jid=$chatJid AND alias_id=$targetId)
            ORDER BY +m.pos
        } row {
            lappend out [dict create id $row(id) occ $row(occ) \
                from $row(fr) own [expr {$row(own) ne ""}] \
                enc $row(enc) fp $row(fp) by_server $row(by_server)]
        }
        return $out
    }

    # True iff a stanza from $chatJid may correct/retract a stored target:
    # same occupant-id in a MUC, same bare jid in 1:1. `sender` is a
    # resolveSender dict for the incoming stanza. Also authorizes our own
    # correction of our own message via is_own - our sent messages may carry
    # no stored occupant_id yet (backfilled only when their echo confirms).
    method SameAuthor {chatJid sender targetOcc targetFrom targetOwn} {
        if {[dict get $sender is_own] && $targetOwn} { return 1 }
        if {[IsMucChatJid $chatJid]} {
            set sid [dict get $sender sender_id]
            return [expr {$sid ne "" && $sid eq $targetOcc}]
        }
        set from [jid bare [dict get $sender from]]
        return [jid equal $from [jid bare $targetFrom]]
    }

    # Extract an XEP-0308 correction into {target_id new_body encryption
    # sender_fp raw_xml sender}, or "" when the stanza carries none.
    # AuthorizeEdit decides whether it may apply. The body is read after
    # OMEMO decrypt (the <replace> hint itself is plaintext, but the
    # corrected body may be encrypted).
    method ParseCorrection {chatJid msgNode} {
        set rep [lindex [xsearch $msgNode replace \
            -ns urn:xmpp:message-correct:0] 0]
        if {$rep eq ""} { return "" }
        set targetId [xsearch $rep -get @id]
        if {$targetId eq ""} { return "" }
        set plainNode [$client omemo decryptForwarded $msgNode]
        # No <body> is no correction (a key transport, say); an empty one
        # corrects the message to empty.
        if {![HasBody $plainNode]} { return "" }
        set body [xsearch $plainNode body -get body]
        lassign [reply::parse $plainNode] replyId replyTo
        if {$replyId ne ""} {
            set body [ReplyBody $plainNode $body]
        }
        set sender [$self resolveSender $chatJid $msgNode]
        dict set sender from [xsearch $msgNode -get @from]
        set enc [expr {[dict exists $plainNode decrypted] ? "omemo" : ""}]
        set senderFp [expr {[dict exists $plainNode sender_fp] \
            ? [dict get $plainNode sender_fp] : ""}]
        return [dict create target_id $targetId new_body $body \
            encryption $enc sender_fp $senderFp \
            raw_xml [jwrite $plainNode] sender $sender]
    }

    # {ok ts} / missing / deny / ignore for a ParseCorrection result against
    # its stored target; ts is the target row's.
    method AuthorizeEdit {chatJid edit} {
        # In a room another occupant is known by occupant-id (XEP-0421) only.
        # A correction without one can't be tied to an author: drop it,
        # rather than store its text as a message of its own.
        set sender [dict get $edit sender]
        if {[IsRoomChatJid $chatJid] && ![dict get $sender is_own]
                && [dict get $sender sender_id] eq ""} {
            return ignore
        }
        set candidates [$self TargetCandidates $chatJid [dict get $edit target_id]]
        if {$candidates eq ""} { return missing }
        set target ""
        foreach c $candidates {
            if {[$self SameAuthor $chatJid $sender \
                    [dict get $c occ] [dict get $c from] [dict get $c own]]} {
                set target $c
                break
            }
        }
        if {$target eq ""} { return deny }
        set targetEnc [dict get $target enc]
        set targetFp [dict get $target fp]
        # Authorship is server-asserted, so the correction must also carry the
        # target's protection: no cleartext rewrite of an encrypted row, and
        # the same sender identity when the target names one. Otherwise the
        # server could swap an e2ee body and leave the padlock on it.
        if {$targetEnc eq "omemo" && [dict get $edit encryption] ne "omemo"} {
            return deny
        }
        if {$targetFp ne "" && [dict get $edit sender_fp] ne $targetFp} {
            return deny
        }
        return [list ok [dict get $target id]]
    }

    # Extract an XEP-0424/0425 retraction into {target_id from}, or "" when
    # the stanza carries none. AuthorizeRetract decides whether it may apply.
    method ParseRetraction {chatJid msgNode} {
        set targetId [RetractTargetId $msgNode]
        if {$targetId eq ""} { return "" }
        set sender [$self resolveSender $chatJid $msgNode]
        dict set sender from [xsearch $msgNode -get @from]
        return [dict create target_id $targetId \
            from [dict get $sender from] sender $sender]
    }

    # {ok ts} / missing / deny for a ParseRetraction result against its
    # stored target. In a MUC the room's moderated broadcast (from the bare
    # room jid, naming the room's stanza-id) is honored, and an occupant's
    # own retraction when its occupant-id is the author's; in 1:1 only the
    # original sender may self-retract.
    method AuthorizeRetract {chatJid retract} {
        set targetId [dict get $retract target_id]
        set candidates [$self TargetCandidates $chatJid $targetId]
        if {$candidates eq ""} { return missing }
        set rawFrom [dict get $retract from]
        foreach c $candidates {
            set targetFrom [dict get $c from]
            if {[IsRoomChatJid $chatJid]} {
                # Moderation comes from the room's bare jid. From an occupant
                # (room/nick) it is an XEP-0424 self-retraction, accepted only
                # with a matching occupant-id (XEP-0421), since nicks get
                # reused.
                if {[jid resource $rawFrom] eq ""} {
                    set ok [dict get $c by_server]
                } else {
                    set ok [$self SameAuthor $chatJid \
                        [dict get $retract sender] [dict get $c occ] \
                        $targetFrom [dict get $c own]]
                }
            } elseif {[IsMucChatJid $chatJid]} {
                # A private chat in a room: only its author, the occupant it
                # came from, may take a message back.
                set ok [expr {[jid norm $rawFrom] eq [jid norm $targetFrom]}]
            } else {
                set ok [jid equal [jid bare $rawFrom] [jid bare $targetFrom]]
            }
            if {$ok} { return [list ok [dict get $c id]] }
        }
        return deny
    }

    # The verdict for a parsed correction/retraction ($kind edit|retract):
    # applied when authorized, held for its target when that isn't stored
    # yet. Unauthorized: a retraction is dropped, and so is a room correction
    # with no occupant-id; any other correction returns "".
    method PatchVerdict {chatJid kind patch ts} {
        set auth [expr {$kind eq "edit"
            ? [$self AuthorizeEdit $chatJid $patch]
            : [$self AuthorizeRetract $chatJid $patch]}]
        switch [lindex $auth 0] {
            ok {
                return [dict create verdict $kind timestamp $ts {*}$patch \
                    target_row [lindex $auth 1]]
            }
            missing {
                return [dict create verdict defer timestamp $ts \
                    kind $kind patch $patch]
            }
        }
        if {$kind eq "edit" && $auth ne "ignore"} { return "" }
        return [dict create verdict drop timestamp $ts]
    }

    # A store just inserted the target of these deferred patches (from
    # messagestore -deferredcmd): authorize each against it now and apply.
    method ApplyDeferred {chatJid deferred} {
        foreach d $deferred {
            set v [$self PatchVerdict $chatJid [dict get $d kind] \
                [dict get $d patch] [dict get $d timestamp]]
            if {$v ne "" && [dict get $v verdict] ne "defer"} {
                $self ApplyPatchVerdict $chatJid $v
            }
        }
    }

    # Apply a `reaction` verdict to the store and, when the target
    # message is present locally, emit a <Reactions> refreshing its aggregated
    # reactions. Shared by the live and every MAM dispatch path.
    method ApplyReactionVerdict {chatJid verdict} {
        set target [$messagestore applyReaction $chatJid \
            [dict get $verdict target_id] [dict get $verdict sender_id] \
            [dict get $verdict sender_label] [dict get $verdict is_own] \
            [dict get $verdict emojis] [dict get $verdict timestamp] \
            [dict get $verdict clock]]
        if {$target eq ""} return
        $self EmitReactionPatch $chatJid $target
    }

    method EmitReactionPatch {chatJid target} {
        set agg [$messagestore reactionsForMessage $chatJid $target]
        $client emit message <Reactions> -jid $chatJid -id $target \
            -reactions $agg
    }

    # Apply an `edit`/`retract` verdict to the store and, when the target is
    # stored, <Edited> its full row so the GUI redraws (edited body/marker or
    # tombstone). Shared by the live and every MAM dispatch path.
    method ApplyEditVerdict {chatJid verdict} {
        set target [$messagestore applyEdit $chatJid \
            [dict get $verdict target_row] [dict get $verdict new_body] \
            [dict get $verdict raw_xml] [dict get $verdict timestamp] \
            [dict create encryption [dict get $verdict encryption] \
                sender_fp [dict get $verdict sender_fp]] \
            [dict getdef $verdict clock server]]
        if {$target ne ""} { $self EmitMessagePatch $chatJid $target }
        # The correction names the message from now on, whether or not its
        # body is the newest. After the edit, so a patch held for these
        # ids lands on top of it.
        if {[dict exists $verdict ids]} {
            $messagestore addAliases $chatJid [dict get $verdict target_row] \
                {*}[dict get $verdict ids]
        }
    }

    method ApplyRetractVerdict {chatJid verdict} {
        # A MAM tombstone names the archive id and needs no author check.
        if {[dict exists $verdict target_row]} {
            set target [dict get $verdict target_row]
        } else {
            set target [$messagestore resolveTargetId $chatJid \
                [dict get $verdict target_id]]
            if {$target eq ""} return
        }
        set target [$self Retract $chatJid $target]
        if {$target eq ""} return
        $self EmitRetracted $chatJid $target
    }

    # A message stored undecrypted (its row marked so) comes round again:
    # decrypt it once more, and if it opens, its row takes the text in place
    # and the GUI redraws it (<Edited>).
    method Redecrypt {chatJid msgNode storedId serverId ownId originId} {
        set node [$client omemo redecrypt $msgNode]
        set msg [$self ParseMessage $node -chat_jid $chatJid \
            -timestamp [$self RowStamp $chatJid $storedId] \
            -server_id $serverId -own_id $ownId -origin_id $originId]
        if {$msg eq "" || [dict get $msg undecrypted]} {
            # A fill reads the chain in order; what it cannot open even so
            # never will be, and stops asking for fills (undecrypted 2).
            if {$InFill} { $messagestore giveUpUndecrypted $chatJid $storedId }
            return
        }
        if {[$messagestore repairUndecrypted $chatJid $storedId $msg]} {
            $self EmitMessagePatch $chatJid $storedId
        }
    }

    # <Edited> carries a message's whole enriched row so the GUI redraws it
    # in place (edited body, the "(edited)" marker, an invite's state).
    # Reserved for content changes; send-status and upload transitions go
    # through <Status>, retractions through <Retracted>.
    method EmitMessagePatch {chatJid target} {
        set dbMsg [lindex [$messagestore get ids $chatJid [list $target]] 0]
        if {$dbMsg eq ""} return
        $client emit message <Edited> -jid $chatJid -message $dbMsg
    }

    # <Retracted> flips the shown entry to a tombstone. The row is kept
    # (retracted=1, no content), so only jid + id cross the wire; the GUI
    # already holds the header it needs to redraw the placeholder.
    method EmitRetracted {chatJid target} {
        $client emit message <Retracted> -jid $chatJid -id $target
    }

    # {serverId ownId originId} off a <message>, derived once for the dedup
    # check and the parser. Callers override -server_id (MAM <result @id>)
    # and -own_id (live carbon). Otherwise server_id from <stanza-id>;
    # origin_id from <origin-id>, else @id; own_id from @id when the stanza
    # is from our own bare JID (it equals the own_id we stored on send, so
    # the row confirms rather than duplicates).
    method ExtractEnvelopeIds {msgNode chatJid args} {
        if {[dict exists $args -server_id]} {
            set serverId [dict get $args -server_id]
        } else {
            set serverId [$self ArchiveStanzaId $msgNode $chatJid]
        }
        set originId [xsearch $msgNode origin-id -ns urn:xmpp:sid:0 -get @id]
        if {$originId eq ""} {
            set originId [xsearch $msgNode -get @id]
        }
        if {[dict exists $args -own_id]} {
            set ownId [dict get $args -own_id]
        } else {
            set rawFrom [xsearch $msgNode -get @from]
            if {$rawFrom ne "" && [jid equal [jid bare $rawFrom] [jid bare [$client cget -jid]]]} {
                set ownId [xsearch $msgNode -get @id]
            } elseif {[IsRoomChatJid $chatJid] && [$self IsOwnByOccupant $chatJid $msgNode]} {
                # Our own message from the room archive. It comes from
                # room/nick, so match on occupant-id: the nick may have
                # belonged to someone else when the message was sent.
                set ownId $originId
            } else {
                set ownId ""
            }
        }
        return [list $serverId $ownId $originId]
    }

    # Whether a room message carries our own occupant-id (XEP-0421). Fails
    # closed: either id unknown is not ours.
    method IsOwnByOccupant {chatJid msgNode} {
        regsub {\?join$} $chatJid {} roomJid
        set occ [xsearch $msgNode occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        set myOcc [$client muc my_occupant_id -jid [jid bare $roomJid]]
        expr {$occ ne "" && $occ eq $myOcc}
    }

    # The <stanza-id> of the archive this message lives in: the room's for
    # groupchat, our own account's otherwise (MUC PMs, and invites a room
    # relays to us). A server only strips stanza-ids claiming to be
    # itself (XEP-0359 3), so a foreign `by` is peer-supplied: honouring one
    # lets a peer replay a past archive id and have the genuine message
    # dropped as a duplicate.
    method ArchiveStanzaId {msgNode chatJid} {
        if {[regexp {(.*)\?join$} $chatJid -> roomJid]
                && [xsearch $msgNode -get @type] eq "groupchat"} {
            set owner $roomJid
        } else {
            set owner [$client cget -jid]
        }
        foreach node [xsearch $msgNode stanza-id -ns urn:xmpp:sid:0] {
            set by [xsearch $node -get @by]
            if {$by ne "" && [jid matches-bare $by $owner]} {
                return [xsearch $node -get @id]
            }
        }
        return ""
    }

    # Build a message dict from a (decrypted) <message> node. Caller
    # supplies -chat_jid, -timestamp and the envelope ids
    # (-server_id/-own_id/-origin_id) from ExtractEnvelopeIds. Returns ""
    # for a displayless stanza (control type or bodyless payload).
    method ParseMessage {msgNode args} {
        set chatJid [dict get $args -chat_jid]
        lassign [reply::parse $msgNode] replyId replyTo
        set body [xsearch $msgNode body -get body]
        if {$replyId ne ""} {
            set body [ReplyBody $msgNode $body]
        }
        set ownId [expr {[dict exists $args -own_id] \
            ? [dict get $args -own_id] : ""}]
        set rawFrom [xsearch $msgNode -get @from]
        set invite [ParseInvite $msgNode]
        # A bodyless invite still gets shown. (A relayed one also counts as
        # a mention below: rooms only alert on mentions.)
        if {$invite ne "" && $body eq ""} {
            set body [InviteBody $invite $ownId]
        }
        # A group call invite shows as the call. Our own (room echo or
        # carbon) is a call we are in, not one to answer.
        set call [ParseCallInvite $msgNode]
        set callOwn 0
        if {$call ne ""} {
            set callOwn [expr {$ownId ne ""
                || [dict get [$self resolveSender $chatJid $msgNode] is_own]}]
            dict set call inviter [$self CallInviter $chatJid $rawFrom]
            if {$body eq ""} { set body [CallBody $call $callOwn] }
        }
        if {[ClassifyMessage $msgNode $body] ne "message"} {
            return ""
        }
        set fromJid [NormalizeAuthorJid $chatJid $rawFrom]
        set fromRes [SplitFromResource $chatJid $rawFrom]
        # Drives the lock on peer messages, so it tracks what we actually
        # decrypted. The EME marker (XEP-0380) is a cleartext hint anyone can
        # attach to an unencrypted body, so it must not be read here.
        set enc [expr {[dict exists $msgNode decrypted] ? "omemo" : ""}]
        set undecrypted [expr {[dict exists $msgNode undecrypted] ? 1 : 0}]
        set senderFp [expr {[dict exists $msgNode sender_fp] \
            ? [dict get $msgNode sender_fp] : ""}]
        set originId [expr {[dict exists $args -origin_id] \
            ? [dict get $args -origin_id] : ""}]
        dict create \
            timestamp  [dict get $args -timestamp] \
            chat_jid   $chatJid \
            from_jid   $fromJid \
            from_resource $fromRes \
            body       $body \
            server_id  [dict get $args -server_id] \
            own_id     $ownId \
            origin_id  $originId \
            occupant_id [xsearch $msgNode occupant-id \
                -ns urn:xmpp:occupant-id:0 -get @id] \
            reply_id   $replyId \
            reply_to   $replyTo \
            raw_xml    [jwrite $msgNode] \
            attachments [ExtractAttachments $msgNode $body] \
            invite     $invite \
            invite_room [expr {$invite eq "" ? "" : [dict get $invite room]}] \
            call       $call \
            call_state [expr {$callOwn ? "joined" : ""}] \
            server_status "" \
            encryption $enc \
            sender_fp  $senderFp \
            undecrypted $undecrypted \
            mentions_me [expr {($invite ne "" && $ownId eq ""
                || $call ne "" && !$callOwn)
                && [IsMucChatJid $chatJid] ? 1
                : [$self MentionsMe $chatJid $body $ownId \
                    [jid resource $rawFrom]]}]
    }

    # Who sent a call invite, as a bare JID: the contact in a 1:1 chat, the
    # occupant's real JID in a room when it shows, else "".
    method CallInviter {chatJid rawFrom} {
        if {![IsMucChatJid $chatJid]} {
            return [expr {[jid valid $rawFrom] ? [jid norm [jid bare $rawFrom]] : ""}]
        }
        set room [jid bare [regsub {\?join$} $chatJid {}]]
        set real [$client muc realJid $room [jid resource $rawFrom]]
        return [expr {$real eq "" ? "" : [jid norm [jid bare $real]]}]
    }

    # Does this room message name our nick? Word-boundary and caseless.
    # Rooms only - a 1:1 message has nothing to mention - and nothing we
    # said counts, whether it echoed back with our id or under our nick.
    method MentionsMe {chatJid body ownId senderNick} {
        if {$ownId ne "" || $body eq ""} { return 0 }
        if {![string match {*\?join} $chatJid]} { return 0 }
        set nick [$client muc my_nick -jid [regsub {\?join$} $chatJid {}]]
        if {$nick eq "" || $senderNick eq $nick} { return 0 }
        set quoted [regsub -all {\W} $nick {\\&}]
        return [regexp -nocase -- "\\y$quoted\\y" $body]
    }
}

# A <body> is a "message", an empty one too: the sender sent a message,
# and the recipient learns it came. A stanza with no text is a control type
# (receipt/marker/chatstate/reaction) when it carries one, even beside an
# empty <body/>; with neither it is "" (e.g. a decrypted keytransport).
# Only "message" is stored; the rest are dropped. $body is the text to show,
# which may stand in for a missing <body> (an invite's, a call's).
proc ClassifyMessage {msgNode body} {
    if {$body ne ""} { return message }
    foreach {kind ns} {
        receipt   urn:xmpp:receipts
        marker    urn:xmpp:chat-markers:0
        chatstate http://jabber.org/protocol/chatstates
        reaction  urn:xmpp:reactions:0
    } {
        if {[llength [xsearch $msgNode * -ns $ns]] > 0} { return $kind }
    }
    if {[HasBody $msgNode]} { return message }
    return ""
}

# Whether a <message> carries a <body> element, empty or not.
proc HasBody {msgNode} {
    expr {[llength [xsearch $msgNode body]] > 0}
}

# A reply's body with its quoted fallback dropped. A quote that would leave
# nothing is the sender's span gone wrong, not a reply with no words: the
# body is kept whole rather than lose the message.
proc ReplyBody {msgNode body} {
    set stripped [reply::strip_fallback $msgNode $body]
    if {[string trim $stripped] eq "" && $body ne ""} { return $body }
    return $stripped
}

# Derive the attachment list for an incoming <message>. An attachment is
# signalled by an XEP-0066 Out-of-Band <x><url/></x> child (what
# Conversations/Dino/Gajim send for XEP-0363 shares). A plaintext body that
# merely *is* a URL is just a link, not an attachment, so it is left as text.
#
# XEP-0454 (OMEMO media) is the exception: the encrypted share has no OOB (the
# aesgcm:// URL carries the key and so lives only in the OMEMO body), so a body
# that is itself an aesgcm:// URL is recognised as the attachment.
# Returns a (possibly empty) Tcl list of attachment dicts.
proc ExtractAttachments {msgNode body} {
    set atts {}
    xsearch $msgNode x -ns jabber:x:oob url -script u {
        set url [dict get $u body]
        if {[is_remote_attachment_url $url]} {
            lappend atts [attachment_dict $url]
        }
    }
    if {[llength $atts] == 0 && [is_aesgcm_url [string trim $body]]} {
        lappend atts [attachment_dict [string trim $body]]
    }
    return $atts
}

# A room invitation in a <message>, as {room inviter reason password}, or "".
#   mediated - relayed by the room: <x muc#user><invite from=.../>
#   direct   - XEP-0249 <x jabber:x:conference jid=.../> from the inviter
# A relayed invite often carries both; mediated wins, as the direct one's
# sender is the room. `inviter` is a bare JID, or "".
proc ParseInvite {msgNode} {
    set mucX [lindex [xsearch $msgNode x -ns http://jabber.org/protocol/muc#user] 0]
    set inviteNode [expr {$mucX eq "" ? "" : [lindex [xsearch $mucX invite] 0]}]
    if {$inviteNode ne ""} {
        set room [xsearch $msgNode -get @from]
        set inviter [xsearch $inviteNode -get @from]
        set reason [xsearch $inviteNode reason -get body]
        set password [xsearch $mucX password -get body]
    } else {
        set confX [lindex [xsearch $msgNode x -ns jabber:x:conference] 0]
        if {$confX eq ""} { return "" }
        set room [xsearch $confX -get @jid]
        set inviter [xsearch $msgNode -get @from]
        set reason [xsearch $confX -get @reason]
        set password [xsearch $confX -get @password]
    }
    if {![jid valid $room]} { return "" }
    set inviter [expr {[jid valid $inviter] ? [jid norm [jid bare $inviter]] : ""}]
    dict create room [jid norm [jid bare $room]] inviter $inviter \
        reason $reason password $password
}

# An XEP-0482 invite to a Muji call, as {room id video}, or "". A direct
# Jingle invite is a 1:1 call's, not ours.
proc ParseCallInvite {msgNode} {
    set inv [lindex [xsearch $msgNode invite -ns urn:xmpp:call-invites:0] 0]
    if {$inv eq ""} { return "" }
    set room [xsearch $inv muji -ns urn:xmpp:jingle:muji:0 -get @room]
    if {$room eq "" || ![jid valid $room]} { return "" }
    dict create room [jid norm [jid bare $room]] id [xsearch $inv -get @id] \
        video [expr {[xsearch $inv -get @video] in {true 1}}]
}

proc CallBody {call own} {
    set what [expr {[dict get $call video] ? "video call" : "call"}]
    return [expr {$own ? "You started a group $what" : "Group $what"}]
}

# Stand-in body for a bodyless invite, worded like server-relayed ones.
proc InviteBody {invite ownId} {
    set room [dict get $invite room]
    set inviter [dict get $invite inviter]
    if {$ownId ne "" || $inviter eq ""} {
        return "Invitation to the room $room"
    }
    return "$inviter invites you to the room $room"
}

# A received attachment has no `path`: only our own send sets one.
proc attachment_dict {url} {
    dict create url $url path "" type [attachment_kind $url] \
        name [attachment_display_name $url] size "" mime ""
}

# Display text for a message with attachments: the body, emptied when it is
# just the (OOB-duplicated) attachment URL, kept when it carries real text.
proc attachment_caption {body attachments} {
    set trimmed [string trim $body]
    foreach att $attachments {
        if {$trimmed eq [dict get $att url]} { return "" }
    }
    return $body
}

# Character ranges where $query matched $text, as a flat {offset length ...}
# list - the styling entities' offset convention, into the string they index.
# Mirrors the store's match: each query word against the start of a body word,
# folded as unicode61 folds. Diacritics are the one thing it can't follow, so
# a hit found only through those is marked nowhere rather than wrongly.
proc search_match_ranges {text query} {
    if {$text eq ""} { return {} }
    set haystack [string tolower $text]
    set ranges {}
    foreach word [search_query_words $query] {
        set needle [string tolower $word]
        set len [string length $needle]
        set pos 0
        while {[set at [string first $needle $haystack $pos]] >= 0} {
            set before [string index $haystack [expr {$at - 1}]]
            if {$at == 0 || ![string is alnum -strict $before]} {
                lappend ranges [list $at $len]
            }
            set pos [expr {$at + 1}]
        }
    }
    # Repeated or prefix-overlapping query words can land on one spot.
    return [concat {*}[lsort -integer -index 0 [lsort -unique $ranges]]]
}

# Single-element attachment list for an outgoing send. `url` is empty until the
# upload completes; `path` is always the local file (drives name/size/mime).
proc OutgoingAttachment {url path} {
    list [dict create url $url path $path type [attachment_kind $path] \
        name [file tail $path] \
        size [expr {[file isfile $path] ? [file size $path] : ""}] \
        mime [attachment_mime $path]]
}

# Author identity within a chat: full `room/nick` for MUC chats (resource
# is the participant's stable nick), bare JID for 1:1 (resource is an
# ephemeral client tag with no identity meaning). chat_jid shapes:
# `room@muc?join` (groupchat) and `room@muc/nick` (PM) are MUC; anything
# else is 1:1.
proc NormalizeAuthorJid {chatJid fromJid} {
    if {[IsMucChatJid $chatJid]} {
        return $fromJid
    }
    return [jid bare $fromJid]
}

# Resource component for 1:1 senders (the ephemeral client tag — useful
# for debug / per-resource features). Empty for MUC, where the resource
# is the nick and lives in from_jid.
proc SplitFromResource {chatJid fromJid} {
    if {[IsMucChatJid $chatJid]} {
        return ""
    }
    return [jid resource $fromJid]
}

proc IsMucChatJid {chatJid} {
    expr {[string match {*\?join} $chatJid] || [string match */* $chatJid]}
}

# The room's own chat, not a private one with an occupant (room@muc/nick).
# Ids, moderation and retraction go by this: in a private chat the partner
# never saw the room's stanza-id, and its author may retract.
proc IsRoomChatJid {chatJid} {
    string match {*\?join} $chatJid
}

# The id a retraction targets, or "" when the message carries none:
# XEP-0424 <retract id>, or the older form inside an XEP-0422 <apply-to id>
# that rooms on pre-1.0 moderation (XEP-0425 v0) still broadcast:
# <retract/> (urn:xmpp:message-retract:0) directly or under <moderated/>.
proc RetractTargetId {msgNode} {
    set id [xsearch $msgNode retract -ns urn:xmpp:message-retract:1 -get @id]
    if {$id ne ""} { return $id }
    foreach a [xsearch $msgNode apply-to -ns urn:xmpp:fasten:0] {
        set inner [list $a {*}[xsearch $a moderated \
            -ns urn:xmpp:message-moderate:0]]
        foreach n $inner {
            if {[llength [xsearch $n retract \
                    -ns urn:xmpp:message-retract:0]]} {
                return [xsearch $a -get @id]
            }
        }
    }
    return ""
}

# Whether an archived message is a tombstone, the placeholder an archive
# keeps for a retracted or moderated message (XEP-0424 / XEP-0425, current
# and v0 forms).
proc IsTombstone {msgNode} {
    foreach ns {urn:xmpp:message-retract:1 urn:xmpp:message-retract:0} {
        if {[llength [xsearch $msgNode retracted -ns $ns]]} { return 1 }
    }
    foreach m [xsearch $msgNode moderated -ns urn:xmpp:message-moderate:0] {
        if {[llength [xsearch $m retracted -ns urn:xmpp:message-retract:0]]} {
            return 1
        }
    }
    return 0
}
