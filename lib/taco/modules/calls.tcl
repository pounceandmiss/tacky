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
#
# Enumeration and the persisted preferred device + volume live on the
# process-global `audio` module (see lib/taco/modules/audio.tcl). Volume
# has no per-call override — `tacky audio setVolume` is the only knob.
#
# tacky listen calls <Outgoing>        $cmd  ;# -sid $sid -to $jid
# tacky listen calls <Incoming>        $cmd  ;# -sid $sid -from $jid
# tacky listen calls <Ringing>         $cmd  ;# -sid $sid          (caller side: peer device alerting)
# tacky listen calls <Active>          $cmd  ;# -sid $sid          (RTP flowing)
# tacky listen calls <Ended>           $cmd  ;# -sid $sid          (terminal — normal teardown)
# tacky listen calls <Failed>          $cmd  ;# -sid $sid -reason $text  (terminal — unrecoverable)
# tacky listen calls <Warning>         $cmd  ;# -sid $sid -reason $text  (non-fatal; call continues)
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
# Per-call state ([dict get $Calls $sid] dict):
#   peer       : remote JID (bare until proceeded, then full)
#   initiator  : 1 for caller, 0 for callee
#   state      : proposed|ringing|proceeded|new|connecting|active|ended|failed
#   peer_ringing : 1 once a peer device answered <ringing> (caller side);
#     a field, not a state, because the state machine does not move for it
#   pc         : tacky::media pc handle (-1 = not created)
#   track      : media handle of the audio track (-1 = not added/received)
#   pending_remote_candidates : list of [list mid candidate], present
#     only while inbound trickle has outpaced our pc creation; drained
#     and unset by HandleSessionInitiate
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

    variable client
    variable Calls           ;# sid -> dict (see file header)
    variable SdpErrors       ;# sid -> reason, see TakeSdpError

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Calls [dict create]
        set SdpErrors [dict create]
        $client iq handler set urn:xmpp:jingle:1 [mymethod OnJingleIq]
        $client bus subscribe $self <Ready> [mymethod OnFreshStream]

        $client caps addFeature urn:xmpp:jingle:1
        $client caps addFeature urn:xmpp:jingle:apps:rtp:1
        $client caps addFeature urn:xmpp:jingle:apps:rtp:audio
        $client caps addFeature urn:xmpp:jingle:apps:rtp:video
        $client caps addFeature urn:xmpp:jingle:apps:dtls:0
        $client caps addFeature urn:xmpp:jingle:transports:ice-udp:1
        $client caps addFeature urn:xmpp:jingle-message:0
    }

    destructor {
        catch {$client iq unhandler set urn:xmpp:jingle:1}
        foreach sid [dict keys $Calls] {
            $self TeardownMedia $sid
        }
    }

    # =========================================================================
    # Public API
    # =========================================================================

    tackymethod start {args} {
        array set opts {-to "" -video 0}
        array set opts $args
        if {$opts(-to) eq ""} { error "start: -to required" }

        set bare [jid bare $opts(-to)]
        set sid [$self NewSid]
        set wantVideo [expr {$opts(-video) ? 1 : 0}]
        dict set Calls $sid [$self NewCallDict $bare 1 proposed $wantVideo]
        $client emit calls <Outgoing> -sid $sid -to $bare
        $client write [$self BuildJmiMessage $bare propose $sid 1 $wantVideo]
        return $sid
    }

    # Per-call state dict. peer is bare until proceeded, then full JID.
    # video_local  : 1 if this side offered/wants to send video
    # video_remote : 1 if the peer's propose advertised media=video
    # vtrack       : media handle of the video track, -1 when absent
    # vsend/vrecv  : 1 once we have asked the backend for that half and it
    #                has not reported the attach failed
    method NewCallDict {peer initiator state wantVideo} {
        return [dict create \
            peer $peer initiator $initiator state $state peer_ringing 0 \
            pc -1 track -1 \
            video_local $wantVideo video_remote 0 \
            vtrack -1 vsend 0 vrecv 0]
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
            $client write [$self BuildJmiMessage $peer proceed $opts(-sid) 0]
            dict set Calls $opts(-sid) state proceeded
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
            set peer [dict get $call peer]
            $client write [$self BuildJmiMessage $peer reject $opts(-sid) 0]
            $client emit calls <Ended> -sid $opts(-sid)
            $self Cleanup $opts(-sid)
            return
        }
        if {$state eq "proposed"} {
            $self RetractProposed $opts(-sid) [dict get $call peer]
            return
        }
        $self EndSession $opts(-sid) [dict get $call peer] $opts(-reason)
    }

    tackymethod hangup {args} {
        array set opts {-sid "" -reason success}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set call [dict get $Calls $opts(-sid)]
        if {[dict get $call state] eq "proposed"} {
            $self RetractProposed $opts(-sid) [dict get $call peer]
            return
        }
        $self EndSession $opts(-sid) [dict get $call peer] $opts(-reason)
    }

    # End a session that reached Jingle: drop the media, tell the peer, and
    # report it gone.
    method EndSession {sid peer reason} {
        $self TeardownMedia $sid
        $self SendTerminate $sid $peer $reason
        $client emit calls <Ended> -sid $sid
        $self Cleanup $sid
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
                state        [dict get $call state] \
                peer_ringing [dict get $call peer_ringing] \
                video_local  [dict get $call video_local] \
                video_remote [dict get $call video_remote]]
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
    method CreatePc {sid iceServers} {
        set pc $self/$sid
        dict set Calls $sid pc $pc
        ::tacky::media createPeer $pc \
            -command [mymethod OnMediaEvent $sid] -ice-servers $iceServers
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
    # Only the shm form has a ring to name; a host-rendered channel just
    # carries its id.
    method VideoEventArgs {ch} {
        set out {}
        foreach key {channel name slots slotBytes maxWidth maxHeight format id} {
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

        jlog debug "SDP $sdpType to [dict get $call peer] (sid=$sid)\n$sdp"

        # SDP->Jingle (creator stays "initiator" on both sides — the
        # responder echoes the initiator's content names verbatim).
        set jingle [::jinglesdp::from_sdp $sdp \
            -creator initiator -initiator $isInitiator]

        if {$sdpType eq "offer"} {
            dict set jingle attrs action session-initiate
            dict set jingle attrs sid $sid
            dict set jingle attrs initiator $me
            $client iq request -type set -to [dict get $call peer] \
                -payload $jingle \
                -command [mymethod OnInitiateAck $sid]
        } elseif {$sdpType eq "answer"} {
            dict set jingle attrs action session-accept
            dict set jingle attrs sid $sid
            dict set jingle attrs responder $me
            $client iq request -type set -to [dict get $call peer] \
                -payload $jingle \
                -command [mymethod OnAcceptAck $sid]
        }
    }

    # Trickle a single ICE candidate to the peer. The API carries the SDP
    # attribute form ("candidate:foo bar baz..."); we strip the
    # "candidate:" prefix so jinglesdp::BuildCandidate sees the same
    # shape it parses out of SDP. An empty mid falls back to the bundle
    # group's audio MID.
    method OnLocalCandidate {sid cand mid} {
        set call [dict get $Calls $sid]
        set me [$client cget -jid]
        set isInitiator [dict get $call initiator]

        set value $cand
        if {[string match "candidate:*" $value]} {
            set value [string range $value 10 end]
        }
        if {$mid eq ""} { set mid $MID }

        set candNode [::jinglesdp::BuildCandidate $value]
        if {$candNode eq ""} return

        set jingle [j jingle -ns urn:xmpp:jingle:1 {
            j content -creator initiator -name $mid {
                j transport -ns urn:xmpp:jingle:transports:ice-udp:1 {
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
        $client iq request -type set -to [dict get $call peer] -payload $jingle
    }

    # Informational only — kept for visibility / future logging hooks. No
    # wire effect; the SDP ships from OnLocalDescription and candidates
    # trickle via OnLocalCandidate.
    method OnGatheringState {sid state} {
        return
    }

    method OnInitiateAck {sid stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $client emit calls <Failed> -sid $sid \
                -reason "session-initiate rejected"
            $self TeardownMedia $sid
            $self Cleanup $sid
        }
    }

    method OnAcceptAck {sid stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $client emit calls <Warning> -sid $sid -reason "session-accept rejected"
        }
    }

    # Backend state strings: new, connecting, connected, disconnected,
    # failed, closed. The internal `state` dict field tracks the full
    # lifecycle; only the connected/closed/failed transitions are surfaced
    # as <Active>/<Ended>/<Failed>. new/connecting are backend internals,
    # too short-lived to be useful to a GUI, and intentionally not emitted.
    # The pre-media transitions (<Outgoing>, <Incoming>, <Ringing>) are
    # emitted from the JMI handlers, not from here.
    method OnPcState {sid state} {
        # ICE lost consent. The backend recovers or moves on to failed by
        # itself, so warn and leave the call running.
        if {$state eq "disconnected"} {
            $client emit calls <Warning> -sid $sid \
                -reason "media path interrupted"
            return
        }
        set mapped [$self MapPcState $state]
        if {$mapped eq ""} return
        dict set Calls $sid state $mapped
        switch -- $mapped {
            new        -
            connecting { return }
            active     { $client emit calls <Active> -sid $sid }
            ended      { $client emit calls <Ended>  -sid $sid }
            failed     {
                $client emit calls <Failed> -sid $sid \
                    -reason "media path failed (ICE/DTLS)"
            }
        }
        if {$mapped in {ended failed}} {
            $self TeardownMedia $sid
            $self Cleanup $sid
        }
    }

    method MapPcState {state} {
        switch -- $state {
            new          { return new }
            connecting   { return connecting }
            connected    { return active }
            failed       { return failed }
            closed       { return ended }
            disconnected { return "" }
            default      { return "" }
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
                set peer [dict get $Calls $sid peer]
                $client emit calls <Failed> -sid $sid \
                    -reason "remote offer rejected: $reason"
                $self TeardownMedia $sid
                $self SendTerminate $sid $peer general-error
                $self Cleanup $sid
                return
            }
            addRemoteCandidate {
                # Stale, duplicate, wrong ufrag: skipped like an
                # unparsable one, since the others may still connect.
                jlog debug "transport-info: candidate rejected: $reason"
                return
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
        if {[dict exists $ev fatal] && [dict get $ev fatal]} {
            $client emit calls <Failed> -sid $sid -reason $reason
            $self TeardownMedia $sid
            $self Cleanup $sid
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
                finish  { # XEP-0353: out of scope, ignored on receipt. }
            }
            return 1
        }
        return 0
    }

    method HandleJmiPropose {stanza sid from} {
        # Carbon of our own outbound propose: drop.
        set myBare [jid bare [$client cget -jid]]
        if {[jid bare $from] eq $myBare} return
        # Duplicate or sid collision: ignore.
        if {[dict exists $Calls $sid]} return

        set ns urn:xmpp:jingle-message:0
        set child [xsearch $stanza propose -ns $ns -get node]
        set hasVideo [$self ProposeHasVideo $child]

        dict set Calls $sid [$self NewCallDict $from 0 ringing 0]
        dict set Calls $sid video_remote $hasVideo
        # We answer video symmetrically: if they offered it, we intend to
        # send it too (the GUI can still mute the camera).
        dict set Calls $sid video_local $hasVideo

        # XEP-0353 §4: tell the initiator this device is alerting the user.
        $client write [$self BuildJmiMessage $from ringing $sid 0]
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
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
            return
        }
        # We're the original caller: latch full JID, then fetch the
        # server's STUN/TURN list (XEP-0215). StartOutgoingMedia runs in
        # the extdisco callback once the iceServers list is in hand.
        if {$state eq "proposed" && [dict get $call initiator]} {
            if {![$self PeerMatches $sid $from]} return
            dict set Calls $sid peer $from
            dict set Calls $sid state proceeded
            $client extdisco fetch -command [mymethod StartOutgoingMedia $sid]
        }
    }

    # Caller side: extdisco callback. Builds the pc with whatever ICE
    # servers the server advertised (empty list = host candidates only),
    # adds the sendrecv audio track, attaches media, and kicks off
    # offer generation. A hangup arriving during the fetch can have
    # removed this sid from Calls — bail in that case.
    method StartOutgoingMedia {sid iceServers} {
        if {![dict exists $Calls $sid]} return
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
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
            return
        }
        # Caller side: callee declined our propose.
        if {$state eq "proposed" && [dict get $call initiator]} {
            if {![$self PeerMatches $sid $from]} return
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
        }
    }

    method HandleJmiRetract {stanza sid from} {
        if {![$self PeerMatches $sid $from]} return
        set call [dict get $Calls $sid]
        # Caller cancelled before we proceeded.
        if {[dict get $call state] eq "ringing"} {
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
        }
    }

    method BuildJmiMessage {to action sid wantDescription {wantVideo 0}} {
        set ns urn:xmpp:jingle-message:0
        return [j message -to $to -type chat {
            if {$wantDescription} {
                j $action -ns $ns -id $sid {
                    j description \
                        -ns urn:xmpp:jingle:apps:rtp:1 \
                        -media audio
                    if {$wantVideo} {
                        j description \
                            -ns urn:xmpp:jingle:apps:rtp:1 \
                            -media video
                    }
                }
            } else {
                j $action -ns $ns -id $sid
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

        switch -- $action {
            session-initiate  { $self HandleSessionInitiate $stanza $jingle $sid $from }
            session-accept    { $self HandleSessionAccept   $stanza $jingle $sid $from }
            session-terminate { $self HandleSessionTerminate $stanza $jingle $sid $from }
            transport-info    { $self HandleTransportInfo   $stanza $jingle $sid $from }
            default           { $self AckIq $stanza }
        }
    }

    method HandleSessionInitiate {stanza jingle sid from} {
        # JMI is mandatory: a session-initiate must be preceded by our
        # own <proceed>. Otherwise the user never agreed to ring and
        # we reject the IQ — the call never existed locally.
        # A sender that isn't our peer gets the same answer as an unknown
        # sid, so a guessed sid can't be confirmed.
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
        # Strip payload-types the backend cannot decode before to_sdp, so
        # the answer only offers what we can actually play back.
        set jingle [$self FilterCodecs $jingle]
        set sdp [::jinglesdp::to_sdp $jingle -initiator 0]
        jlog debug "SDP offer from $from (sid=$sid)\n$sdp"
        dict set Calls $sid peer $from
        dict set Calls $sid state new
        $self AckIq $stanza
        # Fetch ICE servers (XEP-0215) before standing up the pc.
        # StartIncomingMedia drives the rest in the extdisco callback.
        $client extdisco fetch \
            -command [mymethod StartIncomingMedia $sid $sdp]
    }

    # Callee side: extdisco callback. Stands up the pc, applies the
    # remote offer, and drains any transport-info that arrived while
    # the fetch was outstanding. A hangup during the fetch can have
    # removed this sid — bail then.
    method StartIncomingMedia {sid sdp iceServers} {
        if {![dict exists $Calls $sid]} return
        set pc [$self CreatePc $sid $iceServers]
        # Apply the offer; `track` events fire async to drive AttachMedia.
        # A backend that rejects it reports an error, and OnMediaError has
        # already emitted <Failed>, terminated and cleaned up by the time
        # this returns — hence the re-check below.
        ::tacky::media setRemoteDescription $pc -sdp $sdp -type offer
        if {![dict exists $Calls $sid]} return
        $self TakeSdpError $sid
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
        # Drain any candidates that arrived (and were buffered) while this
        # side's pc was still -1. A rejected one isn't fatal to an offer
        # that just applied cleanly; OnMediaError logs and skips it.
        if {[dict exists $Calls $sid pending_remote_candidates]} {
            foreach entry [dict get $Calls $sid pending_remote_candidates] {
                lassign $entry name full
                ::tacky::media addRemoteCandidate $pc \
                    -candidate $full -mid $name
            }
            dict unset Calls $sid pending_remote_candidates
        }
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
        set sdp [::jinglesdp::to_sdp $jingle -initiator 1]
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
        $self AckIq $stanza
    }

    method HandleTransportInfo {stanza jingle sid from} {
        if {![$self PeerMatches $sid $from]} {
            $self IqError $stanza item-not-found
            return
        }
        set pc [dict get $Calls $sid pc]
        # pc==-1 happens during the JMI window: peer may speculatively
        # trickle before we've finished CreatePc + set-remote-description.
        # Buffer in arrival order; HandleSessionInitiate drains.
        xsearch $jingle content -script content {
            set name [xsearch $content -get @name]
            set transport [xsearch $content transport \
                -ns urn:xmpp:jingle:transports:ice-udp:1 -get node]
            if {$transport eq ""} continue
            xsearch $transport candidate -script cand {
                if {[catch {::jinglesdp::CandidateToSdp $cand} value]} {
                    jlog debug "transport-info: skipping unusable candidate"
                    continue
                }
                set full "candidate:$value"
                if {$pc eq -1} {
                    set buffered {}
                    if {[dict exists $Calls $sid pending_remote_candidates]} {
                        set buffered [dict get $Calls $sid pending_remote_candidates]
                    }
                    if {[llength $buffered] >= $MAX_PENDING_CANDIDATES} {
                        jlog debug "transport-info: candidate buffer full"
                        continue
                    }
                    dict update Calls $sid call {
                        dict lappend call pending_remote_candidates \
                            [list $name $full]
                    }
                } else {
                    ::tacky::media addRemoteCandidate $pc \
                        -candidate $full -mid $name
                }
            }
        }
        $self AckIq $stanza
    }

    method HandleSessionTerminate {stanza jingle sid from} {
        $self AckIq $stanza
        if {![$self PeerMatches $sid $from]} return
        $self TeardownMedia $sid
        $client emit calls <Ended> -sid $sid
        $self Cleanup $sid
    }

    # =========================================================================
    # Helpers
    # =========================================================================

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

    method IqError {stanza condition} {
        set payload [j error -type cancel {
            j $condition -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }]
        $client iq respond -type error -for $stanza -payload $payload
    }

    # Cancel a call that never got past our own <propose>. There is no
    # session to terminate yet, so XEP-0353 wants a retract.
    method RetractProposed {sid peer} {
        $client write [$self BuildJmiMessage $peer retract $sid 0]
        $client emit calls <Ended> -sid $sid
        $self Cleanup $sid
    }

    # A fresh (non-resumed) stream invalidates every sid we hold: nothing can
    # route back to a session that died with the old stream. Resumption never
    # lands here, and a plain disconnect is deliberately left alone - the
    # media path is peer to peer and can outlive the outage.
    method OnFreshStream {args} {
        foreach sid [dict keys $Calls] {
            $self TeardownMedia $sid
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
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
        dict unset Calls $sid
    }

    method NewSid {} {
        binary scan [omemo::random 16] H* hex
        return "tk-$hex"
    }
}
