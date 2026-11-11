# taco_notify - which arriving message deserves an alert.
#
# A chat being looked at (chat is_looking) never alerts. Otherwise a message
# alerts only while past chat_own_read; the watermark moving cancels or
# dismisses it.
#
# A live alert waits notify_delay_ms first, so a read from another device
# landing just after can still cancel it.
#
# Policy per chat is `muted` plus `mentions`, and a mention overrides the
# mute. Rooms default to muted, which leaves a public room pinging on your
# nick alone.
#
#   notify <Notify>     -jid J -id I -timestamp T -nick N -body S -unread C -mention B
#   notify <MissedCall> -jid J -timestamp T -nick N -video B
#   notify <Settings>   -jid J -muted B -mentions B
#   notify <Dismiss>    -jid J      read up to the last message alerted: take
#                                   its alert down
#
# A missed call (calls <Missed>) follows the chat's mute like a message.

snit::type taco_notify {
    option -client -readonly yes

    variable client
    # {chat_jid id} -> after token for an alert not yet fired.
    variable Pending
    # chat_jid -> the place (pos) of the last message already alerted.
    # Memory-only, so a restart re-announces a backlog that is still unread.
    variable LastAlerted

    # Alerts emitted for one chat in one catch-up; `unread` still carries
    # the true total.
    typevariable CatchupBurstMax 10
    typevariable DefaultDelayMs 500

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Pending [dict create]
        set LastAlerted [dict create]
        $client bus subscribe $self message:<New> [mymethod OnNew]
        $client bus subscribe $self message:<OwnRead> [mymethod OnOwnRead]
        $client bus subscribe $self message:<CatchupDone> [mymethod OnCatchupDone]
        $client bus subscribe $self calls:<Missed> [mymethod OnMissedCall]
        $client bus subscribe $self <SessionStart> [mymethod OnReady]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        dict for {key token} $Pending { catch {after cancel $token} }
    }

    # -- policy ---------------------------------------------------------

    tackymethod get {args} {
        array set opts $args
        return [$self Store notifyPolicy $opts(-chat)]
    }

    tackymethod set {args} {
        array set opts $args
        set policy [$self Store notifyPolicy $opts(-chat)]
        foreach key {muted mentions} {
            if {[info exists opts(-$key)]} {
                dict set policy $key [AsBool $opts(-$key)]
            }
        }
        $self Store setNotifyPolicy $opts(-chat) \
            [dict get $policy muted] [dict get $policy mentions]
        $client emit notify <Settings> -jid $opts(-chat) \
            -muted [dict get $policy muted] \
            -mentions [dict get $policy mentions]
    }

    method ShouldNotify {chatJid mention} {
        set policy [$self Store notifyPolicy $chatJid]
        if {$mention && [dict get $policy mentions]} { return 1 }
        return [expr {![dict get $policy muted]}]
    }

    # -- arrival --------------------------------------------------------

    method OnNew {args} {
        array set opts {-jid "" -message ""}
        array set opts $args
        if {$opts(-jid) eq "" || $opts(-message) eq ""} return
        if {[dict get $opts(-message) is_outgoing]} return
        set ts [dict get $opts(-message) timestamp]
        set id [dict get $opts(-message) id]
        if {$ts < [$self Floor]} return
        if {[$self Read $opts(-jid) $id]} return
        if {[$client chat is_looking -chat $opts(-jid)]} return
        set mention [$self Store mentionAt $opts(-jid) $id]
        if {![$self ShouldNotify $opts(-jid) $mention]} return
        $self Schedule [dict create jid $opts(-jid) id $id ts $ts \
            mention $mention \
            from [dict get $opts(-message) from_jid] \
            body [ContentPreview $opts(-message)]]
    }

    method Schedule {alert} {
        set key [PendingKey $alert]
        if {[dict exists $Pending $key]} return
        set delay [$self Delay]
        if {$delay <= 0} {
            $self Fire $alert
            return
        }
        dict set Pending $key [after $delay [mymethod Fire $alert]]
    }

    method Fire {alert} {
        dict unset Pending [PendingKey $alert]
        set chatJid [dict get $alert jid]
        if {[$self Read $chatJid [dict get $alert id]]} return
        if {[$client chat is_looking -chat $chatJid]} return
        $self Notify $alert
    }

    # Forward-only per chat, so a catch-up sweep and a live arrival can't
    # announce the same message twice.
    method Notify {alert} {
        set chatJid [dict get $alert jid]
        set id [dict get $alert id]
        set pos [$self Store PosOf $chatJid $id]
        if {$pos eq ""} return
        if {[dict exists $LastAlerted $chatJid]
            && [string compare $pos [dict get $LastAlerted $chatJid]] <= 0} return
        dict set LastAlerted $chatJid $pos
        $client emit notify <Notify> -jid $chatJid -id $id \
            -timestamp [dict get $alert ts] \
            -nick [$self SenderName $chatJid [dict get $alert from]] \
            -from [dict get $alert from] \
            -body [dict get $alert body] \
            -unread [$self Store unreadCount $chatJid] \
            -mention [dict get $alert mention]
    }

    # No delay or watermark: a call has no read state.
    method OnMissedCall {args} {
        array set opts {-from "" -video 0}
        array set opts $args
        if {$opts(-from) eq ""} return
        if {![$self ShouldNotify $opts(-from) 0]} return
        $client emit notify <MissedCall> -jid $opts(-from) \
            -timestamp [clock microseconds] \
            -nick [$self SenderName $opts(-from) $opts(-from)] \
            -video $opts(-video)
    }

    # Who to put on the notification: the room nick, or the contact's name
    # in a 1:1. The author module already owns that rule.
    method SenderName {chatJid fromJid} {
        if {$fromJid eq ""} { return "" }
        set names [$client author get -chat $chatJid]
        if {[dict exists $names $fromJid]} { return [dict get $names $fromJid] }
        return $fromJid
    }

    # Reading cancels anything still waiting out its delay. Dismissing an
    # alert already shown is the frontend's job, off the same event.
    method OnOwnRead {args} {
        array set opts {-jid "" -id ""}
        array set opts $args
        if {[dict exists $LastAlerted $opts(-jid)]} {
            set mark [dict get [$self Store ownRead $opts(-jid)] pos]
            if {$mark ne "" && [string compare \
                    [dict get $LastAlerted $opts(-jid)] $mark] <= 0} {
                $client emit notify <Dismiss> -jid $opts(-jid)
            }
        }
        set stale {}
        dict for {key token} $Pending {
            lassign $key jid id
            if {$jid eq $opts(-jid) && [$self Read $jid $id]} {
                after cancel $token
                lappend stale $key
            }
        }
        foreach key $stale { dict unset Pending $key }
    }

    # Messages that arrived while we were away. No delay: there is no live
    # arrival to lose a race against.
    method OnCatchupDone {args} {
        array set opts {-jid "" -count 0}
        array set opts $args
        if {$opts(-jid) eq ""} return
        if {[$client chat is_looking -chat $opts(-jid)]} return
        set rows [$self Store unreadTail \
            $opts(-jid) [$self Floor] $CatchupBurstMax]
        foreach row [lreverse $rows] {
            lassign $row id mention fromJid body attachments
            if {![$self ShouldNotify $opts(-jid) $mention]} continue
            $self Notify [dict create jid $opts(-jid) id $id \
                ts [$self Store stampOf $opts(-jid) $id] mention $mention \
                from $fromJid body [RowPreview $body $attachments]]
        }
    }

    # Nothing older than the account's first connect ever alerts, so the
    # opening archive fetch stays silent.
    method OnReady {args} {
        if {[taco_setting_get $client notify_floor] ne ""} return
        catch {
            [$client cget -taco] setting set \
                -key notify_floor -value [clock microseconds]
        }
    }

    # -- helpers --------------------------------------------------------

    method Store {args} {
        return [$client message messagestore {*}$args]
    }

    # Whether row $id in $chatJid is at or before our read mark.
    method Read {chatJid id} {
        set mark [dict get [$self Store ownRead $chatJid] pos]
        if {$mark eq ""} { return 0 }
        set pos [$self Store PosOf $chatJid $id]
        expr {$pos eq "" || [string compare $pos $mark] <= 0}
    }

    method Floor {} {
        return [taco_setting_get $client notify_floor 0]
    }

    method Delay {} {
        set ms [taco_setting_get $client notify_delay_ms]
        return [expr {[string is entier -strict $ms] ? $ms : $DefaultDelayMs}]
    }

    proc AsBool {value} {
        return [expr {$value in {1 true yes on}}]
    }

    proc PendingKey {alert} {
        return [list [dict get $alert jid] [dict get $alert id]]
    }

    # Preview text, from a message dict and from a stored row respectively. An
    # attachment carries a caption in place of a body, and nothing at all when
    # the body was only the URL; a retracted row has no content to show.
    proc ContentPreview {msg} {
        if {![dict exists $msg content]} { return "" }
        set content [dict get $msg content]
        foreach key {body caption} {
            if {[dict exists $content $key]} { return [dict get $content $key] }
        }
        return ""
    }

    proc RowPreview {body attachments} {
        if {[llength $attachments] == 0} { return $body }
        return [attachment_caption $body $attachments]
    }
}
