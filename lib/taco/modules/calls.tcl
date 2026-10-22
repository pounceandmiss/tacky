# Voice and video calls: XEP-0353 JMI rings the peer's devices, XEP-0166/
# 0167/0176 Jingle sets the session up, and `tacky::media`'s backend (webrtc,
# rtc or host) carries ICE, DTLS and RTP. The requests and events are in
# doc/DOC.md, "calls"; taco_groupcall (XEP-0272) runs one session per room
# participant here, with no JMI and no <Outgoing>/<Incoming>.
#
# taco_calls is the account's side: it rings and answers, keeps one
# taco_calls::call (call.tcl) per sid, and hands each call the stanzas for it. A call holds
# two machines, and every move of either goes through its Go, which refuses
# one its table does not list:
#
#   state (SESSION_NEXT)       proposed | ringing -> proceeded -> pending
#                              -> established
#   transport (TRANSPORT_NEXT) idle, checking, connected, interrupted,
#                              restarting
#
# Neither has an end state: every end goes through Finish, which tells the
# peer and the bus and drops the call at once. Inbound Jingle a session does
# not take in its state (JINGLE_IN) is refused before any handler runs.
#
# Every inbound stanza for a call must come from its peer: the bare JID while
# JMI rings (any of its devices may answer), the full one once proceed has
# latched it. The sid is no secret, since the propose goes to the bare JID.
#
# Candidates trickle as transport-info after the description; none that
# arrive before the remote description is set are lost (DrainPendingCandidates).
#
# An interrupted path is restarted (XEP-0176 5.9, as Conversations does it):
# either side may offer new credentials in a candidate-less transport-info,
# and the initiator wins a glare. A backend that cannot follow a restart
# keeps the old path and says so with a <Warning>. A call outlives a fresh
# stream if its media is flowing and our full JID is unchanged (OnFreshStream).
#
# Verification, as in Conversations: when OMEMO is on for the chat, each side
# names its OMEMO device in <propose>/<proceed> and sends its DTLS
# fingerprint encrypted for the other's, so a server cannot substitute its
# own certificate. <Verified> says whether we trust the device it came from.

package require tacky::media
package require omemo

snit::type taco_calls {
    option -client -readonly yes

    # XEP-0166's actions (§7.2). A value not among them is refused with
    # <bad-request/>, as the spec has it, before any session sees it.
    typevariable JINGLE_ACTIONS {
        content-accept content-add content-modify content-reject
        content-remove description-info security-info session-accept
        session-info session-initiate session-terminate transport-accept
        transport-info transport-reject transport-replace
    }

    variable client
    variable Calls      ;# sid -> taco_calls::call

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Calls [dict create]
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
        foreach call [dict values $Calls] { $call destroy }
    }

    # =========================================================================
    # The calls
    # =========================================================================

    method NewCall {sid args} {
        set call [::taco_calls::call %AUTO% -calls $self -client $client -sid $sid {*}$args]
        dict set Calls $sid $call
        return $call
    }

    # The call for $sid, "" if none.
    method Call {sid} { dict getdef $Calls $sid "" }

    # $call has ended (its End).
    method Forget {sid call} {
        if {[dict getdef $Calls $sid ""] eq $call} { dict unset Calls $sid }
    }

    # Call method $args on every live call. One may end another meanwhile.
    method Each {args} {
        foreach call [dict values $Calls] {
            if {![$call Ended]} { $call {*}$args }
        }
    }

    method NewSid {} {
        binary scan [omemo::random 16] H* hex
        return "tk-$hex"
    }

    # The session is ending (taco_client endSession): every call ends while
    # the link is still up to say so - a ringing one is declined, a proposed
    # one retracted, the rest terminated as gone.
    method OnClosing {args} {
        foreach {sid call} $Calls {
            if {[catch {$call Hangup gone} err]} {
                jlog warn "call $sid: ending it on close: $err"
                catch {$call Drop}
            }
        }
    }

    # A fresh (non-resumed) stream: see the call's OnFreshStream. Resumption
    # never lands here, and a plain disconnect is deliberately left alone.
    method OnFreshStream {args} {
        $self Each OnFreshStream [$client cget -jid]
    }

    method OnResumed {args} { $self Each OnResumed }

    # Trust changed: recheck live calls. Any of the peer's keys matters,
    # since verifying one ends blind trust for the others.
    method OnTrustChanged {args} { $self Each Reverify [dict get $args -jid] }
    method OnBlindTrust {args} { $self Each Reverify "" }

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
        set video [expr {$opts(-video) ? 1 : 0}]
        set call [$self NewCall $sid -peer $bare -initiator 1 -state proposed \
            -video $video]
        $call StartRingTimer
        $client emit calls <Outgoing> -sid $sid -to $bare -video $video
        $client write [$self BuildJmiMessage $bare propose $sid 1 $video \
            [$call AnnounceDevice]]
        return $sid
    }

    tackymethod accept {args} {
        array set opts {-sid ""}
        array set opts $args
        set call [$self Call $opts(-sid)]
        if {$call eq ""} { error "accept: no such call $opts(-sid)" }
        $call Accept
        return
    }

    tackymethod reject {args} {
        array set opts {-sid "" -reason decline}
        array set opts $args
        set call [$self Call $opts(-sid)]
        if {$call ne ""} { $call Hangup $opts(-reason) }
        return
    }

    tackymethod hangup {args} {
        array set opts {-sid "" -reason success}
        array set opts $args
        set call [$self Call $opts(-sid)]
        if {$call ne ""} { $call Hangup $opts(-reason) }
        return
    }

    # Every call in flight, one dict each, unordered. The only way to
    # learn a sid you did not see <Outgoing>/<Incoming> for, which is what
    # a client that restarted needs. A call is forgotten in the same frame
    # that ends it, so nothing terminal is ever in here. peer is bare, as
    # the events report it, even once proceed has latched a full JID.
    tackymethod list {args} {
        lmap call [dict values $Calls] { $call Row }
    }

    # Mute / unmute the local camera on a live video call. Video is
    # negotiated at start/answer; this only toggles capture.
    tackymethod setVideo {args} {
        array set opts {-sid "" -on 1}
        array set opts $args
        set call [$self Call $opts(-sid)]
        if {$call ne ""} { $call SetVideo $opts(-on) }
        return
    }

    # Hot-swap mic / speaker for a live call. Empty id = system default.
    tackymethod setDevices {args} {
        array set opts {-sid ""}
        array set opts $args
        set call [$self Call $opts(-sid)]
        if {$call eq ""} return
        foreach {flag kind} {-input capture -output playback} {
            if {[info exists opts($flag)]} { $call SetAudioDevice $kind $opts($flag) }
        }
        return
    }

    # Hook called by the global `video` module after the preferred
    # camera changes - hot-swap the camera on every live video call.
    tackymethod applyPreferredCamera {args} {
        array set opts {-id ""}
        array set opts $args
        if {[::tacky::media capability videoDevice]} {
            $self Each SetCamera $opts(-id)
        }
        return
    }

    # Hook called by the global `audio` module after the preferred
    # device changes — hot-swap every live call on this client.
    tackymethod applyPreferredDevice {args} {
        array set opts {-kind "" -id ""}
        array set opts $args
        $self Each SetAudioDevice $opts(-kind) $opts(-id)
        return
    }

    # Hook called by the global `audio` module after the volume changes —
    # hot-swap every live call on this client. Values in [0.0, 1.0]. A call
    # with no audio attached yet is a no-op in the backend; a value the
    # backend rejects surfaces as <Warning> and the call keeps running.
    tackymethod applyVolume {args} {
        array set opts {-kind "" -volume ""}
        array set opts $args
        if {[::tacky::media capability audioVolume]} {
            $self Each SetAudioVolume $opts(-kind) $opts(-volume)
        }
        return
    }

    # One group-call session to a participant's full JID, straight to media
    # and session-initiate (no JMI). Returns the sid.
    method StartGroupSession {args} {
        array set opts {-room "" -peer "" -video 0}
        array set opts $args
        if {$opts(-room) eq "" || $opts(-peer) eq ""} {
            error "StartGroupSession: -room and -peer required"
        }
        set sid [$self NewSid]
        set call [$self NewCall $sid -peer $opts(-peer) -initiator 1 \
            -state proceeded -video [expr {$opts(-video) ? 1 : 0}] \
            -group [jid norm $opts(-room)]]
        $call StartSetupTimer
        $client extdisco fetch -command [$call Callback StartOutgoingMedia]
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

    method EmitMissed {sid from video reason} {
        $client emit calls <Missed> -sid $sid -from [jid bare $from] \
            -video $video -reason $reason
    }

    # =========================================================================
    # Inbound JMI <message> (XEP-0353)
    # =========================================================================

    # Returns 1 if the stanza was claimed (had a JMI child), 0 otherwise. A
    # propose may open a call; the rest are the call's.
    method OnMessage {stanza} {
        set ns urn:xmpp:jingle-message:0
        foreach action {propose proceed ringing reject retract finish} {
            set child [xsearch $stanza $action -ns $ns -get node]
            if {$child eq ""} continue
            set sid [xsearch $child -get @id]
            set from [xsearch $stanza -get @from]
            if {$action eq "propose"} {
                $self OnPropose $stanza $child $sid $from
            } elseif {[set call [$self Call $sid]] ne ""} {
                $call Jmi $action $stanza $from
            }
            return 1
        }
        return 0
    }

    method OnPropose {stanza child sid from} {
        # Carbon of our own outbound propose: drop.
        if {[jid bare $from] eq [jid bare [$client cget -jid]]} return
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
        set ours [$self Call $sid]
        if {$ours ne "" && ![$ours ProposedTo $from]} return
        set video [$self ProposeHasVideo $child]

        # Calls can't be tunneled through a proxy (native ICE bypasses it), so
        # decline instead of ringing. Missed all the same, as busy is.
        if {[$self Blocked] ne ""} {
            $client write [$self BuildJmiMessage $from reject $sid 0]
            $self EmitMissed $sid $from $video proxy
            return
        }

        # Crossing proposes (XEP-0353 §4.1): the lower sid wins (i;octet),
        # then the lower JID; the receiver of the losing propose rejects it
        # with <tie-break/>. Theirs rings only if it beats every propose of
        # ours to them; ours then end.
        set beaten {}
        dict for {oursid call} $Calls {
            if {![$call ProposedTo $from]} continue
            set cmp [string compare $oursid $sid]
            if {$cmp == 0} {
                set cmp [string compare [jid norm [$client cget -jid]] [jid norm $from]]
            }
            if {$cmp < 0} {
                $client write [$self BuildJmiTieBreak $from $sid]
                return
            }
            lappend beaten $call
        }
        foreach call $beaten {
            $call Finish Ended replaced
        }

        # One call at a time: any other, group sessions included, makes
        # this one busy.
        if {[dict size $Calls] > 0} {
            $client write [$self BuildJmiReject $from $sid busy]
            $self EmitMissed $sid $from $video busy
            return
        }

        # We answer video symmetrically: if they offered it, we intend to
        # send it too (the GUI can still mute the camera).
        set call [$self NewCall $sid -peer $from -initiator 0 -state ringing \
            -video $video -video-remote $video]
        $call NotePeerDevice $child
        # XEP-0353 §4: tell the initiator this device is alerting the user.
        $client write [$self BuildJmiMessage $from ringing $sid 0]
        $call StartRingTimer
        $client emit calls <Incoming> -sid $sid -from [jid bare $from] -video $video
    }

    # Does an inbound JMI <propose> advertise a video <description>?
    method ProposeHasVideo {child} {
        foreach d [xsearch $child description \
                       -ns urn:xmpp:jingle:apps:rtp:1 -gather node] {
            if {[xsearch $d -get @media] eq "video"} { return 1 }
        }
        return 0
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
                        j device -ns $::taco_calls::call::NS_VERIFY -id $device
                    }
                }
            } else {
                j $action -ns $ns -id $sid
            }
        }]
    }

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

    # The <reject> of a propose that lost the tie-break (XEP-0353 §4.1).
    method BuildJmiTieBreak {to sid} {
        return [j message -to $to -type chat {
            j reject -ns urn:xmpp:jingle-message:0 -id $sid {
                j reason -ns urn:xmpp:jingle:1 { j expired }
                j tie-break
            }
        }]
    }

    # =========================================================================
    # Inbound Jingle IQ
    # =========================================================================

    # Every action but session-initiate is for a call that exists, from its
    # peer, in a state that takes it; that call's {Jingle action} handles
    # it. A sender that isn't the peer gets the same
    # answer as an unknown sid, so a guessed sid can't be confirmed.
    method OnJingleIq {stanza} {
        set jingle [xsearch $stanza jingle -ns urn:xmpp:jingle:1 -get node]
        if {$jingle eq ""} {
            $self IqError $stanza bad-request
            return
        }
        lassign [xsearch $jingle -get {@action @sid}] action sid
        set from [xsearch $stanza -get @from]
        if {$action ni $JINGLE_ACTIONS} {
            $self IqError $stanza bad-request
            return
        }
        if {$action eq "session-initiate"} {
            if {![$self OpenSession $stanza $jingle $sid $from]} return
        }
        set call [$self Call $sid]
        if {$call eq "" || ![$call Matches $from]} {
            # Acknowledged anyway: whatever it ended is over.
            if {$action eq "session-terminate"} {
                $self AckIq $stanza
            } else {
                $self IqError $stanza item-not-found
            }
            return
        }
        # A session-initiate is the handler's to judge, since it may open
        # the session or cross one of ours.
        if {$action ne "session-initiate" && ![$call Takes $action]} {
            $self IqError $stanza out-of-order
            return
        }
        $call Jingle $action $stanza $jingle $from
    }

    # Make sure a session-initiate has its call, if it may: returns 0 when
    # it may not, having answered it. JMI is mandatory: a session-initiate
    # must be preceded by our own <proceed>, or the user never agreed to
    # ring. Except a Muji session, whose sender taco_groupcall vouches for.
    #
    # Crossing initiates (XEP-0166 §7.2.16): we also have an unanswered
    # group session to this peer. The lower sid wins, then the lower JID.
    # If ours wins, theirs gets <tie-break/>; otherwise, or if ours was
    # never sent, theirs replaces ours, which is dropped silently.
    method OpenSession {stanza jingle sid from} {
        set ours [$self CrossingSession $from]
        set known [$self Call $sid]
        if {$ours eq "" || ($known ne "" && $sid ne $ours)} {
            if {$known ne "" || [$self OpenGroupSession $jingle $sid $from]} {
                return 1
            }
            $self IqError $stanza item-not-found
            return 0
        }
        set call [$self Call $ours]
        set cmp [string compare $sid $ours]
        if {$cmp == 0} {
            set cmp [string compare [jid norm $from] [jid norm [$client cget -jid]]]
        }
        if {[$call Initiated] && $cmp > 0} {
            $self IqError $stanza conflict tie-break
            return 0
        }
        # Same sid: drop ours first, theirs takes the sid.
        if {$sid eq $ours} { $call Drop }
        if {![$self OpenGroupSession $jingle $sid $from $ours]} {
            # groupcall refused theirs: ours stays, or ends if already
            # dropped.
            if {$sid eq $ours} {
                $client emit calls <Ended> -sid $ours -reason replaced
            }
            $self IqError $stanza item-not-found
            return 0
        }
        if {$sid ne $ours} { $call Drop }
        return 1
    }

    # The sid of our unanswered group session to $from (full JID), "" if
    # none.
    method CrossingSession {from} {
        dict for {sid call} $Calls {
            if {[$call UnansweredTo $from]} { return $sid }
        }
        return ""
    }

    # A session-initiate with <muji room/> from a known participant becomes a
    # callee session in `proceeded`, as if JMI-accepted. Returns 1 if opened.
    # $replaces: our unanswered session to $from that this one replaces.
    method OpenGroupSession {jingle sid from {replaces ""}} {
        set room [xsearch $jingle muji -ns urn:xmpp:jingle:muji:0 -get @room]
        if {$room eq "" || ![jid valid $room]} { return 0 }
        set video 0
        xsearch $jingle content -script content {
            set d [xsearch $content description \
                -ns urn:xmpp:jingle:apps:rtp:1 -get node]
            if {$d ne "" && [xsearch $d -get @media] eq "video"} {
                set video 1
            }
        }
        set wantVideo [$client groupcall AcceptSession \
            -room $room -peer $from -sid $sid -video $video -replaces $replaces]
        if {$wantVideo eq ""} { return 0 }
        set call [$self NewCall $sid -peer $from -initiator 0 -state proceeded \
            -video [expr {$wantVideo ? 1 : 0}] -video-remote $video \
            -group [jid norm $room]]
        $call StartSetupTimer
        return 1
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
                        set keep [dict getdef $codecs [dict getdef $d attrs media ""] {}]
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
            if {[dict get $e tag] eq "payload-type"
                    && [lsearch -exact -nocase $keep [dict getdef $e attrs name ""]] < 0} {
                continue
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
