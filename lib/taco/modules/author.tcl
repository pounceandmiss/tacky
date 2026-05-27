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

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set State [dict create]
        $client bus subscribe $self roster:<Changed>  [mymethod OnRosterChanged]
        $client bus subscribe $self nick:<Changed>    [mymethod OnNickChanged]
        $client bus subscribe $self muc:<Presence>    [mymethod OnMucPresence]
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
            # Strip ?join (groupchat) or /nick (PM) to get the room JID
            if {[string match {*\?join} $chatJid]} {
                regsub {\?join$} $chatJid {} roomJid
            } else {
                set roomJid [jid bare $chatJid]
            }
            # Currently-joined occupants
            foreach occ [$client muc occupants -jid $roomJid] {
                set nick [dict get $occ nick]
                dict set d $roomJid/$nick $nick
            }
            # Historical authors from message store (occupants who left
            # but whose messages we still display)
            $client db eval {
                SELECT DISTINCT from_jid FROM chat_message
                WHERE chat_jid = $chatJid
            } row {
                set f $row(from_jid)
                if {![dict exists $d $f]} {
                    dict set d $f [jid resource $f]
                }
            }
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
            dict for {chatJid entries} $State {
                if {[IsMucChatJid $chatJid]} continue
                dict for {fromJid _} $entries {
                    $self RefreshBareIn1to1 $fromJid
                }
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
    # <Presence>; the old nick's entry stays so historical messages keep
    # rendering correctly.
    method OnMucPresence {args} {
        set roomJid [dict get $args -jid]
        set nick    [dict get $args -nick]
        set fromJid $roomJid/$nick
        # Update every tracked chat that maps to this room (could be
        # `room@muc?join` plus zero or more `room@muc/nick` PMs).
        dict for {chatJid entries} $State {
            if {![IsMucChatJid $chatJid]} continue
            if {[string match {*\?join} $chatJid]} {
                regsub {\?join$} $chatJid {} chatRoom
            } else {
                set chatRoom [jid bare $chatJid]
            }
            if {$chatRoom ne $roomJid} continue
            if {[dict exists $entries $fromJid]} continue
            dict set State $chatJid $fromJid $nick
            $client emit author <Changed> \
                -chat $chatJid -from $fromJid -name $nick
        }
    }
}
