# One call: a 1:1 call or one leg of a group call, from the first ring to
# its end. taco_calls (calls.tcl) makes it, hands it the stanzas for its sid,
# and forgets it when it ends; the file header there has the overview.
#
# A call ends in End, which every way out reaches (Finish, Drop). From then
# on no timer fires and no callback from outside reaches it (Callback), and the
# object goes once the methods on the stack have returned: a method that
# drives the backend synchronously checks $ended after, since the backend
# may have ended the call meanwhile.

package require tacky::media
package require omemo

snit::type ::taco_calls::call {
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

    # The XEP-0166 actions (taco_calls JINGLE_ACTIONS) a session takes from
    # its peer in each state; one not in its set is refused out-of-order
    # before a handler runs, and a state not here takes none. Each action
    # taken has its {Jingle action} method, which checks what the table
    # cannot see (the role, whether a pc is up yet). No state takes
    # content-accept, content-reject, transport-accept or transport-reject:
    # they answer content-add and transport-replace, which we never send.
    typevariable JINGLE_IN {
        proposed {
            session-info session-terminate
        }
        ringing {
            session-info session-terminate transport-info
        }
        proceeded {
            content-add content-modify content-remove description-info
            security-info session-info session-initiate session-terminate
            transport-info transport-replace
        }
        pending {
            content-add content-modify content-remove description-info
            security-info session-accept session-info session-initiate
            session-terminate transport-info transport-replace
        }
        established {
            content-add content-modify content-remove description-info
            security-info session-accept session-info session-terminate
            transport-info transport-replace
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
    typevariable NS_ICE_UDP urn:xmpp:jingle:transports:ice-udp:1

    variable calls              ;# the taco_calls that made us
    variable client
    variable sid
    variable ended 0

    # Who and what
    variable peer               ;# bare until proceeded, then full
    variable initiator          ;# 1 if we called
    variable group ""           ;# room JID of a group-call leg
    variable self_jid           ;# our full JID when the call began; a
                                ;# fresh stream that binds another cannot
                                ;# carry the session
    variable video_local 0      ;# we send video
    variable video_remote 0     ;# the peer offered video

    # The two machines
    variable state
    variable transport idle

    # Session
    variable has_session 0      ;# a session-initiate went out or came in:
                                ;# the peer is told the end in Jingle
    variable contents {}        ;# the session's contents: name -> media,
                                ;# senders (XEP-0166 roles)
    variable peer_ringing 0     ;# a device of the peer is alerting
    variable ever_connected 0
    variable active_since 0     ;# [clock microseconds] of the first connect

    # Media
    variable pc -1              ;# tacky::media pc, -1 before CreatePc
    variable pc_state ""        ;# the backend's last connectionState
    variable track -1           ;# audio track
    variable vtrack -1          ;# video track
    variable vsend 0            ;# asked for the camera, not refused
    variable vrecv 0            ;# asked for the peer's video, not refused
    variable sdp_error ""       ;# see TakeSdpError

    # Our description: what our candidates carry, and our DTLS role
    variable ufrag ""
    variable pwd ""
    variable local_setup ""
    variable describing 0       ;# our description is being encrypted
    variable held_candidates {} ;# ours, until it or a restart's is out

    # The peer's description
    variable remote_set 0       ;# applied to the pc
    variable remote_jingle ""   ;# as last applied; a restart re-applies it
    variable remote_ice {}      ;# content -> {ufrag pwd} it names
    variable remote_old {}      ;# ufrags a restart replaced
    variable pending_remote_candidates {} ;# {mid candidate}, until applied

    # Verification
    variable announced 0        ;# our <propose>/<proceed> named our device
    variable peer_device ""     ;# the device the peer's named
    variable fingerprint_encrypted 0
    variable omemo_device ""    ;# the device the peer's fingerprint came from
    variable fingerprint ""     ;# that device's key
    variable verified 0         ;# whether we accept it

    # Connection, as told to the frontend
    variable told_connection ""
    variable told_interrupted 0

    # ICE restart (see "ICE restart" below)
    variable restart ""
    variable restarts 0
    variable restart_attempts 0
    variable restart_hold 0     ;# our candidates wait for our credentials
    variable glare_offer {}     ;# the initiator's offer we are to follow

    # name -> {after-id method...}: ring, setup, interrupted, loss, restart
    variable Timers -array {}

    constructor {args} {
        array set o {-group "" -video 0 -video-remote 0}
        array set o $args
        set calls        $o(-calls)
        set client       $o(-client)
        set sid          $o(-sid)
        set peer         $o(-peer)
        set initiator    $o(-initiator)
        set state        $o(-state)
        set group        $o(-group)
        set video_local  $o(-video)
        set video_remote $o(-video-remote)
        set self_jid     [$client cget -jid]
    }

    destructor {
        $self DisarmAll
        catch {$self TeardownMedia}
    }

    # =========================================================================
    # Life
    # =========================================================================

    method Ended {} { return $ended }

    # A callback to $args for something outside the call - the backend, an
    # IQ answer, extdisco, OMEMO. It reaches the call only while it lasts.
    method Callback {args} { list [myproc Deliver] $self {*}$args }

    proc Deliver {call args} {
        if {[info commands $call] eq "" || [$call Ended]} return
        $call {*}$args
    }

    # See the file header.
    method End {} {
        if {$ended} return
        set ended 1
        $self DisarmAll
        $calls Forget $sid $self
        after idle [list catch [list $self destroy]]
    }

    # Go without a word to anyone: a session that lost a crossing tie-break,
    # or one the account cannot end politely.
    method Drop {} {
        $self TeardownMedia
        $self End
    }

    # The end of every call. Drops the media, tells the peer as far as it
    # knows the call, reports it once, and forgets it:
    #   $event   Ended or Failed
    #   $reason  <Ended>'s -reason, or <Failed>'s text
    #   $wire    the XEP-0166 condition to terminate the session with, or
    #            "" when the peer already knows (it ended it) or there is
    #            no session to end (the JMI paths write their own message)
    # A Jingle session that existed also gets JMI <finish/> (XEP-0353
    # §3.5), so every device of both sides learns the call is over.
    method Finish {event reason {wire ""}} {
        if {$ended} return
        $self TeardownMedia
        if {$wire ne ""} {
            $self SendTerminate $wire
        }
        if {$has_session && $group eq "" && [jid resource $peer] ne ""} {
            set why [expr {$event eq "Failed" ? "connectivity-error" : "success"}]
            if {$wire ne ""} { set why $wire }
            $client write [$calls BuildJmiFinish $peer $sid $why]
        }
        if {$event eq "Failed"} {
            jlog warn "call $sid with $peer failed: $reason"
        }
        $client emit calls <$event> -sid $sid -reason $reason
        $self End
    }

    # Every field, as a dict, and each armed timer as <name>_timer: for
    # tests and debugging.
    method Fields {} {
        set out {}
        foreach v [$self info vars] {
            if {![array exists $v]} { dict set out [namespace tail $v] [set $v] }
        }
        foreach name [array names Timers] {
            dict set out ${name}_timer [lindex $Timers($name) 0]
        }
        return $out
    }

    # =========================================================================
    # Timers
    # =========================================================================

    # Arm the timer $name to run method $args in $ms, in place of one that
    # runs. Fire runs it early; a timer is disarmed before its method runs.
    method Arm {name ms args} {
        $self Disarm $name
        set Timers($name) [list [after $ms [mymethod Fire $name]] $args]
    }

    method Fire {name} {
        if {![info exists Timers($name)]} return
        set command [lindex $Timers($name) 1]
        $self Disarm $name
        $self {*}$command
    }

    method Armed {name} { info exists Timers($name) }

    method Disarm {name} {
        if {![info exists Timers($name)]} return
        after cancel [lindex $Timers($name) 0]
        unset Timers($name)
    }

    method DisarmAll {} {
        foreach name [array names Timers] { $self Disarm $name }
    }

    # =========================================================================
    # The machines
    # =========================================================================

    # Move $machine (state or transport) to $to. A move its table does not
    # list is refused, logged and kept in IllegalMoves; staying where it is
    # is no move. Returns 1 if it moved.
    method Go {machine to} {
        set from [set $machine]
        if {$from eq $to} { return 0 }
        set table [expr {$machine eq "state" ? $SESSION_NEXT : $TRANSPORT_NEXT}]
        if {$to ni [dict getdef $table $from {}]} {
            jlog error "call $sid: $machine $from -> $to is not a move"
            lappend IllegalMoves [list $sid $machine $from $to]
            return 0
        }
        set $machine $to
        if {$machine eq "state" && $to eq "proceeded"} {
            $self Disarm ring
            $self StartSetupTimer
        }
        return 1
    }

    # Whether the session in its state takes $action from its peer
    # (JINGLE_IN).
    method Takes {action} {
        expr {$action in [dict getdef $JINGLE_IN $state {}]}
    }

    # Bare match while peer is still a bare JID (the JMI window: we
    # proposed to the account, any of its resources may answer), exact
    # full JID once the session is latched to one resource.
    method Matches {from} {
        if {![jid valid $from] || ![jid matches-bare $from $peer]} { return 0 }
        set res [jid resource $peer]
        expr {$res eq "" || [jid resource $from] eq $res}
    }

    # Our propose to $from's account, not yet answered.
    method ProposedTo {from} {
        expr {$initiator && $state eq "proposed" && [jid matches-bare $from $peer]}
    }

    # Our group session to $from (full JID), not yet answered.
    method UnansweredTo {from} {
        expr {$initiator && $group ne "" && $peer eq $from && !$remote_set}
    }

    method Initiated {} { return $has_session }

    # The call as `list` shows it.
    method Row {} {
        dict create \
            sid          $sid \
            peer         [jid bare $peer] \
            direction    [expr {$initiator ? "outgoing" : "incoming"}] \
            state        [$self PublicState] \
            connection   [$self ConnectionState] \
            peer_ringing $peer_ringing \
            group        $group \
            video_local  $video_local \
            video_remote $video_remote \
            verified     $verified \
            fingerprint  $fingerprint \
            active_since $active_since
    }

    # The state `list` shows, as it always has: the session's until it is
    # pending, then the media path's.
    method PublicState {} {
        if {$state in {proposed ringing}
                || ($state eq "proceeded" && $transport eq "idle")} {
            return $state
        }
        switch -- $transport {
            idle      { return new }
            connected { return active }
            default   { return connecting }
        }
    }

    # The media path as `list` and <Connection> name it: connecting until
    # it first connects, then connected, interrupted, or reconnecting while
    # the backend checks for a path again.
    method ConnectionState {} {
        if {!$ever_connected} {
            return [expr {$transport eq "connected" ? "connected" : "connecting"}]
        }
        switch -- $transport {
            checking   -
            restarting { return reconnecting }
            default    { return $transport }
        }
    }

    # =========================================================================
    # Ringing, answering, hanging up
    # =========================================================================

    # RingTimeout rechecks the state: it can fire in the same turn as an
    # accept or proceed.
    method StartRingTimer {} {
        $self Arm ring $RING_TIMEOUT_MS RingTimeout
    }

    # Ours is retracted; theirs is rejected with <timeout/> and missed.
    method RingTimeout {} {
        switch -- $state {
            proposed {
                if {$initiator} { $self Retract timeout }
            }
            ringing {
                $client write [$calls BuildJmiReject $peer $sid timeout]
                $self Finish Ended timeout
                $calls EmitMissed $sid $peer $video_remote timeout
            }
        }
    }

    # Answered: the call has SETUP_TIMEOUT_MS to first connect.
    method StartSetupTimer {} {
        if {[$self Armed setup]} return
        $self Arm setup $SETUP_TIMEOUT_MS SetupTimeout
    }

    method SetupTimeout {} {
        if {$ever_connected} return
        $self Finish Failed \
            "no media path within [expr {$SETUP_TIMEOUT_MS / 1000}] s" timeout
    }

    # The user answers: JMI <proceed>. Media waits for the caller's
    # session-initiate.
    method Accept {} {
        if {$state ne "ringing"} return
        $client write [$calls BuildJmiMessage $peer proceed $sid 0 0 \
            [$self AnnounceDevice]]
        $self Go state proceeded
    }

    # The user ends the call: before an answer that is JMI, declining a
    # ring or retracting our propose; after it the session ends with
    # $reason.
    method Hangup {reason} {
        switch -- $state {
            ringing  { $self Decline }
            proposed { $self Retract retracted }
            default  { $self Finish Ended hangup $reason }
        }
    }

    # Turn down a call ringing here (XEP-0353 <reject/>).
    method Decline {} {
        $client write [$calls BuildJmiMessage $peer reject $sid 0]
        $self Finish Ended declined
    }

    # Cancel a call that never got past our own <propose>. There is no
    # session to terminate yet, so XEP-0353 wants a retract.
    method Retract {why} {
        $client write [$calls BuildJmiMessage $peer retract $sid 0]
        $self Finish Ended $why
    }

    # The peer ended the session (session-terminate or JMI <finish/>) with
    # the XEP-0166 condition $reason: one of FAULTS fails the call here
    # too, anything else ends it.
    method PeerEnded {reason} {
        if {$reason in $FAULTS} {
            $self Finish Failed "the peer reported $reason"
        } else {
            $self Finish Ended hangup
        }
    }

    # A fresh (non-resumed) stream, which bound $me. Signalling for a
    # session is addressed to our full JID, so a session survives only where
    # the new stream bound the same one, and only if it is worth keeping:
    # up, with media flowing, since the media path is peer to peer and may
    # well have outlived the outage. Everything else ends: a ring or setup
    # in flight lost messages we cannot know of, and a group call's legs
    # follow its room, which the fresh stream left.
    method OnFreshStream {me} {
        if {$state eq "established" && $transport eq "connected"
                && $group eq "" && $self_jid eq $me} {
            jlog inform "call $sid kept across a fresh stream"
            return
        }
        $self Finish Ended reset
    }

    # The stream came back with its session: a media path that was lost
    # meanwhile most likely went with the network, so restart it now
    # rather than wait out the backend.
    method OnResumed {} {
        if {$transport ni {interrupted checking} || !$ever_connected} return
        $self StartRestart "the stream to the server came back"
    }

    # =========================================================================
    # Verification (see the taco_calls header)
    # =========================================================================

    # Our device for <propose>/<proceed>, or "". Records that we sent it.
    method AnnounceDevice {} {
        set dev [$calls OwnDevice $peer]
        if {$dev ne ""} { set announced 1 }
        return $dev
    }

    # Record the device from the peer's <propose>/<proceed> $child. The
    # caller also starts the session now so the offer doesn't wait on a
    # bundle fetch. The callee doesn't: the caller's prekey message will
    # create the session.
    method NotePeerDevice {child} {
        set dev [xsearch $child device -ns $NS_VERIFY -get @id]
        if {![string is integer -strict $dev] || $dev <= 0} return
        set peer_device $dev
        if {$initiator && [$calls OwnDevice $peer] ne ""} {
            catch {$client omemo readySession [jid bare $peer] $dev}
        }
    }

    # Decrypt the fingerprints in the peer's session-initiate/accept and
    # return the jingle with plain ones, or "" if the call was failed.
    # $expect: the fingerprint must be encrypted (ours was).
    method TakeFingerprints {stanza jingle from expect} {
        if {$group ne ""} { return $jingle }
        set bare [jid bare $from]
        set encrypted 0
        set plain 0
        set by ""
        foreach slot [::taco_calls::verify::transports $jingle] {
            set tr [::taco_calls::verify::get $jingle $slot]
            set fp [::taco_calls::verify::plain $tr]
            set efp [xsearch $tr fingerprint -ns $NS_VERIFY -get node]
            if {$efp eq ""} { incr plain; continue }
            if {$fp ne ""} {
                return [$self FailUnverified $stanza \
                    "a fingerprint came both plain and encrypted"]
            }
            set enc [xsearch $efp encrypted -ns $NS_AXOLOTL -get node]
            if {$enc eq ""} {
                return [$self FailUnverified $stanza \
                    "an encrypted fingerprint without its encryption"]
            }
            set r [$client omemo decryptFrom $enc $bare]
            if {[dict get $r status] ne "ok"} {
                return [$self FailUnverified $stanza [dict get $r reason]]
            }
            if {$by ne "" && [dict get $r device] != [dict get $by device]} {
                return [$self FailUnverified $stanza "fingerprints from two devices"]
            }
            set by $r
            lassign [xsearch $efp -get {@hash @setup}] hash setup
            set body [string trim [dict get $r plaintext]]
            if {[catch {::jinglesdp::CheckFingerprint $hash $body $setup}]} {
                return [$self FailUnverified $stanza \
                    "the encrypted fingerprint is not a fingerprint"]
            }
            set jingle [::taco_calls::verify::put $jingle $slot \
                [::taco_calls::verify::decrypted $tr $hash $setup $body]]
            incr encrypted
        }
        if {$encrypted && $plain} {
            return [$self FailUnverified $stanza "only some fingerprints were encrypted"]
        }
        if {$expect && !$encrypted} {
            return [$self FailUnverified $stanza "the fingerprint was not encrypted"]
        }
        if {$by eq ""} {
            set verified 0
            set fingerprint ""
        } else {
            set omemo_device [dict get $by device]
            set fingerprint  [dict get $by fingerprint]
            set verified     [dict get $by accepted]
        }
        $self EmitVerified
        return $jingle
    }

    # Ack the IQ and end the session with security-error, as Conversations
    # does. Returns "".
    method FailUnverified {stanza reason} {
        $calls AckIq $stanza
        $self Finish Failed "call could not be verified: $reason" security-error
        return ""
    }

    method EmitVerified {} {
        $client emit calls <Verified> -sid $sid -verified $verified \
            -fingerprint $fingerprint
    }

    # Trust changed for $who's keys, or for everyone's when $who is "":
    # recheck the device the peer's fingerprint came from.
    method Reverify {who} {
        if {$omemo_device eq ""} return
        set bare [jid bare $peer]
        if {$who ne "" && $bare ne $who} return
        set now [$client omemo deviceAccepted $bare $omemo_device]
        if {$now == $verified} return
        set verified $now
        $self EmitVerified
    }

    # =========================================================================
    # Devices
    # =========================================================================

    # Mute / unmute the camera. Video is negotiated at start/answer; this
    # only toggles capture.
    method SetVideo {on} {
        if {$pc eq -1} return
        ::tacky::media setVideoEnabled $pc -on [expr {$on ? 1 : 0}]
    }

    # Hot-swap the mic ($kind capture) or speaker (playback); "" is the
    # system default. A backend with nothing attached yet ignores it; one
    # that refuses the device answers with an error event, which becomes a
    # <Warning>.
    method SetAudioDevice {kind id} {
        if {$pc eq -1 || ![::tacky::media capability audioDevices]} return
        ::tacky::media setAudioDevice $pc -kind $kind -id $id
    }

    method SetAudioVolume {kind volume} {
        if {$pc eq -1} return
        ::tacky::media setAudioVolume $pc -kind $kind -volume $volume
    }

    method SetCamera {id} {
        if {!$vsend} return
        ::tacky::media setVideoDevice $pc -id $id
    }

    # =========================================================================
    # PC + media plumbing
    # =========================================================================

    # A fresh pc, its events bound to this call. The caller then adds
    # tracks and attaches media; the callee drives setRemoteDescription and
    # attaches from the `track` events. The pc is recorded only once
    # createPeer took it, so a refused one leaves nothing to close. It is
    # named after the account's calls too, so two accounts in one process
    # on either side of the same call do not collide.
    method CreatePc {iceServers} {
        # The last word for every path into media, ours or the peer's.
        set why [$calls Blocked]
        if {$why ne ""} {
            error [string tolower $why 0 0]
        }
        set name $calls/$sid
        ::tacky::media createPeer $name -sid $sid \
            -command [$self Callback OnMediaEvent] -ice-servers $iceServers
        set pc $name
    }

    # Attach the mic + speaker to a track. The persisted
    # audio_input_device / audio_output_device settings pin specific
    # endpoints; a backend that cannot open one falls back to its default
    # and says so with deviceFallback, so a stale setting - a device that
    # went away, or an id stored against another backend - can't brick
    # every call.
    method AttachMedia {tr} {
        set taco [$client cget -taco]
        set track $tr
        ::tacky::media attachAudio $pc $tr \
            -input         [$taco audio getPreferredDevice -kind capture] \
            -output        [$taco audio getPreferredDevice -kind playback] \
            -input-volume  [$taco audio getVolume -kind capture] \
            -output-volume [$taco audio getVolume -kind playback]
    }

    # Camera -> the peer, plus a self-view: the backend answers with a
    # preview videoChannel, which becomes <VideoPreview>.
    method AttachVideoSender {tr} {
        if {$vsend} return
        set camId ""
        catch {set camId [[$client cget -taco] video getPreferredCamera]}
        set vsend 1
        ::tacky::media attachVideoSender $pc $tr -device-id $camId
    }

    # The peer's camera -> a frame channel. The backend answers with an
    # incoming videoChannel, which becomes <VideoTrack>.
    method AttachVideoReceiver {tr} {
        if {$vrecv} return
        set vtrack $tr
        set vrecv 1
        ::tacky::media attachVideoReceiver $pc $tr
    }

    # Free media + pc. The backend owns the ordering its own handles need;
    # all this decides is whether the video half was ever up, since
    # <VideoEnded> is owed only then.
    method TeardownMedia {} {
        set hadVideo [expr {$vsend || $vrecv}]
        if {$pc ne -1} {
            ::tacky::media closePeer $pc
        }
        if {$hadVideo} {
            $client emit calls <VideoEnded> -sid $sid -mid $VIDEO_MID
        }
        set pc     -1
        set track  -1
        set vtrack -1
        set vsend  0
        set vrecv  0
    }

    # Caller side, once extdisco has the ICE servers (an empty list means
    # host candidates only): the pc, the sendrecv tracks, and the offer. A
    # setup that raises (the backend refusing the pc, a track, the offer)
    # fails the call instead of reaching bgerror and leaving it hanging.
    method StartOutgoingMedia {iceServers} {
        if {[catch {$self SetUpOutgoingMedia $iceServers} err]} {
            $self Finish Failed "media setup failed: $err" general-error
        }
    }

    method SetUpOutgoingMedia {iceServers} {
        $self CreatePc $iceServers
        ::tacky::media addTrack $pc $MID -kind audio -direction sendrecv
        $self AttachMedia $MID
        if {$ended} return
        if {$video_local} {
            ::tacky::media addTrack $pc $VIDEO_MID -kind video -direction sendrecv
            $self AttachVideoSender $VIDEO_MID
            $self AttachVideoReceiver $VIDEO_MID
        }
        # No type: with no remote description set, this is the offer.
        ::tacky::media setLocalDescription $pc
    }

    # Callee side, likewise: the pc, the peer's offer, and the candidates
    # that came while the fetch was out.
    method StartIncomingMedia {sdp iceServers} {
        if {[catch {$self SetUpIncomingMedia $sdp $iceServers} err]} {
            $self Finish Failed "media setup failed: $err" general-error
        }
    }

    method SetUpIncomingMedia {sdp iceServers} {
        $self CreatePc $iceServers
        # `track` events attach the media. A backend that rejects the offer
        # reports an error, which has failed the call by the time this
        # returns.
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type offer
        if {$ended} return
        $self TakeSdpError
        set remote_set 1
        # An `autoAnswer` backend has applied its own answer as part of
        # setRemoteDescription(offer) and calling setLocalDescription now
        # would run in signaling state Stable, where an unspecified type
        # means Offer — generating a fresh offer that silently overwrites
        # that answer. libdatachannel does this
        # (config.disableAutoNegotiation is false by default); libwebrtc
        # does not, and needs the explicit answer.
        if {![::tacky::media capability autoAnswer]} {
            ::tacky::media setLocalDescription $pc -type answer
            if {$ended} return
        }
        $self DrainPendingCandidates
    }

    # Apply the candidates that arrived (and were buffered) before the
    # remote description. A rejected one isn't fatal to a description that
    # just applied cleanly; {Media error} logs and skips it.
    method DrainPendingCandidates {} {
        set cands $pending_remote_candidates
        set pending_remote_candidates {}
        $self AddCandidates $cands
    }

    method AddCandidates {cands} {
        foreach c $cands {
            if {$ended || $pc eq -1} return
            lassign $c mid cand
            ::tacky::media addRemoteCandidate $pc -candidate $cand -mid $mid
        }
    }

    method BufferCandidate {mid cand} {
        if {[llength $pending_remote_candidates] >= $MAX_PENDING_CANDIDATES} {
            jlog debug "transport-info: candidate buffer full"
            return
        }
        lappend pending_remote_candidates [list $mid $cand]
    }

    # Did the setRemoteDescription just issued fail? Only a backend
    # reporting synchronously can answer in time; with an async one the IQ
    # is already acked and {Media error}'s report is the whole story.
    method TakeSdpError {} {
        set err $sdp_error
        set sdp_error ""
        return $err
    }

    # =========================================================================
    # Media events (async, delivered on the Tcl main thread)
    # =========================================================================

    # One {Media type} method per event the call cares about.
    method OnMediaEvent {ev} {
        set type [dict get $ev type]
        # SDP is logged where it is sent.
        if {$type ne "localDescription"} {
            jlog debug "media event (sid=$sid): [dict remove $ev pc]"
        }
        if {"Media $type" in [$self info methods {Media *}]} {
            $self Media $type $ev
        }
    }

    # Fires once per setLocalDescription, and on the responder once more
    # when an `autoAnswer` backend generates the answer inside
    # setRemoteDescription. The SDP here has no candidates yet — those
    # arrive asynchronously and are trickled separately.
    method {Media localDescription} {ev} {
        set sdp [dict get $ev sdp]
        set sdpType [dict get $ev sdpType]

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

        jlog debug "SDP $sdpType to $peer (sid=$sid)\n[jlog_redact_sdp $sdp]"

        # Kept for the candidates that trickle after it: XEP-0176 5.3 has
        # every transport-info carry them.
        regexp -line {^a=ice-ufrag:(\S+)} $sdp -> ufrag
        regexp -line {^a=ice-pwd:(\S+)} $sdp -> pwd
        # The DTLS role we took. An offer says actpass whoever made it -
        # our restart offer too - so only an answer's active/passive is
        # the role, and it lasts the session (RFC 9429 §5.3.3).
        regexp -line {^a=setup:(active|passive)} $sdp -> local_setup

        # A description of an ICE restart goes out as one, never as the
        # session's own.
        if {$transport eq "restarting"} {
            $self OnRestartDescription $sdp $sdpType
            return
        }

        # Only the session's own descriptions go out as such: the caller's
        # first offer from proceeded, the callee's answer from pending. Any
        # other is a backend speaking out of turn and goes nowhere.
        if {!($sdpType eq "offer" && $initiator && $state eq "proceeded")
                && !($sdpType eq "answer" && !$initiator && $state eq "pending")} {
            jlog warn "call $sid: a local $sdpType in $state is not sent"
            return
        }

        # SDP->Jingle (creator stays "initiator" on both sides — the
        # responder echoes the initiator's content names verbatim).
        set jingle [::jinglesdp::from_sdp $sdp \
            -creator initiator -initiator $initiator]
        if {$sdpType eq "offer"} {
            set jingle [$self Stamp $jingle session-initiate 1]
            if {$group ne ""} {
                # XEP-0272: a session belonging to a Muji conference says so.
                dict lappend jingle children \
                    [j muji -ns urn:xmpp:jingle:muji:0 -room $group]
            }
            # Sent: a crossing initiate is now settled by sid.
            set has_session 1
            $self NoteContents $jingle
            $self Go state pending
            $self SendDescription $jingle OnInitiateAck
        } else {
            $self Go state established
            $self SendDescription [$self Stamp $jingle session-accept 1] OnAcceptAck
        }
    }

    method {Media iceCandidate} {ev} {
        $self SendCandidate [dict get $ev candidate] [dict get $ev mid]
    }

    method {Media connectionState} {ev} {
        $self OnPcState [dict get $ev state]
    }

    # The backend reports the media kind: a real peer's offer carries its
    # own BUNDLE mids, not our "audio"/"video" labels, so the mid is only
    # good for reporting.
    method {Media track} {ev} {
        set tr [dict get $ev track]
        if {[dict get $ev kind] eq "video"} {
            if {$vtrack ne -1} return
            $self AttachVideoReceiver $tr
            if {$video_local} {
                $self AttachVideoSender $tr
            }
            return
        }
        if {$track ne -1} return
        $self AttachMedia $tr
    }

    # A frame channel came up: <VideoTrack> for the peer's camera,
    # <VideoPreview> for our own self-view. A frame stream is named; a
    # host-rendered channel just carries its id.
    method {Media videoChannel} {ev} {
        set ch [dict get $ev channel]
        set flags {}
        foreach key {name id} {
            if {[dict exists $ch $key]} { lappend flags -$key [dict get $ch $key] }
        }
        if {[dict get $ev direction] eq "preview"} {
            jlog debug "<VideoPreview> (sid=$sid) $flags"
            $client emit calls <VideoPreview> -sid $sid -direction preview {*}$flags
            return
        }
        jlog debug "<VideoTrack> (sid=$sid) $flags"
        $client emit calls <VideoTrack> -sid $sid -mid [dict get $ev mid] \
            -direction incoming {*}$flags
    }

    # The backend could not open the device we asked for and used its
    # default. The call is fine; the user just isn't on the endpoint they
    # picked, so say so.
    method {Media deviceFallback} {ev} {
        set what [dict getdef {playback output camera camera} [dict get $ev kind] input]
        $client emit calls <Warning> -sid $sid \
            -reason "$what device unavailable, using default"
    }

    # Backend errors. Each op the call drives has its own report, since
    # the text and the consequence differ; anything else falls through to
    # the generic rule - fatal ends the call, advisory warns and it runs on.
    method {Media error} {ev} {
        set reason [dict get $ev reason]
        set side [expr {[dict getdef $ev kind ""] eq "capture" ? "input" : "output"}]
        switch -- [dict get $ev op] {
            setRemoteDescription {
                # Kept for the handler that issued it: with a backend that
                # reports synchronously it is still on the stack and can
                # answer the IQ accordingly.
                set sdp_error $reason
                if {[dict getdef $ev sdpType ""] eq "answer"} {
                    $client emit calls <Warning> -sid $sid \
                        -reason "session-accept rejected: $reason"
                    return
                }
                # An offer we cannot apply is fatal, and the
                # session-initiate is already acked — the peer thinks the
                # call is live, so terminate rather than leave it to
                # time out.
                $self Finish Failed "remote offer rejected: $reason" general-error
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
                    $client emit calls <Warning> -sid $sid \
                        -reason "$side device could not be opened: $reason"
                    return
                }
            }
            setAudioDevice {
                $client emit calls <Warning> -sid $sid \
                    -reason "$side device unavailable: $reason"
                return
            }
            setAudioVolume {
                $client emit calls <Warning> -sid $sid \
                    -reason "$side volume rejected: $reason"
                return
            }
            attachVideoSender {
                set vsend 0
                $client emit calls <Warning> -sid $sid -reason "video sender: $reason"
                return
            }
            attachVideoReceiver {
                set vrecv 0
                set vtrack -1
                $client emit calls <Warning> -sid $sid -reason "video receiver: $reason"
                return
            }
        }
        # A pc the backend gave up on: the peer is told, as for any
        # failure, or it keeps a call nobody is on.
        if {[dict getdef $ev fatal 0]} {
            $self Finish Failed $reason [expr {$has_session ? "general-error" : ""}]
            return
        }
        $client emit calls <Warning> -sid $sid -reason $reason
    }

    # =========================================================================
    # Our side of the signalling
    # =========================================================================

    # $jingle as this session's $action. $signed names us as initiator or
    # responder, as XEP-0166 has the session's own actions do.
    method Stamp {jingle action {signed 0}} {
        dict set jingle attrs action $action
        dict set jingle attrs sid $sid
        if {$signed} {
            dict set jingle attrs [expr {$initiator ? "initiator" : "responder"}] \
                [$client cget -jid]
        }
        return $jingle
    }

    # Send our session-initiate/accept. If both sides announced a device,
    # encrypt the fingerprints first; local candidates are held meanwhile.
    # If encryption fails the call fails; we never fall back to plain.
    method SendDescription {jingle ack} {
        if {$group ne "" || !$announced || $peer_device eq ""} {
            $self ShipDescription $jingle $ack
            return
        }
        set describing 1
        $self EncryptFingerprints $jingle $ack [::taco_calls::verify::transports $jingle]
    }

    method EncryptFingerprints {jingle ack slots} {
        if {![llength $slots]} {
            set fingerprint_encrypted 1
            $self ShipDescription $jingle $ack
            return
        }
        set fp [::taco_calls::verify::plain \
            [::taco_calls::verify::get $jingle [lindex $slots 0]]]
        if {$fp eq ""} {
            $self EncryptFingerprints $jingle $ack [lrange $slots 1 end]
            return
        }
        $client omemo encryptFor [jid bare $peer] $peer_device [dict get $fp body] \
            [$self Callback AfterEncryptFingerprint $jingle $ack $slots]
    }

    method AfterEncryptFingerprint {jingle ack slots status enc} {
        if {$status ne "ok"} {
            set describing 0
            $self Finish Failed "call could not be verified: $enc" security-error
            return
        }
        set slot [lindex $slots 0]
        set jingle [::taco_calls::verify::put $jingle $slot \
            [::taco_calls::verify::encrypted \
                [::taco_calls::verify::get $jingle $slot] $enc]]
        $self EncryptFingerprints $jingle $ack [lrange $slots 1 end]
    }

    method ShipDescription {jingle ack} {
        $client iq request -type set -to $peer -payload $jingle \
            -command [$self Callback $ack]
        if {!$describing} return
        set describing 0
        $self SendHeldCandidates
    }

    method OnInitiateAck {stanza} {
        if {[xsearch $stanza -get @type] ne "error"} return
        # <tie-break/>: the peer kept its own initiate; not a refusal.
        set lost [expr {[xsearch $stanza error tie-break \
            -ns urn:xmpp:jingle:errors:1 -get node] ne ""}]
        $self Finish Failed [expr {$lost
            ? "session-initiate lost a tie-break" : "session-initiate rejected"}]
    }

    method OnAcceptAck {stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $client emit calls <Warning> -sid $sid -reason "session-accept rejected"
        }
    }

    # Trickle a single ICE candidate to the peer. The API carries the SDP
    # attribute form ("candidate:foo bar baz..."); we strip the
    # "candidate:" prefix so jinglesdp::BuildCandidate sees the same
    # shape it parses out of SDP. An empty mid falls back to the bundle
    # group's audio MID.
    method SendCandidate {cand mid} {
        # Hold candidates until the description is sent, or our restart's
        # credentials are taken: one carrying the new credentials before
        # them would read as an answer to a restart nobody offered.
        if {$describing || $restart_hold} {
            lappend held_candidates [list $cand $mid]
            return
        }
        set node [::jinglesdp::BuildCandidate [regsub {^candidate:} $cand ""]]
        if {$node eq ""} return
        if {$mid eq ""} { set mid $MID }
        set credentials {}
        if {$ufrag ne ""} { lappend credentials -ufrag $ufrag }
        if {$pwd ne ""}   { lappend credentials -pwd $pwd }
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j content -creator initiator -name $mid {
                j transport -ns $NS_ICE_UDP {*}$credentials {
                    j #as-is $node
                }
            }
        }]
        $client iq request -type set -to $peer \
            -payload [$self Stamp $jingle transport-info 1] \
            -command [$self Callback OnTransportInfoAck]
    }

    method SendHeldCandidates {} {
        set held $held_candidates
        set held_candidates {}
        foreach h $held { $self SendCandidate {*}$h }
    }

    # The peer answering our transport-info. One that no longer knows the
    # session ends it here too; any other error - a peer offline for a
    # moment, a server in the way - leaves the call to its media path.
    method OnTransportInfoAck {stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $self EndIfPeerGone $stanza
        }
    }

    # The IQ error $stanza says the peer has no such session (it ended it,
    # and we missed the terminate, or it restarted), or its resource is not
    # there - its server answers so only for a resource that is gone, one
    # whose stream waits to be resumed having its stanzas held instead. A
    # call cannot be kept up, or restarted, without signalling to it: end
    # it. Returns 1 if it did.
    method EndIfPeerGone {stanza} {
        set stanzas urn:ietf:params:xml:ns:xmpp-stanzas
        if {[xsearch $stanza error unknown-session -ns urn:xmpp:jingle:errors:1 -get node] ne ""
                || [xsearch $stanza error item-not-found -ns $stanzas -get node] ne ""} {
            $self Finish Failed "the peer no longer has the session"
            return 1
        }
        foreach condition {service-unavailable recipient-unavailable} {
            if {[xsearch $stanza error $condition -ns $stanzas -get node] ne ""} {
                $self Finish Failed "the peer went offline"
                return 1
            }
        }
        return 0
    }

    method SendTerminate {reason} {
        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j reason {
                j $reason
            }
        }]
        $client iq request -type set -to $peer \
            -payload [$self Stamp $jingle session-terminate]
    }

    # Turn down the contents of an incoming $jingle with $action, naming
    # each content (and, for a transport-reject, the transport refused).
    method SendReject {action jingle withTransport} {
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
        dict set out children $contents
        $client iq request -type set -to $peer -payload [$self Stamp $out $action]
    }

    # =========================================================================
    # The media path
    # =========================================================================

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
    method OnPcState {reported} {
        set pc_state $reported
        if {$transport eq "restarting" && $reported ni {connected closed}} return
        switch -- $reported {
            connecting {
                $self Go transport checking
            }
            connected {
                # Said again of a path already up, it is no news.
                if {$transport eq "connected"} return
                $self Disarm interrupted
                $self EndRestart
                $self Go transport connected
                $self OnConnected
            }
            disconnected {
                if {[$self Go transport interrupted]} {
                    $self MediaLost
                    $self Arm interrupted $DISCONNECT_GRACE_MS WarnInterrupted
                }
            }
            failed {
                if {[$self StartRestart "the media path failed"]} return
                if {[$self AwaitPeerRestart]} return
                # The peer is told in Jingle: a peer that ends a session
                # only on session-terminate (another.im's Android app)
                # otherwise keeps the call up, its video frozen.
                $self Finish Failed "media path failed (ICE/DTLS)" connectivity-error
            }
            closed {
                $self Finish Ended hangup success
            }
        }
    }

    # Media flows: the first time it stamps the call and ends the setup
    # timer; every time it is <Active>, with the first stamp, and a
    # <Connection> that takes back an interruption the GUI was told of.
    method OnConnected {} {
        $self Disarm loss
        if {!$ever_connected} {
            set ever_connected 1
            set active_since [clock microseconds]
            $self Disarm setup
        }
        $client emit calls <Active> -sid $sid -since $active_since
        if {$told_interrupted} {
            set told_interrupted 0
            set told_connection ""
            jlog debug "call $sid: <Connection> connected"
            $client emit calls <Connection> -sid $sid -state connected
        }
    }

    method WarnInterrupted {} {
        $self Arm interrupted [expr {max(0, $RESTART_AFTER_MS - $DISCONNECT_GRACE_MS)}] \
            RestartInterrupted
        $self TellConnection interrupted
        $client emit calls <Warning> -sid $sid -reason "media path interrupted"
    }

    # Still interrupted: the backend did not recover by itself.
    method RestartInterrupted {} {
        if {$transport ne "interrupted"} return
        $self StartRestart "the media path stayed interrupted"
    }

    # <Connection> $how, said once per change. Anything said but
    # `connected` is taken back by OnConnected.
    method TellConnection {how} {
        if {$told_connection eq $how} return
        set told_connection $how
        set told_interrupted 1
        jlog debug "call $sid: <Connection> $how"
        $client emit calls <Connection> -sid $sid -state $how
    }

    # Media stopped flowing: the call has MEDIA_LOSS_MAX_MS to get it back,
    # whatever is tried meanwhile.
    method MediaLost {} {
        if {[$self Armed loss]} return
        $self Arm loss $MEDIA_LOSS_MAX_MS Finish Failed \
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
    # `restart` says where one stands while transport is restarting:
    #   offering   we asked our backend for a restart offer
    #   awaiting   our offer is out; the peer's answer has not come
    #   answering  we applied the peer's offer and owe our answer
    #   answered   our answer's credentials go out with our candidates
    # Each has RESTART_WAIT_MS of live signalling to connect.

    # Start a restart of our own, if this call and backend can: returns 1 if
    # one is under way (started now, or already).
    method StartRestart {why} {
        if {$transport eq "restarting"} { return 1 }
        if {![$self CanRestart]} { return 0 }
        incr restarts
        incr restart_attempts
        jlog inform "call $sid: $why, restarting ICE ($restarts of $MAX_RESTARTS)"
        $self Disarm interrupted
        $self Go transport restarting
        $self MediaLost
        set restart offering
        set restart_hold 1
        $self TellConnection reconnecting
        $self Arm restart $RESTART_WAIT_MS RestartWaited
        if {[catch {::tacky::media setLocalDescription $pc \
                -type offer -ice-restart 1} err]} {
            jlog warn "call $sid: the restart offer was refused: $err"
            $self RestartFailed
        }
        return 1
    }

    method CanRestart {} {
        expr {$state eq "established" && $pc ne -1 && $remote_jingle ne ""
            && [::tacky::media capability restartIce]
            && ($initiator || [::tacky::media capability rollback])
            && $restarts < $MAX_RESTARTS
            && $restart_attempts < $MAX_RESTART_ATTEMPTS}
    }

    # We cannot restart, but the peer can and we could follow: give it the
    # time a restart gets. Returns 1 if waiting.
    method AwaitPeerRestart {} {
        if {![::tacky::media capability iceRestart] || $state ne "established"
                || $remote_jingle eq ""
                || $restart_attempts >= $MAX_RESTART_ATTEMPTS} {
            return 0
        }
        jlog inform "call $sid: the media path failed; waiting for the peer to restart it"
        $self Go transport interrupted
        $self MediaLost
        incr restart_attempts
        $self TellConnection interrupted
        $self Arm restart $RESTART_WAIT_MS RestartWaited
        return 1
    }

    # Our backend's description during a restart.
    method OnRestartDescription {sdp sdpType} {
        if {$sdpType eq "offer" && $restart eq "offering"} {
            set restart awaiting
            # Lost a glare before our offer even existed: drop it, and
            # follow the initiator's offer that won.
            if {[dict size $glare_offer]} {
                $self RollBackAndFollow
            } else {
                $self SendIceCredentials $sdp
            }
            return
        }
        if {$sdpType eq "answer" && $restart eq "answering"} {
            set restart answered
            $self ReleaseLocalCandidates
            $self RestartSettled
            return
        }
        jlog warn "call $sid: a local $sdpType during restart $restart is not sent"
    }

    # The credentials of our restart offer, alone, one <transport> per
    # content (XEP-0176 §5.9). Candidates wait for the IQ result.
    method SendIceCredentials {sdp} {
        set offer [::jinglesdp::from_sdp $sdp -creator initiator -initiator $initiator]
        set contents {}
        foreach c [xsearch $offer content -gather node] {
            set tr [xsearch $c transport -ns $NS_ICE_UDP -get node]
            if {$tr eq ""} continue
            lassign [xsearch $tr -get {@ufrag @pwd}] u p
            lappend contents [j content -creator initiator -name [xsearch $c -get @name] {
                j transport -ns $NS_ICE_UDP -ufrag $u -pwd $p
            }]
        }
        set jingle [j jingle -ns urn:xmpp:jingle:1]
        dict set jingle children $contents
        $client iq request -type set -to $peer \
            -payload [$self Stamp $jingle transport-info 1] \
            -command [$self Callback OnRestartOfferAck]
    }

    # The peer took our restart offer: our candidates may follow. Turned
    # down with <tie-break/>, ours lost a glare to the initiator's offer,
    # which is coming (or came); anything else, the peer will not restart.
    method OnRestartOfferAck {stanza} {
        if {[xsearch $stanza -get @type] ne "error"} {
            $self ReleaseLocalCandidates
            return
        }
        if {[xsearch $stanza error tie-break -ns urn:xmpp:jingle:errors:1 -get node] ne ""} {
            jlog inform "call $sid: our ICE restart lost a tie-break"
            return
        }
        if {[$self EndIfPeerGone $stanza]} return
        jlog warn "call $sid: the peer refused our ICE restart"
        $self RestartFailed
    }

    method ReleaseLocalCandidates {} {
        if {!$restart_hold} return
        set restart_hold 0
        if {!$describing} { $self SendHeldCandidates }
    }

    # The peer restarted: $creds is content name -> its new <transport>.
    # Apply its description under them as an offer, and answer it. Returns
    # 1 if followed.
    method FollowRestart {creds} {
        if {![::tacky::media capability iceRestart] || $pc eq -1
                || $remote_jingle eq ""} {
            jlog warn "call $sid: the peer restarted ICE, which this backend cannot follow"
            $client emit calls <Warning> -sid $sid \
                -reason "the peer moved the call to a new connection, which this device cannot follow"
            return 0
        }
        jlog inform "call $sid: the peer restarted ICE; following"
        $self Disarm interrupted
        $self Go transport restarting
        $self MediaLost
        set restart answering
        # A backend may report the new generation's candidates before our
        # answer, which names their credentials: they wait for it.
        set restart_hold 1
        $self TellConnection reconnecting
        $self Arm restart $RESTART_WAIT_MS RestartWaited
        set sdp [$self RemoteSdp $creds actpass]
        if {$sdp eq ""} { return 1 }
        $self TakeRemoteIce $creds
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type offer
        if {$ended} { return 1 }
        if {[$self TakeSdpError] ne ""} {
            $self RestartFailed
            return 1
        }
        if {![::tacky::media capability autoAnswer]} {
            ::tacky::media setLocalDescription $pc -type answer
            if {$ended} { return 1 }
        }
        $self DrainPendingCandidates
        return 1
    }

    # The peer's answer to our restart offer.
    method ApplyRestartAnswer {creds} {
        set sdp [$self RemoteSdp $creds [$self PeerSetup]]
        if {$sdp eq ""} return
        $self TakeRemoteIce $creds
        set restart answered
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type answer
        if {$ended} return
        if {[$self TakeSdpError] ne ""} {
            $self RestartFailed
            return
        }
        $self DrainPendingCandidates
        $self RestartSettled
    }

    # Both descriptions of a restart are in. A backend that never left
    # `connected` will not say so again: the path it has is the call's.
    method RestartSettled {} {
        if {$ended || $transport ne "restarting" || $pc_state ne "connected"} return
        $self OnPcState connected
    }

    # We are the responder and both sides restarted at once: the
    # initiator's offer (glare_offer) wins. Our own offer, which must exist
    # by now for a rollback to drop it, goes with the candidates it
    # gathered; then theirs is followed. Until our backend has produced
    # ours (restart offering), OnRestartDescription waits for it.
    method RollBackAndFollow {} {
        if {$restart eq "offering"} return
        set creds $glare_offer
        set glare_offer {}
        set held_candidates {}
        ::tacky::media setLocalDescription $pc -type rollback
        if {$ended} return
        set restart ""
        $self Disarm restart
        $self Go transport interrupted
        $self FollowRestart $creds
    }

    # The peer's description - its last, with the credentials and
    # candidates in $creds and the DTLS setup $setup - as SDP. "" if it
    # will not convert, which fails the restart.
    method RemoteSdp {creds setup} {
        set first [lindex [dict values $creds] 0]
        set contents {}
        foreach c [dict get $remote_jingle children] {
            if {[dict get $c tag] eq "content"} {
                set name [xsearch $c -get @name]
                set new [dict getdef $creds $name $first]
                set kids {}
                foreach t [dict get $c children] {
                    if {[dict get $t tag] eq "transport" && [dict get $t ns] eq $NS_ICE_UDP} {
                        set t [RestartTransport $t $new $setup]
                    }
                    lappend kids $t
                }
                dict set c children $kids
            }
            lappend contents $c
        }
        set jingle $remote_jingle
        dict set jingle children $contents
        if {[catch {::jinglesdp::to_sdp $jingle -initiator [expr {!$initiator}]} sdp]} {
            jlog warn "call $sid: the restarted description does not convert: $sdp"
            $self RestartFailed
            return ""
        }
        return $sdp
    }

    # Transport $old (the peer's last) under $new's credentials and
    # candidates, its fingerprint kept with setup $setup.
    proc RestartTransport {old new setup} {
        lassign [xsearch $new -get {@ufrag @pwd}] u p
        dict set old attrs ufrag $u
        dict set old attrs pwd $p
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
    method PeerSetup {} {
        set setup [xsearch $remote_jingle content transport fingerprint -get @setup]
        if {$setup in {active passive}} { return $setup }
        expr {$local_setup eq "passive" ? "active" : "passive"}
    }

    # The peer's credentials are now those in $creds; the ones they
    # replace name a generation whose candidates are dropped.
    method TakeRemoteIce {creds} {
        dict for {name t} $creds {
            if {[dict exists $remote_ice $name]} {
                lappend remote_old [lindex [dict get $remote_ice $name] 0]
            }
            dict set remote_ice $name [xsearch $t -get {@ufrag @pwd}]
        }
    }

    # Note the peer's description: what a restart re-applies under new
    # credentials, and the credentials it names.
    method KeepRemoteDescription {jingle} {
        set remote_jingle $jingle
        set remote_ice {}
        foreach c [xsearch $jingle content -gather node] {
            set tr [xsearch $c transport -ns $NS_ICE_UDP -get node]
            if {$tr eq ""} continue
            dict set remote_ice [xsearch $c -get @name] [xsearch $tr -get {@ufrag @pwd}]
        }
    }

    # The wait ran out. Time the stream to the server was down does not
    # count - the restart's signalling could not travel - so it starts
    # again then, under MEDIA_LOSS_MAX_MS.
    method RestartWaited {} {
        if {![$client iq isLive]} {
            $self Arm restart $RESTART_WAIT_MS RestartWaited
            return
        }
        # Media is flowing by the backend's last word: the restart did not
        # finish, but the path it was for is fine.
        if {$pc_state eq "connected"} {
            $self OnPcState connected
            return
        }
        $self RestartFailed
    }

    # This restart, or this wait for the peer's, did not bring the path
    # back: try again if we may, else the call fails.
    method RestartFailed {} {
        if {$ended || $transport eq "connected"} return
        $self Disarm restart
        set restart_hold 0
        set glare_offer {}
        if {$transport eq "restarting"} {
            set restart ""
            $self Go transport interrupted
        }
        if {[$self StartRestart "the restart did not reconnect"]} return
        if {[$self AwaitPeerRestart]} return
        $self Finish Failed "media path failed (ICE/DTLS)" connectivity-error
    }

    # Connected again, by a restart or not: what was under way is over.
    method EndRestart {} {
        $self Disarm restart
        set restart_attempts 0
        set restart ""
        set glare_offer {}
        $self ReleaseLocalCandidates
    }

    # =========================================================================
    # Inbound JMI (XEP-0353); taco_calls handles <propose>
    # =========================================================================

    method {Jmi ringing} {stanza from} {
        if {![$self ProposedTo $from] || ![$self Matches $from]} return
        # The state stays proposed, so this is the only trace `list` has.
        set peer_ringing 1
        $client emit calls <Ringing> -sid $sid
    }

    method {Jmi proceed} {stanza from} {
        # Another of our devices answered the call ringing here.
        if {[$self OwnOtherDevice $from]} {
            $self Finish Ended elsewhere
            return
        }
        # We're the caller: latch the full JID, then fetch the server's
        # STUN/TURN list (XEP-0215); StartOutgoingMedia runs once it is in.
        if {![$self ProposedTo $from] || ![$self Matches $from]} return
        set peer $from
        $self Go state proceeded
        $self NotePeerDevice \
            [xsearch $stanza proceed -ns urn:xmpp:jingle-message:0 -get node]
        $client extdisco fetch -command [$self Callback StartOutgoingMedia]
    }

    method {Jmi reject} {stanza from} {
        # Another of our devices declined the call ringing here.
        if {[$self OwnOtherDevice $from]} {
            $self Finish Ended elsewhere
            return
        }
        # We're the caller: declined, busy, timed out, or a tie-break.
        if {![$self ProposedTo $from] || ![$self Matches $from]} return
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
        $self Finish Ended $why
    }

    method {Jmi retract} {stanza from} {
        if {![$self Matches $from]} return
        switch -- $state {
            ringing {
                # The caller cancelled before we answered.
                $self Finish Ended retracted
                $calls EmitMissed $sid $from $video_remote retracted
            }
            proceeded {
                # Answered, but the caller gave up before its
                # session-initiate (XEP-0353 allows a retract until then).
                if {!$initiator && !$has_session} {
                    $self Finish Ended retracted
                }
            }
        }
    }

    # <finish/> (XEP-0353 §3.5): the session is over. Its session-terminate
    # normally said so first; if the call is still here, it ends now.
    method {Jmi finish} {stanza from} {
        if {![$self Matches $from] || $state in {proposed ringing}} return
        set child [xsearch $stanza finish -ns urn:xmpp:jingle-message:0 -get node]
        $self PeerEnded [lindex [xsearch $child reason * -get tag] 0]
    }

    # Is $from another device of ours, while the call rings here? Its
    # proceed or reject, carboned to us, means it took the call.
    method OwnOtherDevice {from} {
        set me [$client cget -jid]
        expr {$state eq "ringing" && [jid bare $from] eq [jid bare $me] && $from ne $me}
    }

    # =========================================================================
    # Inbound Jingle; taco_calls has checked the sender and JINGLE_IN
    # =========================================================================

    method {Jingle session-initiate} {stanza jingle from} {
        if {$state ne "proceeded" || $initiator} {
            $calls IqError $stanza out-of-order
            return
        }
        # A plain offer is accepted even if the peer announced a device,
        # like Conversations.
        set jingle [$self TakeFingerprints $stanza $jingle $from 0]
        if {$jingle eq ""} return
        # Strip payload-types the backend cannot decode before to_sdp, so
        # the answer only offers what we can actually play back.
        set jingle [$calls FilterCodecs $jingle]
        # -initiator names the SDP's author: the peer, who initiated.
        # An offer that doesn't convert is refused, which ends the session
        # for the peer as well.
        if {[catch {::jinglesdp::to_sdp $jingle -initiator 1} sdp]} {
            $calls IqError $stanza bad-request
            $self Finish Failed "bad offer: $sdp"
            return
        }
        jlog debug "SDP offer from $from (sid=$sid)\n[jlog_redact_sdp $sdp]"
        $self KeepRemoteDescription $jingle
        $self NoteContents $jingle
        set peer $from
        set has_session 1
        $self Go state pending
        $calls AckIq $stanza
        # The ICE servers (XEP-0215) first; StartIncomingMedia does the rest.
        $client extdisco fetch -command [$self Callback StartIncomingMedia $sdp]
    }

    method {Jingle session-accept} {stanza jingle from} {
        # An accept before we've stood up the pc (still fetching ICE
        # servers, or never offered at all) has nothing to apply to.
        if {$pc eq -1} {
            $calls IqError $stanza out-of-order
            return
        }
        # If our offer was encrypted, the answer must be too. A repeated
        # answer is skipped: its key was already used.
        if {!$remote_set} {
            set jingle [$self TakeFingerprints $stanza $jingle $from $fingerprint_encrypted]
            if {$jingle eq ""} return
        }
        # The peer wrote this answer, as the responder. One that doesn't
        # convert ends a call still waiting for it; a malformed repeat of
        # an answer already applied is only refused.
        if {[catch {::jinglesdp::to_sdp $jingle -initiator 0} sdp]} {
            $calls IqError $stanza bad-request
            if {!$remote_set} {
                $self Finish Failed "bad answer: $sdp" failed-application
            }
            return
        }
        # A duplicate/retransmitted accept applies fine once but is
        # rejected the second time — not fatal to the call already
        # running, so {Media error} warns rather than failing it, and we
        # answer with an IQ error instead of AckIq so a retrying peer
        # stops.
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type answer
        if {$ended} return
        if {[$self TakeSdpError] ne ""} {
            $calls IqError $stanza not-acceptable
            return
        }
        if {!$remote_set} {
            $self KeepRemoteDescription $jingle
            set remote_set 1
        }
        if {$initiator} {
            $self Go state established
        }
        $calls AckIq $stanza
        $self DrainPendingCandidates
    }

    # Trickled candidates (XEP-0176), and what else a transport-info may
    # carry: new credentials, which are an ICE restart (see "ICE restart"),
    # and a DTLS fingerprint, which must be the one the session has.
    #
    # Candidates are sorted by the credentials they come under: the
    # peer's current ones go to the pc (or wait, below); a generation a
    # restart replaced is dropped, as is one we never heard of.
    method {Jingle transport-info} {stanza jingle from} {
        # Until the peer's description is applied a candidate has nothing
        # to attach to: on the callee's side the pc may not exist yet (the
        # JMI window), on the caller's the answer may not have come. Buffer
        # in arrival order; DrainPendingCandidates applies them.
        set early [expr {$pc eq -1 || !$remote_set}]
        set creds {}
        set fresh 0
        set cands {}
        set wait {}
        set swapped 0
        xsearch $jingle content -script content {
            set name [xsearch $content -get @name]
            set tr [xsearch $content transport -ns $NS_ICE_UDP -get node]
            if {$tr eq ""} continue
            if {![$self SameFingerprint $tr]} {
                set swapped 1
                break
            }
            lassign [xsearch $tr -get {@ufrag @pwd}] u p
            set target cands
            if {$u ne "" && [dict exists $remote_ice $name]
                    && $u ne [lindex [dict get $remote_ice $name] 0]} {
                if {$p ne "" && $u ni $remote_old} {
                    # New credentials, both of them: a restart.
                    dict set creds $name $tr
                    incr fresh [llength [xsearch $tr candidate -gather node]]
                    continue
                }
                if {[dict exists $glare_offer $name]
                        && $u eq [xsearch [dict get $glare_offer $name] -get @ufrag]} {
                    # The initiator's restart we are about to follow.
                    set target wait
                } else {
                    jlog debug "transport-info: candidates of a replaced or unknown\
                        ICE generation ($u) skipped"
                    continue
                }
            }
            xsearch $tr candidate -script cand {
                if {[catch {::jinglesdp::CandidateToSdp $cand} value]} {
                    jlog debug "transport-info: skipping unusable candidate"
                    continue
                }
                lappend $target [list $name "candidate:$value"]
            }
        }
        if {$swapped} {
            $calls AckIq $stanza
            $self Finish Failed \
                "the peer's DTLS fingerprint changed mid-call" security-error
            return
        }
        if {[dict size $creds]} {
            # With candidates while our own offer is out, it is the answer;
            # anything else is the peer's offer.
            set isAnswer [expr {$restart eq "awaiting" && $fresh > 0}]
            if {!$isAnswer && $restart in {offering awaiting}} {
                # Both restarted at once: the initiator's wins.
                if {$initiator} {
                    $calls IqError $stanza conflict tie-break
                    return
                }
                $calls AckIq $stanza
                set glare_offer $creds
                $self RollBackAndFollow
                $self AddCandidates $cands
                return
            }
            $calls AckIq $stanza
            if {$isAnswer} {
                $self ApplyRestartAnswer $creds
            } elseif {$state eq "established"} {
                $self FollowRestart $creds
            } else {
                jlog debug "transport-info: new credentials before the session is up skipped"
            }
            $self AddCandidates $cands
            return
        }
        foreach c $wait { $self BufferCandidate {*}$c }
        if {$early} {
            foreach c $cands { $self BufferCandidate {*}$c }
        } else {
            $self AddCandidates $cands
        }
        $calls AckIq $stanza
    }

    # A plain fingerprint in a transport-info (XEP-0320 lets one travel
    # there) must be the one the session was set up with: a restart moves
    # the path, never the DTLS keys. An encrypted one is not read here.
    method SameFingerprint {tr} {
        if {$remote_jingle eq ""} { return 1 }
        set fp [::taco_calls::verify::plain $tr]
        if {$fp eq ""} { return 1 }
        set known [::taco_calls::verify::plain \
            [xsearch $remote_jingle content transport -ns $NS_ICE_UDP -get node]]
        if {$known eq ""} { return 1 }
        string equal -nocase [string trim [xsearch $fp -get body]] \
            [string trim [xsearch $known -get body]]
    }

    method {Jingle session-terminate} {stanza jingle from} {
        $calls AckIq $stanza
        $self PeerEnded [lindex [xsearch $jingle reason * -get tag] 0]
    }

    # content-add and transport-replace are acknowledged and then turned
    # down with content-reject / transport-reject, as XEP-0166 7.2 has it:
    # an IQ error there would read as the session failing, and Conversations
    # ends the call (its video button sends content-add mid-call).
    method {Jingle content-add} {stanza jingle from} {
        $calls AckIq $stanza
        $self SendReject content-reject $jingle 0
    }

    method {Jingle transport-replace} {stanza jingle from} {
        $calls AckIq $stanza
        $self SendReject transport-reject $jingle 1
    }

    # Informational actions (XEP-0166 §6.8): one without a payload is a
    # ping, and one whose payload we understand is taken note of; any other
    # gets <feature-not-implemented/> with <unsupported-info/>. We
    # understand XEP-0167's session-info (ringing, active, hold, mute and
    # the like), and no description-info. security-info sets no rule for
    # its receiver.
    method {Jingle session-info} {stanza jingle from} {
        $self Informational $stanza $jingle urn:xmpp:jingle:apps:rtp:info:1
    }

    method {Jingle description-info} {stanza jingle from} {
        $self Informational $stanza $jingle {}
    }

    method {Jingle security-info} {stanza jingle from} {
        $calls AckIq $stanza
    }

    method Informational {stanza jingle understood} {
        foreach payload [dict get $jingle children] {
            if {[dict getdef $payload ns ""] ni $understood} {
                $calls IqError $stanza feature-not-implemented unsupported-info
                return
            }
        }
        $calls AckIq $stanza
    }

    # The peer drops contents (XEP-0166 §7.2.5). Dropping video stops ours;
    # dropping them all ends the session, as the receiver SHOULD.
    method {Jingle content-remove} {stanza jingle from} {
        $calls AckIq $stanza
        foreach c [xsearch $jingle content -gather node] {
            set name [xsearch $c -get @name]
            if {![dict exists $contents $name]} continue
            if {[dict get $contents $name media] eq "video"} {
                $self StopVideo
            }
            dict unset contents $name
        }
        if {$has_session && ![dict size $contents]} {
            $self Finish Ended hangup success
        }
    }

    # The peer changes who sends on contents (XEP-0166 §7.2.3). A change
    # to its own half is taken. Ours stays as negotiated: a change to it is
    # turned down with a content-modify that restores it, as the receiver
    # MAY.
    method {Jingle content-modify} {stanza jingle from} {
        $calls AckIq $stanza
        set contrary {}
        foreach c [xsearch $jingle content -gather node] {
            lassign [xsearch $c -get {@creator @name @senders}] creator name senders
            if {$creator eq ""} { set creator initiator }
            if {![dict exists $contents $name]
                    || $senders ni {both initiator responder none}} continue
            set was [dict get $contents $name senders]
            if {[$self WeSend $senders] == [$self WeSend $was]} {
                dict set contents $name senders $senders
            } else {
                lappend contrary [j content -creator $creator -name $name -senders $was]
            }
        }
        if {![llength $contrary]} return
        set out [j jingle -ns urn:xmpp:jingle:1]
        dict set out children $contrary
        $client iq request -type set -to $peer \
            -payload [$self Stamp $out content-modify 1]
    }

    # Whether XEP-0166 $senders has us sending.
    method WeSend {senders} {
        expr {$senders eq "both" || $senders eq ($initiator ? "initiator" : "responder")}
    }

    # The contents of the session's initiate, which the accept echoes.
    method NoteContents {jingle} {
        set contents {}
        foreach c [xsearch $jingle content -gather node] {
            set media [xsearch $c description -ns urn:xmpp:jingle:apps:rtp:1 -get @media]
            set senders [xsearch $c -get @senders]
            if {$senders eq ""} { set senders both }
            dict set contents [xsearch $c -get @name] [dict create media $media senders $senders]
        }
    }

    # The video half is over, while the call goes on.
    method StopVideo {} {
        if {$pc ne -1} { ::tacky::media setVideoEnabled $pc -on 0 }
        if {$vsend || $vrecv} {
            $client emit calls <VideoEnded> -sid $sid -mid $VIDEO_MID
        }
        set vsend 0
        set vrecv 0
    }
}
