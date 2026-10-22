# Voice calls (XEP-0166/0167/0176). Signaling - Jingle, JMI, SDP conversion,
# call state - lives here; the media itself is behind `tacky::media`, whose
# active backend owns ICE/DTLS/RTP and the mic/speaker/camera path. XEP-0353
# Jingle Message Initiation rings the right device without GUI-side resource
# discovery.
#
# tacky calls start  -acc $jid -to <bare jid> ?-command $cb?   ;# returns sid
# tacky calls accept -acc $jid -sid $sid
# tacky calls reject -acc $jid -sid $sid ?-reason decline?
# tacky calls hangup -acc $jid -sid $sid ?-reason success?
#
# tacky calls setDevices          -acc $jid -sid $sid ?-input $id? ?-output $id?
#   ;# per-call device override; does not touch the persisted preference.
#
# tacky calls list   -acc $jid ?-command $cb?
#   ;# -> one dict per live call: sid peer direction state peer_ringing
#   ;#    group video_local video_remote verified fingerprint active_since
#
# Enumeration and the persisted preferred device + volume live on the
# process-global `audio` module (see lib/taco/modules/audio.tcl). Volume
# has no per-call override — `tacky audio setVolume` is the only knob.
#
# tacky listen calls <Outgoing>        $cmd  ;# -sid $sid -to $jid -video 0|1
# tacky listen calls <Incoming>        $cmd  ;# -sid $sid -from $jid
# tacky listen calls <Ringing>         $cmd  ;# -sid $sid          (caller side: peer device alerting)
# tacky listen calls <Active>          $cmd  ;# -sid $sid -since $us   (RTP flowing)
# tacky listen calls <Ended>           $cmd  ;# -sid $sid -reason $why  (terminal — normal teardown)
# tacky listen calls <Missed>          $cmd  ;# -sid $sid -from $jid -video 0|1 -reason $why
# tacky listen calls <Failed>          $cmd  ;# -sid $sid -reason $text  (terminal — unrecoverable)
# tacky listen calls <Warning>         $cmd  ;# -sid $sid -reason $text  (non-fatal; call continues)
# tacky listen calls <Verified>        $cmd  ;# -sid $sid -verified 0|1 -fingerprint $fp
#
# <Ended> -reason says why, one of:
#   hangup     a session that reached Jingle ended normally, either side
#   declined   the callee said no: us rejecting a ring, or the peer ours
#   busy       the peer turned our propose down because it was busy
#   retracted  the caller gave up before an answer, either side
#   elsewhere  another of our own devices answered or declined the ring
#   timeout    nobody answered within RING_TIMEOUT_MS, either side
#   replaced   a crossing propose or session from the same peer won
#   reset      a fresh stream dropped every sid the old one held
#
# <Missed>: a ring nobody here answered (retracted, timed out, or turned
# away, which had no <Incoming>: busy with another call, or proxy because
# the account goes through a proxy).
#
# Verification, as in Conversations. When OMEMO is on for the chat, each side
# puts its OMEMO device id in <propose>/<proceed> and sends its DTLS
# fingerprint OMEMO-encrypted for the other side's device instead of in
# plain text. The fingerprint then arrives authenticated by that device, so
# a server can't substitute its own certificate.
# <Verified> is emitted once the peer's fingerprint is taken and again when
# the result changes. -verified is 1 when the device that sent it is one we
# would encrypt messages to (omemo deviceAccepted). -fingerprint is that
# device's OMEMO key as `omemo trustList` shows it, "" for a plain call.
# A fingerprint that should be encrypted but isn't, doesn't decrypt, or
# comes from an untrusted device fails the call with security-error.
# Group-call sessions don't use this.
#
# Caller:
#   start
#     -> state=proposed, emit <Outgoing>
#     -> send <message><propose sid/></message> to bare JID
#   <- <message><ringing sid/></message> from full JID
#     -> emit <Ringing> (informational; internal state stays proposed)
#   <- <message><proceed sid/></message> from full JID
#     -> state=proceeded, peer=full JID
#     -> $client extdisco fetch (XEP-0215; async) returns ICE server list
#     -> createPeer + sendrecv audio track, attachAudio,
#        setLocalDescription
#     -> localDescription(offer)       -> send <jingle action=session-initiate>
#     -> iceCandidate * N              -> send <jingle action=transport-info>
#   <- <jingle action=session-accept>  -> setRemoteDescription sdp answer
#   <- <jingle action=transport-info>  -> addRemoteCandidate
#     -> connectionState connected     -> emit <Active>
#
#   hangup while proposed: send <message><retract/></message>
#   hangup after proceed:  pc + media teardown + <jingle action=session-terminate>
#
# Callee:
#   <- <message><propose sid/></message>
#     -> state=ringing, peer=msg @from
#     -> send <message><ringing sid/></message> (XEP-0353 §4 alerting)
#     -> emit <Incoming>
#   accept
#     -> state=proceeded, send <message><proceed sid/></message>
#   <- <jingle action=session-initiate>
#     -> $client extdisco fetch (XEP-0215; async) returns ICE server list
#     -> createPeer, setRemoteDescription sdp offer, then
#        setLocalDescription unless the backend declares `autoAnswer`
#        (see StartIncomingMedia)
#     -> track $tr                     -> attachAudio / attachVideo* on $tr
#     -> localDescription(answer)      -> send <jingle action=session-accept>
#     -> iceCandidate * N              -> send <jingle action=transport-info>
#   <- <jingle action=transport-info>  -> addRemoteCandidate
#
#   reject while ringing:  send <message><reject/></message>
#   hangup after proceed:  pc + media teardown + <jingle action=session-terminate>
#
# Both sides:
#   <- <jingle action=session-terminate> -> destroy media + pc
#                                        -> emit <Ended>
#   <- fresh (non-resumed) stream        -> destroy media + pc
#                                        -> emit <Ended>
#
# Some notes about order:
#   - session-initiate / session-accept are shipped from
#     OnLocalDescription, not from OnGatheringState. The SDP at that
#     point has no candidates yet — those arrive asynchronously and
#     are trickled via OnLocalCandidate → transport-info.
#   - No end-of-candidates marker is emitted. A backend keeps accepting
#     addRemoteCandidate until the pc closes; ICE either succeeds on
#     what's there or fails via its own timer.
#   - Inbound transport-info while pc == -1 (the JMI-ringing window,
#     or any race before set-remote-description) is buffered into
#     [dict get $Calls $sid pending_remote_candidates], not dropped.
#     HandleSessionInitiate drains the buffer right after
#     set-remote-description.
#
# Sender binding: every inbound stanza for a call must come from that
# call's peer - bare match during the JMI window (any of the callee's
# resources may answer), exact full JID once latched. The sid is no
# secret: the propose goes to the bare JID, so all of the peer's
# resources and every server on the path see it.
#
# Group-call sessions: taco_groupcall (XEP-0272 Muji) runs one session per
# participant here. Such a session skips JMI (room presence is the ring),
# carries the room JID as `group`, and emits no <Outgoing>/<Incoming>.
#
# State. A call runs two machines, each one field of its dict, and every
# change of either goes through Go, which refuses a move its table
# (SESSION_NEXT, TRANSPORT_NEXT) does not list:
#
#   state (the session, signalling):
#     proposed   we rang the peer (JMI propose), no answer yet
#     ringing    the peer rings us, we have not answered
#     proceeded  answered (JMI proceed); a group leg starts here
#     pending    a session-initiate went out or came in, not yet accepted
#     established both descriptions are applied: the session is up
#
#   transport (the media path, whatever the backend):
#     idle        no path yet
#     checking    ICE is looking for one
#     connected   media flows
#     interrupted it flowed and stopped; the backend may still recover
#
# Neither has a terminal state: every end goes through Finish, which says
# so on the wire and on the bus and drops the call in the same frame. So
# `list` never shows an ended call. The inbound Jingle actions a session
# takes in each state are a table too (JINGLE_IN); one it does not take is
# refused there, before any handler runs.
#
# Per-call fields ([dict get $Calls $sid] dict):
#   peer       : remote JID (bare until proceeded, then full)
#   initiator  : 1 for caller, 0 for callee
#   group      : room JID for a group-call session, "" for a 1:1 call
#   state, transport : the two machines above
#   jingle     : 1 once a session-initiate went out or came in; the peer
#     then knows the session and is told it ended with session-terminate
#   self_jid   : our full JID when the session started; a fresh stream
#     that binds another one cannot carry the session
#   peer_ringing : 1 once a peer device answered <ringing> (caller side);
#     a field, not a state, because the state machine does not move for it
#   ever_connected : 1 once the transport first reached connected
#   setup_timer : SetupTimeout's after token from proceeded until then
#   pc         : tacky::media pc handle (-1 = not created)
#   track      : media handle of the audio track (-1 = not added/received)
#   pending_remote_candidates : list of [list mid candidate], present
#     only while inbound trickle has outpaced the remote description (no
#     pc yet, or the caller's pc before session-accept); drained and unset
#     once it is set (DrainPendingCandidates)
#   remote_set : present once the peer's description is applied
#   ring_timer : RingTimeout's after token while a propose rings
#   active_since : [clock microseconds] of the first <Active>, 0 before
#   Verification fields, set only when they apply:
#   announced   : our <propose>/<proceed> carried our OMEMO device
#   peer_device : OMEMO device from the peer's <propose>/<proceed>
#   fingerprint_encrypted : our description went out encrypted
#   describing  : our description is being encrypted; local candidates
#     wait in held_candidates until it is sent
#   omemo_device, fingerprint, verified : the peer's device that sent its
#     fingerprint, that device's key, and whether we accept it
#
# The pc handle is this instance plus the sid, so two accounts in one
# process that end up on either side of the same call do not collide.
# Media events for a pc come back to OnMediaEvent with that sid bound, so
# there is no id to map back.

package require tacky::media
package require omemo

snit::type taco_calls {
    option -client -readonly yes

    # The handles we name our own tracks with. They double as the Jingle
    # <content name=...> we expect back, since the m-line labels the rtc
    # backend writes match; a peer using its own mids is dispatched by
    # media kind instead. The codecs and payload types behind them belong
    # to the media backend.
    typevariable MID       audio
    typevariable VIDEO_MID video

    # Ceiling on candidates buffered during the JMI window; a peer trickles
    # a handful, so anything past this is not worth keeping.
    typevariable MAX_PENDING_CANDIDATES 64

    # How long ICE may stay disconnected before we warn: a hanging-up peer
    # drops ICE first, and its session-terminate lands inside this.
    typevariable DISCONNECT_GRACE_MS 2000

    # XEP-0353 sets no limit: a caller that never retracts rings forever.
    typevariable RING_TIMEOUT_MS 60000

    # Answered, a call has this long to first reach a media path: a
    # session-initiate that never comes after proceed, or an accept that
    # never comes after it, would otherwise hold the call forever. Once
    # media has flowed it no longer applies; a path lost later is the
    # transport machine's to recover or fail.
    typevariable SETUP_TIMEOUT_MS 60000

    # The session machine: state -> the states it may move to.
    typevariable SESSION_NEXT {
        proposed    {proceeded}
        ringing     {proceeded}
        proceeded   {pending}
        pending     {established}
        established {}
    }

    # The transport machine, likewise. interrupted -> checking is a path
    # the backend is looking for again by itself (`connecting` after it
    # had connected); restarting is an ICE restart, ours or the peer's,
    # under way (see "ICE restart" below).
    typevariable TRANSPORT_NEXT {
        idle        {checking connected interrupted}
        checking    {connected interrupted restarting}
        connected   {interrupted checking restarting}
        interrupted {connected checking restarting}
        restarting  {connected interrupted}
    }

    # ICE restart (XEP-0176 §5.9, as Conversations does it). A path that
    # stays interrupted this long, or fails, is restarted.
    typevariable RESTART_AFTER_MS 3000
    # One restart has this long to connect, counted only while the stream
    # to the server is up: its signalling cannot travel otherwise.
    typevariable RESTART_WAIT_MS 15000
    # Restarts in a row that do not connect, and in all, before the call
    # is given up.
    typevariable MAX_RESTART_ATTEMPTS 3
    typevariable MAX_RESTARTS 8
    # However it goes, a call whose media has not flowed for this long is
    # over.
    typevariable MEDIA_LOSS_MAX_MS 60000

    # What a session in each state does with an inbound Jingle action from
    # its peer: handle, or refuse with that IQ error. An action not named
    # for a state takes that state's `*`. The handlers check what the table
    # cannot see (the role, whether a pc is up yet).
    typevariable JINGLE_IN {
        proposed {
            session-terminate handle
            session-info      handle
            *                 out-of-order
        }
        ringing {
            session-terminate handle
            session-info      handle
            transport-info    handle
            *                 out-of-order
        }
        proceeded {
            session-accept    out-of-order
            *                 handle
        }
        pending {
            session-accept    handle
            session-terminate handle
            transport-info    handle
            *                 handle
        }
        established {
            session-initiate  out-of-order
            *                 handle
        }
    }

    # Moves Go refused, newest last. A refused move is a bug in this file;
    # the tests check this stays empty.
    typevariable IllegalMoves {}

    # The XEP-0166 conditions that say a session broke rather than ended:
    # a peer ending with one of them failed, and the call fails here too.
    typevariable FAULTS {
        connectivity-error failed-application failed-transport general-error
        incompatible-parameters media-error security-error timeout
        unsupported-applications unsupported-transports
    }

    # Conversations' namespace. "dlts" is a typo, but it is what goes on the
    # wire; don't correct it.
    typevariable NS_VERIFY http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification
    typevariable NS_AXOLOTL eu.siacs.conversations.axolotl

    variable client
    variable Calls           ;# sid -> dict (see file header)
    variable SdpErrors       ;# sid -> reason, see TakeSdpError

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Calls [dict create]
        set SdpErrors [dict create]
        $client iq handler set urn:xmpp:jingle:1 [mymethod OnJingleIq]
        $client bus subscribe $self <SessionStart> [mymethod OnFreshStream]
        $client bus subscribe $self <Resumed> [mymethod OnResumed]
        $client bus subscribe $self <Closing> [mymethod OnClosing]
        $client bus subscribe $self omemo:<TrustChanged> [mymethod OnTrustChanged]
        $client bus subscribe $self omemo:<BlindTrust> [mymethod OnBlindTrust]

        $client caps addFeature urn:xmpp:jingle:1
        $client caps addFeature urn:xmpp:jingle:apps:rtp:1
        $client caps addFeature urn:xmpp:jingle:apps:rtp:audio
        $client caps addFeature urn:xmpp:jingle:apps:rtp:video
        $client caps addFeature urn:xmpp:jingle:apps:dtls:0
        $client caps addFeature urn:xmpp:jingle:transports:ice-udp:1
        $client caps addFeature urn:xmpp:jingle-message:0
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client iq unhandler set urn:xmpp:jingle:1}
        foreach sid [dict keys $Calls] {
            $self TeardownMedia $sid
            $self CancelInterrupted $sid
            $self StopRingTimer $sid
            $self StopSetupTimer $sid
            $self CancelRestartWait $sid
            $self MediaBack $sid
        }
    }

    # The session is ending (taco_client endSession): every call ends while
    # the link is still up to say so - a ringing one is declined, a proposed
    # one retracted, the rest terminated as gone.
    method OnClosing {args} {
        foreach sid [dict keys $Calls] {
            if {[catch {$self reject -sid $sid -reason gone} err]} {
                jlog warn "call $sid: ending it on close: $err"
                catch {$self TeardownMedia $sid}
                catch {$self Cleanup $sid}
            }
        }
    }

    # =========================================================================
    # Public API
    # =========================================================================

    tackymethod start {args} {
        array set opts {-to "" -video 0}
        array set opts $args
        if {$opts(-to) eq ""} { error "start: -to required" }

        set why [$self Blocked]
        if {$why ne ""} { error [string tolower $why 0 0] }

        set bare [jid bare $opts(-to)]
        set sid [$self NewSid]
        set wantVideo [expr {$opts(-video) ? 1 : 0}]
        dict set Calls $sid [$self NewCallDict $bare 1 proposed $wantVideo]
        $self StartRingTimer $sid
        $client emit calls <Outgoing> -sid $sid -to $bare -video $wantVideo
        $client write [$self BuildJmiMessage $bare propose $sid 1 $wantVideo \
            [$self AnnounceDevice $sid]]
        return $sid
    }

    # Why calls are ruled out, as a sentence, or "" when they are not. A
    # proxy does: ICE sends UDP, which a SOCKS5 CONNECT tunnel can't carry,
    # so media would go around the proxy. So does a disabled account, which
    # touches no network.
    method Blocked {} {
        if {![$client cget -enabled]} {
            return "Calls are unavailable while the account is disabled"
        }
        if {[$client conn cget -proxy] ne ""} {
            return "Calls are disabled while a proxy is configured"
        }
        return ""
    }

    # Per-call state dict. peer is bare until proceeded, then full JID.
    # video_local  : 1 if this side offered/wants to send video
    # video_remote : 1 if the peer's propose advertised media=video
    # vtrack       : media handle of the video track, -1 when absent
    # vsend/vrecv  : 1 once we have asked the backend for that half and it
    #                has not reported the attach failed
    method NewCallDict {peer initiator state wantVideo {group ""}} {
        return [dict create \
            peer $peer initiator $initiator state $state transport idle \
            jingle 0 self_jid [$client cget -jid] peer_ringing 0 \
            ever_connected 0 restarts 0 restart_attempts 0 \
            group $group pc -1 track -1 \
            video_local $wantVideo video_remote 0 \
            vtrack -1 vsend 0 vrecv 0 active_since 0]
    }

    # Move $sid's $machine (state or transport) to $to. A move its table
    # does not list is refused, logged and kept in IllegalMoves; staying
    # where it is is no move. Returns 1 if it moved.
    method Go {sid machine to} {
        set from [dict get $Calls $sid $machine]
        if {$from eq $to} { return 0 }
        set table [expr {$machine eq "state" ? $SESSION_NEXT : $TRANSPORT_NEXT}]
        if {![dict exists $table $from] || $to ni [dict get $table $from]} {
            jlog error "call $sid: $machine $from -> $to is not a move"
            lappend IllegalMoves [list $sid $machine $from $to]
            return 0
        }
        dict set Calls $sid $machine $to
        if {$machine eq "state" && $to eq "proceeded"} {
            $self StopRingTimer $sid
            $self StartSetupTimer $sid
        }
        return 1
    }

    # The inbound Jingle table's word for $action in $sid's state.
    method JingleIn {sid action} {
        set row [dict get $JINGLE_IN [dict get $Calls $sid state]]
        if {[dict exists $row $action]} { return [dict get $row $action] }
        return [dict get $row *]
    }

    # The state `list` shows, as it always has: the session's until it is
    # pending, then the media path's.
    method PublicState {call} {
        set state [dict get $call state]
        if {$state in {proposed ringing}} { return $state }
        if {$state eq "proceeded" && [dict get $call transport] eq "idle"} {
            return $state
        }
        switch -- [dict get $call transport] {
            idle      { return new }
            connected { return active }
            default   { return connecting }
        }
    }

    # The end of every call. Drops the media, tells the peer as far as it
    # knows the call, reports it once, and forgets it:
    #   $event   Ended or Failed
    #   $reason  <Ended>'s -reason, or <Failed>'s text
    #   $wire    the XEP-0166 condition to terminate the session with, or
    #            "" when the peer already knows (it ended it) or there is
    #            no session to end (RetractProposed and the JMI paths
    #            write their own message)
    # A Jingle session that existed also gets JMI <finish/> (XEP-0353
    # §3.5), so every device of both sides learns the call is over.
    method Finish {sid event reason {wire ""}} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        set peer [dict get $call peer]
        $self TeardownMedia $sid
        if {$wire ne ""} {
            $self SendTerminate $sid $peer $wire
        }
        if {[dict get $call jingle] && [dict get $call group] eq ""
                && [jid resource $peer] ne ""} {
            set why [expr {$event eq "Failed" ? "connectivity-error" : "success"}]
            if {$wire ne ""} { set why $wire }
            $client write [$self BuildJmiFinish $peer $sid $why]
        }
        if {$event eq "Failed"} {
            jlog warn "call $sid with $peer failed: $reason"
        }
        $client emit calls <$event> -sid $sid -reason $reason
        $self Cleanup $sid
    }

    # Answered: the call has SETUP_TIMEOUT_MS to first connect.
    method StartSetupTimer {sid} {
        if {[dict exists $Calls $sid setup_timer]} return
        dict set Calls $sid setup_timer \
            [after $SETUP_TIMEOUT_MS [mymethod SetupTimeout $sid]]
    }

    method StopSetupTimer {sid} {
        if {![dict exists $Calls $sid setup_timer]} return
        after cancel [dict get $Calls $sid setup_timer]
        dict unset Calls $sid setup_timer
    }

    method SetupTimeout {sid} {
        if {![dict exists $Calls $sid setup_timer]} return
        dict unset Calls $sid setup_timer
        if {[dict get $Calls $sid ever_connected]} return
        $self Finish $sid Failed \
            "no media path within [expr {$SETUP_TIMEOUT_MS / 1000}] s" timeout
    }

    # One group-call session to a participant's full JID, straight to media and
    # session-initiate (no JMI). Returns the sid.
    method StartGroupSession {args} {
        array set opts {-room "" -peer "" -video 0}
        array set opts $args
        if {$opts(-room) eq "" || $opts(-peer) eq ""} {
            error "StartGroupSession: -room and -peer required"
        }
        set sid [$self NewSid]
        set wantVideo [expr {$opts(-video) ? 1 : 0}]
        dict set Calls $sid [$self NewCallDict $opts(-peer) 1 proceeded \
            $wantVideo [jid norm $opts(-room)]]
        $self StartSetupTimer $sid
        $client extdisco fetch -command [mymethod StartOutgoingMedia $sid]
        return $sid
    }

    tackymethod accept {args} {
        array set opts {-sid ""}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} {
            error "accept: no such call $opts(-sid)"
        }
        set call [dict get $Calls $opts(-sid)]
        set state [dict get $call state]
        if {$state eq "ringing"} {
            # JMI: tell the caller we're picking up; flip to proceeded.
            # Media setup is deferred until session-initiate arrives.
            set peer [dict get $call peer]
            $client write [$self BuildJmiMessage $peer proceed $opts(-sid) 0 0 \
                [$self AnnounceDevice $opts(-sid)]]
            $self Go $opts(-sid) state proceeded
            return
        }
        # If session-initiate already landed, HandleSessionInitiate did
        # all the work; nothing left to do here.
        return
    }

    tackymethod reject {args} {
        array set opts {-sid "" -reason decline}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set call [dict get $Calls $opts(-sid)]
        set state [dict get $call state]
        if {$state eq "ringing"} {
            $self DeclineRinging $opts(-sid)
            return
        }
        if {$state eq "proposed"} {
            $self RetractProposed $opts(-sid) [dict get $call peer] retracted
            return
        }
        $self EndSession $opts(-sid) [dict get $call peer] $opts(-reason)
    }

    tackymethod hangup {args} {
        array set opts {-sid "" -reason success}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set call [dict get $Calls $opts(-sid)]
        switch -- [dict get $call state] {
            proposed {
                $self RetractProposed $opts(-sid) [dict get $call peer] retracted
                return
            }
            ringing {
                # Hanging up on a ring is declining it: there is no session
                # to terminate yet.
                $self DeclineRinging $opts(-sid)
                return
            }
        }
        $self EndSession $opts(-sid) [dict get $call peer] $opts(-reason)
    }

    # Turn down a call ringing here (XEP-0353 <reject/>).
    method DeclineRinging {sid} {
        $client write [$self BuildJmiMessage [dict get $Calls $sid peer] reject $sid 0]
        $self Finish $sid Ended declined
    }

    # End a session that reached Jingle: drop the media, tell the peer, and
    # report it gone.
    method EndSession {sid peer reason} {
        $self Finish $sid Ended hangup $reason
    }

    # RingTimeout rechecks the state: it can fire in the same turn as an
    # accept or proceed.
    method StartRingTimer {sid} {
        dict set Calls $sid ring_timer \
            [after $RING_TIMEOUT_MS [mymethod RingTimeout $sid]]
    }

    method StopRingTimer {sid} {
        if {![dict exists $Calls $sid ring_timer]} return
        after cancel [dict get $Calls $sid ring_timer]
        dict unset Calls $sid ring_timer
    }

    # Ours is retracted; theirs is rejected with <timeout/> and missed.
    method RingTimeout {sid} {
        if {![dict exists $Calls $sid]} return
        dict unset Calls $sid ring_timer
        set call [dict get $Calls $sid]
        set peer [dict get $call peer]
        switch -- [dict get $call state] {
            proposed {
                if {[dict get $call initiator]} {
                    $self RetractProposed $sid $peer timeout
                }
            }
            ringing {
                $client write [$self BuildJmiReject $peer $sid timeout]
                $self Finish $sid Ended timeout
                $self EmitMissed $sid $peer [dict get $call video_remote] timeout
            }
        }
    }

    method EmitMissed {sid from video reason} {
        $client emit calls <Missed> -sid $sid -from [jid bare $from] \
            -video $video -reason $reason
    }

    # Fail a session that reached Jingle: emit <Failed>, drop the media and
    # terminate with $jingleReason.
    method FailCall {sid reason jingleReason} {
        $self Finish $sid Failed $reason $jingleReason
    }

    # =========================================================================
    # Verification (see the file header)
    # =========================================================================

    # Our OMEMO device, if OMEMO is on for the chat with $peer and set up,
    # and our published devicelist names it: an announced device obliges
    # the peer to seal for it, and one its fetch of our list does not show
    # fails the call closed.
    method OwnDevice {peer} {
        if {[catch {
            set dev [$client omemo listed_device_id]
            set on [$client omemo isEnabled -jid [jid bare $peer]]
        }]} { return "" }
        expr {$on && [string is integer -strict $dev] && $dev > 0 ? $dev : ""}
    }

    # Our device for <propose>/<proceed>, or "". Records that we sent it.
    method AnnounceDevice {sid} {
        set dev [$self OwnDevice [dict get $Calls $sid peer]]
        if {$dev ne ""} { dict set Calls $sid announced 1 }
        return $dev
    }

    # Record the device from the peer's <propose>/<proceed> $child. The
    # caller also starts the session now so the offer doesn't wait on a
    # bundle fetch. The callee doesn't: the caller's prekey message will
    # create the session.
    method NotePeerDevice {sid child} {
        set dev [xsearch $child device -ns $NS_VERIFY -get @id]
        if {![string is integer -strict $dev] || $dev <= 0} return
        dict set Calls $sid peer_device $dev
        set peer [jid bare [dict get $Calls $sid peer]]
        if {[dict get $Calls $sid initiator] && [$self OwnDevice $peer] ne ""} {
            catch {$client omemo readySession $peer $dev}
        }
    }

    # Decrypt the fingerprints in the peer's session-initiate/accept and
    # return the jingle with plain ones, or "" if the call was failed.
    # $expect: the fingerprint must be encrypted (ours was).
    method TakeFingerprints {sid stanza jingle from expect} {
        if {[dict get $Calls $sid group] ne ""} { return $jingle }
        set peer [jid bare $from]
        set encrypted 0
        set plain 0
        set by ""
        foreach slot [::taco_calls::verify::transports $jingle] {
            set transport [::taco_calls::verify::get $jingle $slot]
            set fp [::taco_calls::verify::plain $transport]
            set efp [xsearch $transport fingerprint -ns $NS_VERIFY -get node]
            if {$efp eq ""} { incr plain; continue }
            if {$fp ne ""} {
                return [$self FailUnverified $sid $stanza \
                    "a fingerprint came both plain and encrypted"]
            }
            set enc [xsearch $efp encrypted -ns $NS_AXOLOTL -get node]
            if {$enc eq ""} {
                return [$self FailUnverified $sid $stanza \
                    "an encrypted fingerprint without its encryption"]
            }
            set r [$client omemo decryptFrom $enc $peer]
            if {[dict get $r status] ne "ok"} {
                return [$self FailUnverified $sid $stanza [dict get $r reason]]
            }
            if {$by ne "" && [dict get $r device] != [dict get $by device]} {
                return [$self FailUnverified $sid $stanza \
                    "fingerprints from two devices"]
            }
            set by $r
            lassign [xsearch $efp -get {@hash @setup}] hash setup
            set body [string trim [dict get $r plaintext]]
            if {[catch {::jinglesdp::CheckFingerprint $hash $body $setup}]} {
                return [$self FailUnverified $sid $stanza \
                    "the encrypted fingerprint is not a fingerprint"]
            }
            set jingle [::taco_calls::verify::put $jingle $slot \
                [::taco_calls::verify::decrypted $transport $hash $setup $body]]
            incr encrypted
        }
        if {$encrypted && $plain} {
            return [$self FailUnverified $sid $stanza \
                "only some fingerprints were encrypted"]
        }
        if {$expect && !$encrypted} {
            return [$self FailUnverified $sid $stanza \
                "the fingerprint was not encrypted"]
        }
        if {$by eq ""} {
            dict set Calls $sid verified 0
            dict set Calls $sid fingerprint ""
        } else {
            dict set Calls $sid omemo_device [dict get $by device]
            dict set Calls $sid fingerprint [dict get $by fingerprint]
            dict set Calls $sid verified [dict get $by accepted]
        }
        $self EmitVerified $sid
        return $jingle
    }

    # Ack the IQ and end the session with security-error, as Conversations
    # does. Returns "".
    method FailUnverified {sid stanza reason} {
        $self AckIq $stanza
        $self FailCall $sid "call could not be verified: $reason" security-error
        return ""
    }

    method EmitVerified {sid} {
        $client emit calls <Verified> -sid $sid \
            -verified [dict get $Calls $sid verified] \
            -fingerprint [dict get $Calls $sid fingerprint]
    }

    # Trust or blind trust changed: recheck live calls. Any of the peer's
    # keys matters, since verifying one ends blind trust for the others.
    method OnTrustChanged {args} { $self Reverify [dict get $args -jid] }
    method OnBlindTrust {args} { $self Reverify "" }

    # Recheck calls with $peer, or all calls when $peer is "".
    method Reverify {peer} {
        dict for {sid call} $Calls {
            if {![dict exists $call omemo_device]} continue
            set bare [jid bare [dict get $call peer]]
            if {$peer ne "" && $bare ne $peer} continue
            set verified [$client omemo deviceAccepted $bare \
                [dict get $call omemo_device]]
            if {$verified == [dict get $call verified]} continue
            dict set Calls $sid verified $verified
            $self EmitVerified $sid
        }
    }

    # Every call in flight, one dict each, unordered. The only way to
    # learn a sid you did not see <Outgoing>/<Incoming> for, which is what
    # a client that restarted needs. Cleanup drops a session in the same
    # frame that ends it, so nothing terminal is ever in here. peer is
    # bare, as the events report it, even once proceed has latched a full
    # JID.
    tackymethod list {args} {
        set out {}
        dict for {sid call} $Calls {
            if {[dict get $call initiator]} {
                set direction outgoing
            } else {
                set direction incoming
            }
            lappend out [dict create \
                sid          $sid \
                peer         [jid bare [dict get $call peer]] \
                direction    $direction \
                state        [$self PublicState $call] \
                connection   [$self ConnectionState $call] \
                peer_ringing [dict get $call peer_ringing] \
                group        [dict get $call group] \
                video_local  [dict get $call video_local] \
                video_remote [dict get $call video_remote] \
                verified     [dict getdef $call verified 0] \
                fingerprint  [dict getdef $call fingerprint ""] \
                active_since [dict get $call active_since]]
        }
        return $out
    }

    # Mute / unmute the local camera on a live video call. Video is
    # negotiated at start/answer; this only toggles capture.
    tackymethod setVideo {args} {
        array set opts {-sid "" -on 1}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set pc [dict get $Calls $opts(-sid) pc]
        if {$pc eq -1} return
        ::tacky::media setVideoEnabled $pc -on [expr {$opts(-on) ? 1 : 0}]
        return
    }

    # Hot-swap mic / speaker for a live call. Empty id = system default.
    # A backend with nothing attached yet ignores it; one that refuses the
    # device answers with an error event, which OnMediaError turns into a
    # <Warning>.
    tackymethod setDevices {args} {
        array set opts {-sid "" -input __unset__ -output __unset__}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set pc [dict get $Calls $opts(-sid) pc]
        if {$pc eq -1} return
        if {![::tacky::media capability audioDevices]} return
        if {$opts(-input) ne "__unset__"} {
            ::tacky::media setAudioDevice $pc -kind capture -id $opts(-input)
        }
        if {$opts(-output) ne "__unset__"} {
            ::tacky::media setAudioDevice $pc -kind playback -id $opts(-output)
        }
        return
    }

    # Hook called by the global `video` module after the preferred
    # camera changes - hot-swap the camera on every live video call.
    tackymethod applyPreferredCamera {args} {
        array set opts {-id ""}
        array set opts $args
        if {![::tacky::media capability videoDevice]} return
        foreach sid [dict keys $Calls] {
            if {![dict get $Calls $sid vsend]} continue
            ::tacky::media setVideoDevice [dict get $Calls $sid pc] -id $opts(-id)
        }
        return
    }

    # Hook called by the global `audio` module after the preferred
    # device changes — hot-swap every live call on this client.
    tackymethod applyPreferredDevice {args} {
        array set opts {-kind "" -id ""}
        array set opts $args
        set flag [expr {$opts(-kind) eq "capture" ? "-input" : "-output"}]
        foreach sid [dict keys $Calls] {
            $self setDevices -sid $sid $flag $opts(-id)
        }
        return
    }

    # Hook called by the global `audio` module after the volume changes —
    # hot-swap every live call on this client. Values in [0.0, 1.0]. A call
    # with no audio attached yet is a no-op in the backend; a value the
    # backend rejects surfaces as <Warning> and the call keeps running.
    tackymethod applyVolume {args} {
        array set opts {-kind "" -volume ""}
        array set opts $args
        if {![::tacky::media capability audioVolume]} return
        foreach sid [dict keys $Calls] {
            set pc [dict get $Calls $sid pc]
            if {$pc eq -1} continue
            ::tacky::media setAudioVolume $pc \
                -kind $opts(-kind) -volume $opts(-volume)
        }
        return
    }

    # =========================================================================
    # PC + media plumbing
    # =========================================================================

    # Create a fresh pc and bind its events to this sid. Caller side then
    # adds tracks and attaches media; callee side drives
    # setRemoteDescription and attaches from the `track` events.
    # The pc is recorded only once createPeer took it, so a refused one
    # leaves nothing to close.
    method CreatePc {sid iceServers} {
        # The last word for every path into media, ours or the peer's.
        set why [$self Blocked]
        if {$why ne ""} {
            error [string tolower $why 0 0]
        }
        set pc $self/$sid
        ::tacky::media createPeer $pc -sid $sid \
            -command [mymethod OnMediaEvent $sid] -ice-servers $iceServers
        dict set Calls $sid pc $pc
        return $pc
    }

    # Attach the mic + speaker to a track. The persisted
    # audio_input_device / audio_output_device settings pin specific
    # endpoints; a backend that cannot open one falls back to its default
    # and says so with deviceFallback, so a stale setting - a device that
    # went away, or an id stored against another backend - can't brick
    # every call.
    method AttachMedia {sid track} {
        set taco [$client cget -taco]
        dict set Calls $sid track $track
        ::tacky::media attachAudio [dict get $Calls $sid pc] $track \
            -input         [$taco audio getPreferredDevice -kind capture] \
            -output        [$taco audio getPreferredDevice -kind playback] \
            -input-volume  [$taco audio getVolume -kind capture] \
            -output-volume [$taco audio getVolume -kind playback]
    }

    # Camera -> the peer, plus a self-view: the backend answers with a
    # preview videoChannel, which OnVideoChannel turns into <VideoPreview>.
    method AttachVideoSender {sid track} {
        if {[dict get $Calls $sid vsend]} return
        set taco [$client cget -taco]
        set camId ""
        catch {set camId [$taco video getPreferredCamera]}
        dict set Calls $sid vsend 1
        ::tacky::media attachVideoSender [dict get $Calls $sid pc] $track \
            -device-id $camId
    }

    # The peer's camera -> a frame channel. The backend answers with an
    # incoming videoChannel, which OnVideoChannel turns into <VideoTrack>.
    method AttachVideoReceiver {sid track} {
        if {[dict get $Calls $sid vrecv]} return
        dict set Calls $sid vtrack $track
        dict set Calls $sid vrecv 1
        ::tacky::media attachVideoReceiver [dict get $Calls $sid pc] $track
    }

    # Turn a backend video channel descriptor into calls-event -flag args.
    # A frame stream is named; a host-rendered channel just carries its id.
    method VideoEventArgs {ch} {
        set out {}
        foreach key {name id} {
            if {[dict exists $ch $key]} {
                lappend out -$key [dict get $ch $key]
            }
        }
        return $out
    }

    # Free media + pc for one call. The backend owns the ordering its own
    # handles need; all this decides is whether the video half was ever up,
    # since <VideoEnded> is owed only then.
    method TeardownMedia {sid} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        set hadVideo [expr {[dict get $call vsend] || [dict get $call vrecv]}]
        if {[dict get $call pc] ne -1} {
            ::tacky::media closePeer [dict get $call pc]
        }
        if {$hadVideo} {
            $client emit calls <VideoEnded> -sid $sid -mid $VIDEO_MID
        }
        dict set Calls $sid pc     -1
        dict set Calls $sid track  -1
        dict set Calls $sid vtrack -1
        dict set Calls $sid vsend  0
        dict set Calls $sid vrecv  0
    }

    # =========================================================================
    # tacky::media events (async, delivered on the Tcl main thread)
    # =========================================================================

    # One sink per call; $sid was bound at createPeer. A call torn down
    # while the backend still had events queued is gone from Calls, and the
    # check here is what every handler below relies on to assume it is not.
    method OnMediaEvent {sid ev} {
        if {![dict exists $Calls $sid]} return
        # SDP is logged where it is sent.
        if {[dict get $ev type] ne "localDescription"} {
            jlog debug "media event (sid=$sid): [dict remove $ev pc]"
        }
        switch -- [dict get $ev type] {
            localDescription {
                $self OnLocalDescription $sid \
                    [dict get $ev sdp] [dict get $ev sdpType]
            }
            iceCandidate {
                $self OnLocalCandidate $sid \
                    [dict get $ev candidate] [dict get $ev mid]
            }
            connectionState { $self OnPcState $sid [dict get $ev state] }
            gatheringState  { $self OnGatheringState $sid [dict get $ev state] }
            track           { $self OnTrack $sid $ev }
            videoChannel    { $self OnVideoChannel $sid $ev }
            deviceFallback  { $self OnDeviceFallback $sid $ev }
            error           { $self OnMediaError $sid $ev }
        }
    }

    # Fires once per setLocalDescription, and on the responder once more
    # when an `autoAnswer` backend generates the answer inside
    # setRemoteDescription. The SDP here has no candidates yet — those
    # arrive asynchronously and are trickled separately.
    method OnLocalDescription {sid sdp sdpType} {
        set call [dict get $Calls $sid]
        set me [$client cget -jid]
        set isInitiator [dict get $call initiator]

        # A backend declaring `sdpSanitize` advertises more on the wire
        # than it honours. rtc-ma sends raw RTP (no media handler on the
        # track) and honours neither negotiated RTP header extensions nor
        # transport-cc feedback, while libdatachannel auto-echoes the
        # remote offer's extmaps into our answer — notably sdes:mid, which
        # libwebrtc peers then expect for transceiver routing in
        # UNIFIED_PLAN and without which they drop every packet we send.
        # See the SDP sanitization block in include/rtcma.h.
        if {[::tacky::media capability sdpSanitize]} {
            regsub -all -line {^a=extmap(-allow-mixed)?.*\n}      $sdp "" sdp
            regsub -all -line {^a=rtcp-fb:[^ ]+ transport-cc.*\n} $sdp "" sdp
        }

        jlog debug "SDP $sdpType to [dict get $call peer] (sid=$sid)\n[jlog_redact_sdp $sdp]"

        # Kept for the candidates that trickle after it: XEP-0176 5.3 has
        # every transport-info carry them.
        if {[regexp -line {^a=ice-ufrag:(\S+)} $sdp -> ufrag]} {
            dict set Calls $sid ufrag $ufrag
        }
        if {[regexp -line {^a=ice-pwd:(\S+)} $sdp -> pwd]} {
            dict set Calls $sid pwd $pwd
        }
        # The DTLS role we took. An offer says actpass whoever made it -
        # our restart offer too - so only an answer's active/passive is
        # the role, and it lasts the session (RFC 9429 §5.3.3).
        if {[regexp -line {^a=setup:(active|passive)} $sdp -> setup]} {
            dict set Calls $sid local_setup $setup
        }

        # A description of an ICE restart goes out as one, never as the
        # session's own.
        if {[dict get $call transport] eq "restarting"} {
            $self OnRestartDescription $sid $sdp $sdpType
            return
        }

        # SDP->Jingle (creator stays "initiator" on both sides — the
        # responder echoes the initiator's content names verbatim).
        set jingle [::jinglesdp::from_sdp $sdp \
            -creator initiator -initiator $isInitiator]

        # Only the session's own descriptions go out as such: the caller's
        # first offer from proceeded, the callee's answer from pending. Any
        # other is a backend speaking out of turn and goes nowhere.
        set state [dict get $call state]
        if {!($sdpType eq "offer" && $isInitiator && $state eq "proceeded")
                && !($sdpType eq "answer" && !$isInitiator && $state eq "pending")} {
            jlog warn "call $sid: a local $sdpType in $state is not sent"
            return
        }

        if {$sdpType eq "offer"} {
            dict set jingle attrs action session-initiate
            dict set jingle attrs sid $sid
            dict set jingle attrs initiator $me
            if {[dict get $call group] ne ""} {
                # XEP-0272: a session belonging to a Muji conference says so.
                dict lappend jingle children \
                    [j muji -ns urn:xmpp:jingle:muji:0 -room [dict get $call group]]
            }
            # Sent: a crossing initiate is now settled by sid.
            dict set Calls $sid jingle 1
            $self Go $sid state pending
            $self SendDescription $sid $jingle OnInitiateAck
        } elseif {$sdpType eq "answer"} {
            dict set jingle attrs action session-accept
            dict set jingle attrs sid $sid
            dict set jingle attrs responder $me
            $self Go $sid state established
            $self SendDescription $sid $jingle OnAcceptAck
        }
    }

    # Send our session-initiate/accept. If both sides announced a device,
    # encrypt the fingerprints first; local candidates are held meanwhile.
    # If encryption fails the call fails; we never fall back to plain.
    method SendDescription {sid jingle ack} {
        set call [dict get $Calls $sid]
        if {[dict get $call group] ne "" || ![dict exists $call announced]
                || ![dict exists $call peer_device]} {
            $self ShipDescription $sid $jingle $ack
            return
        }
        dict set Calls $sid describing 1
        $self EncryptFingerprints $sid $jingle $ack \
            [::taco_calls::verify::transports $jingle]
    }

    method EncryptFingerprints {sid jingle ack slots} {
        if {![dict exists $Calls $sid]} return
        if {[llength $slots] == 0} {
            dict set Calls $sid fingerprint_encrypted 1
            $self ShipDescription $sid $jingle $ack
            return
        }
        set slot [lindex $slots 0]
        set fp [::taco_calls::verify::plain [::taco_calls::verify::get $jingle $slot]]
        if {$fp eq ""} {
            $self EncryptFingerprints $sid $jingle $ack [lrange $slots 1 end]
            return
        }
        set call [dict get $Calls $sid]
        $client omemo encryptFor [jid bare [dict get $call peer]] \
            [dict get $call peer_device] [dict get $fp body] \
            [mymethod AfterEncryptFingerprint $sid $jingle $ack $slots]
    }

    method AfterEncryptFingerprint {sid jingle ack slots status enc} {
        if {![dict exists $Calls $sid]} return
        if {$status ne "ok"} {
            dict unset Calls $sid describing
            $self FailCall $sid "call could not be verified: $enc" security-error
            return
        }
        set slot [lindex $slots 0]
        set jingle [::taco_calls::verify::put $jingle $slot \
            [::taco_calls::verify::encrypted \
                [::taco_calls::verify::get $jingle $slot] $enc]]
        $self EncryptFingerprints $sid $jingle $ack [lrange $slots 1 end]
    }

    method ShipDescription {sid jingle ack} {
        $client iq request -type set -to [dict get $Calls $sid peer] \
            -payload $jingle -command [mymethod $ack $sid]
        if {![dict exists $Calls $sid describing]} return
        dict unset Calls $sid describing
        if {![dict exists $Calls $sid held_candidates]} return
        foreach held [dict get $Calls $sid held_candidates] {
            $self OnLocalCandidate $sid {*}$held
        }
        dict unset Calls $sid held_candidates
    }

    # Trickle a single ICE candidate to the peer. The API carries the SDP
    # attribute form ("candidate:foo bar baz..."); we strip the
    # "candidate:" prefix so jinglesdp::BuildCandidate sees the same
    # shape it parses out of SDP. An empty mid falls back to the bundle
    # group's audio MID.
    method OnLocalCandidate {sid cand mid} {
        set call [dict get $Calls $sid]
        # Hold candidates until the description is sent, or our restart's
        # credentials are taken: one carrying the new credentials before
        # them would read as an answer to a restart nobody offered.
        if {[dict exists $call describing] || [dict exists $call restart_hold]} {
            dict set Calls $sid held_candidates [linsert \
                [dict getdef $call held_candidates {}] end [list $cand $mid]]
            return
        }
        set me [$client cget -jid]
        set isInitiator [dict get $call initiator]

        set value $cand
        if {[string match "candidate:*" $value]} {
            set value [string range $value 10 end]
        }
        if {$mid eq ""} { set mid $MID }

        set candNode [::jinglesdp::BuildCandidate $value]
        if {$candNode eq ""} return

        set iceAttrs {}
        foreach key {ufrag pwd} {
            if {[dict exists $call $key]} { lappend iceAttrs -$key [dict get $call $key] }
        }
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j content -creator initiator -name $mid {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 {*}$iceAttrs {
                    j #as-is $candNode
                }
            }
        }]
        dict set jingle attrs action transport-info
        dict set jingle attrs sid $sid
        if {$isInitiator} {
            dict set jingle attrs initiator $me
        } else {
            dict set jingle attrs responder $me
        }
        $client iq request -type set -to [dict get $call peer] -payload $jingle \
            -command [mymethod OnTransportInfoAck $sid]
    }

    # The peer answering our transport-info. One that no longer knows the
    # session (it ended it, and we missed the terminate, or it restarted)
    # ends it here too; any other error - a peer offline for a moment, a
    # server in the way - leaves the call to its media path.
    method OnTransportInfoAck {sid stanza} {
        if {![dict exists $Calls $sid]} return
        if {[xsearch $stanza -get @type] ne "error"} return
        if {[$self SessionUnknown $stanza]} {
            $self Finish $sid Failed "the peer no longer has the session"
        } elseif {[$self PeerOffline $stanza]} {
            $self Finish $sid Failed "the peer went offline"
        }
    }

    # Does the IQ error $stanza say the peer's resource is not there? Its
    # server answers so only for a resource that is gone - one whose stream
    # waits to be resumed has its stanzas held instead - and a call cannot
    # be kept up, or restarted, without signalling to it.
    method PeerOffline {stanza} {
        foreach condition {service-unavailable recipient-unavailable} {
            if {[xsearch $stanza error $condition \
                    -ns urn:ietf:params:xml:ns:xmpp-stanzas -get node] ne ""} {
                return 1
            }
        }
        return 0
    }

    # Does the IQ error $stanza say the peer has no such session?
    method SessionUnknown {stanza} {
        expr {[xsearch $stanza error unknown-session \
                    -ns urn:xmpp:jingle:errors:1 -get node] ne ""
            || [xsearch $stanza error item-not-found \
                    -ns urn:ietf:params:xml:ns:xmpp-stanzas -get node] ne ""}
    }

    # Informational only — kept for visibility / future logging hooks. No
    # wire effect; the SDP ships from OnLocalDescription and candidates
    # trickle via OnLocalCandidate.
    method OnGatheringState {sid state} {
        return
    }

    method OnInitiateAck {sid stanza} {
        # Already dropped for a crossing initiate; the peer answers it with
        # <tie-break/>.
        if {![dict exists $Calls $sid]} return
        if {[xsearch $stanza -get @type] eq "error"} {
            # <tie-break/>: the peer kept its own initiate; not a refusal.
            set lost [expr {[xsearch $stanza error tie-break \
                -ns urn:xmpp:jingle:errors:1 -get node] ne ""}]
            $self Finish $sid Failed [expr {$lost
                ? "session-initiate lost a tie-break" : "session-initiate rejected"}]
        }
    }

    method OnAcceptAck {sid stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $client emit calls <Warning> -sid $sid -reason "session-accept rejected"
        }
    }

    # The backend's connectionState drives the transport machine:
    #
    #   new          nothing yet
    #   connecting   idle -> checking; after a connect, the backend looking
    #                for a path again by itself (checking)
    #   connected    -> connected: <Active> (again after an interruption,
    #                with the first connect's -since)
    #   disconnected -> interrupted: consent lost, which the backend may
    #                recover from; said once it lasts DISCONNECT_GRACE_MS,
    #                since a hanging-up peer drops ICE first and its
    #                session-terminate lands inside that, and restarted
    #                once it lasts RESTART_AFTER_MS
    #   failed       the path is gone: restarted if we can, else waited on
    #                for the peer's restart if we could follow one, else
    #                the call fails
    #   closed       the pc closed under us: the call ends
    #
    # While a restart is under way only `connected` (it worked) and
    # `closed` count: the old path failing meanwhile is expected, and
    # RESTART_WAIT_MS judges the new one. A backend whose path never broke
    # (the peer restarted over a path that works here) may report nothing
    # at all, staying connected throughout; pc_state, its last word, lets
    # the restart end on that once its descriptions are in (RestartSettled).
    #
    # The pre-media events (<Outgoing>, <Incoming>, <Ringing>) come from the
    # JMI handlers, not from here.
    method OnPcState {sid state} {
        # A late event for a call already gone must not bring it back.
        if {![dict exists $Calls $sid]} return
        dict set Calls $sid pc_state $state
        set transport [dict get $Calls $sid transport]
        if {$transport eq "restarting" && $state ni {connected closed}} return
        switch -- $state {
            new {}
            connecting {
                $self Go $sid transport checking
            }
            connected {
                # Said again of a path already up, it is no news.
                if {$transport eq "connected"} return
                $self CancelInterrupted $sid
                $self EndRestart $sid
                $self Go $sid transport connected
                $self OnConnected $sid
            }
            disconnected {
                if {[$self Go $sid transport interrupted]} {
                    $self MediaLost $sid
                    dict set Calls $sid disconnect_timer \
                        [after $DISCONNECT_GRACE_MS [mymethod WarnInterrupted $sid]]
                }
            }
            failed {
                if {[$self StartRestart $sid "the media path failed"]} return
                if {[$self AwaitPeerRestart $sid]} return
                # The peer is told in Jingle: a peer that ends a session
                # only on session-terminate (another.im's Android app)
                # otherwise keeps the call up, its video frozen.
                $self Finish $sid Failed "media path failed (ICE/DTLS)" \
                    connectivity-error
            }
            closed {
                $self Finish $sid Ended hangup success
            }
        }
    }

    # Media flows: the first time it stamps the call and ends the setup
    # timer; every time it is <Active>, with the first stamp, and a
    # <Connection> that takes back an interruption the GUI was told of.
    method OnConnected {sid} {
        $self MediaBack $sid
        if {![dict get $Calls $sid ever_connected]} {
            dict set Calls $sid ever_connected 1
            dict set Calls $sid active_since [clock microseconds]
            $self StopSetupTimer $sid
        }
        $client emit calls <Active> -sid $sid \
            -since [dict get $Calls $sid active_since]
        if {[dict exists $Calls $sid told_interrupted]} {
            dict unset Calls $sid told_interrupted
            dict unset Calls $sid told_connection
            jlog debug "call $sid: <Connection> connected"
            $client emit calls <Connection> -sid $sid -state connected
        }
    }

    method WarnInterrupted {sid} {
        if {![dict exists $Calls $sid disconnect_timer]} return
        dict set Calls $sid disconnect_timer \
            [after [expr {max(0, $RESTART_AFTER_MS - $DISCONNECT_GRACE_MS)}] \
                [mymethod RestartInterrupted $sid]]
        $self TellConnection $sid interrupted
        $client emit calls <Warning> -sid $sid -reason "media path interrupted"
    }

    # Still interrupted: the backend did not recover by itself.
    method RestartInterrupted {sid} {
        if {![dict exists $Calls $sid disconnect_timer]} return
        dict unset Calls $sid disconnect_timer
        if {[dict get $Calls $sid transport] ne "interrupted"} return
        $self StartRestart $sid "the media path stayed interrupted"
    }

    method CancelInterrupted {sid} {
        if {![dict exists $Calls $sid disconnect_timer]} return
        after cancel [dict get $Calls $sid disconnect_timer]
        dict unset Calls $sid disconnect_timer
    }

    # <Connection> $state, said once per change. Anything said but
    # `connected` is taken back by OnConnected.
    method TellConnection {sid state} {
        if {[dict getdef $Calls $sid told_connection ""] eq $state} return
        dict set Calls $sid told_connection $state
        dict set Calls $sid told_interrupted 1
        jlog debug "call $sid: <Connection> $state"
        $client emit calls <Connection> -sid $sid -state $state
    }

    # Media stopped flowing: the call has MEDIA_LOSS_MAX_MS to get it back,
    # whatever is tried meanwhile.
    method MediaLost {sid} {
        if {[dict exists $Calls $sid loss_timer]} return
        dict set Calls $sid loss_timer \
            [after $MEDIA_LOSS_MAX_MS [mymethod MediaLostTooLong $sid]]
    }

    method MediaBack {sid} {
        if {![dict exists $Calls $sid loss_timer]} return
        after cancel [dict get $Calls $sid loss_timer]
        dict unset Calls $sid loss_timer
    }

    method MediaLostTooLong {sid} {
        if {![dict exists $Calls $sid loss_timer]} return
        dict unset Calls $sid loss_timer
        $self Finish $sid Failed \
            "no media for [expr {$MEDIA_LOSS_MAX_MS / 1000}] s" connectivity-error
    }

    # =========================================================================
    # ICE restart
    # =========================================================================
    #
    # A session that is up can move its media to a new path under new ICE
    # credentials, without a new session (XEP-0176 §5.9). The wire is
    # Conversations': the side restarting sends a transport-info carrying
    # its new ufrag/pwd and no candidates - the offer - and trickles its
    # candidates once that is acked. The other side applies the peer's
    # description under those credentials as an offer, and its answer's
    # credentials travel on the candidates it trickles; there is no answer
    # stanza. So a transport-info with new credentials and no candidates is
    # an offer, and one with candidates is the answer when we have an offer
    # out, else an offer too (taken broadly: some peer may send it so).
    #
    # Either side may restart. Both at once is settled as XEP-0166 settles
    # crossing actions: the initiator's wins. The initiator answers the
    # responder's offer with <conflict/><tie-break/>; the responder rolls
    # its own offer back and follows the initiator's. A responder whose
    # backend cannot roll back does not start restarts, only follows them.
    #
    # The `restart` field says where one stands while transport is
    # restarting:
    #   offering   we asked our backend for a restart offer
    #   awaiting   our offer is out; the peer's answer has not come
    #   answering  we applied the peer's offer and owe our answer
    #   answered   our answer's credentials go out with our candidates
    # Each has RESTART_WAIT_MS of live signalling to connect.

    # Start a restart of our own, if this call and backend can: returns 1 if
    # one is under way (started now, or already).
    method StartRestart {sid why} {
        set call [dict get $Calls $sid]
        if {[dict get $call transport] eq "restarting"} { return 1 }
        if {![$self CanRestart $sid]} { return 0 }
        jlog inform "call $sid: $why, restarting ICE\
            ([expr {[dict get $call restarts] + 1}] of $MAX_RESTARTS)"
        $self CancelInterrupted $sid
        $self Go $sid transport restarting
        $self MediaLost $sid
        dict set Calls $sid restart offering
        dict set Calls $sid restarts [expr {[dict get $Calls $sid restarts] + 1}]
        dict set Calls $sid restart_attempts [expr {[dict get $Calls $sid restart_attempts] + 1}]
        dict set Calls $sid restart_hold 1
        $self TellConnection $sid reconnecting
        $self ArmRestartWait $sid
        if {[catch {::tacky::media setLocalDescription [dict get $call pc] \
                -type offer -ice-restart 1} err]} {
            jlog warn "call $sid: the restart offer was refused: $err"
            $self RestartFailed $sid
        }
        return 1
    }

    method CanRestart {sid} {
        set call [dict get $Calls $sid]
        expr {[dict get $call state] eq "established" && [dict get $call pc] ne -1
            && [dict exists $call remote_jingle]
            && [::tacky::media capability restartIce]
            && ([dict get $call initiator] || [::tacky::media capability rollback])
            && [dict get $call restarts] < $MAX_RESTARTS
            && [dict get $call restart_attempts] < $MAX_RESTART_ATTEMPTS}
    }

    # We cannot restart, but the peer can and we could follow: give it the
    # time a restart gets. Returns 1 if waiting.
    method AwaitPeerRestart {sid} {
        set call [dict get $Calls $sid]
        if {![::tacky::media capability iceRestart]
                || [dict get $call state] ne "established"
                || ![dict exists $call remote_jingle]
                || [dict get $call restart_attempts] >= $MAX_RESTART_ATTEMPTS} {
            return 0
        }
        jlog inform "call $sid: the media path failed; waiting for the peer to restart it"
        $self Go $sid transport interrupted
        $self MediaLost $sid
        dict set Calls $sid restart_attempts [expr {[dict get $Calls $sid restart_attempts] + 1}]
        $self TellConnection $sid interrupted
        $self ArmRestartWait $sid
        return 1
    }

    # Our backend's description during a restart.
    method OnRestartDescription {sid sdp sdpType} {
        set restart [dict getdef $Calls $sid restart ""]
        if {$sdpType eq "offer" && $restart eq "offering"} {
            # Lost a glare before our offer even existed: drop it, and
            # follow the initiator's offer that won.
            if {[dict exists $Calls $sid glare_offer]} {
                dict set Calls $sid restart awaiting
                $self RollBackAndFollow $sid
                return
            }
            dict set Calls $sid restart awaiting
            $self SendIceCredentials $sid $sdp
            return
        }
        if {$sdpType eq "answer" && $restart eq "answering"} {
            dict set Calls $sid restart answered
            $self ReleaseLocalCandidates $sid
            $self RestartSettled $sid
            return
        }
        jlog warn "call $sid: a local $sdpType during restart $restart is not sent"
    }

    # The credentials of our restart offer, alone, one <transport> per
    # content (XEP-0176 §5.9). Candidates wait for the IQ result.
    method SendIceCredentials {sid sdp} {
        set call [dict get $Calls $sid]
        set me [$client cget -jid]
        set local [::jinglesdp::from_sdp $sdp -creator initiator \
            -initiator [dict get $call initiator]]
        set contents {}
        foreach c [xsearch $local content -gather node] {
            set t [xsearch $c transport -ns urn:xmpp:jingle:transports:ice-udp:1 -get node]
            if {$t eq ""} continue
            lassign [xsearch $t -get {@ufrag @pwd}] ufrag pwd
            lappend contents [j content -creator initiator -name [xsearch $c -get @name] {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 \
                    -ufrag $ufrag -pwd $pwd
            }]
        }
        set jingle [j jingle -ns urn:xmpp:jingle:1]
        dict set jingle attrs action transport-info
        dict set jingle attrs sid $sid
        dict set jingle attrs [expr {[dict get $call initiator] ? "initiator" : "responder"}] $me
        dict set jingle children $contents
        $client iq request -type set -to [dict get $call peer] -payload $jingle \
            -command [mymethod OnRestartOfferAck $sid]
    }

    # The peer took our restart offer: our candidates may follow. Turned
    # down with <tie-break/>, ours lost a glare to the initiator's offer,
    # which is coming (or came); anything else, the peer will not restart.
    method OnRestartOfferAck {sid stanza} {
        if {![dict exists $Calls $sid]} return
        if {[xsearch $stanza -get @type] ne "error"} {
            $self ReleaseLocalCandidates $sid
            return
        }
        if {[xsearch $stanza error tie-break -ns urn:xmpp:jingle:errors:1 -get node] ne ""} {
            jlog inform "call $sid: our ICE restart lost a tie-break"
            return
        }
        if {[$self SessionUnknown $stanza]} {
            $self Finish $sid Failed "the peer no longer has the session"
            return
        }
        if {[$self PeerOffline $stanza]} {
            $self Finish $sid Failed "the peer went offline"
            return
        }
        jlog warn "call $sid: the peer refused our ICE restart"
        $self RestartFailed $sid
    }

    method ReleaseLocalCandidates {sid} {
        if {![dict exists $Calls $sid restart_hold]} return
        dict unset Calls $sid restart_hold
        if {[dict exists $Calls $sid describing]} return
        set held [dict getdef $Calls $sid held_candidates {}]
        dict unset Calls $sid held_candidates
        foreach h $held { $self OnLocalCandidate $sid {*}$h }
    }

    # The peer restarted: $creds is content name -> its new <transport>.
    # Apply its description under them as an offer, and answer it. Returns
    # 1 if followed.
    method FollowRestart {sid creds} {
        set call [dict get $Calls $sid]
        if {![::tacky::media capability iceRestart] || [dict get $call pc] eq -1
                || ![dict exists $call remote_jingle]} {
            jlog warn "call $sid: the peer restarted ICE, which this backend cannot follow"
            $client emit calls <Warning> -sid $sid \
                -reason "the peer moved the call to a new connection, which this device cannot follow"
            return 0
        }
        jlog inform "call $sid: the peer restarted ICE; following"
        $self CancelInterrupted $sid
        $self Go $sid transport restarting
        $self MediaLost $sid
        dict set Calls $sid restart answering
        # A backend may report the new generation's candidates before our
        # answer, which names their credentials: they wait for it.
        dict set Calls $sid restart_hold 1
        $self TellConnection $sid reconnecting
        $self ArmRestartWait $sid
        set pc [dict get $call pc]
        set sdp [$self RemoteSdp $sid $creds actpass]
        if {$sdp eq ""} { return 1 }
        $self TakeRemoteIce $sid $creds
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type offer
        if {![dict exists $Calls $sid]} { return 1 }
        if {[$self TakeSdpError $sid] ne ""} {
            $self RestartFailed $sid
            return 1
        }
        if {![::tacky::media capability autoAnswer]} {
            ::tacky::media setLocalDescription $pc -type answer
            if {![dict exists $Calls $sid]} { return 1 }
        }
        $self DrainPendingCandidates $sid $pc
        return 1
    }

    # The peer's answer to our restart offer.
    method ApplyRestartAnswer {sid creds} {
        set call [dict get $Calls $sid]
        set sdp [$self RemoteSdp $sid $creds [$self PeerSetup $sid]]
        if {$sdp eq ""} return
        $self TakeRemoteIce $sid $creds
        dict set Calls $sid restart answered
        ::tacky::media setRemoteDescription [dict get $call pc] -sdp $sdp -type answer
        if {![dict exists $Calls $sid]} return
        if {[$self TakeSdpError $sid] ne ""} {
            $self RestartFailed $sid
            return
        }
        $self DrainPendingCandidates $sid [dict get $call pc]
        $self RestartSettled $sid
    }

    # Both descriptions of a restart are in. A backend that never left
    # `connected` will not say so again: the path it has is the call's.
    method RestartSettled {sid} {
        if {![dict exists $Calls $sid]} return
        if {[dict get $Calls $sid transport] ne "restarting"} return
        if {[dict getdef $Calls $sid pc_state ""] ne "connected"} return
        $self OnPcState $sid connected
    }

    # We are the responder and both sides restarted at once: the
    # initiator's offer (glare_offer) wins. Our own offer, which must exist
    # by now for a rollback to drop it, goes with the candidates it
    # gathered; then theirs is followed. Until our backend has produced
    # ours (restart offering), OnRestartDescription waits for it.
    method RollBackAndFollow {sid} {
        if {[dict get $Calls $sid restart] eq "offering"} return
        set creds [dict get $Calls $sid glare_offer]
        dict unset Calls $sid glare_offer
        dict unset Calls $sid held_candidates
        ::tacky::media setLocalDescription [dict get $Calls $sid pc] -type rollback
        if {![dict exists $Calls $sid]} return
        dict unset Calls $sid restart
        $self CancelRestartWait $sid
        $self Go $sid transport interrupted
        $self FollowRestart $sid $creds
    }

    # The peer's description - its last, with the credentials and
    # candidates in $creds and the DTLS setup $setup - as SDP. "" if it
    # will not convert, which fails the restart.
    method RemoteSdp {sid creds setup} {
        set call [dict get $Calls $sid]
        set jingle [dict get $call remote_jingle]
        set first [lindex [dict values $creds] 0]
        set contents {}
        foreach c [dict get $jingle children] {
            if {[dict get $c tag] eq "content"} {
                set name [xsearch $c -get @name]
                set new [expr {[dict exists $creds $name]
                    ? [dict get $creds $name] : $first}]
                set kids {}
                foreach t [dict get $c children] {
                    if {[dict get $t tag] eq "transport"
                            && [dict get $t ns] eq "urn:xmpp:jingle:transports:ice-udp:1"} {
                        set t [$self RestartTransport $t $new $setup]
                    }
                    lappend kids $t
                }
                dict set c children $kids
            }
            lappend contents $c
        }
        dict set jingle children $contents
        set authorInitiator [expr {![dict get $call initiator]}]
        if {[catch {::jinglesdp::to_sdp $jingle -initiator $authorInitiator} sdp]} {
            jlog warn "call $sid: the restarted description does not convert: $sdp"
            $self RestartFailed $sid
            return ""
        }
        return $sdp
    }

    # Transport $old (the peer's last) under $new's credentials and
    # candidates, its fingerprint kept with setup $setup.
    method RestartTransport {old new setup} {
        lassign [xsearch $new -get {@ufrag @pwd}] ufrag pwd
        dict set old attrs ufrag $ufrag
        dict set old attrs pwd $pwd
        set kids {}
        foreach k [dict get $old children] {
            if {[dict get $k tag] eq "fingerprint"} {
                dict set k attrs setup $setup
                lappend kids $k
            }
        }
        foreach k [dict get $new children] {
            if {[dict get $k tag] eq "candidate"} { lappend kids $k }
        }
        dict set old children $kids
        return $old
    }

    # The DTLS role the peer took, which an answer to our restart offer
    # keeps (RFC 9429 §5.3.3): its own, or the other of ours where it
    # offered actpass.
    method PeerSetup {sid} {
        set jingle [dict get $Calls $sid remote_jingle]
        set setup [xsearch $jingle content transport fingerprint -get @setup]
        if {$setup in {active passive}} { return $setup }
        expr {[dict getdef $Calls $sid local_setup active] eq "active" ? "passive" : "active"}
    }

    # The peer's credentials are now those in $creds; the ones they
    # replace name a generation whose candidates are dropped.
    method TakeRemoteIce {sid creds} {
        set ice [dict getdef $Calls $sid remote_ice {}]
        set old [dict getdef $Calls $sid remote_old {}]
        dict for {name t} $creds {
            if {[dict exists $ice $name]} { lappend old [lindex [dict get $ice $name] 0] }
            dict set ice $name [xsearch $t -get {@ufrag @pwd}]
        }
        dict set Calls $sid remote_ice $ice
        dict set Calls $sid remote_old $old
    }

    # Note the peer's description: what a restart re-applies under new
    # credentials, and the credentials it names.
    method KeepRemoteDescription {sid jingle} {
        dict set Calls $sid remote_jingle $jingle
        set ice {}
        foreach c [xsearch $jingle content -gather node] {
            set t [xsearch $c transport -ns urn:xmpp:jingle:transports:ice-udp:1 -get node]
            if {$t eq ""} continue
            dict set ice [xsearch $c -get @name] [xsearch $t -get {@ufrag @pwd}]
        }
        dict set Calls $sid remote_ice $ice
    }

    method ArmRestartWait {sid} {
        $self CancelRestartWait $sid
        dict set Calls $sid restart_timer \
            [after $RESTART_WAIT_MS [mymethod RestartWaited $sid]]
    }

    method CancelRestartWait {sid} {
        if {![dict exists $Calls $sid restart_timer]} return
        after cancel [dict get $Calls $sid restart_timer]
        dict unset Calls $sid restart_timer
    }

    # The wait ran out. Time the stream to the server was down does not
    # count - the restart's signalling could not travel - so it starts
    # again then, under MEDIA_LOSS_MAX_MS.
    method RestartWaited {sid} {
        if {![dict exists $Calls $sid restart_timer]} return
        dict unset Calls $sid restart_timer
        if {![$client iq isLive]} {
            $self ArmRestartWait $sid
            return
        }
        # Media is flowing by the backend's last word: the restart did not
        # finish, but the path it was for is fine.
        if {[dict getdef $Calls $sid pc_state ""] eq "connected"} {
            $self OnPcState $sid connected
            return
        }
        $self RestartFailed $sid
    }

    # This restart, or this wait for the peer's, did not bring the path
    # back: try again if we may, else the call fails.
    method RestartFailed {sid} {
        if {![dict exists $Calls $sid]} return
        if {[dict get $Calls $sid transport] eq "connected"} return
        $self CancelRestartWait $sid
        dict unset Calls $sid restart_hold
        dict unset Calls $sid glare_offer
        if {[dict get $Calls $sid transport] eq "restarting"} {
            dict unset Calls $sid restart
            $self Go $sid transport interrupted
        }
        if {[$self StartRestart $sid "the restart did not reconnect"]} return
        if {[$self AwaitPeerRestart $sid]} return
        $self Finish $sid Failed "media path failed (ICE/DTLS)" connectivity-error
    }

    # Connected again, by a restart or not: what was under way is over.
    method EndRestart {sid} {
        $self CancelRestartWait $sid
        dict set Calls $sid restart_attempts 0
        dict unset Calls $sid restart
        dict unset Calls $sid glare_offer
        $self ReleaseLocalCandidates $sid
    }

    # The stream came back with its session: a media path that was lost
    # meanwhile most likely went with the network, so restart it now
    # rather than wait out the backend.
    method OnResumed {args} {
        dict for {sid call} $Calls {
            if {[dict get $call transport] ni {interrupted checking}} continue
            if {![dict get $call ever_connected]} continue
            $self StartRestart $sid "the stream to the server came back"
        }
    }

    # The media path as `list` and <Connection> name it: connecting until
    # it first connects, then connected, interrupted, or reconnecting while
    # the backend checks for a path again.
    method ConnectionState {call} {
        set transport [dict get $call transport]
        if {![dict get $call ever_connected]} {
            return [expr {$transport eq "connected" ? "connected" : "connecting"}]
        }
        switch -- $transport {
            checking   -
            restarting { return reconnecting }
            default    { return $transport }
        }
    }

    # The backend reports the media kind: a real peer's offer carries its
    # own BUNDLE mids, not our "audio"/"video" labels, so the mid is only
    # good for reporting.
    method OnTrack {sid ev} {
        set call [dict get $Calls $sid]
        set tr [dict get $ev track]
        if {[dict get $ev kind] eq "video"} {
            if {[dict get $call vtrack] ne -1} return
            $self AttachVideoReceiver $sid $tr
            if {[dict get $call video_local]} {
                $self AttachVideoSender $sid $tr
            }
            return
        }
        if {[dict get $call track] ne -1} return
        $self AttachMedia $sid $tr
    }

    # A frame channel came up: <VideoTrack> for the peer's camera,
    # <VideoPreview> for our own self-view.
    method OnVideoChannel {sid ev} {
        set args [$self VideoEventArgs [dict get $ev channel]]
        if {[dict get $ev direction] eq "preview"} {
            jlog debug "<VideoPreview> (sid=$sid) $args"
            $client emit calls <VideoPreview> -sid $sid \
                -direction preview {*}$args
            return
        }
        jlog debug "<VideoTrack> (sid=$sid) $args"
        $client emit calls <VideoTrack> -sid $sid -mid [dict get $ev mid] \
            -direction incoming {*}$args
    }

    # The backend could not open the device we asked for and used its
    # default. The call is fine; the user just isn't on the endpoint they
    # picked, so say so.
    method OnDeviceFallback {sid ev} {
        set what [expr {[dict get $ev kind] eq "playback" ? "output" : "input"}]
        if {[dict get $ev kind] eq "camera"} { set what camera }
        $client emit calls <Warning> -sid $sid \
            -reason "$what device unavailable, using default"
    }

    # Backend errors. Each op the module drives has its own report, since
    # the text and the consequence differ; anything else falls through to
    # the generic rule - fatal ends the call, advisory warns and it runs on.
    method OnMediaError {sid ev} {
        set op [dict get $ev op]
        set reason [dict get $ev reason]
        switch -- $op {
            setRemoteDescription {
                # Recorded for the handler that issued it: with a backend
                # that reports synchronously it is still on the stack and
                # can answer the IQ accordingly.
                dict set SdpErrors $sid $reason
                if {[dict exists $ev sdpType]
                        && [dict get $ev sdpType] eq "answer"} {
                    $client emit calls <Warning> -sid $sid \
                        -reason "session-accept rejected: $reason"
                    return
                }
                # An offer we cannot apply is fatal, and the
                # session-initiate is already acked — the peer thinks the
                # call is live, so terminate rather than leave it to
                # time out.
                $self Finish $sid Failed "remote offer rejected: $reason" \
                    general-error
                return
            }
            addRemoteCandidate {
                # Stale, duplicate, wrong ufrag: skipped like an
                # unparsable one, since the others may still connect.
                jlog debug "transport-info: candidate rejected: $reason"
                return
            }
            attachAudio {
                # Advisory: one side has no device, the call runs on and
                # picking a device opens it. Fatal falls through below.
                if {![dict getdef $ev fatal 0]} {
                    $client emit calls <Warning> -sid $sid -reason \
                        "[$self AudioSide $ev] device could not be opened: $reason"
                    return
                }
            }
            setAudioDevice {
                $client emit calls <Warning> -sid $sid \
                    -reason "[$self AudioSide $ev] device unavailable: $reason"
                return
            }
            setAudioVolume {
                $client emit calls <Warning> -sid $sid \
                    -reason "[$self AudioSide $ev] volume rejected: $reason"
                return
            }
            attachVideoSender {
                dict set Calls $sid vsend 0
                $client emit calls <Warning> -sid $sid \
                    -reason "video sender: $reason"
                return
            }
            attachVideoReceiver {
                dict set Calls $sid vrecv 0
                dict set Calls $sid vtrack -1
                $client emit calls <Warning> -sid $sid \
                    -reason "video receiver: $reason"
                return
            }
        }
        # A pc the backend gave up on: the peer is told, as for any
        # failure, or it keeps a call nobody is on.
        if {[dict exists $ev fatal] && [dict get $ev fatal]} {
            $self Finish $sid Failed $reason \
                [expr {[dict get $Calls $sid jingle] ? "general-error" : ""}]
            return
        }
        $client emit calls <Warning> -sid $sid -reason $reason
    }

    method AudioSide {ev} {
        return [expr {[dict get $ev kind] eq "capture" ? "input" : "output"}]
    }

    # Did the setRemoteDescription just issued for $sid fail? Only a
    # backend reporting synchronously can answer in time; with an async one
    # the IQ is already acked and OnMediaError's report is the whole story.
    method TakeSdpError {sid} {
        if {![dict exists $SdpErrors $sid]} { return "" }
        set err [dict get $SdpErrors $sid]
        dict unset SdpErrors $sid
        return $err
    }

    # =========================================================================
    # Incoming JMI <message> dispatch (XEP-0353)
    # =========================================================================

    # Returns 1 if the stanza was claimed (had a JMI child), 0 otherwise.
    method OnMessage {stanza} {
        set ns urn:xmpp:jingle-message:0
        foreach action {propose proceed ringing reject retract finish} {
            set child [xsearch $stanza $action -ns $ns -get node]
            if {$child eq ""} continue
            set sid [xsearch $child -get @id]
            set from [xsearch $stanza -get @from]
            switch -- $action {
                propose { $self HandleJmiPropose $stanza $sid $from }
                proceed { $self HandleJmiProceed $stanza $sid $from }
                ringing { $self HandleJmiRinging $stanza $sid $from }
                reject  { $self HandleJmiReject  $stanza $sid $from }
                retract { $self HandleJmiRetract $stanza $sid $from }
                finish  { $self HandleJmiFinish  $stanza $sid $from }
            }
            return 1
        }
        return 0
    }

    method HandleJmiPropose {stanza sid from} {
        # Carbon of our own outbound propose: drop.
        set myBare [jid bare [$client cget -jid]]
        if {[jid bare $from] eq $myBare} return
        # An occupant of a room we are in, joining or have bookmarked is
        # not a caller: anyone in a public room could ring us and learn
        # from our <ringing/> that we are online. Dropped unanswered.
        if {[jid resource $from] ne ""
                && ([$client muc isTracked -jid $from]
                    || [$client muc isKnownRoom -jid $from])} {
            jlog debug "call propose from $from dropped: a room occupant"
            return
        }
        # Duplicate or sid collision: ignore, unless it is our own proposed
        # sid from the account we call (equal-sid tie-break below).
        if {[dict exists $Calls $sid]} {
            set ours [dict get $Calls $sid]
            if {![dict get $ours initiator] || [dict get $ours state] ne "proposed"
                    || ![jid matches-bare $from [dict get $ours peer]]} return
        }
        set ns urn:xmpp:jingle-message:0
        set child [xsearch $stanza propose -ns $ns -get node]
        set hasVideo [$self ProposeHasVideo $child]

        # Calls can't be tunneled through a proxy (native ICE bypasses it), so
        # decline instead of ringing. Missed all the same, as busy is.
        if {[$self Blocked] ne ""} {
            $client write [$self BuildJmiMessage $from reject $sid 0]
            $self EmitMissed $sid $from $hasVideo proxy
            return
        }

        # Crossing proposes (XEP-0353 §4.1): the lower sid wins (i;octet),
        # then the lower JID; the receiver of the losing propose rejects it
        # with <tie-break/>. Theirs rings only if it beats every propose of
        # ours to them; ours then end.
        set beaten {}
        dict for {ours call} $Calls {
            if {![dict get $call initiator] || [dict get $call state] ne "proposed"} continue
            if {![jid matches-bare $from [dict get $call peer]]} continue
            set cmp [string compare $ours $sid]
            if {$cmp == 0} {
                set cmp [string compare [jid norm [$client cget -jid]] [jid norm $from]]
            }
            if {$cmp < 0} {
                $client write [$self BuildJmiTieBreak $from $sid]
                return
            }
            lappend beaten $ours
        }
        foreach ours $beaten {
            $self Finish $ours Ended replaced
        }

        # One call at a time: any other, group sessions included, makes
        # this one busy.
        if {[dict size $Calls] > 0} {
            $client write [$self BuildJmiReject $from $sid busy]
            $self EmitMissed $sid $from $hasVideo busy
            return
        }

        dict set Calls $sid [$self NewCallDict $from 0 ringing 0]
        $self NotePeerDevice $sid $child
        dict set Calls $sid video_remote $hasVideo
        # We answer video symmetrically: if they offered it, we intend to
        # send it too (the GUI can still mute the camera).
        dict set Calls $sid video_local $hasVideo

        # XEP-0353 §4: tell the initiator this device is alerting the user.
        $client write [$self BuildJmiMessage $from ringing $sid 0]
        $self StartRingTimer $sid
        $client emit calls <Incoming> -sid $sid -from [jid bare $from] \
            -video $hasVideo
    }

    method HandleJmiRinging {stanza sid from} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        if {[dict get $call state] ne "proposed"
                || ![dict get $call initiator]} return
        if {![$self PeerMatches $sid $from]} return
        # The state stays proposed, so this is the only trace `list` has.
        dict set Calls $sid peer_ringing 1
        $client emit calls <Ringing> -sid $sid
    }

    method HandleJmiProceed {stanza sid from} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        set state [dict get $call state]
        set myJid [$client cget -jid]
        set myBare [jid bare $myJid]

        # Carbon of someone else's proceed on a call we're ringing on
        # (another device of ours answered): drop our ringing state.
        if {$state eq "ringing" && [jid bare $from] eq $myBare \
                && $from ne $myJid} {
            $self Finish $sid Ended elsewhere
            return
        }
        # We're the original caller: latch full JID, then fetch the
        # server's STUN/TURN list (XEP-0215). StartOutgoingMedia runs in
        # the extdisco callback once the iceServers list is in hand.
        if {$state eq "proposed" && [dict get $call initiator]} {
            if {![$self PeerMatches $sid $from]} return
            dict set Calls $sid peer $from
            $self Go $sid state proceeded
            $self NotePeerDevice $sid \
                [xsearch $stanza proceed -ns urn:xmpp:jingle-message:0 -get node]
            $client extdisco fetch -command [mymethod StartOutgoingMedia $sid]
        }
    }

    # Caller side: extdisco callback. Builds the pc with whatever ICE
    # servers the server advertised (empty list = host candidates only),
    # adds the sendrecv audio track, attaches media, and kicks off
    # offer generation. A hangup arriving during the fetch can have
    # removed this sid from Calls — bail in that case. A setup that
    # raises (the backend refusing the pc, a track, the offer) fails the
    # call here instead of reaching bgerror and leaving it hanging.
    method StartOutgoingMedia {sid iceServers} {
        if {![dict exists $Calls $sid]} return
        if {[catch {$self SetUpOutgoingMedia $sid $iceServers} err]} {
            $self FailCall $sid "media setup failed: $err" general-error
        }
    }

    method SetUpOutgoingMedia {sid iceServers} {
        set pc [$self CreatePc $sid $iceServers]
        ::tacky::media addTrack $pc $MID -kind audio -direction sendrecv
        $self AttachMedia $sid $MID
        if {![dict exists $Calls $sid]} return
        if {[dict get $Calls $sid video_local]} {
            ::tacky::media addTrack $pc $VIDEO_MID -kind video -direction sendrecv
            $self AttachVideoSender $sid $VIDEO_MID
            $self AttachVideoReceiver $sid $VIDEO_MID
        }
        # No type: with no remote description set, this is the offer.
        ::tacky::media setLocalDescription $pc
    }

    method HandleJmiReject {stanza sid from} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        set state [dict get $call state]
        set myJid [$client cget -jid]
        set myBare [jid bare $myJid]

        # Another of our devices took the call from underneath us while
        # we were ringing — drop locally.
        if {$state eq "ringing" && [jid bare $from] eq $myBare \
                && $from ne $myJid} {
            $self Finish $sid Ended elsewhere
            return
        }
        # Caller side: declined, busy, timed out, or a tie-break.
        if {$state eq "proposed" && [dict get $call initiator]} {
            if {![$self PeerMatches $sid $from]} return
            set child [xsearch $stanza reject -ns urn:xmpp:jingle-message:0 -get node]
            set why declined
            if {[xsearch $child tie-break -get node] ne ""} {
                set why replaced
            } else {
                switch -- [lindex [xsearch $child reason * -get tag] 0] {
                    busy    { set why busy }
                    timeout { set why timeout }
                }
            }
            $self Finish $sid Ended $why
        }
    }

    method HandleJmiRetract {stanza sid from} {
        if {![$self PeerMatches $sid $from]} return
        set call [dict get $Calls $sid]
        switch -- [dict get $call state] {
            ringing {
                # Caller cancelled before we answered.
                $self Finish $sid Ended retracted
                $self EmitMissed $sid $from [dict get $call video_remote] retracted
            }
            proceeded {
                # Answered, but the caller gave up before its
                # session-initiate (XEP-0353 allows a retract until then).
                if {![dict get $call initiator] && ![dict get $call jingle]} {
                    $self Finish $sid Ended retracted
                }
            }
        }
    }

    # <finish/> (XEP-0353 §3.5): the session is over. Its session-terminate
    # normally said so first; if we still hold the call, it ends here.
    method HandleJmiFinish {stanza sid from} {
        if {![$self PeerMatches $sid $from]} return
        if {[dict get $Calls $sid state] in {proposed ringing}} return
        set child [xsearch $stanza finish -ns urn:xmpp:jingle-message:0 -get node]
        $self PeerEnded $sid [lindex [xsearch $child reason * -get tag] 0]
    }

    # $device: our OMEMO device id to announce, if any.
    method BuildJmiMessage {to action sid wantDescription {wantVideo 0} {device ""}} {
        set ns urn:xmpp:jingle-message:0
        return [j message -to $to -type chat {
            if {$wantDescription || $device ne ""} {
                j $action -ns $ns -id $sid {
                    if {$wantDescription} {
                        j description \
                            -ns urn:xmpp:jingle:apps:rtp:1 \
                            -media audio
                    }
                    if {$wantVideo} {
                        j description \
                            -ns urn:xmpp:jingle:apps:rtp:1 \
                            -media video
                    }
                    if {$device ne ""} {
                        j device -ns $NS_VERIFY -id $device
                    }
                }
            } else {
                j $action -ns $ns -id $sid
            }
        }]
    }

    # The <reject> of a propose that lost the tie-break (XEP-0353 §4.1).
    # <reject/> with a XEP-0166 condition.
    method BuildJmiReject {to sid condition} {
        return [j message -to $to -type chat {
            j reject -ns urn:xmpp:jingle-message:0 -id $sid {
                j reason -ns urn:xmpp:jingle:1 { j $condition }
            }
        }]
    }

    # <finish/> with a XEP-0166 condition (XEP-0353 §3.5).
    method BuildJmiFinish {to sid condition} {
        return [j message -to $to -type chat {
            j finish -ns urn:xmpp:jingle-message:0 -id $sid {
                j reason -ns urn:xmpp:jingle:1 { j $condition }
            }
            j store -ns urn:xmpp:hints
        }]
    }

    method BuildJmiTieBreak {to sid} {
        return [j message -to $to -type chat {
            j reject -ns urn:xmpp:jingle-message:0 -id $sid {
                j reason -ns urn:xmpp:jingle:1 { j expired }
                j tie-break
            }
        }]
    }

    # Does an inbound JMI <propose> advertise a video <description>?
    method ProposeHasVideo {child} {
        foreach d [xsearch $child description \
                       -ns urn:xmpp:jingle:apps:rtp:1 -gather node] {
            if {[xsearch $d -get @media] eq "video"} { return 1 }
        }
        return 0
    }

    # =========================================================================
    # Incoming Jingle IQ dispatch
    # =========================================================================

    method OnJingleIq {stanza} {
        set jingle [xsearch $stanza jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jingle eq ""} {
            $self IqError $stanza bad-request
            return
        }
        set action [xsearch $jingle -get @action]
        set sid [xsearch $jingle -get @sid]
        set from [xsearch $stanza -get @from]

        # A known session's peer is held to the table: what the session
        # does not take in its state is refused before any handler. A
        # session-initiate is the handler's to judge, since it may open
        # the session or cross one of ours.
        if {$action ne "session-initiate" && [$self PeerMatches $sid $from]} {
            set word [$self JingleIn $sid $action]
            if {$word ne "handle"} {
                $self IqError $stanza $word
                return
            }
        }
        switch -- $action {
            session-initiate  { $self HandleSessionInitiate $stanza $jingle $sid $from }
            session-accept    { $self HandleSessionAccept   $stanza $jingle $sid $from }
            session-terminate { $self HandleSessionTerminate $stanza $jingle $sid $from }
            transport-info    { $self HandleTransportInfo   $stanza $jingle $sid $from }
            default           { $self HandleOtherAction $stanza $jingle $action $sid $from }
        }
    }

    # Any other action. One for a session that is not this peer's is
    # refused like the rest. session-info (ringing, mute, hold) and the
    # other informational actions are acknowledged. content-add and
    # transport-replace are acknowledged and then turned down with
    # content-reject / transport-reject, as XEP-0166 7.2 has it: an IQ
    # error there would read as the session failing, and Conversations
    # ends the call (its video button sends content-add mid-call).
    # Anything else gets feature-not-implemented.
    method HandleOtherAction {stanza jingle action sid from} {
        if {![$self PeerMatches $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        switch -- $action {
            session-info - content-modify - content-remove -
            description-info - security-info {
                $self AckIq $stanza
            }
            content-add {
                $self AckIq $stanza
                $self SendReject $sid $from content-reject $jingle 0
            }
            transport-replace {
                $self AckIq $stanza
                $self SendReject $sid $from transport-reject $jingle 1
            }
            default {
                $self IqError $stanza feature-not-implemented
            }
        }
    }

    # Turn down the contents of an incoming $jingle with $action, naming
    # each content (and, for a transport-reject, the transport refused).
    method SendReject {sid peer action jingle withTransport} {
        set contents {}
        foreach c [xsearch $jingle content -gather node] {
            lassign [xsearch $c -get {@creator @name}] creator name
            set content [j content -creator $creator -name $name]
            if {$withTransport} {
                dict set content children [xsearch $c transport -gather node]
            }
            lappend contents $content
        }
        set out [j jingle -ns urn:xmpp:jingle:1]
        dict set out attrs action $action
        dict set out attrs sid $sid
        dict set out children $contents
        $client iq request -type set -to $peer -payload $out
    }

    method HandleSessionInitiate {stanza jingle sid from} {
        # JMI is mandatory: a session-initiate must be preceded by our
        # own <proceed>. Otherwise the user never agreed to ring and
        # we reject the IQ — the call never existed locally.
        # A sender that isn't our peer gets the same answer as an unknown
        # sid, so a guessed sid can't be confirmed.
        # Except a Muji session, whose sender taco_groupcall vouches for.
        #
        # Crossing initiates (XEP-0166 §7.2.16): we also have an unanswered
        # group session to this peer. The lower sid wins, then the lower JID.
        # If ours wins, theirs gets <tie-break/>; otherwise, or if ours was
        # never sent, theirs replaces ours, which is dropped silently.
        set ours [$self CrossingSession $from]
        if {$ours ne "" && ([dict exists $Calls $sid] && $sid ne $ours)} {
            set ours ""
        }
        if {$ours ne ""} {
            set cmp [string compare $sid $ours]
            if {$cmp == 0} {
                set cmp [string compare [jid norm $from] [jid norm [$client cget -jid]]]
            }
            if {[dict get $Calls $ours jingle] && $cmp > 0} {
                $self IqError $stanza conflict tie-break
                return
            }
            # Same sid: drop ours first, theirs reuses the entry.
            if {$sid eq $ours} { $self DropSession $ours }
            if {![$self OpenGroupSession $jingle $sid $from $ours]} {
                # groupcall refused theirs: ours stays, or ends if already
                # dropped.
                if {$sid eq $ours} {
                    $client emit calls <Ended> -sid $ours -reason replaced
                }
                $self IqError $stanza item-not-found
                return
            }
            if {$sid ne $ours} { $self DropSession $ours }
        } elseif {![dict exists $Calls $sid] && ![$self OpenGroupSession $jingle $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        if {![$self PeerMatches $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        set call [dict get $Calls $sid]
        if {[dict get $call state] ne "proceeded"
                || [dict get $call initiator]} {
            $self IqError $stanza out-of-order
            return
        }
        # A plain offer is accepted even if the peer announced a device,
        # like Conversations.
        set jingle [$self TakeFingerprints $sid $stanza $jingle $from 0]
        if {$jingle eq ""} return
        # Strip payload-types the backend cannot decode before to_sdp, so
        # the answer only offers what we can actually play back.
        set jingle [$self FilterCodecs $jingle]
        # -initiator names the SDP's author: the peer, who initiated.
        # An offer that doesn't convert is refused, which ends the session
        # for the peer as well.
        if {[catch {::jinglesdp::to_sdp $jingle -initiator 1} sdp]} {
            $self IqError $stanza bad-request
            $self Finish $sid Failed "bad offer: $sdp"
            return
        }
        jlog debug "SDP offer from $from (sid=$sid)\n[jlog_redact_sdp $sdp]"
        $self KeepRemoteDescription $sid $jingle
        dict set Calls $sid peer $from
        dict set Calls $sid jingle 1
        $self Go $sid state pending
        $self AckIq $stanza
        # Fetch ICE servers (XEP-0215) before standing up the pc.
        # StartIncomingMedia drives the rest in the extdisco callback.
        $client extdisco fetch \
            -command [mymethod StartIncomingMedia $sid $sdp]
    }

    # Callee side: extdisco callback. Stands up the pc, applies the
    # remote offer, and drains any transport-info that arrived while
    # the fetch was outstanding. A hangup during the fetch can have
    # removed this sid — bail then. A setup that raises fails the call, as
    # the caller's does.
    method StartIncomingMedia {sid sdp iceServers} {
        if {![dict exists $Calls $sid]} return
        if {[catch {$self SetUpIncomingMedia $sid $sdp $iceServers} err]} {
            $self FailCall $sid "media setup failed: $err" general-error
        }
    }

    method SetUpIncomingMedia {sid sdp iceServers} {
        set pc [$self CreatePc $sid $iceServers]
        # Apply the offer; `track` events fire async to drive AttachMedia.
        # A backend that rejects it reports an error, and OnMediaError has
        # already emitted <Failed>, terminated and cleaned up by the time
        # this returns — hence the re-check below.
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type offer
        if {![dict exists $Calls $sid]} return
        $self TakeSdpError $sid
        dict set Calls $sid remote_set 1
        # An `autoAnswer` backend has applied its own answer as part of
        # setRemoteDescription(offer) and calling setLocalDescription now
        # would run in signaling state Stable, where an unspecified type
        # means Offer — generating a fresh offer that silently overwrites
        # that answer. libdatachannel does this
        # (config.disableAutoNegotiation is false by default); libwebrtc
        # does not, and needs the explicit answer.
        if {![::tacky::media capability autoAnswer]} {
            ::tacky::media setLocalDescription $pc -type answer
            if {![dict exists $Calls $sid]} return
        }
        $self DrainPendingCandidates $sid $pc
    }

    # Apply the candidates that arrived (and were buffered) before the
    # remote description. A rejected one isn't fatal to a description that
    # just applied cleanly; OnMediaError logs and skips it.
    method DrainPendingCandidates {sid pc} {
        if {![dict exists $Calls $sid pending_remote_candidates]} return
        foreach entry [dict get $Calls $sid pending_remote_candidates] {
            lassign $entry name full
            ::tacky::media addRemoteCandidate $pc \
                -candidate $full -mid $name
        }
        dict unset Calls $sid pending_remote_candidates
    }

    method HandleSessionAccept {stanza jingle sid from} {
        if {![$self PeerMatches $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        set pc [dict get $Calls $sid pc]
        # An accept before we've stood up the pc (still fetching ICE
        # servers, or never offered at all) has nothing to apply to.
        if {$pc eq -1} {
            $self IqError $stanza out-of-order
            return
        }
        # If our offer was encrypted, the answer must be too. A repeated
        # answer is skipped: its key was already used.
        if {![dict exists $Calls $sid remote_set]} {
            set jingle [$self TakeFingerprints $sid $stanza $jingle $from \
                [dict exists $Calls $sid fingerprint_encrypted]]
            if {$jingle eq ""} return
        }
        # The peer wrote this answer, as the responder. One that doesn't
        # convert ends a call still waiting for it; a malformed repeat of
        # an answer already applied is only refused.
        if {[catch {::jinglesdp::to_sdp $jingle -initiator 0} sdp]} {
            $self IqError $stanza bad-request
            if {![dict exists $Calls $sid remote_set]} {
                $self FailCall $sid "bad answer: $sdp" failed-application
            }
            return
        }
        # A duplicate/retransmitted accept applies fine once but is
        # rejected the second time — not fatal to the call already
        # running, so OnMediaError warns rather than failing it, and we
        # answer with an IQ error instead of AckIq so a retrying peer
        # stops.
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type answer
        if {![dict exists $Calls $sid]} return
        if {[$self TakeSdpError $sid] ne ""} {
            $self IqError $stanza not-acceptable
            return
        }
        if {![dict exists $Calls $sid remote_set]} {
            $self KeepRemoteDescription $sid $jingle
        }
        dict set Calls $sid remote_set 1
        if {[dict get $Calls $sid initiator]} {
            $self Go $sid state established
        }
        $self AckIq $stanza
        $self DrainPendingCandidates $sid $pc
    }

    # Trickled candidates (XEP-0176), and what else a transport-info may
    # carry: new credentials, which are an ICE restart (see "ICE restart"),
    # and a DTLS fingerprint, which must be the one the session has.
    #
    # Candidates are sorted by the credentials they come under: the
    # peer's current ones go to the pc (or wait, below); a generation a
    # restart replaced is dropped, as is one we never heard of.
    method HandleTransportInfo {stanza jingle sid from} {
        if {![$self PeerMatches $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        set call [dict get $Calls $sid]
        set pc [dict get $call pc]
        set ice [dict getdef $call remote_ice {}]
        set old [dict getdef $call remote_old {}]
        set glare [dict getdef $call glare_offer {}]
        # Until the peer's description is applied a candidate has nothing
        # to attach to: on the callee's side the pc may not exist yet (the
        # JMI window), on the caller's the answer may not have come. Buffer
        # in arrival order; DrainPendingCandidates applies them.
        set early [expr {$pc eq -1 || ![dict exists $call remote_set]}]
        set creds {}
        set fresh 0
        set cands {}
        set wait {}
        set swapped 0
        xsearch $jingle content -script content {
            set name [xsearch $content -get @name]
            set transport [xsearch $content transport \
                -ns urn:xmpp:jingle:transports:ice-udp:1 -get node]
            if {$transport eq ""} continue
            if {![$self SameFingerprint $sid $transport]} {
                set swapped 1
                break
            }
            lassign [xsearch $transport -get {@ufrag @pwd}] ufrag pwd
            set target cands
            if {$ufrag ne "" && [dict exists $ice $name]
                    && $ufrag ne [lindex [dict get $ice $name] 0]} {
                if {$pwd ne "" && $ufrag ni $old} {
                    # New credentials, both of them: a restart.
                    dict set creds $name $transport
                    incr fresh [llength [xsearch $transport candidate -gather node]]
                    continue
                }
                if {[dict exists $glare $name]
                        && $ufrag eq [xsearch [dict get $glare $name] -get @ufrag]} {
                    # The initiator's restart we are about to follow.
                    set target wait
                } else {
                    jlog debug "transport-info: candidates of a replaced or unknown\
                        ICE generation ($ufrag) skipped"
                    continue
                }
            }
            xsearch $transport candidate -script cand {
                if {[catch {::jinglesdp::CandidateToSdp $cand} value]} {
                    jlog debug "transport-info: skipping unusable candidate"
                    continue
                }
                lappend $target [list $name "candidate:$value"]
            }
        }
        if {$swapped} {
            $self AckIq $stanza
            $self Finish $sid Failed \
                "the peer's DTLS fingerprint changed mid-call" security-error
            return
        }
        if {[dict size $creds]} {
            # With candidates while our own offer is out, it is the answer;
            # anything else is the peer's offer.
            set restart [dict getdef $call restart ""]
            set isAnswer [expr {$restart eq "awaiting" && $fresh > 0}]
            if {!$isAnswer && $restart in {offering awaiting}} {
                # Both restarted at once: the initiator's wins.
                if {[dict get $call initiator]} {
                    $self IqError $stanza conflict tie-break
                    return
                }
                $self AckIq $stanza
                dict set Calls $sid glare_offer $creds
                $self RollBackAndFollow $sid
                $self AddCandidates $sid $cands
                return
            }
            $self AckIq $stanza
            if {$isAnswer} {
                $self ApplyRestartAnswer $sid $creds
            } elseif {[dict get $call state] eq "established"} {
                $self FollowRestart $sid $creds
            } else {
                jlog debug "transport-info: new credentials before the session is up skipped"
            }
            if {![dict exists $Calls $sid]} return
            $self AddCandidates $sid $cands
            return
        }
        foreach c $wait { $self BufferCandidate $sid {*}$c }
        if {$early} {
            foreach c $cands { $self BufferCandidate $sid {*}$c }
        } else {
            $self AddCandidates $sid $cands
        }
        $self AckIq $stanza
    }

    method AddCandidates {sid cands} {
        set pc [dict get $Calls $sid pc]
        if {$pc eq -1} return
        foreach c $cands {
            lassign $c name full
            ::tacky::media addRemoteCandidate $pc -candidate $full -mid $name
            if {![dict exists $Calls $sid]} return
        }
    }

    method BufferCandidate {sid name full} {
        set buffered [dict getdef $Calls $sid pending_remote_candidates {}]
        if {[llength $buffered] >= $MAX_PENDING_CANDIDATES} {
            jlog debug "transport-info: candidate buffer full"
            return
        }
        dict update Calls $sid call {
            dict lappend call pending_remote_candidates [list $name $full]
        }
    }

    # A plain fingerprint in a transport-info (XEP-0320 lets one travel
    # there) must be the one the session was set up with: a restart moves
    # the path, never the DTLS keys. An encrypted one is not read here.
    method SameFingerprint {sid transport} {
        if {![dict exists $Calls $sid remote_jingle]} { return 1 }
        set fp [::taco_calls::verify::plain $transport]
        if {$fp eq ""} { return 1 }
        set known [::taco_calls::verify::plain [xsearch \
            [dict get $Calls $sid remote_jingle] content transport \
            -ns urn:xmpp:jingle:transports:ice-udp:1 -get node]]
        if {$known eq ""} { return 1 }
        expr {[string equal -nocase [string trim [xsearch $fp -get body]] \
                   [string trim [xsearch $known -get body]]]}
    }

    method HandleSessionTerminate {stanza jingle sid from} {
        $self AckIq $stanza
        if {![$self PeerMatches $sid $from]} return
        $self PeerEnded $sid [lindex [xsearch $jingle reason * -get tag] 0]
    }

    # The peer ended the session (session-terminate or JMI <finish/>) with
    # the XEP-0166 condition $reason: one of FAULTS fails the call here
    # too, anything else ends it.
    method PeerEnded {sid reason} {
        if {$reason in $FAULTS} {
            $self Finish $sid Failed "the peer reported $reason"
        } else {
            $self Finish $sid Ended hangup
        }
    }

    # =========================================================================
    # Helpers
    # =========================================================================

    # A session-initiate with <muji room/> from a known participant becomes a
    # callee session in `proceeded`, as if JMI-accepted. Returns 1 if opened.
    # $replaces: our unanswered session to $from that this one replaces.
    method OpenGroupSession {jingle sid from {replaces ""}} {
        set room [xsearch $jingle muji -ns urn:xmpp:jingle:muji:0 -get @room]
        if {$room eq "" || ![jid valid $room]} { return 0 }
        set hasVideo 0
        xsearch $jingle content -script content {
            set d [xsearch $content description \
                -ns urn:xmpp:jingle:apps:rtp:1 -get node]
            if {$d ne "" && [xsearch $d -get @media] eq "video"} {
                set hasVideo 1
            }
        }
        set wantVideo [$client groupcall AcceptSession \
            -room $room -peer $from -sid $sid -video $hasVideo -replaces $replaces]
        if {$wantVideo eq ""} { return 0 }
        dict set Calls $sid [$self NewCallDict $from 0 proceeded \
            [expr {$wantVideo ? 1 : 0}] [jid norm $room]]
        dict set Calls $sid video_remote $hasVideo
        $self StartSetupTimer $sid
        return 1
    }

    # Drop a session that lost a crossing tie-break: no terminate, no event.
    method DropSession {sid} {
        $self TeardownMedia $sid
        $self Cleanup $sid
    }

    # Our unanswered group session to $from (full JID), "" if none.
    method CrossingSession {from} {
        dict for {sid call} $Calls {
            if {![dict get $call initiator] || [dict get $call group] eq ""} continue
            if {[dict get $call peer] ne $from || [dict exists $call remote_set]} continue
            return $sid
        }
        return ""
    }

    # Walk a session-initiate's Jingle tree and drop, from each rtp
    # <description>, every <payload-type> the backend cannot decode.
    # Mirrors gajim's codec filter: keep the negotiation honest about what
    # we can actually play. Otherwise a backend that auto-answers accepts
    # everything the peer offered and is then free to be sent RTP in any
    # of it — rtc-ma's opus_decode -4 on every packet. A backend with no
    # opinion for a kind (an empty list) has everything left in.
    method FilterCodecs {jingle} {
        set NS_RTP urn:xmpp:jingle:apps:rtp:1
        set codecs [::tacky::media codecs]
        set jc {}
        foreach c [dict get $jingle children] {
            if {[dict get $c tag] eq "content"} {
                set cc {}
                foreach d [dict get $c children] {
                    if {[dict get $d tag] eq "description"
                            && [dict get $d ns] eq $NS_RTP} {
                        set media ""
                        if {[dict exists $d attrs media]} {
                            set media [dict get $d attrs media]
                        }
                        set keep {}
                        if {[dict exists $codecs $media]} {
                            set keep [dict get $codecs $media]
                        }
                        if {[llength $keep]} {
                            dict set d children \
                                [$self KeepPayloadTypes [dict get $d children] $keep]
                        }
                    }
                    lappend cc $d
                }
                dict set c children $cc
            }
            lappend jc $c
        }
        dict set jingle children $jc
        return $jingle
    }

    method KeepPayloadTypes {children keep} {
        set out {}
        foreach e $children {
            if {[dict get $e tag] eq "payload-type"} {
                set name ""
                if {[dict exists $e attrs name]} {
                    set name [dict get $e attrs name]
                }
                if {[lsearch -exact -nocase $keep $name] < 0} continue
            }
            lappend out $e
        }
        return $out
    }

    # Bare <iq type='result'/> ack. Built by hand because $client iq respond
    # currently requires a -payload.
    method AckIq {stanza} {
        lassign [xsearch $stanza -get {@from @id}] from id
        set ackArgs [list -type result -id $id]
        if {$from ne ""} { lappend ackArgs -to $from }
        $client write [j iq {*}$ackArgs]
    }

    # $jingleCondition: an optional urn:xmpp:jingle:errors:1 condition.
    method IqError {stanza condition {jingleCondition ""}} {
        set payload [j error -type cancel {
            j $condition -ns urn:ietf:params:xml:ns:xmpp-stanzas
            if {$jingleCondition ne ""} {
                j $jingleCondition -ns urn:xmpp:jingle:errors:1
            }
        }]
        $client iq respond -type error -for $stanza -payload $payload
    }

    # Cancel a call that never got past our own <propose>. There is no
    # session to terminate yet, so XEP-0353 wants a retract.
    method RetractProposed {sid peer why} {
        $client write [$self BuildJmiMessage $peer retract $sid 0]
        $self Finish $sid Ended $why
    }

    # A fresh (non-resumed) stream. Signalling for a session is addressed to
    # our full JID, so a session survives only where the new stream bound
    # the same one, and only if it is worth keeping: up, with media
    # flowing, since the media path is peer to peer and may well have
    # outlived the outage. Everything else ends: a ring or setup in flight
    # lost messages we cannot know of, and a group call's legs follow its
    # room, which the fresh stream left. Resumption never lands here, and a
    # plain disconnect is deliberately left alone.
    method OnFreshStream {args} {
        set me [$client cget -jid]
        foreach sid [dict keys $Calls] {
            set call [dict get $Calls $sid]
            if {[dict get $call state] eq "established"
                    && [dict get $call transport] eq "connected"
                    && [dict get $call group] eq ""
                    && [dict get $call self_jid] eq $me} {
                jlog inform "call $sid kept across a fresh stream"
                continue
            }
            $self Finish $sid Ended reset
        }
    }

    method SendTerminate {sid peer reason} {
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j reason {
                j $reason
            }
        }]
        dict set jingle attrs action session-terminate
        dict set jingle attrs sid $sid
        $client iq request -type set -to $peer -payload $jingle
    }

    # Bare match while peer is still a bare JID (the JMI window: we
    # proposed to the account, any of its resources may answer), exact
    # full JID once the session is latched to one resource.
    method PeerMatches {sid from} {
        if {![dict exists $Calls $sid] || ![jid valid $from]} { return 0 }
        set peer [dict get $Calls $sid peer]
        if {![jid matches-bare $from $peer]} { return 0 }
        set res [jid resource $peer]
        if {$res eq ""} { return 1 }
        return [expr {[jid resource $from] eq $res}]
    }

    method Cleanup {sid} {
        dict unset SdpErrors $sid
        if {![dict exists $Calls $sid]} return
        $self CancelInterrupted $sid
        $self StopRingTimer $sid
        $self StopSetupTimer $sid
        $self CancelRestartWait $sid
        $self MediaBack $sid
        dict unset Calls $sid
    }

    method NewSid {} {
        binary scan [omemo::random 16] H* hex
        return "tk-$hex"
    }
}

# Helpers for reading and replacing the DTLS fingerprint in a <jingle>'s
# ice-udp transports. A slot is {content index, transport index}.
namespace eval ::taco_calls::verify {
    variable NS_VERIFY  http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification
    variable NS_DTLS    urn:xmpp:jingle:apps:dtls:0
    variable NS_ICE_UDP urn:xmpp:jingle:transports:ice-udp:1
}

proc ::taco_calls::verify::transports {jingle} {
    variable NS_ICE_UDP
    set slots {}
    set ci 0
    foreach content [dict get $jingle children] {
        if {[dict get $content tag] eq "content"} {
            set ti 0
            foreach child [dict get $content children] {
                if {[dict get $child tag] eq "transport"
                        && [dict get $child ns] eq $NS_ICE_UDP} {
                    lappend slots [list $ci $ti]
                }
                incr ti
            }
        }
        incr ci
    }
    return $slots
}

proc ::taco_calls::verify::get {jingle slot} {
    lassign $slot ci ti
    lindex [dict get [lindex [dict get $jingle children] $ci] children] $ti
}

proc ::taco_calls::verify::put {jingle slot transport} {
    lassign $slot ci ti
    set contents [dict get $jingle children]
    set content [lindex $contents $ci]
    dict set content children \
        [lreplace [dict get $content children] $ti $ti $transport]
    dict set jingle children [lreplace $contents $ci $ci $content]
}

# The transport's plain <fingerprint/> node, or "".
proc ::taco_calls::verify::plain {transport} {
    variable NS_DTLS
    xsearch $transport fingerprint -ns $NS_DTLS -get node
}

# $transport with its fingerprint (namespace $from) replaced by $node.
proc ::taco_calls::verify::Swap {transport from node} {
    set children {}
    foreach child [dict get $transport children] {
        if {[dict get $child tag] eq "fingerprint" && [dict get $child ns] eq $from} {
            set child $node
        }
        lappend children $child
    }
    dict set transport children $children
}

# Replace the plain fingerprint with one wrapping $enc.
proc ::taco_calls::verify::encrypted {transport enc} {
    variable NS_DTLS
    variable NS_VERIFY
    set fp [plain $transport]
    set attrs [list -hash [xsearch $fp -get @hash]]
    set setup [xsearch $fp -get @setup]
    if {$setup ne ""} { lappend attrs -setup $setup }
    Swap $transport $NS_DTLS [j fingerprint -ns $NS_VERIFY {*}$attrs {
        j #as-is $enc
    }]
}

# Replace the encrypted fingerprint with the decrypted plain one.
proc ::taco_calls::verify::decrypted {transport hash setup body} {
    variable NS_DTLS
    variable NS_VERIFY
    set attrs [list -hash $hash]
    if {$setup ne ""} { lappend attrs -setup $setup }
    Swap $transport $NS_VERIFY [j fingerprint -ns $NS_DTLS {*}$attrs -body $body]
}
