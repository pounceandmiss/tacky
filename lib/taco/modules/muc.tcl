# tacky muc join -acc $jid -jid $room -nick $nick ?-password $pw? ?-history {...}? ?-hidden 0|1?
#   ;# -hidden: a room for tacky's own use (a group call's): not bookmarked,
#   ;# listed or archived; events stay on the bus tagged -hidden 1, messages
#   ;# are dropped.
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
# tacky muc myNick -acc $jid -jid $room
# tacky muc myRole -acc $jid -jid $room
# tacky muc myAffiliation -acc $jid -jid $room
# tacky muc haveVoice -acc $jid -jid $room
# tacky muc isJoined -acc $jid -jid $room
# tacky muc isHidden -acc $jid -jid $room
# tacky muc rooms -acc $jid                  ;# joined rooms, hidden ones left out
#
# tacky listen muc <Joined> $cmd             ;# -jid $room -nick $myNick
# tacky listen muc <Left> $cmd               ;# -jid $room -nick $myNick -involuntary $bool -codes $codes
# tacky listen muc <Error> $cmd              ;# -jid $room -error $errorType -stanza $stanza
# tacky listen muc <Presence> $cmd           ;# -jid $room -nick $nick -occupant $dict
# tacky listen muc <Unavailable> $cmd        ;# -jid $room -nick $nick -reason $r -codes $codes -occupant $dict
# tacky listen muc <Subject> $cmd            ;# -jid $room -nick $nick -subject $text
# NOTE: MUC messages are delivered via message <New>, not muc events.
# NOTE: invitations are stored as messages (content type "invite"), not muc
# events: a room-relayed one in the room's chat, a direct one in the inviter's.
# tacky listen muc <Decline> $cmd            ;# -jid $room -from $declinerJid -reason $text
# tacky listen muc <NickChanged> $cmd        ;# -jid $room -oldNick $old -newNick $new -self $bool
# tacky listen muc <Kicked> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <Banned> $cmd             ;# -jid $room -nick $nick -actor $actorNick -reason $text
# tacky listen muc <ConfigChanged> $cmd      ;# -jid $room -codes $statusCodes
# tacky listen muc <RoomCreated> $cmd        ;# -jid $room
# tacky listen muc <Destroyed> $cmd          ;# -jid $room -altRoom $jidOrEmpty -reason $text
# tacky listen muc <VoiceRequest> $cmd       ;# -jid $room -from $jid -nick $nick -form $formDict
# tacky listen muc <AffiliationChanged> $cmd ;# -jid $room -target $bareJid -affiliation $new

snit::type taco_muc {
    variable client

    # roomJid -> dict: nick, subject, joined, leaving, occupants (dict nick->occupantDict)
    # Each occupantDict: {nick $n jid $fullJid role $r affiliation $a show $s status $st}
    variable Rooms -array {}

    # roomJid -> join -command callback (pending joins)
    variable JoinCallbacks -array {}
    # roomJid -> the after token giving up on a join the room never answers
    variable JoinTimers -array {}
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
    }

    method OnDisconnect {args} {
        foreach roomJid [array names JoinCallbacks] {
            $self FailJoin $roomJid disconnected
        }
        foreach roomJid [array names JoinTimers] {
            after cancel $JoinTimers($roomJid)
        }
        array unset JoinTimers *
        array unset Rooms *
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
        unset Rooms($roomJid)
        $self Emit $roomJid <Error> -jid $roomJid -error remote-server-timeout -stanza {}
    }

    # =====================================================================
    # Joining / Leaving
    # =====================================================================

    method join {args} {
        array set opts {-password "" -history {} -command "" -hidden 0}
        array set opts $args
        set opts(-jid) [jid norm $opts(-jid)]

        # Initialize room tracking state
        set Rooms($opts(-jid)) [dict create \
            nick $opts(-nick) myOccupantId "" subject "" joined 0 \
            leaving 0 occupants [dict create] \
            hidden [expr {$opts(-hidden) ? 1 : 0}] created 0]

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

    method invite {args} {
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
    method acceptInvite {args} {
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
    method declineInvite {args} {
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
            $client chats forget $chatJid
        } else {
            $client message EmitMessagePatch $chatJid $ts
        }
        $client chatlist EmitEntry $chatJid
    }

    # =====================================================================
    # Voice
    # =====================================================================

    method requestVoice {args} {
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

    method kick {args} {
        $self role {*}[dict set args -role none]
    }

    method role {args} {
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

    method affiliation {args} {
        array set opts {-reason "" -nick "" -command "" -onerror ""}
        array set opts $args

        set itemAttrs [list -jid $opts(-target) -affiliation $opts(-affiliation)]
        if {$opts(-nick) ne ""} {
            lappend itemAttrs -nick $opts(-nick)
        }

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

    method createInstant {args} {
        array set opts {-command ""}
        array set opts $args

        $client iq request -type set -to $opts(-jid) \
            -command [mymethod OnIqResult $opts(-command)] \
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

    method discoverRooms {args} {
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

    tackymethod isHidden {args} {
        set room [jid norm [dict get $args -jid]]
        expr {[info exists Rooms($room)] && [dict get $Rooms($room) hidden]}
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
            unset Rooms($roomJid)
        }

        $self Emit $roomJid <Error> -jid $roomJid -error $errorType -stanza $stanza
    }

    method OnSelfPresence {roomJid nick stanza mucX codes} {
        set occupant [$self ParseItem $mucX $nick $stanza]

        # Nick may have been rewritten by service (status 210)
        dict set Rooms($roomJid) nick $nick
        dict set Rooms($roomJid) occupants $nick $occupant

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

            $self Emit $roomJid <Joined> -jid $roomJid -nick $nick

            # Fetch room avatar for bookmark display
            if {![dict get $Rooms($roomJid) hidden]} {
                $client avatar ensureVCard $roomJid
            }

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
        # have just changed; refresh them all.
        dict for {onick occ} [dict get $Rooms($roomJid) occupants] {
            if {$onick eq $nick} continue
            $self Emit $roomJid <Presence> -jid $roomJid -nick $onick \
                -occupant [$self WithCaps $roomJid $occ]
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
        if {![dict get $Rooms($roomJid) hidden]} {
            $client avatar OnVCardPresence [xsearch $stanza -get @from] $stanza
        }
        $self Emit $roomJid <Presence> -jid $roomJid -nick $nick \
            -occupant [$self WithCaps $roomJid $occupant]
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
            $self Emit $roomJid <Destroyed> -jid $roomJid -altRoom $altRoom -reason $destroyReason
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

            $self Emit $roomJid <NickChanged> -jid $roomJid -oldNick $nick -newNick $newNick -self $isSelf
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
                $self OnRoomError $errRoom $stanza
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
            # an XEP-0424/0425 <retract> (moderation broadcast) or an
            # XEP-0482 call invite or answer is forwarded too;
            # ingestLive/Classify handle it. Other bodyless groupchat
            # stanzas fall through to the status-code handling below.
            set hasReactions [expr {[llength \
                [xsearch $stanza reactions -ns urn:xmpp:reactions:0]] > 0}]
            set hasRetract [expr {[llength \
                [xsearch $stanza retract -ns urn:xmpp:message-retract:1]] > 0}]
            set hasCall [expr {[llength \
                [xsearch $stanza * -ns urn:xmpp:call-invites:0]] > 0}]
            if {$bodyText ne "" || $hasReactions || $hasRetract || $hasCall} {
                $self OnGroupchatMessage $roomJid $nick $stanza
                return 1
            }

            # Config change notifications come as groupchat with muc#user status codes
            if {$mucX ne ""} {
                set codes [$self ParseStatusCodes $mucX]
                if {[llength $codes] > 0} {
                    $self Emit $roomJid <ConfigChanged> -jid $roomJid -codes $codes
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
                set itemAffil [xsearch $mucX item -get @affiliation]
                set itemJid [xsearch $mucX item -get @jid]
                $self Emit $roomJid <AffiliationChanged> \
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
        if {$occ ne ""} {
            set isOwn [expr {$myOcc ne "" && $occ eq $myOcc}]
        } else {
            set isOwn [expr {$nick eq [dict get $Rooms($roomJid) nick]}]
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

    # Result handler for moderation actions (kick/ban/role/affiliation). On an
    # error stanza it hands -onerror a ready message; success goes to -command.
    method OnActionResult {command onerror stanza} {
        if {[$self ReportActionError $onerror $stanza]} return
        if {$command ne ""} {
            {*}$command $stanza
        }
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
    method OnRoomError {roomJid stanza} {
        set mucX [lindex [xsearch $stanza x \
            -ns http://jabber.org/protocol/muc#user] 0]
        if {$mucX eq ""} return
        set codes [$self ParseStatusCodes $mucX]
        if {110 ni $codes} return
        if {[xsearch $mucX item -get @role] ne "none"} return
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
    method SelfLeft {roomJid involuntary codes} {
        set myNick ""
        if {[info exists Rooms($roomJid)]} {
            set myNick [dict get $Rooms($roomJid) nick]
        }
        set hidden [$self isHidden -jid $roomJid]
        $self CleanupRoom $roomJid
        $self EmitAs $hidden <Left> -jid $roomJid -nick $myNick \
            -involuntary $involuntary -codes $codes
    }

    # A hidden room's events go only on the bus, tagged -hidden 1 so
    # bookmarks and the stores skip them; never to the frontend.
    method Emit {roomJid event args} {
        $self EmitAs [$self isHidden -jid $roomJid] $event {*}$args
    }

    method EmitAs {hidden event args} {
        if {$hidden} {
            $client bus publish muc:$event -hidden 1 {*}$args
        } else {
            $client emit muc $event {*}$args
        }
    }

    method CleanupRoom {roomJid} {
        unset -nocomplain Rooms($roomJid)
        # A join still waiting is over: say so rather than drop it.
        $self FailJoin $roomJid item-not-found
    }
}
