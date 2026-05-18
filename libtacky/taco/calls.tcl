# Voice calls (XEP-0166/0167/0176) driven directly by libdatachannel
# (::rtc::*) for ICE/DTLS/RTP + rtc-ma (::rtcma::*) for the
# mic-in / speaker-out audio path. XEP-0353 Jingle Message Initiation
# rings the right device without GUI-side resource discovery.
#
# tacky calls start  -acc $jid -to <bare jid> ?-command $cb?   ;# returns sid
# tacky calls accept -acc $jid -sid $sid
# tacky calls reject -acc $jid -sid $sid ?-reason decline?
# tacky calls hangup -acc $jid -sid $sid ?-reason success?
#
# tacky calls setDevices          -acc $jid -sid $sid ?-input $id? ?-output $id?
#   ;# per-call device override; does not touch the persisted preference.
#
# Enumeration and the persisted preferred device + volume live on the
# process-global `audio` module (see libtacky/taco/audio.tcl). Volume
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
#     -> create pc + sendrecv audio track, attach capturer+player,
#        set-local-description ""
#     -> on-local-description(offer)   -> send <jingle action=session-initiate>
#     -> on-local-candidate * N        -> send <jingle action=transport-info>
#   <- <jingle action=session-accept>  -> set-remote-description sdp answer
#   <- <jingle action=transport-info>  -> add-remote-candidate
#     -> on-state-change connected     -> emit <Active>
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
#     -> create pc, set-remote-description sdp offer
#        (libdatachannel auto-negotiation generates + applies the answer
#        internally — we do NOT call set-local-description here; see
#        HandleSessionInitiate for why)
#     -> on-track $tr                  -> attach capturer+player to $tr
#     -> on-local-description(answer)  -> send <jingle action=session-accept>
#     -> on-local-candidate * N        -> send <jingle action=transport-info>
#   <- <jingle action=transport-info>  -> add-remote-candidate
#
#   reject while ringing:  send <message><reject/></message>
#   hangup after proceed:  pc + media teardown + <jingle action=session-terminate>
#
# Both sides:
#   <- <jingle action=session-terminate> -> destroy media + pc
#                                        -> emit <Ended>
#
# Some notes about order:
#   - session-initiate / session-accept are shipped from
#     OnLocalDescription, not from OnGatheringState. The SDP at that
#     point has no candidates yet — those arrive asynchronously and
#     are trickled via OnLocalCandidate → transport-info.
#   - No end-of-candidates marker is emitted. libdatachannel keeps
#     accepting add-remote-candidate until the pc closes; ICE either
#     succeeds on what's there or fails via its own timer.
#   - Inbound transport-info while pc == -1 (the JMI-ringing window,
#     or any race before set-remote-description) is buffered into
#     [dict get $Calls $sid pending_remote_candidates], not dropped.
#     HandleSessionInitiate drains the buffer right after
#     set-remote-description.
#
# Per-call state ([dict get $Calls $sid] dict):
#   peer       : remote JID (bare until proceeded, then full)
#   initiator  : 1 for caller, 0 for callee
#   state      : proposed|ringing|proceeded|new|connecting|active|ended|failed
#   pc         : ::rtc pc id (-1 = not created)
#   track      : ::rtc track id (-1 = not added/received)
#   capturer   : ::rtcma capturer handle ("" = none)
#   player     : ::rtcma player handle ("" = none)
#   pending_remote_candidates : list of [list mid candidate], present
#     only while inbound trickle has outpaced our pc creation; drained
#     and unset by HandleSessionInitiate
#
# PcToSid maps a libdatachannel pc id back to its sid for the async
# rtc callbacks

package require rtc
package require rtcma

snit::type taco_calls {
    option -client -readonly yes

    # Media constants. Mid is the SDP m-line label, kept identical on
    # both sides for Jingle <content name=...>. Opus stereo @ 48 kHz
    # matches rtc-ma's fixed audio pipeline.
    typevariable MID            audio
    typevariable PAYLOAD_TYPE   111
    typevariable AUDIO_CHANNELS 2

    variable client
    variable Calls           ;# sid -> dict (see file header)
    variable PcToSid         ;# pc -> sid
    variable SidCounter 0

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Calls [dict create]
        array set PcToSid {}
        $client iq handler set urn:xmpp:jingle:1 [mymethod OnJingleIq]
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
        array set opts {-to ""}
        array set opts $args
        if {$opts(-to) eq ""} { error "start: -to required" }

        set bare [jid bare $opts(-to)]
        set sid [$self NewSid]
        dict set Calls $sid [dict create \
            peer $bare initiator 1 state proposed \
            pc -1 track -1 capturer "" player ""]
        $client emit calls <Outgoing> -sid $sid -to $bare
        $client write [$self BuildJmiMessage $bare propose $sid 1]
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
        $self TeardownMedia $opts(-sid)
        $self SendTerminate $opts(-sid) [dict get $call peer] $opts(-reason)
        $client emit calls <Ended> -sid $opts(-sid)
        $self Cleanup $opts(-sid)
        return
    }

    tackymethod hangup {args} {
        array set opts {-sid "" -reason success}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set call [dict get $Calls $opts(-sid)]
        set state [dict get $call state]
        if {$state eq "proposed"} {
            # Caller cancels before proceed: retract instead of terminate.
            set peer [dict get $call peer]
            $client write [$self BuildJmiMessage $peer retract $opts(-sid) 0]
            $client emit calls <Ended> -sid $opts(-sid)
            $self Cleanup $opts(-sid)
            return
        }
        $self TeardownMedia $opts(-sid)
        $self SendTerminate $opts(-sid) [dict get $call peer] $opts(-reason)
        $client emit calls <Ended> -sid $opts(-sid)
        $self Cleanup $opts(-sid)
        return
    }

    # Hot-swap mic / speaker for a live call. Empty id = system default.
    # No-op before AttachMedia has populated capturer/player.
    tackymethod setDevices {args} {
        array set opts {-sid "" -input __unset__ -output __unset__}
        array set opts $args
        if {![dict exists $Calls $opts(-sid)]} return
        set call [dict get $Calls $opts(-sid)]
        set capturer [dict get $call capturer]
        set player   [dict get $call player]
        if {$opts(-input) ne "__unset__" && $capturer ne ""} {
            if {[catch {
                ::rtcma::capturer::reopen $capturer -device-id $opts(-input)
            } err]} {
                $client emit calls <Warning> -sid $opts(-sid) \
                    -reason "input device unavailable: $err"
            }
        }
        if {$opts(-output) ne "__unset__" && $player ne ""} {
            if {[catch {
                ::rtcma::player::reopen $player -device-id $opts(-output)
            } err]} {
                $client emit calls <Warning> -sid $opts(-sid) \
                    -reason "output device unavailable: $err"
            }
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
    # hot-swap every live call on this client. Values in [0.0, 1.0];
    # rtcma applies the change atomically on the mixer factor with no
    # clicks. No-op for calls still before AttachMedia. Out-of-range or
    # NaN values surface as <Warning>; the call keeps running.
    tackymethod applyVolume {args} {
        array set opts {-kind "" -volume ""}
        array set opts $args
        foreach sid [dict keys $Calls] {
            set call [dict get $Calls $sid]
            if {$opts(-kind) eq "capture"} {
                set capturer [dict get $call capturer]
                if {$capturer eq ""} continue
                if {[catch {
                    ::rtcma::capturer::set-volume $capturer $opts(-volume)
                } err]} {
                    $client emit calls <Warning> -sid $sid \
                        -reason "input volume rejected: $err"
                }
            } else {
                set player [dict get $call player]
                if {$player eq ""} continue
                if {[catch {
                    ::rtcma::player::set-volume $player $opts(-volume)
                } err]} {
                    $client emit calls <Warning> -sid $sid \
                        -reason "output volume rejected: $err"
                }
            }
        }
        return
    }

    # =========================================================================
    # PC + media plumbing
    # =========================================================================

    # Create a fresh pc, hook callbacks, and (caller side) add the audio
    # track + attach media. Callee path uses CreatePc and then drives
    # set-remote-description; on-track attaches media.
    method CreatePc {sid iceServers} {
        set pc [::rtc::pc::new \
            -ice-servers $iceServers]
        set PcToSid($pc) $sid
        dict set Calls $sid pc $pc
        ::rtc::pc::on-local-description      $pc [mymethod OnLocalDescription]
        ::rtc::pc::on-local-candidate        $pc [mymethod OnLocalCandidate]
        ::rtc::pc::on-gathering-state-change $pc [mymethod OnGatheringState]
        ::rtc::pc::on-state-change           $pc [mymethod OnPcState]
        ::rtc::pc::on-track                  $pc [mymethod OnTrack]
        return $pc
    }

    # libdatachannel media-description fragment for one sendrecv Opus
    # audio m-line. Format: "<media> <port> <proto> <pt>\r\na=...\r\n..."
    # — the bytes after the m= prefix. PT and channels are fixed so the
    # responder side (which mirrors via on-track) gets matching codec
    # config from the offer SDP.
    method BuildAudioMediaDesc {} {
        set lines [list \
            "audio 9 UDP/TLS/RTP/SAVPF $PAYLOAD_TYPE" \
            "a=mid:$MID" \
            "a=sendrecv" \
            "a=rtpmap:$PAYLOAD_TYPE opus/48000/$AUDIO_CHANNELS" \
            "a=fmtp:$PAYLOAD_TYPE minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1"]
        return [join $lines \r\n]
    }

    # Attach a mic capturer + speaker player to a sendrecv track.
    # rtc-ma supports both on one track id: the player owns the
    # message-callback / RTP recv side, the capturer only ever calls
    # rtcSendMessage. Persisted audio_input_device / audio_output_device
    # settings pin specific endpoints; on failure (stale id, backend
    # swap) we fall back to system default so a bad setting can't
    # brick all calls.
    method AttachMedia {sid track} {
        set taco [$client cget -taco]
        set inId   [$taco audio getPreferredDevice -kind capture]
        set outId  [$taco audio getPreferredDevice -kind playback]
        set inVol  [$taco audio getVolume -kind capture]
        set outVol [$taco audio getVolume -kind playback]

        # rtc-ma self-configures from the negotiated track description
        # at attach time — no need to pass channels / payload-type here.
        if {[catch {::rtcma::capturer::new -device-id $inId} capturer]} {
            $client emit calls <Warning> -sid $sid \
                -reason "input device unavailable, using default"
            set capturer [::rtcma::capturer::new]
        }
        if {[catch {::rtcma::capturer::attach $capturer $track} err]} {
            catch {::rtcma::capturer::destroy $capturer}
            error "capturer attach failed: $err"
        }
        ::rtcma::capturer::start $capturer
        catch {::rtcma::capturer::set-volume $capturer $inVol}

        if {[catch {::rtcma::player::new -device-id $outId} player]} {
            $client emit calls <Warning> -sid $sid \
                -reason "output device unavailable, using default"
            set player [::rtcma::player::new]
        }
        if {[catch {::rtcma::player::attach $player $track} err]} {
            catch {::rtcma::player::destroy $player}
            catch {::rtcma::capturer::destroy $capturer}
            error "player attach failed: $err"
        }
        ::rtcma::player::start $player
        catch {::rtcma::player::set-volume $player $outVol}

        dict set Calls $sid track    $track
        dict set Calls $sid capturer $capturer
        dict set Calls $sid player   $player
    }

    # Free media + pc for one call. Ordering matters: rtcma handles
    # own the libdatachannel track's message callback + user pointer,
    # so they must be destroyed before ::rtc::pc::delete frees the
    # track. ::rtcma::*::destroy implicitly detaches.
    method TeardownMedia {sid} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        set capturer [dict get $call capturer]
        set player   [dict get $call player]
        set pc       [dict get $call pc]
        if {$capturer ne ""} { catch {::rtcma::capturer::destroy $capturer} }
        if {$player   ne ""} { catch {::rtcma::player::destroy   $player}   }
        if {$pc != -1} {
            # Drop callback scripts BEFORE close+delete so any events
            # already queued by libdatachannel become no-ops at dispatch
            # time. Otherwise a queued state-change can fire after
            # `tacky destroy` and try to call a method on a dead snit
            # instance.
            catch {::rtc::pc::on-local-description      $pc ""}
            catch {::rtc::pc::on-local-candidate        $pc ""}
            catch {::rtc::pc::on-gathering-state-change $pc ""}
            catch {::rtc::pc::on-state-change           $pc ""}
            catch {::rtc::pc::on-track                  $pc ""}
            catch {::rtc::pc::close  $pc}
            catch {::rtc::pc::delete $pc}
            unset -nocomplain PcToSid($pc)
        }
        dict set Calls $sid capturer ""
        dict set Calls $sid player   ""
        dict set Calls $sid pc       -1
        dict set Calls $sid track    -1
    }

    # =========================================================================
    # ::rtc::pc::* callbacks (async, delivered on the Tcl main thread)
    # =========================================================================

    # Fires once per setLocalDescription (and once on the responder when
    # set-remote-description triggers libdatachannel's auto-generated
    # answer). The SDP we get here has no candidates yet — those arrive
    # asynchronously via on-local-candidate and are trickled separately.
    method OnLocalDescription {pc sdp sdpType} {
        if {![info exists PcToSid($pc)]} return
        set sid $PcToSid($pc)
        set call [dict get $Calls $sid]
        set me [$client cget -jid]
        set isInitiator [dict get $call initiator]

        # rtc-ma sends raw RTP (no media handler on the track) and does
        # not honour any negotiated RTP header extensions or transport-cc
        # feedback. libdatachannel auto-echoes the remote offer's
        # extmaps into our answer, which mis-advertises capabilities
        # that libwebrtc-based peers then expect on the wire (notably
        # sdes:mid for transceiver routing in UNIFIED_PLAN); without
        # this strip those peers drop every packet we send. See the
        # SDP sanitization block in include/rtcma.h for the full
        # rationale.
        regsub -all -line {^a=extmap(-allow-mixed)?.*\n}      $sdp "" sdp
        regsub -all -line {^a=rtcp-fb:[^ ]+ transport-cc.*\n} $sdp "" sdp

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

    # Trickle a single ICE candidate to the peer. libdatachannel emits
    # the SDP attribute form ("candidate:foo bar baz..."); we strip the
    # "candidate:" prefix so jinglesdp::BuildCandidate sees the same
    # shape it parses out of SDP. Empty mid falls back to the bundle
    # group's audio MID.
    method OnLocalCandidate {pc cand mid} {
        if {![info exists PcToSid($pc)]} return
        set sid $PcToSid($pc)
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

    # Informational only — kept registered for visibility / future
    # logging hooks. No wire effect; the SDP ships from
    # OnLocalDescription and candidates trickle via OnLocalCandidate.
    method OnGatheringState {pc state} {
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

    # libdatachannel state strings: new, connecting, connected,
    # disconnected, failed, closed. The internal `state` dict field
    # tracks the full lifecycle; only the connected/closed/failed
    # transitions are surfaced as <Active>/<Ended>/<Failed>.
    # new/connecting are libdatachannel internals, too short-lived to
    # be useful to a GUI, and intentionally not emitted. The pre-media
    # transitions (<Outgoing>, <Incoming>, <Ringing>) are emitted from
    # the JMI handlers, not from here.
    method OnPcState {pc state} {
        if {![info exists PcToSid($pc)]} return
        set sid $PcToSid($pc)
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

    method OnTrack {pc tr} {
        if {![info exists PcToSid($pc)]} return
        set sid $PcToSid($pc)
        set call [dict get $Calls $sid]
        # On the callee, the offer's m-section creates a track id that
        # we attach our capturer + player to. The caller already
        # attached media to its locally-added track, so it shouldn't
        # see this firing — guard against double-attach anyway.
        if {[dict get $call track] != -1} return
        $self AttachMedia $sid $tr
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
        dict set Calls $sid [dict create \
            peer $from initiator 0 state ringing \
            pc -1 track -1 capturer "" player ""]
        # XEP-0353 §4: tell the initiator this device is alerting the user.
        $client write [$self BuildJmiMessage $from ringing $sid 0]
        $client emit calls <Incoming> -sid $sid -from [jid bare $from]
    }

    method HandleJmiRinging {stanza sid from} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        if {[dict get $call state] ne "proposed"
                || ![dict get $call initiator]} return
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
        set track [::rtc::pc::add-track $pc [$self BuildAudioMediaDesc]]
        $self AttachMedia $sid $track
        # Empty type = libdatachannel infers offer (no remote desc set).
        ::rtc::pc::set-local-description $pc ""
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
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
        }
    }

    method HandleJmiRetract {stanza sid from} {
        if {![dict exists $Calls $sid]} return
        set call [dict get $Calls $sid]
        # Caller cancelled before we proceeded.
        if {[dict get $call state] eq "ringing"} {
            $client emit calls <Ended> -sid $sid
            $self Cleanup $sid
        }
    }

    method BuildJmiMessage {to action sid wantDescription} {
        set ns urn:xmpp:jingle-message:0
        return [j message -to $to -type chat {
            if {$wantDescription} {
                j $action -ns $ns -id $sid {
                    j description \
                        -ns urn:xmpp:jingle:apps:rtp:1 \
                        -media audio
                }
            } else {
                j $action -ns $ns -id $sid
            }
        }]
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
            session-accept    { $self HandleSessionAccept   $stanza $jingle $sid }
            session-terminate { $self HandleSessionTerminate $stanza $jingle $sid }
            transport-info    { $self HandleTransportInfo   $stanza $jingle $sid }
            default           { $self AckIq $stanza }
        }
    }

    method HandleSessionInitiate {stanza jingle sid from} {
        # JMI is mandatory: a session-initiate must be preceded by our
        # own <proceed>. Otherwise the user never agreed to ring and
        # we reject the IQ — the call never existed locally.
        if {![dict exists $Calls $sid]} {
            $self IqError $stanza item-not-found
            return
        }
        set call [dict get $Calls $sid]
        if {[dict get $call state] ne "proceeded"
                || [dict get $call initiator]} {
            $self IqError $stanza out-of-order
            return
        }
        # rtc-ma only decodes opus. If we leave the peer's other
        # offered codecs (PCMU/PCMA/G722/telephone-event/...) in the
        # description, libdatachannel's auto-generated answer accepts
        # them all and the peer is free to send RTP encoded as any of
        # them — producing opus_decode -4 on every packet. Strip
        # non-opus payload-types before to_sdp so the answer offers
        # opus only.
        set jingle [$self FilterOpusOnly $jingle]
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
        # Apply the offer; on-track fires async to drive AttachMedia.
        # NOTE: do NOT call set-local-description here — libdatachannel's
        # auto-negotiation (config.disableAutoNegotiation = false by
        # default) calls setLocalDescription(Answer) internally as part
        # of setRemoteDescription(Offer). Calling it ourselves afterwards
        # runs in signaling state Stable, where Unspec is treated as
        # Offer, which would generate a fresh offer and silently
        # overwrite the auto-generated answer.
        ::rtc::pc::set-remote-description $pc $sdp offer
        # Drain any candidates that arrived (and were buffered) while
        # this side's pc was still -1.
        if {[dict exists $Calls $sid pending_remote_candidates]} {
            foreach entry [dict get $Calls $sid pending_remote_candidates] {
                lassign $entry name full
                ::rtc::pc::add-remote-candidate $pc $full $name
            }
            dict unset Calls $sid pending_remote_candidates
        }
    }

    method HandleSessionAccept {stanza jingle sid} {
        if {![dict exists $Calls $sid]} {
            $self IqError $stanza item-not-found
            return
        }
        set sdp [::jinglesdp::to_sdp $jingle -initiator 1]
        set pc [dict get $Calls $sid pc]
        ::rtc::pc::set-remote-description $pc $sdp answer
        $self AckIq $stanza
    }

    method HandleTransportInfo {stanza jingle sid} {
        if {![dict exists $Calls $sid]} {
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
                set value [::jinglesdp::CandidateToSdp $cand]
                set full "candidate:$value"
                if {$pc == -1} {
                    dict update Calls $sid call {
                        dict lappend call pending_remote_candidates \
                            [list $name $full]
                    }
                } else {
                    ::rtc::pc::add-remote-candidate $pc $full $name
                }
            }
        }
        $self AckIq $stanza
    }

    method HandleSessionTerminate {stanza jingle sid} {
        $self AckIq $stanza
        if {![dict exists $Calls $sid]} return
        $self TeardownMedia $sid
        $client emit calls <Ended> -sid $sid
        $self Cleanup $sid
    }

    # =========================================================================
    # Helpers
    # =========================================================================

    # Walk a session-initiate's Jingle tree and remove any
    # <payload-type> whose name isn't "opus" from each rtp <description>.
    # Mirrors gajim's codec filter: keep the negotiation honest about
    # what we can actually decode.
    method FilterOpusOnly {jingle} {
        set NS_RTP urn:xmpp:jingle:apps:rtp:1
        set jc {}
        foreach c [dict get $jingle children] {
            if {[dict get $c tag] eq "content"} {
                set cc {}
                foreach d [dict get $c children] {
                    if {[dict get $d tag] eq "description"
                            && [dict get $d ns] eq $NS_RTP} {
                        set dc {}
                        foreach e [dict get $d children] {
                            if {[dict get $e tag] eq "payload-type"} {
                                set name ""
                                if {[dict exists $e attrs name]} {
                                    set name [dict get $e attrs name]
                                }
                                if {![string equal -nocase $name opus]} continue
                            }
                            lappend dc $e
                        }
                        dict set d children $dc
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

    method Cleanup {sid} {
        if {![dict exists $Calls $sid]} return
        set pc [dict get $Calls $sid pc]
        if {$pc != -1} { unset -nocomplain PcToSid($pc) }
        dict unset Calls $sid
    }

    method NewSid {} {
        return "tk-[clock microseconds]-[incr SidCounter]"
    }
}
