# tacky muc join -acc $jid -jid $room -nick $nick ?-password $pw? ?-history {...}?
# tacky muc leave -acc $jid -jid $room ?-status $text?
# tacky muc nick -acc $jid -jid $room -nick $newNick
# tacky muc status -acc $jid -jid $room ?-show $val? ?-status $text?
# tacky muc say -acc $jid -jid $room -body $text
# tacky muc pm -acc $jid -jid $occupantJid -body $text
# tacky muc subject -acc $jid -jid $room -body $text
# tacky muc invite -acc $jid -jid $room -to $jid ?-reason $text?
# tacky muc decline -acc $jid -jid $room -to $inviterJid ?-reason $text?
# tacky muc requestVoice -acc $jid -jid $room
# tacky muc kick -acc $jid -jid $room -nick $nick ?-reason $text? ?-command $cb?
# tacky muc role -acc $jid -jid $room -nick $nick -role $role ?-reason $text? ?-command $cb?
# tacky muc affiliation -acc $jid -jid $room -target $bareJid -affiliation $a ?-reason $t? ?-nick $n? ?-command $cb?
# tacky muc getList -acc $jid -jid $room -what $what ?-command $cb?
# tacky muc configGet -acc $jid -jid $room ?-command $cb?
# tacky muc configSet -acc $jid -jid $room -fields $formFields ?-command $cb?
# tacky muc configCancel -acc $jid -jid $room ?-command $cb?
# tacky muc createInstant -acc $jid -jid $room ?-command $cb?
# tacky muc destroyRoom -acc $jid -jid $room ?-altRoom $jid? ?-reason $t? ?-password $pw? ?-command $cb?
# tacky muc registerGet -acc $jid -jid $room ?-command $cb?
# tacky muc registerSet -acc $jid -jid $room -fields $formFields ?-command $cb?
# tacky muc discoverRooms -acc $jid -jid $serviceJid ?-command $cb?
# tacky muc reservedNick -acc $jid -jid $room ?-command $cb?
#
# tacky muc getSubject -acc $jid -jid $room
# tacky muc occupants -acc $jid -jid $room
# tacky muc occupant -acc $jid -jid $room -nick $nick
# tacky muc myNick -acc $jid -jid $room
# tacky muc myRole -acc $jid -jid $room
# tacky muc myAffiliation -acc $jid -jid $room
# tacky muc haveVoice -acc $jid -jid $room
# tacky muc isJoined -acc $jid -jid $room
# tacky muc rooms -acc $jid
#
# tacky listen muc <Joined> $cmd             ;# -jid $room -nick $myNick
# tacky listen muc <Left> $cmd               ;# -jid $room -nick $myNick
# tacky listen muc <Error> $cmd              ;# -jid $room -error $errorType -stanza $stanza
# tacky listen muc <Presence> $cmd           ;# -jid $room -nick $nick -occupant $dict
# tacky listen muc <Unavailable> $cmd        ;# -jid $room -nick $nick -reason $r -codes $codes -occupant $dict
# tacky listen muc <Subject> $cmd            ;# -jid $room -nick $nick -subject $text
# NOTE: MUC messages are delivered via message <Received>, not muc events.
# tacky listen muc <Invite> $cmd             ;# -jid $room -from $inviterJid -reason $t -password $pw -continue $thread
# tacky listen muc <Decline> $cmd            ;# -jid $room -from $declinerJid -reason $text
# tacky listen muc <NickChanged> $cmd        ;# -jid $room -oldNick $old -newNick $new -self $bool
# tacky listen muc <Kicked> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <Banned> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <ConfigChanged> $cmd      ;# -jid $room -codes $statusCodes
# tacky listen muc <RoomCreated> $cmd        ;# -jid $room
# tacky listen muc <Destroyed> $cmd          ;# -jid $room -altRoom $jidOrEmpty -reason $text
# tacky listen muc <VoiceRequest> $cmd       ;# -jid $room -from $jid -nick $nick -form $formStanza
# tacky listen muc <AffiliationChanged> $cmd ;# -jid $room -target $bareJid -affiliation $new

snit::type taco_muc {
    variable client

    # roomJid -> dict: nick, subject, joined, occupants (dict nick->occupantDict)
    # Each occupantDict: {nick $n jid $fullJid role $r affiliation $a show $s status $st}
    variable Rooms -array {}

    # roomJid -> join -command callback (pending joins)
    variable JoinCallbacks -array {}

    option -client -readonly yes

    constructor args {
        $self configurelist $args
        set client $options(-client)
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    method OnDisconnect {args} {
        array unset Rooms *
        array unset JoinCallbacks *
    }

    # =====================================================================
    # Joining / Leaving
    # =====================================================================

    method join {args} {
        array set opts {-password "" -history {} -command ""}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]

        # Initialize room tracking state
        set Rooms($opts(-jid)) [dict create \
            nick $opts(-nick) subject "" joined 0 occupants [dict create]]

        if {$opts(-command) ne ""} {
            set JoinCallbacks($opts(-jid)) $opts(-command)
        }

        # Build <x xmlns='muc'> with optional children
        set mucChildren {}
        if {$opts(-password) ne ""} {
            lappend mucChildren password $opts(-password)
        }

        set historyAttrs {}
        dict for {k v} $opts(-history) {
            lappend historyAttrs -$k $v
        }

        $client write [j presence -to $opts(-jid)/$opts(-nick) {
            j x -ns http://jabber.org/protocol/muc {
                if {$mucChildren ne ""} {
                    foreach {ctag cval} $mucChildren {
                        j $ctag #body $cval
                    }
                }
                if {$historyAttrs ne ""} {
                    j history {*}$historyAttrs
                }
            }
        }]
    }

    method leave {args} {
        array set opts {-status ""}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]

        if {![info exists Rooms($opts(-jid))]} return
        set nick [dict get $Rooms($opts(-jid)) nick]

        if {$opts(-status) ne ""} {
            $client write [j presence -to $opts(-jid)/$nick -type unavailable {
                j status #body $opts(-status)
            }]
        } else {
            $client write [j presence -to $opts(-jid)/$nick -type unavailable]
        }
    }

    method nick {args} {
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]
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
                j show #body $opts(-show)
            }
            if {$opts(-status) ne ""} {
                j status #body $opts(-status)
            }
        }]
    }

    # =====================================================================
    # Messaging
    # =====================================================================

    method say {args} {
        array set opts $args
        $client message send -chat_jid $opts(-jid)?join -body $opts(-body)
    }

    method pm {args} {
        array set opts $args
        $client write [j message -to $opts(-jid) -type chat {
            j body #body $opts(-body)
            j x -ns http://jabber.org/protocol/muc#user
        }]
    }

    method subject {args} {
        array set opts $args
        $client write [j message -to $opts(-jid) -type groupchat {
            j subject #body $opts(-body)
        }]
    }

    # =====================================================================
    # Invitations
    # =====================================================================

    method invite {args} {
        array set opts {-reason ""}
        array set opts $args

        $client write [j message -to $opts(-jid) {
            j x -ns http://jabber.org/protocol/muc#user {
                j invite -to $opts(-to) {
                    if {$opts(-reason) ne ""} {
                        j reason #body $opts(-reason)
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
                        j reason #body $opts(-reason)
                    }
                }
            }
        }]
    }

    # =====================================================================
    # Voice
    # =====================================================================

    method requestVoice {args} {
        set jid [dict get $args -jid]
        $client write [j message -to $jid {
            j x -ns jabber:x:data -type submit {
                j field -var FORM_TYPE {
                    j value #body http://jabber.org/protocol/muc#request
                }
                j field -var muc#role -type list-single -label {Requested role} {
                    j value #body participant
                }
            }
        }]
    }

    # =====================================================================
    # Role management (by nick, muc#admin)
    # =====================================================================

    method kick {args} {
        $self role {*}[dict set args -role none]
    }

    method role {args} {
        array set opts {-reason "" -command ""}
        array set opts $args

        set itemAttrs [list -nick $opts(-nick) -role $opts(-role)]

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item {*}$itemAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason #body $opts(-reason)
                    }
                }
            }]
    }

    # =====================================================================
    # Affiliation management (by bare JID, muc#admin)
    # =====================================================================

    method affiliation {args} {
        array set opts {-reason "" -nick "" -command ""}
        array set opts $args

        set itemAttrs [list -jid $opts(-target) -affiliation $opts(-affiliation)]
        if {$opts(-nick) ne ""} {
            lappend itemAttrs -nick $opts(-nick)
        }

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item {*}$itemAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason #body $opts(-reason)
                    }
                }
            }]
    }

    # =====================================================================
    # List queries
    # =====================================================================

    method getList {args} {
        array set opts {-command ""}
        array set opts $args

        lassign [$self ListQuerySpec $opts(-what)] attr val

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnListResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#admin {
                j item -$attr $val
            }]
    }

    # =====================================================================
    # Room configuration (muc#owner)
    # =====================================================================

    method configGet {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnConfigGetResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner]
    }

    method configSet {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [$self FormSubmitPayload \
                http://jabber.org/protocol/muc#owner \
                http://jabber.org/protocol/muc#roomconfig \
                $opts(-fields)]
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

    method createInstant {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j x -ns jabber:x:data -type submit
            }]
    }

    # =====================================================================
    # Room destruction (muc#owner)
    # =====================================================================

    method destroyRoom {args} {
        array set opts {-altRoom "" -reason "" -password "" -command ""}
        array set opts $args

        set destroyAttrs {}
        if {$opts(-altRoom) ne ""} {
            set destroyAttrs [list -jid $opts(-altRoom)]
        }

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [j query -ns http://jabber.org/protocol/muc#owner {
                j destroy {*}$destroyAttrs {
                    if {$opts(-reason) ne ""} {
                        j reason #body $opts(-reason)
                    }
                    if {$opts(-password) ne ""} {
                        j password #body $opts(-password)
                    }
                }
            }]
    }

    # =====================================================================
    # Registration (jabber:iq:register)
    # =====================================================================

    method registerGet {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnConfigGetResult $opts(-command)] \
            -payload [j query -ns jabber:iq:register]
    }

    method registerSet {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
            -payload [$self FormSubmitPayload \
                jabber:iq:register \
                http://jabber.org/protocol/muc#register \
                $opts(-fields)]
    }

    # =====================================================================
    # Discovery helpers
    # =====================================================================

    method discoverRooms {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type get -to $opts(-jid) \
            -command [mymethod OnDiscoverRoomsResult $opts(-command)] \
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
            lappend result $occ
        }
        return $result
    }

    tackymethod occupant {args} {
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]
        if {![info exists Rooms($opts(-jid))]} {return ""}
        set occs [dict get $Rooms($opts(-jid)) occupants]
        if {[dict exists $occs $opts(-nick)]} {
            return [dict get $occs $opts(-nick)]
        }
        return ""
    }

    tackymethod myNick {args} {
        set jid [jid norm [dict get $args -jid]]
        if {![info exists Rooms($jid)]} {return ""}
        return [dict get $Rooms($jid) nick]
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

    tackymethod rooms {args} {
        set result {}
        foreach jid [array names Rooms] {
            if {[dict get $Rooms($jid) joined]} {
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

        # MUC presence comes from room@service/nick
        if {![jid valid $from] || [jid resource $from] eq ""} return

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

        # Fire join callback if pending
        if {[info exists JoinCallbacks($roomJid)]} {
            set cmd $JoinCallbacks($roomJid)
            unset JoinCallbacks($roomJid)
            {*}$cmd [list -jid $roomJid -error $errorType -stanza $stanza]
        }

        # Clean up room tracking if we never joined
        if {[info exists Rooms($roomJid)] && ![dict get $Rooms($roomJid) joined]} {
            unset Rooms($roomJid)
        }

        $client emit muc <Error> -jid $roomJid -error $errorType -stanza $stanza
    }

    method OnSelfPresence {roomJid nick stanza mucX codes} {
        set occupant [$self ParseItem $mucX $nick $stanza]

        # Nick may have been rewritten by service (status 210)
        dict set Rooms($roomJid) nick $nick
        dict set Rooms($roomJid) occupants $nick $occupant

        if {![dict get $Rooms($roomJid) joined]} {
            # First self-presence = join complete
            dict set Rooms($roomJid) joined 1

            if {[info exists JoinCallbacks($roomJid)]} {
                set cmd $JoinCallbacks($roomJid)
                unset JoinCallbacks($roomJid)
                {*}$cmd [list -jid $roomJid -nick $nick]
            }

            $client emit muc <Joined> -jid $roomJid -nick $nick

            # Fetch room avatar for bookmark display
            $client avatar ensureVCard $roomJid

            # Status 201 = room was just created, needs configuration
            if {201 in $codes} {
                $client emit muc <RoomCreated> -jid $roomJid
            }
        }

        $client avatar OnVCardPresence [xsearch $stanza -get @from] $stanza
        $client emit muc <Presence> -jid $roomJid -nick $nick -occupant $occupant
    }

    method OnOccupantPresence {roomJid nick stanza mucX} {
        set occupant [$self ParseItem $mucX $nick $stanza]
        dict set Rooms($roomJid) occupants $nick $occupant
        $client avatar OnVCardPresence [xsearch $stanza -get @from] $stanza
        $client emit muc <Presence> -jid $roomJid -nick $nick -occupant $occupant
    }

    method OnUnavailable {roomJid nick stanza mucX} {
        set codes [$self ParseStatusCodes $mucX]
        set isSelf [expr {110 in $codes}]
        set occupant [$self ParseItem $mucX $nick $stanza]

        set actor [xsearch $mucX item actor -get @nick]
        set reason [xsearch $mucX item reason -get body]

        # Room destroyed
        set destroyNode [xsearch $mucX destroy]
        if {[llength $destroyNode] > 0} {
            set destroyNode [lindex $destroyNode 0]
            set altRoom [xsearch $destroyNode -get @jid]
            set destroyReason [xsearch $destroyNode reason -get body]

            $self CleanupRoom $roomJid
            $client emit muc <Destroyed> -jid $roomJid -altRoom $altRoom -reason $destroyReason
            return
        }

        # Nick change (status 303)
        if {303 in $codes} {
            set newNick [xsearch $mucX item -get @nick]
            # Remove old nick from occupants
            set occs [dict get $Rooms($roomJid) occupants]
            dict unset occs $nick
            dict set Rooms($roomJid) occupants $occs

            if {$isSelf} {
                dict set Rooms($roomJid) nick $newNick
            }

            $client emit muc <NickChanged> -jid $roomJid -oldNick $nick -newNick $newNick -self $isSelf
            return
        }

        # Remove from occupants
        set occs [dict get $Rooms($roomJid) occupants]
        dict unset occs $nick
        dict set Rooms($roomJid) occupants $occs

        # Kicked (307)
        if {307 in $codes && !(333 in $codes)} {
            $client emit muc <Kicked> -jid $roomJid -nick $nick -actor $actor -reason $reason
        }

        # Banned (301)
        if {301 in $codes} {
            $client emit muc <Banned> -jid $roomJid -nick $nick -actor $actor -reason $reason
        }

        if {$isSelf} {
            set myNick [dict get $Rooms($roomJid) nick]
            $self CleanupRoom $roomJid
            $client emit muc <Left> -jid $roomJid -nick $myNick
            return
        }

        $client emit muc <Unavailable> \
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

            # Subject change: has <subject>, no <body>
            set subjectText [xsearch $stanza subject -get body]
            set subjectNodes [xsearch $stanza subject]
            set bodyText [xsearch $stanza body -get body]

            if {[llength $subjectNodes] > 0 && $bodyText eq ""} {
                $self OnSubjectMessage $roomJid $nick $subjectText
                return 1
            }

            if {$bodyText ne ""} {
                $self OnGroupchatMessage $roomJid $nick $stanza
                return 1
            }

            # Config change notifications come as groupchat with muc#user status codes
            if {[llength $mucX] > 0} {
                set codes [$self ParseStatusCodes [lindex [xsearch $stanza x -ns http://jabber.org/protocol/muc#user] 0]]
                if {[llength $codes] > 0} {
                    $client emit muc <ConfigChanged> -jid $roomJid -codes $codes
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
        if {[llength $mucX] > 0} {
            set mucXNode [lindex [xsearch $stanza x -ns http://jabber.org/protocol/muc#user] 0]
            set codes [$self ParseStatusCodes $mucXNode]
            if {101 in $codes} {
        set roomJid [jid norm [jid bare $from]]
                set itemAffil [xsearch $mucXNode item -get @affiliation]
                set itemJid [xsearch $mucXNode item -get @jid]
                $client emit muc <AffiliationChanged> \
                    -jid $roomJid -target $itemJid -affiliation $itemAffil
                return 1
            }
        }

        return 0
    }

    method OnSubjectMessage {roomJid nick subjectText} {
        if {[info exists Rooms($roomJid)]} {
            dict set Rooms($roomJid) subject $subjectText
        }
        $client emit muc <Subject> -jid $roomJid -nick $nick -subject $subjectText
    }

    method OnGroupchatMessage {roomJid nick stanza} {
        $client message store ${roomJid}?join $stanza
    }

    method OnPrivateMessage {roomJid nick stanza} {
        $client message store ${roomJid}/${nick} $stanza
    }

    method OnInvite {stanza mucX} {
        set roomJid [jid norm [jid bare [xsearch $stanza -get @from]]]
        set inviteNode [lindex [xsearch $mucX invite] 0]
        set inviterJid [xsearch $inviteNode -get @from]
        set reason [xsearch $inviteNode reason -get body]
        set password [xsearch $mucX password -get body]

        set continueThread [xsearch $inviteNode continue -get @thread]

        $client emit muc <Invite> \
            -jid $roomJid -from $inviterJid -reason $reason \
            -password $password -continue $continueThread
    }

    method OnDecline {stanza mucX} {
        set roomJid [jid norm [jid bare [xsearch $stanza -get @from]]]
        set declineNode [lindex [xsearch $mucX decline] 0]
        set declinerJid [xsearch $declineNode -get @from]
        set reason [xsearch $declineNode reason -get body]

        $client emit muc <Decline> \
            -jid $roomJid -from $declinerJid -reason $reason
    }

    method OnVoiceRequest {stanza xdataNode} {
        set roomJid [jid norm [jid bare [xsearch $stanza -get @from]]]
        set reqJid [xsearch $xdataNode field @var muc#jid value -get body]
        set reqNick [xsearch $xdataNode field @var muc#roomnick value -get body]

        $client emit muc <VoiceRequest> \
            -jid $roomJid -from $reqJid -nick $reqNick -form $xdataNode
    }

    # =====================================================================
    # Internal: IQ result handlers
    # =====================================================================

    method OnIqResult {command stanza} {
        if {$command ne ""} {
            {*}$command $stanza
        }
    }

    method OnListResult {command stanza} {
        if {$command eq ""} return

        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            {*}$command [list error 1 stanza $stanza]
            return
        }

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

    method OnConfigGetResult {command stanza} {
        if {$command eq ""} return

        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            {*}$command [list error 1 stanza $stanza]
            return
        }

        set formNode [xsearch $stanza query x -ns jabber:x:data]
        if {[llength $formNode] > 0} {
            {*}$command [lindex $formNode 0]
        } else {
            {*}$command {}
        }
    }

    method OnDiscoverRoomsResult {command stanza} {
        if {$command eq ""} return

        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            {*}$command [list error 1 stanza $stanza]
            return
        }

        set rooms {}
        xsearch $stanza query item -script itemNode {
            set jid [xsearch $itemNode -get @jid]
            set name [xsearch $itemNode -get @name]
            if {$jid ne ""} {
                set occupants ""
                set formNodes [xsearch $itemNode x -ns jabber:x:data]
                if {[llength $formNodes] > 0} {
                    array set form [::tacky::forms::tolist [lindex $formNodes 0]]
                    if {[info exists form(field,muc#roominfo_occupants,value)]} {
                        set occupants $form(field,muc#roominfo_occupants,value)
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

        return [dict create \
            nick $nick \
            jid $jid_ \
            role $role \
            affiliation $affiliation \
            show $show \
            status $statusText]
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

    method FormSubmitPayload {queryNs formType fieldSpecs} {
        j query -ns $queryNs {
            j x -ns jabber:x:data -type submit {
                j field -var FORM_TYPE -type hidden {
                    j value #body $formType
                }
                foreach fieldSpec $fieldSpecs {
                    set var [lindex $fieldSpec 0]
                    set values [lrange $fieldSpec 1 end]
                    j field -var $var {
                        foreach v $values {
                            j value #body $v
                        }
                    }
                }
            }
        }
    }

    method CleanupRoom {roomJid} {
        unset -nocomplain Rooms($roomJid)
        unset -nocomplain JoinCallbacks($roomJid)
    }
}
