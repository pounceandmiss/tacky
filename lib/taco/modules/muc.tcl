# tacky muc join -acc $jid -jid $room -nick $nick ?-password $pw? ?-history {...}? ?-hidden 0|1?
#   ;# -hidden: a room for tacky's own use (a group call's): not bookmarked,
#   ;# listed or archived; messages dropped. Events are as for any room.
# tacky muc leave -acc $jid -jid $room ?-status $text?
# tacky muc nick -acc $jid -jid $room -nick $newNick
# tacky muc status -acc $jid -jid $room ?-show $val? ?-status $text?
# tacky muc say -acc $jid -jid $room -body $text
# tacky muc pm -acc $jid -jid $occupantJid -body $text
# tacky muc subject -acc $jid -jid $room -body $text
# tacky muc invite -acc $jid -jid $room -to $jid ?-reason $text?
# tacky muc decline -acc $jid -jid $room -to $inviterJid ?-reason $text?
# tacky muc acceptInvite -acc $jid -chat $chatJid -timestamp $ts
# tacky muc declineInvite -acc $jid -chat $chatJid -timestamp $ts ?-reason $text?
# tacky muc requestVoice -acc $jid -jid $room
# tacky muc kick -acc $jid -jid $room -nick $nick ?-reason $text? ?-command $cb?
# tacky muc role -acc $jid -jid $room -nick $nick -role $role ?-reason $text? ?-command $cb?
# tacky muc affiliation -acc $jid -jid $room -target $bareJid -affiliation $a ?-reason $t? ?-nick $n? ?-command $cb?
# tacky muc getList -acc $jid -jid $room -what $what ?-command $cb? ?-onerror $ecb?
# tacky muc configGet -acc $jid -jid $room ?-command $cb? ?-onerror $ecb?   ;# cb gets a form dict
# tacky muc configSet -acc $jid -jid $room -form $formDict ?-command $cb?
# tacky muc configCancel -acc $jid -jid $room ?-command $cb?
# tacky muc createInstant -acc $jid -jid $room ?-command $cb?
# tacky muc createRoom -acc $jid -jid $room -nick $nick ?-hidden 0|1? ?-config {var value ...}? ?-command $cb? ?-onerror $ecb?
#   ;# a new room, configured before anyone can enter; cb gets the room JID,
#   ;# ecb a reason. An existing room is an error.
# tacky muc destroyRoom -acc $jid -jid $room ?-altRoom $jid? ?-reason $t? ?-password $pw? ?-command $cb?
# tacky muc registerGet -acc $jid -jid $room ?-command $cb? ?-onerror $ecb? ;# cb gets a form dict
# tacky muc registerSet -acc $jid -jid $room -form $formDict ?-command $cb?
# tacky muc discoverRooms -acc $jid -jid $serviceJid ?-command $cb? ?-onerror $ecb?
# tacky muc findService -acc $jid -command $cb   ;# cb gets our server's MUC service JID, "" if none
# tacky muc reservedNick -acc $jid -jid $room ?-command $cb?
#
# tacky muc getSubject -acc $jid -jid $room
# tacky muc occupants -acc $jid -jid $room
# tacky muc occupant -acc $jid -jid $room -nick $nick
#   ;# occupant: nick jid jids role affiliation show status occupant_id caps, plus
#   ;# fields from addOccupantField (groupcall's call)
# tacky muc myNick -acc $jid -jid $room
# tacky muc myRole -acc $jid -jid $room
# tacky muc myAffiliation -acc $jid -jid $room
# tacky muc haveVoice -acc $jid -jid $room
# tacky muc isJoined -acc $jid -jid $room
# tacky muc isHidden -acc $jid -jid $room   ;# remembered after leaving, until rejoined
# tacky muc rooms -acc $jid                  ;# joined rooms, hidden ones left out
# tacky muc roomInfo -acc $jid -jid $room    ;# {known live members_only non_anonymous occupant_id}
# tacky muc roomPrivacy -acc $jid -jid $room ;# why its readers aren't known, {} when they are
# tacky muc members -acc $jid -jid $room     ;# {list $status members {$realJid $affiliation ...}}
# tacky muc people -acc $jid -jid $room      ;# {list groups me people}: who to show (see "People")
#
# tacky listen muc <Joined> $cmd             ;# -jid $room -nick $myNick
# tacky listen muc <Left> $cmd               ;# -jid $room -nick $myNick -involuntary $bool -codes $codes ?-disconnected 1? ?-destroyed 1?
# tacky listen muc <Error> $cmd              ;# -jid $room -error $errorType -stanza $stanza
# tacky listen muc <Presence> $cmd           ;# -jid $room -nick $nick -occupant $dict ?-replay 1?
#   ;# -replay 1: re-sent after our role changed (caps), not a new presence
# tacky listen muc <Unavailable> $cmd        ;# -jid $room -nick $nick -reason $r -codes $codes -occupant $dict
# tacky listen muc <Subject> $cmd            ;# -jid $room -nick $nick -subject $text
# NOTE: MUC messages are delivered via message <New>, not muc events.
# NOTE: invitations are stored as messages (content type "invite"), not muc
# events: a room-relayed one in the room's chat, a direct one in the inviter's.
# tacky listen muc <Decline> $cmd            ;# -jid $room -from $declinerJid -reason $text
# tacky listen muc <NickChanged> $cmd        ;# -jid $room -oldNick $old -newNick $new -self $bool -occupant $dict
# tacky listen muc <NickError> $cmd          ;# -jid $room -nick $refusedNick -error $condition
# tacky listen muc <Kicked> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <Banned> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <ConfigChanged> $cmd      ;# -jid $room -codes $statusCodes
# tacky listen muc <RoomCreated> $cmd        ;# -jid $room
# tacky listen muc <Destroyed> $cmd          ;# -jid $room -altRoom $jidOrEmpty -reason $text
# tacky listen muc <VoiceRequest> $cmd       ;# -jid $room -from $jid -nick $nick -form $formDict
# tacky listen muc <AffiliationChanged> $cmd ;# -jid $room -target $bareJid -affiliation $new
# tacky listen muc <RoomInfo> $cmd           ;# -jid $room -info $roomInfo (disco#info answered)
# tacky listen muc <MembersChanged> $cmd     ;# -jid $room (members or its list status changed)
# tacky listen muc <PeopleChanged> $cmd      ;# -jid $room (what `people` answers changed; coalesced)

snit::type taco_muc {
    variable client

    # roomJid -> dict: nick, myOccupantId, subject, joined, leaving,
    # occupants (dict nick->occupantDict), hidden, created, plus what the
    # room is and who reads it:
    #   features      its disco#info features, once `fetched` is 1
    #   members       real bare JID -> owner|admin|member: everyone with an
    #                 affiliation, in the room or not (see "Membership")
    #   memberList    none|pending|complete|partial|presence: how far the
    #                 affiliation lists got (partial: some refused;
    #                 presence: all refused, so members are those seen)
    #   memberSerial  the member-list request this join is waiting on
    # Each occupantDict: {nick $n jid $fullJid jids $allItemJids role $r
    # affiliation $a show $s status $st occupant_id $id}, plus one key per
    # addOccupantField. occupant_id is only the room's word where the room
    # vouches for occupant-ids (TrustsOccupantId).
    # All of it goes with the room on leave: the member list is asked again
    # at every join, so nothing reads a stale one.
    variable Rooms -array {}

    # Member-list requests in flight: serial -> {left N refused N items L}.
    variable MembersPending -array {}
    variable MembersSerial 0

    # roomJid -> hidden flag of a room no longer tracked (isHidden); cleared
    # on rejoin.
    variable WasHidden -array {}

    # name -> parse command for extra occupant fields (addOccupantField).
    variable OccupantFields {}
    # name -> command for extra person fields (addPersonField).
    variable PersonFields {}
    # roomJid -> the after token of a <PeopleChanged> still to go out.
    variable PeopleDue -array {}

    # roomJid -> join -command callback (pending joins)
    variable JoinCallbacks -array {}
    # roomJid -> the after token giving up on a join the room never answers
    variable JoinTimers -array {}

    # roomJid -> nick requested in a joined room, until the room answers
    # with a 303 (accepted) or an error (<NickError>).
    variable PendingNick -array {}
    # How long a room has to answer a join.
    typevariable JoinTimeoutMs 30000
    # Our server's MUC service, probed once per session; ServiceWaiters are
    # the callers waiting on the probe.
    variable ServiceJid ""
    variable ServiceFound 0
    variable ServiceWaiters {}

    # Cap on occupants tracked per room; new ones past it are dropped.
    typevariable MaxOccupants 10000

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client bus subscribe $self <SessionEnd> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        foreach roomJid [array names JoinTimers] {
            after cancel $JoinTimers($roomJid)
        }
        foreach roomJid [array names PeopleDue] {
            after cancel $PeopleDue($roomJid)
        }
    }

    method OnDisconnect {args} {
        foreach roomJid [array names JoinCallbacks] {
            $self FailJoin $roomJid disconnected
        }
        foreach roomJid [array names JoinTimers] {
            after cancel $JoinTimers($roomJid)
        }
        array unset JoinTimers *
        # The session took us out of every room, joined or still joining.
        foreach roomJid [array names Rooms] {
            $self SelfLeft $roomJid 0 {} -disconnected 1
        }
    }

    # A join that ends without our self-presence: its -command hears it,
    # once, whatever ended it.
    method FailJoin {roomJid error} {
        if {[info exists JoinTimers($roomJid)]} {
            after cancel $JoinTimers($roomJid)
            unset JoinTimers($roomJid)
        }
        if {![info exists JoinCallbacks($roomJid)]} return
        set cmd $JoinCallbacks($roomJid)
        unset JoinCallbacks($roomJid)
        {*}$cmd [list -jid $roomJid -error $error]
    }

    method JoinTimedOut {roomJid} {
        unset -nocomplain JoinTimers($roomJid)
        if {![info exists Rooms($roomJid)] || [dict get $Rooms($roomJid) joined]} return
        jlog warn "$roomJid did not answer the join"
        $self FailJoin $roomJid remote-server-timeout
        $self ForgetRoom $roomJid
        $self Emit $roomJid <Error> -jid $roomJid -error remote-server-timeout -stanza {}
    }

    # =====================================================================
    # Joining / Leaving
    # =====================================================================

    method join {args} {
        array set opts {-password "" -history {} -command "" -hidden 0}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]
        # A hidden join never takes over a room we are in or joining as
        # ourselves: it would drop the room's messages, and its leave would
        # take us out of the room.
        if {$opts(-hidden) && [info exists Rooms($opts(-jid))]
                && ![dict get $Rooms($opts(-jid)) hidden]} {
            error "muc join: $opts(-jid) is a room we are in or joining"
        }

        # Initialize room tracking state
        unset -nocomplain WasHidden($opts(-jid))
        set Rooms($opts(-jid)) [dict create \
            nick $opts(-nick) myOccupantId "" subject "" joined 0 \
            leaving 0 occupants [dict create] \
            hidden [expr {$opts(-hidden) ? 1 : 0}] created 0 \
            features {} fetched 0 \
            members [dict create] memberList none memberSerial 0]

        if {$opts(-command) ne ""} {
            set JoinCallbacks($opts(-jid)) $opts(-command)
        }
        if {[info exists JoinTimers($opts(-jid))]} {
            after cancel $JoinTimers($opts(-jid))
        }
        set JoinTimers($opts(-jid)) \
            [after $JoinTimeoutMs [mymethod JoinTimedOut $opts(-jid)]]

        # Build <x xmlns='muc'> with optional children
        set mucChildren {}
        if {$opts(-password) ne ""} {
            lappend mucChildren password $opts(-password)
        }

        # A room whose archive answered before gets its history from MAM
        # after the join (message DoMucCatchup); the join history would
        # only repeat the newest of it.
        if {![dict exists $args -history] && [$self HasArchive $opts(-jid)]} {
            set opts(-history) {maxstanzas 0}
        }
        set historyAttrs {}
        dict for {k v} $opts(-history) {
            lappend historyAttrs -$k $v
        }

        $client write [j presence -to $opts(-jid)/$opts(-nick) {
            j x -ns http://jabber.org/protocol/muc {
                if {$mucChildren ne ""} {
                    foreach {ctag cval} $mucChildren {
                        j $ctag -body $cval
                    }
                }
                if {$historyAttrs ne ""} {
                    j history {*}$historyAttrs
                }
            }
        }]

        $self Emit $opts(-jid) <Joining> -jid $opts(-jid)
    }

    method leave {args} {
        array set opts {-status ""}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]

        if {![info exists Rooms($opts(-jid))]} return
        set nick [dict get $Rooms($opts(-jid)) nick]
        # The room's unavailable echo is identical whether we left or were
        # put out, so record that we asked.
        dict set Rooms($opts(-jid)) leaving 1

        if {$opts(-status) ne ""} {
            $client write [j presence -to $opts(-jid)/$nick -type unavailable {
                j status -body $opts(-status)
            }]
        } else {
            $client write [j presence -to $opts(-jid)/$nick -type unavailable]
        }
    }

    method nick {args} {
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]
        if {[info exists Rooms($opts(-jid))] && [dict get $Rooms($opts(-jid)) joined]} {
            set PendingNick($opts(-jid)) $opts(-nick)
        }
        $client write [j presence -to $opts(-jid)/$opts(-nick)]
    }

    method status {args} {
        array set opts {-show "" -status ""}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]

        if {![info exists Rooms($opts(-jid))]} return
        set nick [dict get $Rooms($opts(-jid)) nick]

        $client write [j presence -to $opts(-jid)/$nick {
            if {$opts(-show) ne ""} {
                j show -body $opts(-show)
            }
            if {$opts(-status) ne ""} {
                j status -body $opts(-status)
            }
        }]
    }

    # Our presence to a joined room with extra child nodes (e.g. XEP-0272
    # Muji). Carries our caps: occupants see only the room's rebroadcast.
    method sendPresence {roomJid nodes} {
        set roomJid [jid norm $roomJid]
        if {![info exists Rooms($roomJid)]} return
        set nick [dict get $Rooms($roomJid) nick]
        $client write [j presence -to $roomJid/$nick {
            j #as-is [$client caps cNode]
            foreach node $nodes {
                j #as-is $node
            }
        }]
    }

    # The real JID behind an occupant, "" when the room hides it or the
    # nick is unknown.
    method realJid {roomJid nick} {
        set roomJid [jid norm $roomJid]
        if {![info exists Rooms($roomJid)]} { return "" }
        set occs [dict get $Rooms($roomJid) occupants]
        if {![dict exists $occs $nick]} { return "" }
        return [dict get $occs $nick jid]
    }

    # =====================================================================
    # What the room is, and who reads it
    # =====================================================================
    #
    # A room's disco#info features say whether its readers are known: a
    # members-only room admits only those with an affiliation, and a
    # non-anonymous one tells every occupant everyone's real JID. Both
    # together are what OMEMO needs (XEP-0384 §5.7). The features are kept
    # per account too (setting muc.features.<room>), so a room is known for
    # what it is before this connection has asked it.
    #
    # Membership: everyone the room gives an owner, admin or member
    # affiliation, by real bare JID. The three affiliation lists are asked
    # together once the room is known to be private; until all three have
    # answered the list is `pending`. A room may refuse a member the lists;
    # then the members are those its presences show (`presence`). From then
    # on what the room says keeps it current: an occupant's presence with
    # its real JID and affiliation, an unavailable one taking the
    # affiliation away (321, a ban), and the room's own affiliation notices
    # for someone not in it. Leaving the room is not losing the affiliation.

    # The features that matter to reading a room, as remembered.
    typevariable RememberedFeatures {muc_membersonly muc_nonanonymous urn:xmpp:occupant-id:0}

    method NoteRoomFeatures {roomJid features} {
        if {![info exists Rooms($roomJid)]} return
        if {[dict get $Rooms($roomJid) hidden]} return
        dict set Rooms($roomJid) features $features
        dict set Rooms($roomJid) fetched 1
        set kept {}
        foreach f $RememberedFeatures {
            if {$f in $features} { lappend kept $f }
        }
        # "-" is a room seen with none of them, unlike a room never seen.
        set value [expr {[llength $kept] ? $kept : "-"}]
        catch {
            if {[$client setting get -key muc.features.$roomJid] ne $value} {
                $client setting set -key muc.features.$roomJid -value $value
            }
        }
        # Occupant-ids the presences carried are the room's word now.
        if {[$self TrustsOccupantId $roomJid 1]} {
            dict for {nick occ} [dict get $Rooms($roomJid) occupants] {
                $self LearnFromOccupant $roomJid $occ
            }
        }
        $self Emit $roomJid <RoomInfo> -jid $roomJid \
            -info [$self RoomInfoOf $roomJid]
        if {[llength [$self RoomReasons $roomJid]] == 0
                && [dict get $Rooms($roomJid) memberList] eq "none"} {
            $self FetchMembers $roomJid
        }
    }

    # {known 0|1 live 0|1 members_only 0|1 non_anonymous 0|1
    #  occupant_id 0|1}: `live` when the room answered this connection,
    # `known` when it did or a past one did.
    method RoomInfoOf {roomJid} {
        set roomJid [jid norm $roomJid]
        set feats ""
        set live 0
        if {[info exists Rooms($roomJid)] && [dict get $Rooms($roomJid) fetched]} {
            set feats [dict get $Rooms($roomJid) features]
            set live 1
        } else {
            catch {set feats [$client setting get -key muc.features.$roomJid]}
        }
        return [dict create \
            known [expr {$feats ne ""}] live $live \
            members_only [expr {"muc_membersonly" in $feats}] \
            non_anonymous [expr {"muc_nonanonymous" in $feats}] \
            occupant_id [expr {"urn:xmpp:occupant-id:0" in $feats}]]
    }

    tackymethod roomInfo {args} {
        $self RoomInfoOf [dict get $args -jid]
    }

    # Why the room's readers are not known, as a list of words ({} when
    # they are): unknown (the room has never said what it is),
    # not_members_only, anonymous.
    method RoomReasons {roomJid} {
        set info [$self RoomInfoOf $roomJid]
        if {![dict get $info known]} { return {unknown} }
        set out {}
        if {![dict get $info members_only]} { lappend out not_members_only }
        if {![dict get $info non_anonymous]} { lappend out anonymous }
        return $out
    }

    tackymethod roomPrivacy {args} {
        $self RoomReasons [dict get $args -jid]
    }

    # Whether the room stamps occupant-ids (XEP-0421), which it then also
    # strips from what occupants send: only then is an <occupant-id/> the
    # room's word rather than the sender's. By what the room said this
    # connection, or (unless $live) what it said before: an archive page can
    # come in ahead of the room's disco#info. What is kept for good (the
    # occupant map) is only learned on this connection's word.
    method TrustsOccupantId {roomJid {live 0}} {
        set roomJid [jid norm $roomJid]
        if {![info exists Rooms($roomJid)]} { return 0 }
        set info [$self RoomInfoOf $roomJid]
        if {$live && ![dict get $info live]} { return 0 }
        dict get $info occupant_id
    }

    # The owner, admin and member lists, asked together.
    method FetchMembers {roomJid} {
        if {![info exists Rooms($roomJid)]} return
        if {[dict get $Rooms($roomJid) memberList] eq "pending"} return
        set serial [incr MembersSerial]
        dict set Rooms($roomJid) memberList pending
        dict set Rooms($roomJid) memberSerial $serial
        set MembersPending($serial) [dict create left 3 refused 0 items {}]
        foreach affil {owner admin member} {
            $client iq request -type get -to $roomJid \
                -command [mymethod OnMembersPart $roomJid $serial] \
                -payload [j query -ns http://jabber.org/protocol/muc#admin {
                    j item -affiliation $affil
                }]
        }
        $self EmitMembers $roomJid
    }

    method OnMembersPart {roomJid serial stanza} {
        if {![info exists MembersPending($serial)]} return
        set st $MembersPending($serial)
        dict incr st left -1
        if {[xsearch $stanza -get @type] eq "error"} {
            dict incr st refused
        } else {
            xsearch $stanza query item -script it {
                set ij [xsearch $it -get @jid]
                set ia [xsearch $it -get @affiliation]
                if {$ij eq "" || ![jid valid $ij] || $ia ni {owner admin member}} continue
                dict lappend st items [list [jid norm [jid bare $ij]] $ia]
            }
        }
        if {[dict get $st left] > 0} {
            set MembersPending($serial) $st
            return
        }
        unset MembersPending($serial)
        # A reply to a join we have since left or redone.
        if {![info exists Rooms($roomJid)]
                || [dict get $Rooms($roomJid) memberSerial] != $serial} return
        foreach item [dict get $st items] {
            $self SetMember $roomJid {*}$item
        }
        set refused [dict get $st refused]
        dict set Rooms($roomJid) memberList [expr {$refused == 3 ? "presence"
            : $refused ? "partial" : "complete"}]
        if {$refused} {
            jlog inform "$roomJid: $refused of the 3 affiliation lists refused;\
                members are also those its presences show"
        }
        $self EmitMembers $roomJid
    }

    # Add or drop one member on the room's word. 1 when that changed it.
    method SetMember {roomJid real affil} {
        set members [dict get $Rooms($roomJid) members]
        if {$affil in {owner admin member}} {
            if {[dict exists $members $real] && [dict get $members $real] eq $affil} {
                return 0
            }
            dict set Rooms($roomJid) members $real $affil
            return 1
        }
        if {![dict exists $members $real]} { return 0 }
        dict unset members $real
        dict set Rooms($roomJid) members $members
        return 1
    }

    # An occupant as the room describes it: its real JID when the room
    # says, with its affiliation, and its occupant-id.
    method NoteOccupant {roomJid occ} {
        if {[dict get $Rooms($roomJid) hidden]} return
        set real [$self OccupantRealJid $occ]
        if {$real eq ""} return
        $self LearnFromOccupant $roomJid $occ
        set affil [dict get $occ affiliation]
        if {$affil eq ""} return
        if {[$self SetMember $roomJid $real $affil]} {
            $self EmitMembers $roomJid
        }
    }

    method OccupantRealJid {occ} {
        set j [dict get $occ jid]
        if {$j eq "" || ![jid valid $j]} { return "" }
        return [jid norm [jid bare $j]]
    }

    method LearnFromOccupant {roomJid occ} {
        set occId [dict get $occ occupant_id]
        if {$occId eq "" || ![$self TrustsOccupantId $roomJid 1]} return
        set real [$self OccupantRealJid $occ]
        if {$real ne ""} { $self LearnOccupant $roomJid $occId $real }
    }

    # The room's notice that someone's affiliation changed (XEP-0045
    # 9.3-9.8, status 101 when they are not in the room).
    method OnAffiliationNotice {roomJid mucX} {
        set itemJid [xsearch $mucX item -get @jid]
        set itemAffil [xsearch $mucX item -get @affiliation]
        if {$itemJid eq "" || $itemAffil eq ""} return
        if {[info exists Rooms($roomJid)] && ![dict get $Rooms($roomJid) hidden]
                && [jid valid $itemJid]
                && [$self SetMember $roomJid [jid norm [jid bare $itemJid]] $itemAffil]} {
            $self EmitMembers $roomJid
        }
        $self Emit $roomJid <AffiliationChanged> \
            -jid $roomJid -target $itemJid -affiliation $itemAffil
    }

    method EmitMembers {roomJid} {
        $self Emit $roomJid <MembersChanged> -jid $roomJid
    }

    # members -jid $room -> {list none|pending|complete|partial|presence
    #                         members {jid affiliation ...}}
    tackymethod members {args} {
        set roomJid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($roomJid)]} {
            return [dict create list none members {}]
        }
        return [dict create list [dict get $Rooms($roomJid) memberList] \
            members [dict get $Rooms($roomJid) members]]
    }

    # Joined rooms $realJid is a member of.
    method roomsOfMember {realJid} {
        set out {}
        foreach roomJid [array names Rooms] {
            if {[dict exists [dict get $Rooms($roomJid) members] $realJid]} {
                lappend out $roomJid
            }
        }
        return [lsort $out]
    }

    # =====================================================================
    # People
    # =====================================================================
    #
    # Who to show for a room: everyone in it, and every member who is not.
    # An occupant is matched to a member by the real bare JID its presence
    # carries; one the room shows no JID for (an anonymous room) or that
    # has no affiliation (an open room) is listed for being there. What
    # the member list could not say (refused, `presence`) is simply not
    # listed: the members are then the occupants.
    #
    # Ordered for showing, by group: moderator, participant, visitor,
    # other (no role yet), then absent; by nick within a group, by JID
    # among the absent.

    typevariable GroupRank {moderator 0 participant 1 visitor 2 other 3 absent 4}

    method GroupOf {role} {
        expr {$role in {moderator participant visitor} ? $role : "other"}
    }

    # What the current user may do about the room itself, as OccupantCaps
    # is about one occupant.
    method RoomCaps {roomJid} {
        set myRole [$self MyOccupantField $roomJid role]
        set myAffil [$self MyOccupantField $roomJid affiliation]
        dict create \
            request_voice [expr {$myRole eq "visitor"}] \
            destroy [expr {$myAffil eq "owner"}]
    }

    # people -jid $room -> {list $memberList groups {$group $count ...}
    #                       me $roomCaps people {$person ...}}
    # A person: {key nick jid occupant present self group role
    # affiliation show status occupant_id caps}, plus each occupant field
    # ("" for the absent) and each addPersonField. `key` is the real JID,
    # or nick:$nick where there is none (or a second nick shares it); `jid`
    # is the bare real JID; `occupant` is room/nick, "" for the absent.
    tackymethod people {args} {
        set roomJid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($roomJid)] || [dict get $Rooms($roomJid) hidden]} {
            return [dict create list none groups {} \
                me [dict create request_voice 0 destroy 0] people {}]
        }
        set myNick [dict get $Rooms($roomJid) nick]
        set members [dict get $Rooms($roomJid) members]
        set present {}
        set seen [dict create]
        dict for {nick occ} [dict get $Rooms($roomJid) occupants] {
            set real [$self OccupantRealJid $occ]
            set key [expr {$real ne "" && ![dict exists $seen $real]
                ? $real : "nick:$nick"}]
            if {$real ne ""} { dict set seen $real 1 }
            set p [$self WithCaps $roomJid $occ]
            dict unset p jids
            dict set p key $key
            dict set p jid $real
            dict set p occupant $roomJid/$nick
            dict set p present 1
            dict set p self [expr {$nick eq $myNick}]
            dict set p group [$self GroupOf [dict get $occ role]]
            lappend present [$self WithPersonFields $roomJid $real $p]
        }
        set present [lsort -command [mymethod ComparePresent] $present]
        set absent {}
        foreach real [lsort [dict keys $members]] {
            if {[dict exists $seen $real]} continue
            set p [dict create key $real nick "" jid $real occupant "" \
                present 0 self 0 group absent role none \
                affiliation [dict get $members $real] show "" status "" \
                occupant_id "" caps [$self EmptyCaps]]
            dict for {name cmd} $OccupantFields { dict set p $name "" }
            lappend absent [$self WithPersonFields $roomJid $real $p]
        }
        set groups [dict create]
        foreach p [concat $present $absent] {
            dict incr groups [dict get $p group]
        }
        return [dict create list [dict get $Rooms($roomJid) memberList] \
            groups $groups me [$self RoomCaps $roomJid] \
            people [concat $present $absent]]
    }

    method ComparePresent {a b} {
        set c [expr {[dict get $GroupRank [dict get $a group]]
            - [dict get $GroupRank [dict get $b group]]}]
        if {$c} { return $c }
        set c [string compare -nocase [dict get $a nick] [dict get $b nick]]
        if {$c} { return $c }
        string compare [dict get $a nick] [dict get $b nick]
    }

    method WithPersonFields {roomJid real p} {
        dict for {name cmd} $PersonFields {
            set v ""
            if {[catch {{*}$cmd $roomJid $real} v]} {
                jlog warn "muc people: $name for $real in $roomJid: $v"
                set v ""
            }
            dict set p $name $v
        }
        return $p
    }

    # What `people` answers for $room may have changed: say so once, when
    # the burst that changed it is over - a join is a presence per
    # occupant. Public for the modules behind addPersonField.
    method peopleChanged {roomJid} {
        set roomJid [jid norm $roomJid]
        if {[info exists Rooms($roomJid)]
                ? [dict get $Rooms($roomJid) hidden]
                : [info exists WasHidden($roomJid)] && $WasHidden($roomJid)} return
        if {[info exists PeopleDue($roomJid)]} return
        set PeopleDue($roomJid) [after idle [mymethod EmitPeopleChanged $roomJid]]
    }

    method EmitPeopleChanged {roomJid} {
        unset -nocomplain PeopleDue($roomJid)
        $client emit muc <PeopleChanged> -jid $roomJid
    }

    # An occupant-id the room vouched for, and the real JID its presence
    # carried. Kept: an archived message is attributed by it. The first JID
    # stays: XEP-0421 gives each real bare JID its own id, so another JID
    # under the same id is the room contradicting itself.
    method LearnOccupant {roomJid occId real} {
        if {$occId eq "" || [string length $occId] > 128} return
        set known [$self occupantJid $roomJid $occId]
        if {$known eq $real} return
        if {$known ne ""} {
            jlog warn "$roomJid: occupant-id $occId was $known and is now\
                said to be $real; keeping $known"
            return
        }
        $client db eval {
            INSERT OR IGNORE INTO muc_occupant(room_jid, occupant_id, real_jid)
            VALUES($roomJid, $occId, $real)
        }
    }

    # The real bare JID behind an occupant-id of $roomJid, "" when unknown.
    method occupantJid {roomJid occId} {
        if {$occId eq ""} { return "" }
        return [$client db onecolumn {
            SELECT real_jid FROM muc_occupant
            WHERE room_jid=$roomJid AND occupant_id=$occId
        }]
    }

    # =====================================================================
    # Messaging
    # =====================================================================

    method say {args} {
        array set opts $args
        $client message send -chat $opts(-jid)?join -body $opts(-body)
    }

    method pm {args} {
        array set opts $args
        $client write [j message -to $opts(-jid) -type chat {
            j body -body $opts(-body)
            j x -ns http://jabber.org/protocol/muc#user
        }]
    }

    method subject {args} {
        array set opts $args
        $client write [j message -to $opts(-jid) -type groupchat {
            j subject -body $opts(-body)
        }]
    }

    # =====================================================================
    # Invitations
    # =====================================================================

    tackymethod -noreturn invite {args} {
        array set opts {-reason ""}
        array set opts $args

        $client write [j message -to $opts(-jid) {
            j x -ns http://jabber.org/protocol/muc#user {
                j invite -to $opts(-to) {
                    if {$opts(-reason) ne ""} {
                        j reason -body $opts(-reason)
                    }
                }
            }
        }]
    }

    method decline {args} {
        array set opts {-reason ""}
        array set opts $args

        $client write [j message -to $opts(-jid) {
            j x -ns http://jabber.org/protocol/muc#user {
                j decline -to $opts(-to) {
                    if {$opts(-reason) ne ""} {
                        j reason -body $opts(-reason)
                    }
                }
            }
        }]
    }

    # Accept and decline name the invite row by chat and timestamp, so a
    # frontend never handles the password. A non-invite row is a no-op; the
    # new `state` follows on <Edited>.

    # Bookmark the room with autojoin and the invite's password, undoing an
    # earlier decline.
    tackymethod -noreturn acceptInvite {args} {
        set chatJid [dict get $args -chat]
        set ts [dict get $args -timestamp]
        set row [$client message messagestore inviteAt $chatJid $ts]
        if {$row eq ""} return
        set invite [dict merge {room "" password ""} [dict get $row invite]]
        if {[dict get $row declined]} {
            $client message messagestore setInviteDeclined $chatJid $ts 0
        }
        set bm [list -jid [dict get $invite room] -autojoin 1]
        if {[dict get $invite password] ne ""} {
            lappend bm -password [dict get $invite password]
        }
        # Its <Changed> redraws every invite to the room, this one included.
        $client bookmarks item {*}$bm
    }

    # A relayed invite's decline goes to the inviter through the room; a
    # direct one (XEP-0249 has no decline) is only marked. A room chat left
    # holding only declined invites is dropped, and leaves the chat list.
    tackymethod -noreturn declineInvite {args} {
        array set opts {-reason ""}
        array set opts $args
        set chatJid $opts(-chat)
        set ts $opts(-timestamp)
        set store [list $client message messagestore]
        set row [{*}$store inviteAt $chatJid $ts]
        if {$row eq ""} return
        set invite [dict merge {room "" inviter ""} [dict get $row invite]]
        set relayed [string match {*\?join} $chatJid]
        if {$relayed && [dict get $invite inviter] ne ""} {
            $self decline -jid [dict get $invite room] \
                -to [dict get $invite inviter] -reason $opts(-reason)
        }
        {*}$store setInviteDeclined $chatJid $ts 1
        if {$relayed && [{*}$store onlyDeclinedInvites $chatJid]} {
            {*}$store forgetChat $chatJid
            $client chatlist forget $chatJid
        } else {
            $client message EmitMessagePatch $chatJid $ts
        }
        $client chatlist EmitEntry $chatJid
    }

    # =====================================================================
    # Voice
    # =====================================================================

    tackymethod -noreturn requestVoice {args} {
        set jid [dict get $args -jid]
        $client write [j message -to $jid {
            j x -ns jabber:x:data -type submit {
                j field -var FORM_TYPE {
                    j value -body http://jabber.org/protocol/muc#request
                }
                j field -var muc#role -type list-single -label {Requested role} {
                    j value -body participant
                }
            }
        }]
    }

    # =====================================================================
    # Role management (by nick, muc#admin)
    # =====================================================================

    tackymethod -async kick {args} {
        $self role {*}[dict set args -role none]
    }

    tackymethod -async role {args} {
        array set opts {-reason "" -command "" -onerror ""}
        array set opts $args

        set itemAttrs [list -nick $opts(-nick) -role $opts(-role)]

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnActionResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item {*}$itemAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason -body $opts(-reason)
                    }
                }
            }]
    }

    # =====================================================================
    # Affiliation management (by bare JID, muc#admin)
    # =====================================================================

    tackymethod -async affiliation {args} {
        array set opts {-reason "" -nick "" -command "" -onerror ""}
        array set opts $args

        set itemAttrs [list -jid $opts(-target) -affiliation $opts(-affiliation)]
        if {$opts(-nick) ne ""} {
            lappend itemAttrs -nick $opts(-nick)
        }

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnAffiliationResult [jid norm $opts(-jid)] \
                $opts(-target) $opts(-affiliation) $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item {*}$itemAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason -body $opts(-reason)
                    }
                }
            }]
    }

    # =====================================================================
    # List queries
    # =====================================================================

    method getList {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args

        lassign [$self ListQuerySpec $opts(-what)] attr val

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnListResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item -$attr $val
            }]
    }

    # =====================================================================
    # Room configuration (muc#owner)
    # =====================================================================

    method configGet {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnConfigGetResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner]
    }

    method configSet {args} {
        array set opts {-form "" -command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j #as-is [::tacky::forms::serialize $opts(-form)]
            }]
    }

    method configCancel {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j x -ns jabber:x:data -type cancel
            }]
    }

    tackymethod -async createInstant {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnOwnerResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j x -ns jabber:x:data -type submit
            }]
    }

    method createRoom {args} {
        array set opts {-jid "" -nick "" -hidden 0 -config {} -command "" -onerror ""}
        array set opts $args
        set room [jid norm $opts(-jid)]
        set done [list $opts(-command) $opts(-onerror)]
        $self join -jid $room -nick $opts(-nick) -hidden $opts(-hidden) \
            -history {maxstanzas 0} \
            -command [mymethod OnCreateJoined $room $opts(-config) $done]
    }

    method OnCreateJoined {room config done result} {
        if {[dict exists $result -error]} {
            $self CreateFailed $room $done "cannot enter: [dict get $result -error]" 0
            return
        }
        if {![dict get $Rooms($room) created]} {
            $self CreateFailed $room $done "room already exists" 1
            return
        }
        $self configGet -jid $room \
            -command [mymethod OnCreateForm $room $config $done] \
            -onerror [mymethod OnCreateNoForm $room $done]
    }

    method OnCreateNoForm {room done msg} {
        $self CreateFailed $room $done "no configuration form: $msg" 1
    }

    method OnCreateForm {room config done form} {
        if {$form eq ""} {
            $self CreateFailed $room $done "no configuration form" 1
            return
        }
        # Fields the service does not offer are skipped, not errors.
        $self configSet -jid $room -form [::tacky::forms::apply $form $config] \
            -command [mymethod OnCreateConfigured $room $done]
    }

    method OnCreateConfigured {room done stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $self CreateFailed $room $done \
                "configuration refused: [dict get [stanza_error $stanza] condition]" 1
            return
        }
        lassign $done command
        if {$command ne ""} { {*}$command $room }
    }

    # A room we could not set up is left, so it does not linger half made.
    method CreateFailed {room done reason inRoom} {
        jlog warn "muc: $room: $reason"
        if {$inRoom} { $self leave -jid $room }
        lassign $done command onerror
        if {$onerror ne ""} { {*}$onerror $reason }
    }

    # =====================================================================
    # Our server's MUC service
    # =====================================================================

    # The first of the server's disco items that is a text conference
    # service.
    method findService {args} {
        array set opts {-command ""}
        array set opts $args
        if {$ServiceFound} {
            {*}$opts(-command) $ServiceJid
            return
        }
        lappend ServiceWaiters $opts(-command)
        if {[llength $ServiceWaiters] > 1} return
        $client iq request -type get -to [jid domain [$client cget -jid]] \
            -payload [j query -ns http://jabber.org/protocol/disco#items] \
            -command [mymethod OnServiceItems]
    }

    method OnServiceItems {stanza} {
        set items {}
        if {[xsearch $stanza -get @type] eq "result"} {
            xsearch $stanza query item -script it {
                set ij [xsearch $it -get @jid]
                if {$ij ne ""} { lappend items $ij }
            }
        }
        $self ProbeService $items
    }

    method ProbeService {items} {
        if {![llength $items]} {
            $self ServiceResolved ""
            return
        }
        set items [lassign $items first]
        $client iq request -type get -to $first \
            -payload [j query -ns http://jabber.org/protocol/disco#info] \
            -command [mymethod OnServiceInfo $first $items]
    }

    method OnServiceInfo {probed rest stanza} {
        set isMuc 0
        xsearch $stanza query identity -script id {
            if {[xsearch $id -get @category] eq "conference"
                    && [xsearch $id -get @type] eq "text"} { set isMuc 1 }
        }
        if {$isMuc} {
            $self ServiceResolved $probed
        } else {
            $self ProbeService $rest
        }
    }

    method ServiceResolved {jid} {
        set ServiceJid $jid
        set ServiceFound 1
        set waiters $ServiceWaiters
        set ServiceWaiters {}
        foreach cmd $waiters { {*}$cmd $jid }
    }

    # =====================================================================
    # Room destruction (muc#owner)
    # =====================================================================

    tackymethod -async destroyRoom {args} {
        array set opts {-altRoom "" -reason "" -password "" -command "" -onerror ""}
        array set opts $args

        set destroyAttrs {}
        if {$opts(-altRoom) ne ""} {
            set destroyAttrs [list -jid $opts(-altRoom)]
        }

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnOwnerResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j destroy {*}$destroyAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason -body $opts(-reason)
                    }
                    if {$opts(-password) ne ""} {
                        j password -body $opts(-password)
                    }
                }
            }]
    }

    # =====================================================================
    # Registration (jabber:iq:register)
    # =====================================================================

    method registerGet {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnConfigGetResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns jabber:iq:register]
    }

    method registerSet {args} {
        array set opts {-form "" -command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns jabber:iq:register {
                j #as-is [::tacky::forms::serialize $opts(-form)]
            }]
    }

    # =====================================================================
    # Discovery helpers
    # =====================================================================

    tackymethod -async discoverRooms {args} {
        array set opts {-command "" -onerror ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnDiscoverRoomsResult $opts(-command) $opts(-onerror)] \
            -payload [j query -ns http://jabber.org/protocol/disco#items]
    }

    method reservedNick {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnReservedNickResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/disco#info \
                -node x-roomuser-item]
    }

    # =====================================================================
    # Local state queries
    # =====================================================================

    tackymethod getSubject {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return ""}
        return [dict get $Rooms($jid) subject]
    }

    tackymethod occupants {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return {}}
        set result {}
        dict for {nick occ} [dict get $Rooms($jid) occupants] {
            lappend result [$self WithCaps $jid $occ]
        }
        return $result
    }

    tackymethod occupant {args} {
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]
        if {![info exists Rooms($opts(-jid))]} {return ""}
        set occs [dict get $Rooms($opts(-jid)) occupants]
        if {[dict exists $occs $opts(-nick)]} {
            return [$self WithCaps $opts(-jid) [dict get $occs $opts(-nick)]]
        }
        return ""
    }

    tackymethod myNick {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return ""}
        return [dict get $Rooms($jid) nick]
    }

    # Our own XEP-0421 occupant-id in the room, captured from self-presence.
    # Non-empty iff the service stamps occupant-ids (i.e. the room supports
    # XEP-0421); "" otherwise.
    tackymethod myOccupantId {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return ""}
        return [dict get $Rooms($jid) myOccupantId]
    }

    tackymethod myRole {args} {
        $self MyOccupantField [jid norm [dict get $args -jid]] role
    }

    tackymethod myAffiliation {args} {
        $self MyOccupantField [jid norm [dict get $args -jid]] affiliation
    }

    tackymethod haveVoice {args} {
        set role [$self MyOccupantField [jid norm [dict get $args -jid]] role]
        expr {$role ne "" && $role ni {visitor none}}
    }

    tackymethod isJoined {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return 0}
        return [dict get $Rooms($jid) joined]
    }

    # Whether $room's MAM archive answered the last time it was asked,
    # remembered across sessions so the next join can skip join history.
    method HasArchive {room} {
        set v ""
        catch {set v [$client setting get -key muc.archive.$room]}
        expr {$v eq "1"}
    }

    # Record what the room's archive said (message's room catchup): 1 when
    # it answered, 0 when the room has none.
    method noteArchive {room has} {
        set room [jid norm $room]
        set has [expr {$has ? 1 : 0}]
        if {$has == [$self HasArchive $room]} return
        $client setting set -key muc.archive.$room -value $has
    }

    # Whether $jid is a room we know of: joined now, bookmarked, or with
    # room history stored. For telling a room's (or an occupant's) stanza
    # from a contact's when nothing in the stanza can be trusted to say so.
    tackymethod isKnownRoom {args} {
        set room [jid norm [jid bare [dict get $args -jid]]]
        if {[info exists Rooms($room)] && [dict get $Rooms($room) joined]} {
            return 1
        }
        set roomChat ${room}?join
        expr {[$client db exists {SELECT 1 FROM bookmark WHERE jid=$room}]
            || [$client db exists {
                SELECT 1 FROM chat_message WHERE chat_jid=$roomChat
            }]}
    }

    # Whether we are in $room or joining it (join sent, no answer yet).
    tackymethod isTracked {args} {
        info exists Rooms([jid norm [jid bare [dict get $args -jid]]])
    }

    # Whether $room was joined -hidden; remembered after leaving, until
    # rejoined, so the events reporting it gone can be told apart.
    tackymethod isHidden {args} {
        set room [jid norm [dict get $args -jid]]
        if {[info exists Rooms($room)]} { return [dict get $Rooms($room) hidden] }
        expr {[info exists WasHidden($room)] && $WasHidden($room)}
    }

    # Add $name to every occupant: {*}$cmd $stanza on each presence, ""
    # when absent. A module reads a presence extension off the occupants
    # this way and gets renames and leaves for free.
    method addOccupantField {name cmd} {
        dict set OccupantFields $name $cmd
    }

    # Add $name to every person `people` lists: {*}$cmd $room $realJid,
    # $realJid "" for an occupant whose real JID the room does not show.
    # A module that changes such a field says so with peopleChanged.
    method addPersonField {name cmd} {
        dict set PersonFields $name $cmd
    }

    tackymethod rooms {args} {
        set result {}
        foreach jid [array names Rooms] {
            if {[dict get $Rooms($jid) joined] && ![dict get $Rooms($jid) hidden]} {
                lappend result $jid
            }
        }
        return $result
    }

    # =====================================================================
    # Internal: Presence handling
    # =====================================================================

    method OnPresence {stanza} {
        set from [xsearch $stanza -get @from]
        if {$from eq ""} return

        # MUC presence comes from room@service/nick, but a service may reject
        # a join (no such room, service unavailable) from the bare room jid.
        # Fail the join now instead of at its timeout.
        if {![jid valid $from]} return
        if {[jid resource $from] eq ""} {
            set roomJid [jid norm $from]
            if {![info exists Rooms($roomJid)]} return
            set type_ [xsearch $stanza -get @type]
            if {$type_ eq "error"} {
                if {![dict get $Rooms($roomJid) joined]} {
                    $self OnPresenceError $roomJid "" $stanza
                }
                return
            }
            # The room's own presence carries its avatar hash (XEP-0153),
            # sent on join and when an owner changes it. Only the room's
            # bare jid reaches this branch; an occupant can only affect its
            # room/nick entry.
            if {$type_ eq "" && ![dict get $Rooms($roomJid) hidden]} {
                $client avatar OnVCardPresence $roomJid $stanza
            }
            return
        }

        set roomJid [jid norm [jid bare $from]]
        set nick [jid resource $from]

        # Only process if we're tracking this room
        if {![info exists Rooms($roomJid)]} return

        set type_ [xsearch $stanza -get @type]

        # Handle error presences early
        if {$type_ eq "error"} {
            $self OnPresenceError $roomJid $nick $stanza
            return
        }

        # Look for <x xmlns='muc#user'>
        set mucX [xsearch $stanza x -ns http://jabber.org/protocol/muc#user]
        if {[llength $mucX] == 0} return
        set mucX [lindex $mucX 0]

        if {$type_ eq "unavailable"} {
            $self OnUnavailable $roomJid $nick $stanza $mucX
            return
        }

        # Available presence
        set codes [$self ParseStatusCodes $mucX]
        set isSelf [expr {110 in $codes}]

        if {$isSelf} {
            $self OnSelfPresence $roomJid $nick $stanza $mucX $codes
        } else {
            $self OnOccupantPresence $roomJid $nick $stanza $mucX
        }
    }

    method OnPresenceError {roomJid nick stanza} {
        set errorType [xsearch $stanza error * -get tag]
        if {$errorType eq ""} {
            set errorType unknown
        }

        # Already joined: the error rejects a later request (a nick change, a
        # status update) and we are still in the room, so it isn't a join
        # failure.
        if {[dict get $Rooms($roomJid) joined]} {
            if {[info exists PendingNick($roomJid)]
                    && $nick eq $PendingNick($roomJid)} {
                unset PendingNick($roomJid)
                $self Emit $roomJid <NickError> -jid $roomJid -nick $nick \
                    -error $errorType
            } else {
                jlog warn "$roomJid: presence refused ($errorType)" \
                    -stanza $stanza
            }
            return
        }

        # Fire join callback if pending
        if {[info exists JoinTimers($roomJid)]} {
            after cancel $JoinTimers($roomJid)
            unset JoinTimers($roomJid)
        }
        if {[info exists JoinCallbacks($roomJid)]} {
            set cmd $JoinCallbacks($roomJid)
            unset JoinCallbacks($roomJid)
            {*}$cmd [list -jid $roomJid -error $errorType -stanza $stanza]
        }

        # Clean up room tracking if we never joined
        if {[info exists Rooms($roomJid)] && ![dict get $Rooms($roomJid) joined]} {
            $self ForgetRoom $roomJid
        }

        $self Emit $roomJid <Error> -jid $roomJid -error $errorType -stanza $stanza
    }

    method OnSelfPresence {roomJid nick stanza mucX codes} {
        set occupant [$self ParseItem $mucX $nick $stanza]

        # Nick may have been rewritten by service (status 210)
        dict set Rooms($roomJid) nick $nick
        dict set Rooms($roomJid) occupants $nick $occupant
        $self NoteOccupant $roomJid $occupant

        # Our own occupant-id is stable across nick changes, so capture it
        # once; a stray self-presence without one must not clobber it.
        set occId [xsearch $stanza occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        if {$occId ne ""} {
            dict set Rooms($roomJid) myOccupantId $occId
        }

        if {![dict get $Rooms($roomJid) joined]} {
            # First self-presence = join complete
            dict set Rooms($roomJid) joined 1
            if {[info exists JoinTimers($roomJid)]} {
                after cancel $JoinTimers($roomJid)
                unset JoinTimers($roomJid)
            }
            # Status 201: a new room, locked until configured. Set before
            # the join callback, which reads it.
            dict set Rooms($roomJid) created [expr {201 in $codes}]

            if {[info exists JoinCallbacks($roomJid)]} {
                set cmd $JoinCallbacks($roomJid)
                unset JoinCallbacks($roomJid)
                {*}$cmd [list -jid $roomJid -nick $nick \
                    -created [dict get $Rooms($roomJid) created]]
            }

            # What the room is (its features, for OMEMO) and its avatar,
            # asked before <Joined> so the answer comes ahead of the
            # archive page that <Joined> starts.
            if {![dict get $Rooms($roomJid) hidden]} {
                $self RoomInfo $roomJid
            }

            $self Emit $roomJid <Joined> -jid $roomJid -nick $nick

            # Status 201 = room was just created, needs configuration
            if {201 in $codes} {
                $self Emit $roomJid <RoomCreated> -jid $roomJid
            }
        }

        if {![dict get $Rooms($roomJid) hidden]} {
            $client avatar OnVCardPresence [xsearch $stanza -get @from] $stanza
        }
        $self Emit $roomJid <Presence> -jid $roomJid -nick $nick \
            -occupant [$self WithCaps $roomJid $occupant]

        # Every occupant's caps are relative to my role/affiliation, which may
        # have just changed; refresh them all (-replay 1).
        dict for {onick occ} [dict get $Rooms($roomJid) occupants] {
            if {$onick eq $nick} continue
            $self Emit $roomJid <Presence> -jid $roomJid -nick $onick \
                -occupant [$self WithCaps $roomJid $occ] -replay 1
        }
    }

    method OnOccupantPresence {roomJid nick stanza mucX} {
        set occs [dict get $Rooms($roomJid) occupants]
        if {![dict exists $occs $nick]
            && [dict size $occs] >= $MaxOccupants} {
            jlog debug "muc: $roomJid at occupant cap\
                ($MaxOccupants); dropping $nick"
            return
        }
        set occupant [$self ParseItem $mucX $nick $stanza]
        dict set Rooms($roomJid) occupants $nick $occupant
        $self NoteOccupant $roomJid $occupant
        if {![dict get $Rooms($roomJid) hidden]} {
            $client avatar OnVCardPresence [xsearch $stanza -get @from] $stanza
        }
        $self Emit $roomJid <Presence> -jid $roomJid -nick $nick \
            -occupant [$self WithCaps $roomJid $occupant]
    }

    method OnUnavailable {roomJid nick stanza mucX} {
        set codes [$self ParseStatusCodes $mucX]
        # 110 marks presence about us. Some servers leave it off a removal
        # (MongooseIM's kick has only 307), but a room's nick is held by one
        # occupant, so presence from our own nick is about us anyway.
        set isSelf [expr {110 in $codes
            || $nick eq [dict get $Rooms($roomJid) nick]}]
        set occupant [$self ParseItem $mucX $nick $stanza]

        set actor [xsearch $mucX item actor -get @nick]
        set reason [xsearch $mucX item reason -get body]

        # Room destroyed
        set destroyNode [xsearch $mucX destroy]
        if {[llength $destroyNode] > 0} {
            set destroyNode [lindex $destroyNode 0]
            set altRoom [xsearch $destroyNode -get @jid]
            set destroyReason [xsearch $destroyNode reason -get body]

            # We are out of the room: emit <Left>, flagged -destroyed so
            # bookmarks doesn't rejoin (and recreate) it.
            $self SelfLeft $roomJid 1 $codes -destroyed 1
            $self Emit $roomJid <Destroyed> -jid $roomJid -altRoom $altRoom -reason $destroyReason
            return
        }

        # Nick change (status 303)
        if {303 in $codes} {
            set newNick [xsearch $mucX item -get @nick]
            # Move the occupant to the new nick now; the next presence updates it.
            set occs [dict get $Rooms($roomJid) occupants]
            set moved [expr {[dict exists $occs $nick] ? [dict get $occs $nick] : $occupant}]
            dict set moved nick $newNick
            dict unset occs $nick
            dict set occs $newNick $moved
            dict set Rooms($roomJid) occupants $occs

            if {$isSelf} {
                dict set Rooms($roomJid) nick $newNick
                unset -nocomplain PendingNick($roomJid)
            }

            $self Emit $roomJid <NickChanged> -jid $roomJid -oldNick $nick -newNick $newNick \
                -self $isSelf -occupant [$self WithCaps $roomJid $moved]
            return
        }

        # Remove from occupants
        set occs [dict get $Rooms($roomJid) occupants]
        dict unset occs $nick
        dict set Rooms($roomJid) occupants $occs

        # Kicked (307)
        if {307 in $codes && !(333 in $codes)} {
            $self Emit $roomJid <Kicked> -jid $roomJid -nick $nick -actor $actor -reason $reason
        }

        # Banned (301)
        if {301 in $codes} {
            $self Emit $roomJid <Banned> -jid $roomJid -nick $nick -actor $actor -reason $reason
        }

        if {$isSelf} {
            $self SelfLeft $roomJid \
                [expr {![dict get $Rooms($roomJid) leaving]}] $codes
            return
        }

        # Gone is not removed: a member out of the room still reads it. Only
        # an affiliation taken away (321, a ban) makes them no member.
        $self NoteOccupant $roomJid $occupant

        $self Emit $roomJid <Unavailable> \
            -jid $roomJid -nick $nick -reason $reason -codes $codes -occupant $occupant
    }

    # =====================================================================
    # Internal: Message handling
    # =====================================================================

    # Returns 1 if the stanza was claimed (MUC message), 0 otherwise.
    method OnMessage {stanza} {
        set from [xsearch $stanza -get @from]
        if {$from eq ""} { return 0 }

        set type_ [xsearch $stanza -get @type]

        # An error from a room we are in reports a failed delivery, not a
        # message. Claim it: falling through reaches message.tcl, which files
        # anything from a bare jid into a 1:1 chat - a phantom conversation
        # with the room, holding whatever body the error echoed back.
        if {$type_ eq "error" && [jid valid $from]} {
            set errRoom [jid norm [jid bare $from]]
            if {[info exists Rooms($errRoom)]} {
                $self OnRoomError $errRoom $stanza [jid resource $from]
                return 1
            }
        }

        # Check for mediated invitation or decline (can arrive even when not in room)
        set mucX [xsearch $stanza x -ns http://jabber.org/protocol/muc#user]
        if {[llength $mucX] > 0} {
            set mucX [lindex $mucX 0]

            set inviteNodes [xsearch $mucX invite]
            if {[llength $inviteNodes] > 0} {
                $self OnInvite $stanza $mucX
                return 1
            }

            set declineNodes [xsearch $mucX decline]
            if {[llength $declineNodes] > 0} {
                $self OnDecline $stanza $mucX
                return 1
            }
        }

        # Voice request form (message with x:data, FORM_TYPE=muc#request)
        set xdataNodes [xsearch $stanza x -ns jabber:x:data]
        if {[llength $xdataNodes] > 0} {
            set xdata [lindex $xdataNodes 0]
            set formType [xsearch $xdata field @var FORM_TYPE value -get body]
            if {$formType eq "http://jabber.org/protocol/muc#request"} {
                $self OnVoiceRequest $stanza $xdata
                return 1
            }
        }

        # Groupchat messages
        if {$type_ eq "groupchat"} {
            if {![jid valid $from]} { return 1 }
        set roomJid [jid norm [jid bare $from]]
            set nick [jid resource $from]

            # Drop groupchat from rooms we never requested to join
            if {![info exists Rooms($roomJid)]} { return 1 }

            # Subject change: has <subject>, no <body>
            set subjectText [xsearch $stanza subject -get body]
            set subjectNodes [xsearch $stanza subject]
            set bodyText [xsearch $stanza body -get body]

            if {[llength $subjectNodes] > 0 && $bodyText eq ""} {
                $self OnSubjectMessage $roomJid $nick $subjectText
                return 1
            }

            # A bodyless groupchat message carrying an XEP-0444 <reactions>,
            # an XEP-0424/0425 <retract> (moderation broadcast, v1 or v0) or an
            # XEP-0482 call invite or answer is forwarded too;
            # ingestLive/Classify handle it. Other bodyless groupchat
            # stanzas fall through to the status-code handling below.
            set hasReactions [expr {[llength \
                [xsearch $stanza reactions -ns urn:xmpp:reactions:0]] > 0}]
            set hasRetract [expr {[RetractTargetId $stanza] ne ""}]
            set hasCall [expr {[llength \
                [xsearch $stanza * -ns urn:xmpp:call-invites:0]] > 0}]
            if {$bodyText ne "" || $hasReactions || $hasRetract || $hasCall} {
                $self OnGroupchatMessage $roomJid $nick $stanza
                return 1
            }

            # Config change notifications come as groupchat with muc#user status codes
            if {$mucX ne ""} {
                # The room's own notice of an affiliation change (XEP-0045
                # 9.3-9.8), for someone in the room or not.
                if {$nick eq ""} {
                    $self OnAffiliationNotice $roomJid $mucX
                }
                set codes [$self ParseStatusCodes $mucX]
                if {[llength $codes] > 0} {
                    $self Emit $roomJid <ConfigChanged> -jid $roomJid -codes $codes
                    # 104: the room configuration changed, possibly its
                    # avatar too; 170-174: logging, anonymity. Re-read
                    # disco#info, which says whether OMEMO can be used.
                    set reread 0
                    foreach code {104 170 171 172 173 174} {
                        if {$code in $codes} { set reread 1 }
                    }
                    if {$reread && [info exists Rooms($roomJid)]
                            && ![dict get $Rooms($roomJid) hidden]} {
                        $self RoomInfo $roomJid
                    }
                }
            }
            return 1
        }

        # Private message (type=chat from occupant JID in a room we're in)
        if {$type_ eq "chat" && [jid valid $from] && [jid resource $from] ne ""} {
        set roomJid [jid norm [jid bare $from]]
            if {[info exists Rooms($roomJid)] && [dict get $Rooms($roomJid) joined]} {
                set nick [jid resource $from]
                set bodyText [xsearch $stanza body -get body]
                if {$bodyText ne ""} {
                    $self OnPrivateMessage $roomJid $nick $stanza
                    return 1
                }
            }
        }

        # Status code 101: affiliation changed while not in room
        if {$mucX ne ""} {
            set codes [$self ParseStatusCodes $mucX]
            if {101 in $codes} {
                # From the room itself, never one of its occupants.
                if {![jid valid $from] || [jid resource $from] ne ""} { return 1 }
                set roomJid [jid norm $from]
                $self OnAffiliationNotice $roomJid $mucX
                return 1
            }
            # The same notice without 101, from a room we are in.
            if {[jid valid $from] && [jid resource $from] eq ""
                    && [info exists Rooms([jid norm $from])]
                    && [xsearch $mucX item -get @jid] ne ""
                    && [xsearch $mucX item -get @affiliation] ne ""} {
                $self OnAffiliationNotice [jid norm $from] $mucX
                return 1
            }
        }

        return 0
    }

    method OnSubjectMessage {roomJid nick subjectText} {
        if {[info exists Rooms($roomJid)]} {
            dict set Rooms($roomJid) subject $subjectText
        }
        $self Emit $roomJid <Subject> -jid $roomJid -nick $nick -subject $subjectText
    }

    method OnGroupchatMessage {roomJid nick stanza} {
        if {![info exists Rooms($roomJid)]} { return }
        if {[dict get $Rooms($roomJid) hidden]} return
        set myOcc [dict get $Rooms($roomJid) myOccupantId]
        set occ [xsearch $stanza occupant-id -ns urn:xmpp:occupant-id:0 -get @id]
        # Fail closed: with an occupant-id on the stanza but none captured for
        # ourselves, nick equality would let another occupant take our nick and
        # forge a first-person message.
        # Without one, by our nick, though history replayed on join may be
        # whoever held it before us (message NickIsOurs).
        if {$occ ne ""} {
            set isOwn [expr {$myOcc ne "" && $occ eq $myOcc}]
        } else {
            set isOwn [expr {$nick eq [dict get $Rooms($roomJid) nick]
                && [$client message NickIsOurs ${roomJid}?join $stanza]}]
        }
        # OMEMO (XEP-0384 §5.7): read as its sender's, whom the room names.
        # The plaintext stanza keeps every other child, so the echo of our
        # own send still reconciles by its origin-id.
        if {[llength [xsearch $stanza encrypted \
                -ns eu.siacs.conversations.axolotl]]} {
            if {[catch {$client omemo decryptRoomMessage $roomJid $stanza} plain]} {
                jlog warn "$roomJid: OMEMO message not read: $plain"
                return
            }
            if {$plain eq ""} return
            set stanza $plain
        }
        $client message ingestLive ${roomJid}?join $stanza $isOwn
    }

    method OnPrivateMessage {roomJid nick stanza} {
        if {[$self isHidden -jid $roomJid]} return
        $client message ingestLive ${roomJid}/${nick} $stanza
    }

    # Kept as a message, not an event, since it waits on the user.
    method OnInvite {stanza mucX} {
        set chatJid [$client message inviteChat $stanza]
        if {$chatJid eq ""} return
        $client message ingestLive $chatJid $stanza
    }

    # Relayed by the room, so from its bare JID, about a room of ours: anyone
    # else could otherwise announce declines for any room.
    method FromKnownRoom {stanza} {
        set from [xsearch $stanza -get @from]
        if {![jid valid $from] || [jid resource $from] ne ""} { return "" }
        set roomJid [jid norm $from]
        if {![info exists Rooms($roomJid)]} { return "" }
        return $roomJid
    }

    method OnDecline {stanza mucX} {
        set roomJid [$self FromKnownRoom $stanza]
        if {$roomJid eq ""} return
        set declineNode [lindex [xsearch $mucX decline] 0]
        set declinerJid [xsearch $declineNode -get @from]
        set reason [xsearch $declineNode reason -get body]

        $self Emit $roomJid <Decline> \
            -jid $roomJid -from $declinerJid -reason $reason
    }

    method OnVoiceRequest {stanza xdataNode} {
        set roomJid [$self FromKnownRoom $stanza]
        if {$roomJid eq ""} return
        set reqJid [xsearch $xdataNode field @var muc#jid value -get body]
        set reqNick [xsearch $xdataNode field @var muc#roomnick value -get body]

        $self Emit $roomJid <VoiceRequest> \
            -jid $roomJid -from $reqJid -nick $reqNick \
            -form [::tacky::forms::parse $xdataNode]
    }

    # =====================================================================
    # Internal: IQ result handlers
    # =====================================================================

    method OnIqResult {command stanza} {
        if {$command ne ""} {
            {*}$command $stanza
        }
    }

    # The room took an affiliation change of ours: the member list follows
    # now, without waiting for the room's notice, which not every service
    # sends for someone not in the room (MongooseIM does not).
    method OnAffiliationResult {roomJid target affil command onerror stanza} {
        if {[xsearch $stanza -get @type] ne "error"
                && [info exists Rooms($roomJid)]
                && ![dict get $Rooms($roomJid) hidden]
                && [jid valid $target]
                && [$self SetMember $roomJid [jid norm [jid bare $target]] $affil]} {
            $self EmitMembers $roomJid
        }
        $self OnActionResult $command $onerror $stanza
    }

    # Result handler for moderation actions (kick/ban/role/affiliation). On an
    # error stanza it hands -onerror a ready message; success answers "".
    method OnActionResult {command onerror stanza} {
        if {[$self ReportActionError $onerror $stanza]} return
        if {$command ne ""} {
            {*}$command ""
        }
    }

    # createInstant/destroyRoom: "" on success, error text on failure.
    method OnOwnerResult {command onerror stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            if {$onerror ne ""} { {*}$onerror [stanza_error_text $stanza] }
            return
        }
        if {$command ne ""} { {*}$command "" }
    }

    # 1 if $stanza is an error (and $onerror, when set, has been told).
    method ReportActionError {onerror stanza} {
        if {[xsearch $stanza -get @type] ne "error"} { return 0 }
        if {$onerror ne ""} {
            {*}$onerror [$self ActionErrorText \
                [dict get [stanza_error $stanza] condition]]
        }
        return 1
    }

    method ActionErrorText {condition} {
        switch -- $condition {
            forbidden      { return "You do not have permission to do that" }
            not-allowed    { return "The server does not allow that action" }
            not-acceptable { return "The server rejected that action" }
            conflict       { return "That conflicts with the room's current state" }
            item-not-found { return "That participant is no longer in the room" }
            default        { return "The action could not be completed" }
        }
    }

    method OnListResult {command onerror stanza} {
        if {[$self ReportActionError $onerror $stanza]} return
        if {$command eq ""} return

        set items {}
        xsearch $stanza query item -script itemNode {
            set d {}
            foreach attr {jid nick role affiliation} {
                dict set d $attr [xsearch $itemNode -get @$attr]
            }
            set reason [xsearch $itemNode reason -get body]
            if {$reason ne ""} {
                dict set d reason $reason
            }
            lappend items $d
        }
        {*}$command $items
    }

    method OnConfigGetResult {command onerror stanza} {
        if {[$self ReportActionError $onerror $stanza]} return
        if {$command eq ""} return

        set formNode [xsearch $stanza query x -ns jabber:x:data]
        if {[llength $formNode] > 0} {
            {*}$command [::tacky::forms::parse [lindex $formNode 0]]
        } else {
            {*}$command {}
        }
    }

    # Ask the room's disco#info for its avatar hash (XEP-0486,
    # muc#roominfo_avatarhash). Unlike the room's presence on join, which is
    # only sent when there is an avatar, it also reports when there is none.
    # A room whose disco#info has no such field gets the one-time vCard
    # fetch instead.
    method RoomInfo {roomJid} {
        $client iq request -type get -to $roomJid \
            -command [mymethod OnRoomInfo $roomJid] \
            -payload [j query -ns http://jabber.org/protocol/disco#info]
    }

    method OnRoomInfo {roomJid stanza} {
        if {[xsearch $stanza -get @type] eq "error"} {
            $client avatar ensureVCard $roomJid
            return
        }
        set features {}
        xsearch $stanza query feature -script fn {
            lappend features [xsearch $fn -get @var]
        }
        $self NoteRoomFeatures $roomJid $features
        foreach formNode [xsearch $stanza query x -ns jabber:x:data] {
            set form [::tacky::forms::parse $formNode]
            foreach field [dict get $form fields] {
                if {[dict get $field var] ne "muc#roominfo_avatarhash"} continue
                $client avatar announce $roomJid \
                    [string tolower [lindex [dict get $field value] 0]]
                return
            }
        }
        $client avatar ensureVCard $roomJid
    }

    method OnDiscoverRoomsResult {command onerror stanza} {
        if {[$self ReportActionError $onerror $stanza]} return
        if {$command eq ""} return

        set rooms {}
        xsearch $stanza query item -script itemNode {
            set jid [xsearch $itemNode -get @jid]
            set name [xsearch $itemNode -get @name]
            if {$jid ne ""} {
                set occupants ""
                set formNodes [xsearch $itemNode x -ns jabber:x:data]
                if {[llength $formNodes] > 0} {
                    set form [::tacky::forms::parse [lindex $formNodes 0]]
                    foreach field [dict get $form fields] {
                        if {[dict get $field var] eq "muc#roominfo_occupants"} {
                            set occupants [lindex [dict get $field value] 0]
                            break
                        }
                    }
                }
                if {$occupants eq "" && [regexp {^(.*)\s+\((\d+)\)\s*$} $name -> stripped count]} {
                    set name $stripped
                    set occupants $count
                }
                lappend rooms [dict create jid $jid name $name occupants $occupants]
            }
        }
        {*}$command $rooms
    }

    method OnReservedNickResult {command stanza} {
        if {$command eq ""} return

        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            {*}$command ""
            return
        }

        set nick [xsearch $stanza query identity -get @name]
        {*}$command $nick
    }

    # =====================================================================
    # Internal: helpers
    # =====================================================================

    method ParseItem {mucX nick stanza} {
        set role [xsearch $mucX item -get @role]
        set affiliation [xsearch $mucX item -get @affiliation]
        set jid_ [xsearch $mucX item -get @jid]
        set show [xsearch $stanza show -get body]
        set statusText [xsearch $stanza status -get body]
        # One <item> per session sharing the nick.
        set jids {}
        xsearch $mucX item -script it {
            set ij [xsearch $it -get @jid]
            if {$ij ne ""} { lappend jids $ij }
        }

        set occ [dict create \
            nick $nick \
            jid $jid_ \
            jids $jids \
            role $role \
            affiliation $affiliation \
            show $show \
            status $statusText \
            occupant_id [xsearch $stanza occupant-id -ns urn:xmpp:occupant-id:0 -get @id]]
        dict for {name cmd} $OccupantFields {
            dict set occ $name [{*}$cmd $stanza]
        }
        return $occ
    }

    method ParseStatusCodes {mucX} {
        set codes {}
        xsearch $mucX status -script snode {
            set code [xsearch $snode -get @code]
            if {$code ne ""} {
                lappend codes [scan $code %d]
            }
        }
        return $codes
    }

    method ListQuerySpec {what} {
        switch -- $what {
            members    {return {affiliation member}}
            outcasts   {return {affiliation outcast}}
            admins     {return {affiliation admin}}
            owners     {return {affiliation owner}}
            moderators {return {role moderator}}
            participants {return {role participant}}
            visitors   {return {role visitor}}
            default    {error "Unknown list type: $what"}
        }
    }

    method MyOccupantField {jid field} {
        if {![info exists Rooms($jid)]} {return ""}
        set nick [dict get $Rooms($jid) nick]
        set occs [dict get $Rooms($jid) occupants]
        if {[dict exists $occs $nick]} {
            return [dict get [dict get $occs $nick] $field]
        }
        return ""
    }

    method AffilLevel {affiliation} {
        switch -- $affiliation {
            owner   { return 4 }
            admin   { return 3 }
            member  { return 2 }
            none    { return 1 }
            outcast { return 0 }
            default { return 1 }
        }
    }

    method EmptyCaps {} {
        return {kick 0 ban 0 make_moderator 0 grant_voice 0 \
            revoke_voice 0 grant_membership 0 revoke_membership 0}
    }

    # Moderation actions the current user (myRole/myAffil) may take against one
    # occupant, per XEP-0045 role/affiliation rules. Computed here so the GUI
    # reads flags rather than re-deriving the authorization policy.
    method OccupantCaps {myRole myAffil target} {
        set caps [$self EmptyCaps]
        set targetRole [dict get $target role]
        set targetAffil [dict get $target affiliation]
        set targetJid [dict get $target jid]
        set iModerate [expr {$myRole eq "moderator"}]
        set iAdmin [expr {[$self AffilLevel $myAffil] >= [$self AffilLevel admin]}]

        if {$iModerate && $targetAffil ni {admin owner}} {
            dict set caps kick 1
        }
        if {$iAdmin && [$self AffilLevel $targetAffil] < [$self AffilLevel $myAffil] \
            && $targetJid ne ""} {
            dict set caps ban 1
        }
        if {$iAdmin && $targetRole ne "moderator"} {
            dict set caps make_moderator 1
        }
        if {$iModerate && $targetRole eq "visitor"} {
            dict set caps grant_voice 1
        }
        if {$iModerate && $targetRole eq "participant"} {
            dict set caps revoke_voice 1
        }
        if {$iAdmin && $targetAffil eq "none" && $targetJid ne ""} {
            dict set caps grant_membership 1
        }
        if {$iAdmin && $targetAffil eq "member" && $targetJid ne ""} {
            dict set caps revoke_membership 1
        }
        return $caps
    }

    # Stamp an occupant dict with the current user's caps against it. Self gets
    # no caps (you don't moderate yourself).
    method WithCaps {roomJid occupant} {
        if {![info exists Rooms($roomJid)]} {
            dict set occupant caps [$self EmptyCaps]
            return $occupant
        }
        set myNick [dict get $Rooms($roomJid) nick]
        if {$myNick eq "" || [dict get $occupant nick] eq $myNick} {
            dict set occupant caps [$self EmptyCaps]
            return $occupant
        }
        set myRole [$self MyOccupantField $roomJid role]
        set myAffil [$self MyOccupantField $roomJid affiliation]
        dict set occupant caps [$self OccupantCaps $myRole $myAffil $occupant]
        return $occupant
    }

    # The only part of a room's error worth acting on is a self-removal
    # notice (110 with role none): some servers report putting us out this
    # way instead of with the <presence type='unavailable'> XEP-0045 7.14
    # asks for. Unhandled, the room stays marked joined for the session, so
    # isJoined holds every rejoin path off it and its messages are lost.
    # Only the room's word counts: the notice from its bare JID or our own
    # nick. From another occupant's nick it may be that occupant's own
    # error, relayed by the service, so it leaves a joined room alone.
    method OnRoomError {roomJid stanza fromNick} {
        set mucX [lindex [xsearch $stanza x \
            -ns http://jabber.org/protocol/muc#user] 0]
        if {$mucX eq ""} return
        set codes [$self ParseStatusCodes $mucX]
        if {110 ni $codes} return
        if {[xsearch $mucX item -get @role] ne "none"} return
        if {$fromNick ne "" && $fromNick ne [dict get $Rooms($roomJid) nick]
                && [dict get $Rooms($roomJid) joined]} {
            jlog inform "$roomJid: ignoring a removal notice from $fromNick"
            return
        }
        jlog inform "$roomJid: removed by an error stanza\
            ([dict get [stanza_error $stanza] condition])"
        # A room may answer a leave we asked for this way; re-entering
        # would undo the request.
        $self SelfLeft $roomJid \
            [expr {![dict get $Rooms($roomJid) leaving]}] $codes
    }

    # We are out of this room: drop its state and say so. `involuntary` is 1
    # when the server put us out rather than us asking, and `codes` carries
    # the status codes behind it; bookmarks decides on re-entry from both.
    method SelfLeft {roomJid involuntary codes args} {
        set myNick ""
        if {[info exists Rooms($roomJid)]} {
            set myNick [dict get $Rooms($roomJid) nick]
        }
        $self CleanupRoom $roomJid
        $self Emit $roomJid <Left> -jid $roomJid -nick $myNick \
            -involuntary $involuntary -codes $codes {*}$args
    }

    # Same events for every room. Modules that file rooms (bookmarks,
    # message, author) skip hidden ones via isHidden.
    method Emit {roomJid event args} {
        $client emit muc $event {*}$args
        if {$event in {<Presence> <Unavailable> <NickChanged> <Joined> <Left>
                <MembersChanged> <AffiliationChanged>}} {
            $self peopleChanged $roomJid
        }
    }

    # Stop tracking a room; keep its hidden flag for isHidden.
    method ForgetRoom {roomJid} {
        if {![info exists Rooms($roomJid)]} return
        set WasHidden($roomJid) [dict get $Rooms($roomJid) hidden]
        unset Rooms($roomJid)
        unset -nocomplain PendingNick($roomJid)
    }

    method CleanupRoom {roomJid} {
        $self ForgetRoom $roomJid
        # A join still waiting is over: say so rather than drop it.
        $self FailJoin $roomJid item-not-found
    }
}
