# Group calls: XEP-0272 Muji with XEP-0482 call invites. Participants
# announce the call in their MUC presence and each pair holds one Jingle
# session, a mesh (see calls.tcl "Group-call sessions").
# This module picks the room, who calls whom and when, and the payloads.
#
# A call is a room; its JID is the call's -jid. Two kinds:
#
#   hosted   a room made for the call, as Dino does: members-only, real
#            JIDs shown, joined hidden under a random nick per device (a
#            shared nick would show one device's presence for all), and
#            announced by an invite posted to the chat it was started from.
#   in-room  held in the group chat itself under our nick, as Movim does.
#            We join these but never start one.
#
# tacky groupcall start        -acc $jid -chat $chat ?-video 0|1?
#   ;# a hosted call for $chat (a group chat, bare or ?join, or a contact):
#   ;# <Started> once its room is up, then as join; <StartFailed> if no room
#   ;# could be made. If the chat's newest call's room still exists
#   ;# (disco#info), that call is joined instead (join -chat -timestamp).
# tacky groupcall join         -acc $jid -jid $room ?-video 0|1? ?-chat $chat? ?-id $inviteId?
#   ;# a room we are in: its in-room call. Any other: a hosted call's room,
#   ;# entered hidden; -chat and -id (from the invite) let the chat know.
# tacky groupcall join         -acc $jid -chat $chat -timestamp $ts ?-video 0|1?
#   ;# answer the call invite stored at $ts in $chat (content type "call")
# tacky groupcall decline      -acc $jid -chat $chat -timestamp $ts
# tacky groupcall inCall       -acc $jid -jid $room      ;# -> bool
# tacky groupcall leave        -acc $jid -jid $room
# tacky groupcall setVideo     -acc $jid -jid $room -on 0|1   ;# camera mute, every session
# tacky groupcall invite       -acc $jid -jid $room -to $bareJid
# tacky groupcall list         -acc $jid
#   ;# -> one dict per room we are in a call in: jid chat hosted count video mode
#   ;#    preview (the self-view's channel, {name $n} or {id $i}; {} if none)
#   ;#    sessions (peer real JID -> sid)
#
# Participants are MUC occupants. Each carries `call`, parsed from their
# <muji> presence: "" when not in the call, else {state preparing|announced
# audio 0|1 video 0|1 contents {media -> payload list}}. Track them with muc
# occupants and muc <Presence>/<Unavailable>/<NickChanged>; count is the
# occupants announced.
#
# tacky listen groupcall <Started>    $cmd ;# -jid $room -chat $chat
# tacky listen groupcall <StartFailed> $cmd ;# -chat $chat -reason $t
# tacky listen groupcall <Joined>     $cmd ;# -jid $room ?-chat $chat?
# tacky listen groupcall <Session>    $cmd ;# -jid $room -peer $fullJid -sid $sid -video $b
# tacky listen groupcall <Left>       $cmd ;# -jid $room -reason $t ?-chat $chat?
# tacky listen groupcall <Invited>    $cmd ;# -jid $room -from $bareJid -chat $chat -timestamp $ts -video $b
# tacky listen groupcall <Warning>    $cmd ;# -jid $room -reason $t
# tacky listen groupcall <VideoPreview> $cmd ;# -jid $room ?-chat $chat? ?-name $n? ?-id $i?
#
# <Session>: our session with -peer (an occupant's real JID) is now -sid,
# replacing any earlier one for that peer. Its media state comes from the
# calls events for that sid. A session ending does not mean the peer left.
#
# <VideoPreview> is our self-view for the whole video call, on a camera the
# backend shares with every session (the `preview` media capability), so it runs
# while we are alone and outlives any peer. Without that capability the
# sessions' own <VideoPreview> is the self-view.
#
# join sends <muji><preparing/></muji>, waits for the echo, then waits up to
# PREPARE_TIMEOUT_MS for occupants that were preparing at that point. It
# then announces the agreed payload types and calls everyone already
# announced (XEP-0272 §3: the joiner initiates).
#
# "Already announced" follows the room's presence order, which every
# occupant sees the same: we call anyone whose contents arrive before the
# echo of ours and expect a call from anyone after. If both sides initiate
# anyway, calls keeps the lower sid (XEP-0166 §7.2.16) and AcceptSession
# -replaces swaps it in.
#
# leave clears the presence before terminating (§4).
#
# Participants are keyed by real JID: sessions go there (XEP-0272 v0.2) and
# nicks change. An occupant whose JID the room hides gets a <Warning>, no
# session, and is not waited for. Codec changes after we announced
# re-announce; live sessions keep what they negotiated.
#
# Per-room state (Rooms($room) dict, only while we are in the call):
#   state    : preparing|announced
#   video    : 1 if we offer video
#   mode     : mesh
#   payloads : media -> list of {id name clockrate ?channels?} we announced
#   sessions : real JID -> {sid video}; sid "" before it exists or after it ends
#   timer    : pending after id or "": the echo wait, then the prepare wait
#   echoed   : 1 once the room has echoed our <preparing/>
#   waitfor  : real JIDs preparing when our <preparing/> echoed
#   placed   : 1 once the room has echoed our contents
#   warned   : nicks already warned about a hidden JID
#   preview  : the media preview we hold for the self-view, "" when none
#   view     : its channel, {name $n} or {id $i}, {} until it is up
#
# Calls($room) is a hosted call we are entering or in:
#   chat     : the chat it belongs to, "" when unknown
#   id       : the XEP-0482 invite id our accept/left/retract refer to
#   ours     : 1 if we started it
#   met      : 1 once anyone else was in it (leaving then says <left>,
#              not <retract>)
#   admitted : bare JIDs we made members of its room

snit::type taco_groupcall {
    option -client -readonly yes

    typevariable NS         urn:xmpp:jingle:muji:0
    typevariable NS_JINGLE  urn:xmpp:jingle:1
    typevariable NS_RTP     urn:xmpp:jingle:apps:rtp:1
    typevariable NS_INVITES urn:xmpp:call-invites:0

    # A participant stuck in <preparing/> holds the room's join up; past
    # this we announce without them.
    typevariable PREPARE_TIMEOUT_MS 5000

    # Our <preparing/> should echo straight back. If another session of ours
    # holds the nick, the room shows its presence instead; past this we give up.
    typevariable ECHO_TIMEOUT_MS 10000

    # How long a room's disco#info is waited for (AskRoom), and how often
    # in a row one that went unanswered is asked again. ejabberd can leave
    # one unanswered while the last occupant's leave tears the room down.
    typevariable ASK_TIMEOUT_MS 5000
    typevariable ASK_RETRIES 2

    # A hosted call's room: only those let in may enter (so a room name is
    # no key), everyone's real JID shows (sessions go to them), and it is
    # gone once empty. Fields a service lacks are simply not set.
    typevariable ROOM_CONFIG {
        muc#roomconfig_membersonly    1
        muc#roomconfig_whois          anyone
        muc#roomconfig_persistentroom 0
        muc#roomconfig_publicroom     0
        muc#roomconfig_allowinvites   1
    }

    variable client
    variable Rooms -array {}
    variable Calls -array {}
    # See "Whether a hosted call is still going".
    variable Live -array {}
    variable Asking -array {}
    variable Gen -array {}

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client muc addOccupantField call [mymethod ParseMuji]
        $client bus subscribe $self calls:<Ended>     [mymethod OnSessionEnded ended]
        $client bus subscribe $self calls:<Failed>    [mymethod OnSessionEnded failed]
        $client bus subscribe $self muc:<Presence>    [mymethod OnMucPresence]
        $client bus subscribe $self muc:<Unavailable> [mymethod OnOccupantGone]
        $client bus subscribe $self muc:<Left>        [mymethod OnRoomLeft]
        $client bus subscribe $self muc:<Destroyed>   [mymethod OnRoomLeft]
        $client bus subscribe $self <SessionEnd>      [mymethod OnDisconnect]
        $client caps addFeature $NS
        $client caps addFeature $NS_INVITES
    }

    destructor {
        catch {$client bus unsubscribe $self}
        foreach room [array names Rooms] {
            after cancel [dict get $Rooms($room) timer]
        }
    }

    # =========================================================================
    # Public API
    # =========================================================================

    tackymethod start {args} {
        array set opts {-chat "" -video 0}
        array set opts $args
        if {$opts(-chat) eq ""} { error "start: -chat required" }
        set chat [jid norm [regsub {\?join$} $opts(-chat) {}]]
        set video [expr {$opts(-video) ? 1 : 0}]
        set spec [dict create chat $chat video $video \
            id [$self RandomHex 16] nick [$self RandomHex 4]]
        # Offline, the room would wait on a stream that may be a while coming.
        if {![$client iq isLive]} {
            after idle [mymethod StartFailed $spec "not connected"]
            return
        }
        # One call per chat at a time: if the chat's newest call's room is
        # still there, someone is in it, and starting means joining it.
        foreach stored [list $chat?join $chat] {
            set newest [$client message messagestore newestCall $stored]
            if {$newest eq ""} continue
            lassign $newest ts room
            $self AskRoom $room [mymethod StartAsked $spec $stored $ts]
            return
        }
        $self Create $spec
        return
    }

    tackymethod join {args} {
        array set opts {-jid "" -video 0 -chat "" -id "" -timestamp ""}
        array set opts $args
        # An invite stored as a message: its call, and the chat to tell.
        if {$opts(-timestamp) ne ""} {
            set at [$client message messagestore callAt $opts(-chat) $opts(-timestamp)]
            if {$at eq ""} { error "join: no call invite at $opts(-timestamp) in $opts(-chat)" }
            set opts(-jid) [dict get $at call room]
            set opts(-id) [dict get $at call id]
        }
        if {$opts(-jid) eq ""} { error "join: -jid required" }
        set room [jid norm $opts(-jid)]
        set video [expr {$opts(-video) ? 1 : 0}]
        if {[info exists Rooms($room)] || [info exists Calls($room)]} return
        if {[$client muc isJoined -jid $room]} {
            $client message SettleCall $room joined
            $self BeginJoin $room $video
            return
        }
        # A hosted call's room is never one of our group chats: anyone who
        # can post an invite may name one, and entering it hidden would
        # drop its messages and leave it with the call.
        if {([$client muc isTracked -jid $room] && ![$client muc isHidden -jid $room])
                || [$client muc isKnownRoom -jid $room]} {
            error "join: $room is one of your group chats, not a call's room"
        }
        # A hosted call: its room, under a nick no other device of ours has.
        set chat [expr {$opts(-chat) eq "" ? ""
                        : [jid norm [regsub {\?join$} $opts(-chat) {}]]}]
        if {![$client iq isLive]} {
            after idle [list $client emit groupcall <Left> -jid $room \
                -reason "not connected" {*}[expr {$chat eq "" ? {} : [list -chat $chat]}]]
            return
        }
        set Calls($room) [dict create chat $chat id $opts(-id) ours 0 \
            met 0 admitted {}]
        $client muc join -jid $room -nick [$self RandomHex 4] -hidden 1 \
            -history {maxstanzas 0} -command [mymethod OnHostedJoined $room $video]
        return
    }

    # Turn down a stored call invite: the chat hears <reject>, the row says
    # declined. Nothing for a call we are in, or one already answered.
    tackymethod decline {args} {
        array set opts {-chat "" -timestamp ""}
        array set opts $args
        set at [$client message messagestore callAt $opts(-chat) $opts(-timestamp)]
        if {$at eq "" || [dict get $at state] ne ""} return
        $client message messagestore setCallState $opts(-chat) $opts(-timestamp) declined
        $client message EmitMessagePatch $opts(-chat) $opts(-timestamp)
        set chat [jid norm [regsub {\?join$} $opts(-chat) {}]]
        set id [dict get $at call id]
        if {$id ne ""} { $self SendToChat $chat [j reject -ns $NS_INVITES -id $id] }
        return
    }

    tackymethod inCall {args} {
        array set opts {-jid ""}
        array set opts $args
        info exists Rooms([jid norm $opts(-jid)])
    }

    tackymethod leave {args} {
        array set opts {-jid ""}
        array set opts $args
        set room [jid norm $opts(-jid)]
        if {![info exists Rooms($room)]} {
            # Still entering a hosted call's room: stop there.
            if {[info exists Calls($room)]} {
                $client emit groupcall <Left> -jid $room -reason "left" \
                    {*}[$self ChatArgs $room]
                unset Calls($room)
                if {[$client muc isJoined -jid $room]} { $client muc leave -jid $room }
            }
            return
        }
        # XEP-0272 §4: the muji-less presence goes first, so nobody joining
        # right now initiates to a session that is being torn down.
        $client muc sendPresence $room {}
        $self Farewell $room
        $self Leave $room "left"
        return
    }

    tackymethod setVideo {args} {
        array set opts {-jid "" -on 1}
        array set opts $args
        set room [jid norm $opts(-jid)]
        if {![info exists Rooms($room)]} return
        dict for {real session} [dict get $Rooms($room) sessions] {
            if {[dict get $session sid] eq ""} continue
            $client calls setVideo -sid [dict get $session sid] -on $opts(-on)
        }
        return
    }

    # Hook called by the global `video` module after the preferred camera
    # changes. The sessions switch through calls; this reaches the self-view,
    # which may be all there is while we are alone in the call.
    tackymethod applyPreferredCamera {args} {
        array set opts {-id ""}
        array set opts $args
        if {![::tacky::media capability videoDevice]} return
        foreach room [array names Rooms] {
            set name [dict get $Rooms($room) preview]
            if {$name ne ""} { ::tacky::media setVideoDevice $name -id $opts(-id) }
        }
        return
    }

    tackymethod invite {args} {
        array set opts {-jid "" -to ""}
        array set opts $args
        if {$opts(-jid) eq "" || $opts(-to) eq ""} {
            error "invite: -jid and -to required"
        }
        set room [jid norm $opts(-jid)]
        set to [jid bare $opts(-to)]
        # A hosted call's room lets in only its members.
        if {[info exists Calls($room)]} { $self Admit $room [list $to] }
        set id [expr {[info exists Calls($room)] && [dict get $Calls($room) id] ne ""
                      ? [dict get $Calls($room) id] : [$self RandomHex 16]}]
        $client write [j message -to $to -type chat {
            j #as-is [$self InviteNode $room $id]
        }]
        return
    }

    tackymethod list {args} {
        set out {}
        foreach room [lsort [array names Rooms]] {
            if {[dict get $Rooms($room) state] ne "announced"} continue
            lappend out [dict create jid $room \
                chat [$self ChatOf $room] hosted [info exists Calls($room)] \
                count [$self CallSize $room] \
                video [dict get $Rooms($room) video] \
                mode [dict get $Rooms($room) mode] \
                preview [dict get $Rooms($room) view] \
                sessions [$self SessionSids $room]]
        }
        return $out
    }

    # =========================================================================
    # taco_calls hook: an inbound session-initiate with <muji room/>
    # =========================================================================

    # Whether $peer may open a session in $room's call: our video intent
    # (0/1), or "" to refuse. Refused when we are not announced, when $peer is
    # not an announced occupant's real JID, or when we already have a session
    # with them other than -replaces (ours, which lost a crossing tie-break).
    method AcceptSession {args} {
        array set opts {-room "" -peer "" -sid "" -video 0 -replaces ""}
        array set opts $args
        set room [jid norm $opts(-room)]
        if {![info exists Rooms($room)]
                || [dict get $Rooms($room) state] ne "announced"} {
            return ""
        }
        set occ [$self OccupantOf $room $opts(-peer)]
        if {$occ eq "" || [$self CallState $occ] ne "announced"} { return "" }
        set peer $opts(-peer)
        if {[dict exists $Rooms($room) sessions $peer]} {
            set old [dict get $Rooms($room) sessions $peer sid]
            if {$old ne "" && $old ne $opts(-replaces)} { return "" }
        }
        dict set Rooms($room) sessions $peer \
            [dict create sid $opts(-sid) video $opts(-video)]
        $client emit groupcall <Session> -jid $room \
            -peer $peer -sid $opts(-sid) -video $opts(-video)
        $self Met $room
        return [dict get $Rooms($room) video]
    }

    # =========================================================================
    # Presence: the room's occupants, as muc reports them
    # =========================================================================

    # The occupant field `call` from a <muji> presence; "" if absent or empty.
    method ParseMuji {stanza} {
        set muji [xsearch $stanza muji -ns $NS -get node]
        if {$muji eq ""} { return "" }
        # <preparing/> inherits muji's namespace on the wire; matched by tag.
        set preparing [expr {[xsearch $muji preparing -get node] ne ""}]
        set contents [$self ParseContents $muji]
        if {!$preparing && ![dict size $contents]} { return "" }
        return [dict create state [expr {$preparing ? "preparing" : "announced"}] \
            audio [dict exists $contents audio] video [dict exists $contents video] \
            contents $contents]
    }

    # preparing, announced, or "" if not in the call.
    method CallState {occ} {
        if {![dict exists $occ call] || [dict get $occ call] eq ""} { return "" }
        return [dict get $occ call state]
    }

    # Every occupant presence, in room order.
    method OnMucPresence {args} {
        $self OnChatPresence {*}$args
        # A caps refresh, not a new presence.
        if {[dict exists $args -replay] && [dict get $args -replay]} return
        set room [jid norm [dict get $args -jid]]
        if {![info exists Rooms($room)]} return
        set occ [dict get $args -occupant]
        if {[dict get $args -nick] eq [$client muc myNick -jid $room]} {
            $self OnOwnPresence $room $occ
            return
        }
        set real [dict get $occ jid]
        switch -- [$self CallState $occ] {
            "" { $self OnOutOfCall $room $real }
            preparing {
                # They started after us and wait for us.
                if {[dict get $Rooms($room) state] eq "preparing"} { $self MaybeAnnounce $room }
            }
            announced {
                if {[dict get $Rooms($room) state] eq "preparing"} {
                    # Someone we may be waiting on is done.
                    $self MaybeAnnounce $room
                    return
                }
                # Before our contents echo we call them; after it they call us.
                $self ReannounceIfChanged $room
                if {$real eq ""} {
                    $self WarnHidden $room [dict get $occ nick]
                } elseif {![dict exists $Rooms($room) sessions $real]} {
                    dict set Rooms($room) sessions $real [dict create sid "" video 0]
                    if {![dict get $Rooms($room) placed]} { $self Dial $room $real }
                }
            }
        }
    }

    # A presence of ours came back from the room.
    method OnOwnPresence {room occ} {
        set state [dict get $Rooms($room) state]
        # A nick shared with another session of ours: the room shows theirs,
        # so nobody sees our <muji>, and peers would refuse our sessions.
        if {$state eq "preparing"} {
            set mine [jid norm [$client cget -jid]]
            foreach ij [dict get $occ jids] {
                if {[jid norm $ij] eq $mine} continue
                $self GiveUp $room "another device of yours ($ij) is in this\
                    room as [dict get $occ nick], and the room shows its\
                    presence instead of this one"
                return
            }
        }
        switch -- [$self CallState $occ] {
            "" {
                # We left, or another client of ours cleared it. While a new
                # join still waits for its <preparing/> echo, this is the echo
                # of the earlier leave (or of the room join): ignore it.
                if {$state ne "preparing" || [dict get $Rooms($room) echoed]} {
                    $self Leave $room "left"
                }
            }
            preparing {
                if {$state ne "preparing"} return
                if {![dict get $Rooms($room) echoed]} {
                    dict set Rooms($room) echoed 1
                    after cancel [dict get $Rooms($room) timer]
                    dict set Rooms($room) timer ""
                    # Wait only for those preparing now; hidden JIDs are
                    # unreachable anyway.
                    set ahead {}
                    foreach o [$client muc occupants -jid $room] {
                        if {[dict get $o nick] eq [dict get $occ nick]} continue
                        if {[$self CallState $o] ne "preparing" || [dict get $o jid] eq ""} continue
                        lappend ahead [dict get $o jid]
                    }
                    dict set Rooms($room) waitfor $ahead
                }
                $self MaybeAnnounce $room
            }
            announced {
                if {$state eq "announced"} { dict set Rooms($room) placed 1 }
            }
        }
    }

    method OnEchoTimeout {room} {
        if {![info exists Rooms($room)]} return
        dict set Rooms($room) timer ""
        if {[dict get $Rooms($room) echoed]} return
        $self GiveUp $room "the room never showed our call presence"
    }

    # A join that cannot go on: take the <preparing/> back and report it.
    method GiveUp {room reason} {
        jlog error "groupcall: $room: $reason"
        $client muc sendPresence $room {}
        $self Farewell $room
        $self Leave $room $reason
    }

    # After our <preparing/> echo, announce once nobody in waitfor is still
    # preparing, or after PREPARE_TIMEOUT_MS.
    method MaybeAnnounce {room} {
        if {[dict get $Rooms($room) state] ne "preparing"} return
        if {![dict get $Rooms($room) echoed]} return
        set waiting 0
        foreach real [dict get $Rooms($room) waitfor] {
            set occ [$self OccupantOf $room $real]
            if {$occ ne "" && [$self CallState $occ] eq "preparing"} { incr waiting }
        }
        if {$waiting} {
            if {[dict get $Rooms($room) timer] eq ""} {
                dict set Rooms($room) timer \
                    [after $PREPARE_TIMEOUT_MS [mymethod OnPrepareTimeout $room]]
            }
            return
        }
        $self Announce $room
    }

    method OnPrepareTimeout {room} {
        if {![info exists Rooms($room)]} return
        dict set Rooms($room) timer ""
        if {[dict get $Rooms($room) state] ne "preparing"} return
        jlog debug "groupcall: $room: announcing without the peers still preparing"
        $self Announce $room
    }

    # Publish our contents and connect to everyone already in.
    method Announce {room} {
        after cancel [dict get $Rooms($room) timer]
        dict set Rooms($room) timer ""
        # Nothing to announce without the backend's payload types. Take the
        # <preparing/> back and give up, or the join would wait forever.
        if {[catch {$self AgreedPayloads $room} payloads]} {
            $self GiveUp $room "media backend failed: $payloads"
            return
        }
        dict set Rooms($room) payloads $payloads
        dict set Rooms($room) state announced
        $client muc sendPresence $room [list [$self ContentsNode $payloads]]
        $client emit groupcall <Joined> -jid $room {*}[$self ChatArgs $room]
        $client message PatchCallRows $room

        set myNick [$client muc myNick -jid $room]
        foreach occ [$client muc occupants -jid $room] {
            if {[dict get $occ nick] eq $myNick || [$self CallState $occ] ne "announced"} continue
            set real [dict get $occ jid]
            if {$real eq ""} {
                $self WarnHidden $room [dict get $occ nick]
                continue
            }
            if {[dict exists $Rooms($room) sessions $real]} continue
            $self Dial $room $real
        }
    }

    # Start our session with $real.
    method Dial {room real} {
        set occ [$self OccupantOf $room $real]
        set video [expr {[dict get $Rooms($room) video]
                         && $occ ne "" && [dict get $occ call video]}]
        set sid [$client calls StartGroupSession \
            -room $room -peer $real -video $video]
        dict set Rooms($room) sessions $real [dict create sid $sid video $video]
        $client emit groupcall <Session> -jid $room \
            -peer $real -sid $sid -video $video
        $self Met $room
    }

    # Warn once per nick that the room hides their JID.
    method WarnHidden {room nick} {
        if {$nick in [dict get $Rooms($room) warned]} return
        dict lappend Rooms($room) warned $nick
        $client emit groupcall <Warning> -jid $room \
            -reason "$nick: JID hidden by the room, cannot connect"
    }

    # The room's codec set moved under us: say what we can still do. Live
    # sessions keep what they negotiated.
    method ReannounceIfChanged {room} {
        set payloads [$self AgreedPayloads $room]
        if {$payloads eq [dict get $Rooms($room) payloads]} return
        dict set Rooms($room) payloads $payloads
        $client muc sendPresence $room [list [$self ContentsNode $payloads]]
    }

    # $real left the call or the room: hang up their session, and recheck
    # whether we can announce.
    method OnOutOfCall {room real} {
        if {![info exists Rooms($room)]} return
        if {$real ne "" && [dict exists $Rooms($room) sessions $real]} {
            set sid [dict get $Rooms($room) sessions $real sid]
            dict unset Rooms($room) sessions $real
            if {$sid ne ""} { $client calls hangup -sid $sid }
        }
        if {[dict get $Rooms($room) state] eq "preparing"} { $self MaybeAnnounce $room }
    }

    method OnOccupantGone {args} {
        set room [jid norm [dict get $args -jid]]
        $self OnOutOfCall $room [dict get $args -occupant jid]
    }

    # The call goes with the room. On a session end OnDisconnect does this
    # instead, and the sessions stay taco_calls' to end or resume.
    method OnRoomLeft {args} {
        array set opts {-jid "" -disconnected 0}
        array set opts $args
        if {$opts(-disconnected)} return
        set room [jid norm $opts(-jid)]
        if {![info exists Rooms($room)] && [info exists Calls($room)]} {
            $client emit groupcall <Left> -jid $room -reason "left the room" \
                {*}[$self ChatArgs $room]
            unset Calls($room)
        }
        if {[info exists Rooms($room)]} { $self Leave $room "left the room" }
    }

    # Only the room state is ours to drop, with nothing on the wire; the sessions
    # are taco_calls' to end or resume.
    method OnDisconnect {args} {
        array unset Live *
        foreach room [array names Rooms] {
            $self Leave $room "disconnected" 0
        }
        foreach room [array names Calls] {
            $client emit groupcall <Left> -jid $room -reason "disconnected" \
                {*}[$self ChatArgs $room]
            unset Calls($room)
        }
    }

    # =========================================================================
    # Sessions ending on their own
    # =========================================================================

    # A session ended (calls <Ended>/<Failed>). The participant stays;
    # nothing redials.
    method OnSessionEnded {how args} {
        set sid [dict get $args -sid]
        foreach room [array names Rooms] {
            dict for {real session} [dict get $Rooms($room) sessions] {
                if {[dict get $session sid] ne $sid} continue
                dict set Rooms($room) sessions $real sid ""
                # A refusing peer does not see us in the call, usually
                # because another session of ours shares the nick (which our
                # own echo does not always reveal).
                if {$how eq "failed" && [dict exists $args -reason]
                        && [dict get $args -reason] eq "session-initiate rejected"} {
                    set occ [$self OccupantOf $room $real]
                    set who [expr {$occ eq "" ? $real : [dict get $occ nick]}]
                    set me [$client muc myNick -jid $room]
                    $client emit groupcall <Warning> -jid $room \
                        -reason "$who does not see you in the call; is another\
                            device of yours in this room as $me?"
                }
                return
            }
        }
    }

    # =========================================================================
    # XEP-0482 invites
    # =========================================================================

    # A live call invite from someone else, just stored in $chat: <Invited>
    # lets a frontend ring. Parsing and storing are the message module's
    # (ParseCallInvite, ApplyCallVerdict).
    method OnInvited {chat ts} {
        set at [$client message messagestore callAt $chat $ts]
        if {$at eq ""} return
        set call [dict get $at call]
        $client emit groupcall <Invited> -jid [dict get $call room] \
            -from [dict get $call inviter] -chat $chat -timestamp $ts \
            -video [dict get $call video]
    }

    # =========================================================================
    # Helpers
    # =========================================================================

    # Drop our room state and hang up every session. The presence is the
    # caller's business: leave sends it, the other exits already lost it.
    method Leave {room reason {hangup 1}} {
        set state $Rooms($room)
        after cancel [dict get $state timer]
        unset Rooms($room)
        if {[dict get $state preview] ne ""} {
            ::tacky::media closePreview [dict get $state preview]
        }
        if {$hangup} {
            dict for {real session} [dict get $state sessions] {
                if {[dict get $session sid] ne ""} {
                    $client calls hangup -sid [dict get $session sid]
                }
            }
        }
        # Others may still be in it.
        $self ForgetLiveness $room
        # Still preparing counts: a frontend showing "joining" waits for it.
        $client emit groupcall <Left> -jid $room -reason $reason {*}[$self ChatArgs $room]
        $client message PatchCallRows $room
        # A hosted call's room is the call's alone: out of the call, out of it.
        if {[info exists Calls($room)]} {
            unset Calls($room)
            if {[$client muc isJoined -jid $room]} { $client muc leave -jid $room }
        }
    }

    # -chat and the chat a call belongs to, for an event; nothing when none.
    method ChatArgs {room} {
        set chat [$self ChatOf $room]
        return [expr {$chat eq "" ? {} : [list -chat $chat]}]
    }

    # The chat a call belongs to: a hosted call's own, else the room itself
    # when that is a group chat (an in-room call).
    method ChatOf {room} {
        if {[info exists Calls($room)]} { return [dict get $Calls($room) chat] }
        if {[$client muc isJoined -jid $room] && ![$client muc isHidden -jid $room]} {
            return $room
        }
        return ""
    }

    # Occupants announcing contents (not merely preparing), us included.
    method CallSize {room} {
        set n 0
        foreach occ [$client muc occupants -jid $room] {
            if {[$self CallState $occ] eq "announced"} { incr n }
        }
        return $n
    }

    # The occupant whose real JID is $fullJid, "" if none.
    method OccupantOf {room fullJid} {
        if {$fullJid eq ""} { return "" }
        foreach occ [$client muc occupants -jid $room] {
            if {[dict get $occ jid] eq $fullJid} { return $occ }
        }
        return ""
    }

    # Real JID -> sid of our existing sessions in $room.
    method SessionSids {room} {
        set out {}
        dict for {real session} [dict get $Rooms($room) sessions] {
            if {[dict get $session sid] ne ""} { dict set out $real [dict get $session sid] }
        }
        return $out
    }

    # media -> payload list, from a <muji> node's contents. Content
    # elements come in the jingle namespace (Dino, Movim) or inherit muji's
    # (the XEP's examples); either is fine.
    method ParseContents {muji} {
        set out {}
        xsearch $muji content -script content {
            set d [xsearch $content description -ns $NS_RTP -get node]
            if {$d eq ""} continue
            set media [xsearch $d -get @media]
            if {$media eq ""} continue
            set pts {}
            xsearch $d payload-type -script pt {
                set entry [dict create \
                    id [xsearch $pt -get @id] \
                    name [xsearch $pt -get @name] \
                    clockrate [xsearch $pt -get @clockrate]]
                set ch [xsearch $pt -get @channels]
                if {$ch ne ""} { dict set entry channels $ch }
                lappend pts $entry
            }
            dict set out $media $pts
        }
        return $out
    }

    # XEP-0272 §3: the intersection of what everyone in announced, keeping
    # their ids, cut down to what our backend does. With nobody in yet it
    # is ours. Video is announced only if we offer it.
    method AgreedPayloads {room} {
        set mine [::tacky::media payloadTypes]
        set myNick [$client muc myNick -jid $room]
        set media {audio}
        if {[dict get $Rooms($room) video]} { lappend media video }
        set out {}
        foreach kind $media {
            set ours [expr {[dict exists $mine $kind] ? [dict get $mine $kind] : {}}]
            set agreed {}
            set anyone 0
            foreach occ [$client muc occupants -jid $room] {
                if {[dict get $occ nick] eq $myNick || [$self CallState $occ] ne "announced"} continue
                if {![dict exists $occ call contents $kind]} continue
                set theirs [dict get $occ call contents $kind]
                set agreed [expr {$anyone ? [$self Intersect $agreed $theirs] : $theirs}]
                set anyone 1
            }
            dict set out $kind \
                [expr {$anyone ? [$self Intersect $agreed $ours] : $ours}]
        }
        return $out
    }

    # Entries of $keep whose codec (name, clock rate, channels) $other also
    # lists; $keep's ids survive.
    method Intersect {keep other} {
        set keys {}
        foreach pt $other { lappend keys [$self CodecKey $pt] }
        set out {}
        foreach pt $keep {
            if {[$self CodecKey $pt] in $keys} { lappend out $pt }
        }
        return $out
    }

    method CodecKey {pt} {
        set ch [expr {[dict exists $pt channels] ? [dict get $pt channels] : 1}]
        return [list [string tolower [dict get $pt name]] \
            [dict get $pt clockrate] $ch]
    }

    # =========================================================================
    # Hosted calls
    # =========================================================================

    # Our <preparing/>, in a room we are in.
    method BeginJoin {room video} {
        set Rooms($room) [dict create state preparing video $video mode mesh \
            payloads {} sessions {} echoed 0 waitfor {} placed 0 warned {} preview "" view {} \
            timer [after $ECHO_TIMEOUT_MS [mymethod OnEchoTimeout $room]]]
        $client muc sendPresence $room [list [$self PreparingNode]]
        if {$video} { $self OpenPreview $room }
    }

    # The self-view, held from joining to leaving. A camera that will not
    # open is a warning; the call goes on without it.
    method OpenPreview {room} {
        if {[catch {::tacky::media capability preview} has] || !$has} return
        set name "groupcall:$client:$room"
        set cam ""
        catch {set cam [[$client cget -taco] video getPreferredCamera]}
        dict set Rooms($room) preview $name
        if {[catch {::tacky::media openPreview $name \
                -command [mymethod OnPreviewEvent $room $name] -device-id $cam} err]} {
            if {[info exists Rooms($room)]} { dict set Rooms($room) preview "" }
            $client emit groupcall <Warning> -jid $room -reason "camera: $err"
        }
    }

    method OnPreviewEvent {room name ev} {
        if {![info exists Rooms($room)] || [dict get $Rooms($room) preview] ne $name} return
        switch -- [dict get $ev type] {
            videoChannel {
                set view [dict filter [dict get $ev channel] key name id]
                dict set Rooms($room) view $view
                set flags {}
                dict for {key value} $view { lappend flags -$key $value }
                $client emit groupcall <VideoPreview> -jid $room \
                    {*}[$self ChatArgs $room] {*}$flags
            }
            deviceFallback {
                $client emit groupcall <Warning> -jid $room \
                    -reason "camera device unavailable, using default"
            }
            error {
                if {![dict get $ev fatal]} return
                dict set Rooms($room) preview ""
                dict set Rooms($room) view {}
                ::tacky::media closePreview $name
                $client emit groupcall <Warning> -jid $room \
                    -reason "camera: [dict get $ev reason]"
            }
        }
    }

    # A hosted call's room, made and configured for $spec: on the chat's own
    # service first, since everyone in the chat can reach it; ours when that
    # refuses us, or for a 1:1 chat.
    method Create {spec} {
        set chat [dict get $spec chat]
        if {[$client muc isJoined -jid $chat]} {
            $self CreateOn $spec [jid domain $chat] chat
        } else {
            $client muc findService -command [mymethod OnOwnService $spec ""]
        }
    }

    method CreateOn {spec service where} {
        set room "[$self RandomHex 6]@$service"
        $client muc createRoom -jid $room -nick [dict get $spec nick] -hidden 1 \
            -config $ROOM_CONFIG \
            -command [mymethod OnCreated $spec] \
            -onerror [mymethod OnCreateFailed $spec $service $where]
    }

    # The chat's service would not have us: ours, if that is another one.
    method OnCreateFailed {spec service where reason} {
        if {$where eq "chat"} {
            $client muc findService -command [mymethod OnOwnService $spec $service]
            return
        }
        $self StartFailed $spec "no room for the call: $reason"
    }

    method OnOwnService {spec tried service} {
        if {$service eq "" || $service eq $tried} {
            $self StartFailed $spec "no group chat service to hold the call"
            return
        }
        $self CreateOn $spec $service own
    }

    method StartFailed {spec reason} {
        jlog warn "groupcall: [dict get $spec chat]: $reason"
        $client emit groupcall <StartFailed> -chat [dict get $spec chat] -reason $reason
    }

    # The room is up and ours: let the chat in, take our place, tell the chat.
    method OnCreated {spec room} {
        set chat [dict get $spec chat]
        set id [dict get $spec id]
        set Calls($room) [dict create chat $chat id $id ours 1 met 0 admitted {}]
        $client emit groupcall <Started> -jid $room -chat $chat
        $self AdmitChat $room
        $self BeginJoin $room [dict get $spec video]
        $self SendToChat $chat [$self InviteNode $room $id [dict get $spec video]]
    }

    # =========================================================================
    # Whether a hosted call is still going
    # =========================================================================

    # A hosted call's room is gone once empty, so disco#info on it says
    # whether the call is going. Live($room) is the last answer; Gen($room)
    # counts forgets, so an answer to a question asked before someone came or
    # went is stale and asked again.

    # 1 or 0 as the room last said; "" while unknown, which asks it and
    # re-sends the call's rows on the answer. A call we are in is live.
    method Liveness {room} {
        set room [jid norm $room]
        if {[info exists Rooms($room)]} { return 1 }
        if {[info exists Live($room)]} { return $Live($room) }
        $self AskRoom $room
        return ""
    }

    # Someone went in or out of the call in $room.
    method ForgetLiveness {room} {
        set room [jid norm $room]
        unset -nocomplain Live($room)
        incr Gen($room)
    }

    # Ask $room, then call $cmd with the answer: 1, 0, or "" for an answer
    # that says neither (anything but a result, item-not-found or gone).
    # Questions in flight are shared. $tries: how often this question went
    # unanswered already.
    method AskRoom {room {cmd ""} {tries 0}} {
        set inFlight [info exists Asking($room)]
        lappend Asking($room)
        if {$cmd ne ""} { lappend Asking($room) $cmd }
        if {$inFlight} return
        if {![$client iq isLive]} {
            after idle [mymethod OnRoomInfo $room "" $tries ""]
            return
        }
        set gen [expr {[info exists Gen($room)] ? $Gen($room) : 0}]
        $client iq request -type get -to $room -timeout $ASK_TIMEOUT_MS \
            -payload [j query -ns http://jabber.org/protocol/disco#info] \
            -command [mymethod OnRoomInfo $room $gen $tries]
    }

    method OnRoomInfo {room gen tries stanza} {
        set live ""
        set cond ""
        if {$stanza ne "" && [xsearch $stanza -get @type] eq "result"} {
            set live 1
        } elseif {$stanza ne ""} {
            set cond [xsearch $stanza error * \
                -ns urn:ietf:params:xml:ns:xmpp-stanzas -get node]
            if {$cond ne "" && [dict get $cond tag] in {item-not-found gone}} {
                set live 0
            }
        }
        set waiters $Asking($room)
        unset Asking($room)
        # Unanswered within ASK_TIMEOUT_MS: ask again rather than leave
        # the rows and the waiters on a lost question.
        if {$cond ne "" && [dict get $cond tag] eq "remote-server-timeout"
                && $tries < $ASK_RETRIES} {
            incr tries
            $self AskRoom $room "" $tries
            foreach cmd $waiters { $self AskRoom $room $cmd $tries }
            return
        }
        set now [expr {[info exists Gen($room)] ? $Gen($room) : 0}]
        if {$live ne "" && $gen ne "" && $gen != $now} {
            $self AskRoom $room
            foreach cmd $waiters { $self AskRoom $room $cmd }
            return
        }
        if {$live ne ""} {
            set was [expr {[info exists Live($room)] ? $Live($room) : ""}]
            set Live($room) $live
            if {$was ne $live} { $client message PatchCallRows $room }
        }
        foreach cmd $waiters { {*}$cmd $live }
    }

    # start, once the chat's newest call's room has answered.
    method StartAsked {spec stored ts live} {
        if {$live eq "1"} {
            $self join -chat $stored -timestamp $ts -video [dict get $spec video]
        } else {
            $self Create $spec
        }
    }

    method OnHostedJoined {room video result} {
        if {![info exists Calls($room)]} {
            # Left while we were getting in.
            if {![dict exists $result -error]} { $client muc leave -jid $room }
            return
        }
        set reason ""
        if {[dict exists $result -error]} {
            set reason [switch -- [dict get $result -error] {
                registration-required { format "you are not on this call's guest list" }
                item-not-found        { format "the call has ended" }
                forbidden             { format "you are not allowed into this call" }
                default               { format "cannot enter the call: [dict get $result -error]" }
            }]
        } elseif {[dict get $result -created]} {
            # A fresh room: the call's had gone.
            $client muc leave -jid $room
            set reason "the call has ended"
        }
        if {$reason ne ""} {
            $client emit groupcall <Left> -jid $room -reason $reason \
                {*}[$self ChatArgs $room]
            unset Calls($room)
            if {$reason eq "the call has ended"} {
                set Live($room) 0
                $client message SettleCall $room ended
                $client message PatchCallRows $room
            }
            return
        }
        # Settled before our <accept> echoes back, which would otherwise
        # read as another device of ours answering.
        $client message SettleCall $room joined
        set id [dict get $Calls($room) id]
        if {$id ne ""} {
            $self SendToChat [dict get $Calls($room) chat] \
                [j accept -ns $NS_INVITES -id $id]
        }
        $self BeginJoin $room $video
    }

    # Tell the chat we are out: <retract> for a call of ours nobody came to,
    # which takes the invite back, else <left>.
    method Farewell {room} {
        if {![info exists Calls($room)]} return
        set call $Calls($room)
        if {[dict get $call id] eq ""} return
        set tag [expr {[dict get $call ours] && ![dict get $call met] ? "retract" : "left"}]
        $self SendToChat [dict get $call chat] \
            [j $tag -ns $NS_INVITES -id [dict get $call id]]
    }

    method Met {room} {
        if {[info exists Calls($room)]} { dict set Calls($room) met 1 }
    }

    # A message carrying $node to a chat: to the room for a group chat, else
    # to the contact.
    method SendToChat {chat node} {
        if {$chat eq ""} return
        set type [expr {[$client muc isJoined -jid $chat] ? "groupchat" : "chat"}]
        $client write [j message -to $chat -type $type { j #as-is $node }]
    }

    # id is what accept/reject/left/retract refer to, and Dino drops an
    # invite without one; video says what we joined with; multi, that this
    # is a group call.
    method InviteNode {room id {video ""}} {
        if {$video eq ""} {
            set video [expr {[info exists Rooms($room)] && [dict get $Rooms($room) video]}]
        }
        set room [jid norm $room]
        return [j invite -ns $NS_INVITES -id $id \
            -video [expr {$video ? "true" : "false"}] -multi true {
            j muji -ns $NS -room $room
        }]
    }

    # Everyone in the call's chat, made a member of its room: a group
    # chat's occupants whose real JIDs show, and its member list when we may
    # read it; a 1:1 chat's contact. Owners, as Dino does, so any of them
    # can let in more.
    method AdmitChat {room} {
        set chat [dict get $Calls($room) chat]
        if {$chat eq ""} return
        if {![$client muc isJoined -jid $chat]} {
            $self Admit $room [list $chat]
            return
        }
        set jids {}
        foreach occ [$client muc occupants -jid $chat] {
            if {[dict get $occ jid] ne ""} { lappend jids [jid bare [dict get $occ jid]] }
        }
        $self Admit $room $jids
        foreach what {members admins owners} {
            $client muc getList -jid $chat -what $what \
                -command [mymethod OnChatList $room] -onerror {apply {{args} {}}}
        }
    }

    method OnChatList {room items} {
        set jids {}
        foreach item $items {
            if {[dict exists $item jid] && [dict get $item jid] ne ""} {
                lappend jids [jid bare [dict get $item jid]]
            }
        }
        $self Admit $room $jids
    }

    method Admit {room jids} {
        if {![info exists Calls($room)]} return
        set me [jid bare [$client cget -jid]]
        foreach bare $jids {
            set bare [jid norm $bare]
            if {$bare eq $me || $bare in [dict get $Calls($room) admitted]} continue
            dict lappend Calls($room) admitted $bare
            $client muc affiliation -jid $room -target $bare -affiliation owner
        }
    }

    # Someone entering a chat whose hosted call we are in is let into its
    # room, so a late arrival can still come to the call.
    method OnChatPresence {args} {
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        set chat [jid norm [dict get $args -jid]]
        set occ [dict get $args -occupant]
        if {![dict exists $occ jid] || [dict get $occ jid] eq ""} return
        foreach room [array names Calls] {
            if {[dict get $Calls($room) chat] ne $chat} continue
            if {![info exists Rooms($room)]} continue
            if {[$client muc myAffiliation -jid $room] ni {owner admin}} continue
            $self Admit $room [list [jid bare [dict get $occ jid]]]
        }
    }

    method RandomHex {bytes} {
        binary scan [omemo::random $bytes] H* hex
        return $hex
    }

    method PreparingNode {} {
        return [j muji -ns $NS {
            j preparing
        }]
    }

    # <muji> with one <content> per media, in the jingle namespace so Dino
    # reads it (Movim does the same). The content name is the media name,
    # which is also the session's m-line label (taco_calls MID / VIDEO_MID):
    # XEP-0272 §3 matches session contents to conference ones by name.
    method ContentsNode {payloads} {
        return [j muji -ns $NS {
            dict for {media pts} $payloads {
                j content -ns $NS_JINGLE -creator initiator -name $media {
                    j description -ns $NS_RTP -media $media {
                        foreach pt $pts {
                            set attrs [list -id [dict get $pt id] \
                                -name [dict get $pt name] \
                                -clockrate [dict get $pt clockrate]]
                            if {[dict exists $pt channels]} {
                                lappend attrs -channels [dict get $pt channels]
                            }
                            j payload-type {*}$attrs
                        }
                    }
                }
            }
        }]
    }
}
