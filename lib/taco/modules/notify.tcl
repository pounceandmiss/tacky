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
#   notify <Alert>    -jid J -timestamp T -unread N -mention B
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
        $self Schedule $opts(-jid) $ts $mention
    }

    method Schedule {chatJid ts mention} {
        set key [list $chatJid $ts]
        if {[dict exists $Pending $key]} return
        set delay [$self Delay]
        if {$delay <= 0} {
            $self Fire $chatJid $ts $mention
            return
        }
        dict set Pending $key \
            [after $delay [mymethod Fire $chatJid $ts $mention]]
    }

    method Fire {chatJid ts mention} {
        dict unset Pending [list $chatJid $ts]
        if {$ts <= [$self Watermark $chatJid]} return
        $self Alert $chatJid $ts $mention
    }

    # Forward-only per chat, so a catch-up sweep and a live arrival can't
    # announce the same message twice.
    method Alert {chatJid ts mention} {
        if {[dict exists $LastAlerted $chatJid]
            && $ts <= [dict get $LastAlerted $chatJid]} return
        dict set LastAlerted $chatJid $ts
        $client emit notify <Alert> -jid $chatJid -timestamp $ts \
            -unread [$self Store unreadCount $chatJid] -mention $mention
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
            lassign $row ts mention
            if {![$self ShouldNotify $opts(-jid) $mention]} continue
            $self Alert $opts(-jid) $ts $mention
        }
    }

    # Nothing older than the account's first connect ever alerts, so the
    # opening archive fetch stays silent.
    method OnReady {args} {
        if {[$self Setting notify_floor] ne ""} return
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
        set floor [$self Setting notify_floor]
        return [expr {$floor eq "" ? 0 : $floor}]
    }

    method Delay {} {
        set ms [$self Setting notify_delay_ms]
        return [expr {[string is entier -strict $ms] ? $ms : $DefaultDelayMs}]
    }

    method Setting {key} {
        if {[catch {[$client cget -taco] setting get -key $key} value]} {
            return ""
        }
        return $value
    }

    proc AsBool {value} {
        return [expr {$value in {1 true yes on}}]
    }
}
