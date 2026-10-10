# Per-chat author display state.
#
# Encapsulates the MUC-vs-1:1 rule for "what name to show for this
# message's sender" so consumers (GUI) can treat all chats uniformly:
# they get back a dict keyed by stored from_jid → display name.
#
#   tacky author get -acc $acc -chat $chatJid
#       Returns dict from_jid → name. Lazy per-chat; built on first
#       call and kept in sync via the events below.
#
#   tacky listen author <Changed> -acc $acc -chat $chatJid $cmd
#       Fires whenever a name in the cache for $chatJid changes, or
#       a new author appears. Args: -chat -from -name.
#
# Resolution rules:
#   MUC chat (chat_jid `room@muc?join` or `room@muc/nick`):
#       name = [jid resource $fromJid]   (the participant nick)
#   1:1 chat (bare chat_jid):
#       name = roster_item.name → pep_nick.nick → bare JID itself

snit::type taco_author {
    option -client -readonly yes
    variable client

    # State: dict chatJid -> dict from_jid -> name.
    # Populated lazily on first `get` for a chat.
    variable State

    # dict chatJid -> dict from_jid -> 1: the room entries of State there
    # because the occupant is present, not because the store has a message
    # from it. They go when the occupant leaves or changes nick, unless the
    # store has a message from it by then; otherwise every nick a room ever
    # showed stays for the life of the client.
    variable PresenceOnly

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set State [dict create]
        set PresenceOnly [dict create]
        $client bus subscribe $self roster:<Changed>  [mymethod OnRosterChanged]
        $client bus subscribe $self nick:<Changed>    [mymethod OnNickChanged]
        $client bus subscribe $self muc:<Presence>    [mymethod OnMucPresence]
        $client bus subscribe $self muc:<Unavailable> [mymethod OnMucUnavailable]
        $client bus subscribe $self muc:<NickChanged> [mymethod OnMucNickChanged]
        $client bus subscribe $self muc:<Left>        [mymethod OnMucLeft]
    }

    destructor {
        catch {$client bus unsubscribe $self}
    }

    tackymethod get {args} {
        set chatJid [dict get $args -chat]
        if {![dict exists $State $chatJid]} {
            dict set State $chatJid [$self Build $chatJid]
        }
        return [dict get $State $chatJid]
    }

    method Build {chatJid} {
        set d [dict create]
        if {[IsMucChatJid $chatJid]} {
            set roomJid [RoomOf $chatJid]
            # Currently-joined occupants
            set present [dict create]
            foreach occ [$client muc occupants -jid $roomJid] {
                set nick [dict get $occ nick]
                dict set d $roomJid/$nick $nick
                dict set present $roomJid/$nick 1
            }
            # Historical authors from message store (occupants who left
            # but whose messages we still display)
            foreach f [$self StoredAuthors $chatJid] {
                dict unset present $f
                if {![dict exists $d $f]} {
                    dict set d $f [jid resource $f]
                }
            }
            dict set PresenceOnly $chatJid $present
        } else {
            # 1:1: own + peer. Both stored from_jids are bare after
            # Phase 1 normalization.
            set myBare [jid bare [$client cget -jid]]
            dict set d $myBare [$self ResolveBareName $myBare]
            set peerBare [jid norm [jid bare $chatJid]]
            dict set d $peerBare [$self ResolveBareName $peerBare]
        }
        return $d
    }

    method StoredAuthors {chatJid} {
        $client db eval {
            SELECT DISTINCT from_jid FROM chat_message
            WHERE chat_jid = $chatJid AND kind='message'
        }
    }

    # Strip ?join (groupchat) or /nick (PM) to get the room JID
    proc RoomOf {chatJid} {
        if {[string match {*\?join} $chatJid]} {
            regsub {\?join$} $chatJid {} roomJid
            return $roomJid
        }
        return [jid bare $chatJid]
    }

    # roster name → PEP nick → bare itself.
    method ResolveBareName {bareJid} {
        set name [$client db onecolumn {
            SELECT name FROM roster_item WHERE jid=$bareJid
        }]
        if {$name ne ""} { return $name }
        set name [$client db onecolumn {
            SELECT nick FROM pep_nick WHERE jid=$bareJid
        }]
        if {$name ne ""} { return $name }
        return $bareJid
    }

    # Re-resolve $bareJid in every tracked 1:1 chat where it's an
    # author; emit <Changed> on actual diffs.
    method RefreshBareIn1to1 {bareJid} {
        dict for {chatJid entries} $State {
            if {[IsMucChatJid $chatJid]} continue
            if {![dict exists $entries $bareJid]} continue
            set oldName [dict get $entries $bareJid]
            set newName [$self ResolveBareName $bareJid]
            if {$newName eq $oldName} continue
            dict set State $chatJid $bareJid $newName
            $client emit author <Changed> \
                -chat $chatJid -from $bareJid -name $newName
        }
    }

    method OnRosterChanged {args} {
        # -action clear has no -jid; conservatively rebuild every tracked
        # 1:1 chat's authors that resolve via roster.
        if {![dict exists $args -jid]} {
            # RefreshBareIn1to1 walks every tracked chat itself, so gather
            # the distinct authors first and refresh each one once.
            set authors [dict create]
            dict for {chatJid entries} $State {
                if {[IsMucChatJid $chatJid]} continue
                dict for {fromJid _} $entries {
                    dict set authors $fromJid 1
                }
            }
            dict for {fromJid _} $authors {
                $self RefreshBareIn1to1 $fromJid
            }
            return
        }
        $self RefreshBareIn1to1 [dict get $args -jid]
    }

    method OnNickChanged {args} {
        $self RefreshBareIn1to1 [dict get $args -jid]
    }

    # New MUC participant (or presence update): add an entry if missing.
    # NickChanged is handled implicitly — the new nick generates a fresh
    # <Presence>; the old nick's entry stays while the store has messages
    # from it, so historical messages keep rendering correctly
    # (OccupantsGone).
    method OnMucPresence {args} {
        # A hidden room (see muc join -hidden) is none of ours.
        if {[$client muc isHidden -jid [dict get $args -jid]]} return
        set roomJid [dict get $args -jid]
        set nick    [dict get $args -nick]
        set fromJid $roomJid/$nick
        # Update every tracked chat that maps to this room (could be
        # `room@muc?join` plus zero or more `room@muc/nick` PMs).
        dict for {chatJid entries} $State {
            if {![IsMucChatJid $chatJid]} continue
            if {[RoomOf $chatJid] ne $roomJid} continue
            if {[dict exists $entries $fromJid]} continue
            dict set State $chatJid $fromJid $nick
            dict set PresenceOnly $chatJid $fromJid 1
            $client emit author <Changed> \
                -chat $chatJid -from $fromJid -name $nick
        }
    }

    method OnMucUnavailable {args} {
        set roomJid [dict get $args -jid]
        $self OccupantsGone $roomJid [list $roomJid/[dict get $args -nick]]
    }

    method OnMucNickChanged {args} {
        set roomJid [dict get $args -jid]
        $self OccupantsGone $roomJid [list $roomJid/[dict get $args -oldNick]]
    }

    # We left: nobody in the room is present any more
    method OnMucLeft {args} {
        $self OccupantsGone [dict get $args -jid] *
    }

    # Occupants of $roomJid gone ($fromJids, or * for all): their
    # presence-only entries go from every tracked chat of the room, unless
    # the store has a message from them now.
    method OccupantsGone {roomJid fromJids} {
        dict for {chatJid marks} $PresenceOnly {
            if {[RoomOf $chatJid] ne $roomJid} continue
            if {$fromJids eq "*"} {
                set gone [dict keys $marks]
            } else {
                set gone {}
                foreach f $fromJids {
                    if {[dict exists $marks $f]} { lappend gone $f }
                }
            }
            if {![llength $gone]} continue
            set authors [$self StoredAuthors $chatJid]
            foreach f $gone {
                dict unset PresenceOnly $chatJid $f
                if {$f in $authors} continue
                if {[dict exists $State $chatJid]} { dict unset State $chatJid $f }
            }
        }
    }
}
