# taco_notify - which arriving message deserves an alert.
#
# The gate is the read watermark, not window focus: a message alerts only
# while it sits past chat_own_read, and the watermark moving is what cancels
# or dismisses it. So there is no "I am looking at this chat" call to make.
#
# A live alert waits out notify_delay_ms first. The chat view marks the tail
# read on focus, scroll and arrival, so a message landing in a chat the user
# is already reading is read inside that window and never alerts.
#
# Policy per chat is `muted` plus `mentions`, and a mention overrides the
# mute. Rooms default to muted, which leaves a public room pinging on your
# nick alone.
#
#   notify <Notify>   -jid J -timestamp T -nick N -body S -unread C -mention B
#   notify <Settings> -jid J -muted B -mentions B

snit::type taco_notify {
    option -client -readonly yes

    variable client
    # {chat_jid timestamp} -> after token for an alert not yet fired.
    variable Pending
    # chat_jid -> newest timestamp already alerted. Memory-only, so a
    # restart re-announces a backlog that is still unread.
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
        $client bus subscribe $self <Ready> [mymethod OnReady]
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
        if {$ts < [$self Floor]} return
        if {$ts <= [$self Watermark $opts(-jid)]} return
        set mention [$self Store mentionAt $opts(-jid) $ts]
        if {![$self ShouldNotify $opts(-jid) $mention]} return
        $self Schedule [dict create jid $opts(-jid) ts $ts mention $mention \
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
        if {[dict get $alert ts] <= [$self Watermark $chatJid]} return
        $self Notify $alert
    }

    # Forward-only per chat, so a catch-up sweep and a live arrival can't
    # announce the same message twice.
    method Notify {alert} {
        set chatJid [dict get $alert jid]
        set ts [dict get $alert ts]
        if {[dict exists $LastAlerted $chatJid]
            && $ts <= [dict get $LastAlerted $chatJid]} return
        dict set LastAlerted $chatJid $ts
        $client emit notify <Notify> -jid $chatJid -timestamp $ts \
            -nick [$self SenderName $chatJid [dict get $alert from]] \
            -body [dict get $alert body] \
            -unread [$self Store unreadCount $chatJid] \
            -mention [dict get $alert mention]
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
        array set opts {-jid "" -timestamp 0}
        array set opts $args
        set stale {}
        dict for {key token} $Pending {
            lassign $key jid ts
            if {$jid eq $opts(-jid) && $ts <= $opts(-timestamp)} {
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
        set rows [$self Store unreadTail \
            $opts(-jid) [$self Floor] $CatchupBurstMax]
        foreach row [lreverse $rows] {
            lassign $row ts mention fromJid body attachments
            if {![$self ShouldNotify $opts(-jid) $mention]} continue
            $self Notify [dict create jid $opts(-jid) ts $ts mention $mention \
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

    method Watermark {chatJid} {
        return [dict get [$self Store ownRead $chatJid] read_ts]
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
        return [list [dict get $alert jid] [dict get $alert ts]]
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
