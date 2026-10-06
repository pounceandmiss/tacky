# groupcallwindow - a group call in a room: one videotile per participant,
# our own preview, mic/speaker/camera controls, leave. One per room;
# `groupcallwindow show` reuses the open one.
#
# Tiles are the room's occupants with a `call`, re-synced from muc occupants
# on each muc event for the room. groupcall <Session> binds a sid to a
# participant, and that sid's calls events drive the tile. Tiles are keyed
# by real JID and labelled by nick.
#
# Usage:
#   groupcallwindow show -acc $acc -jid $room

snit::widgetadaptor groupcallwindow {
    option -acc -readonly yes
    option -jid -readonly yes

    typevariable Windows {}   ;# "$acc $room" -> window
    typevariable Seq 0        ;# tile widget names, never reused

    variable tiles {}        ;# real JID -> videotile
    variable sessions {}     ;# sid -> real JID
    variable bound {}        ;# real JIDs with a session, whose status calls drives
    variable myNick ""
    variable preview ""      ;# the preview videotile, "" until a stream shows
    variable countVar ""
    variable warningVar ""
    variable cameraOn 1
    variable closeTimer ""

    typemethod show {args} {
        array set opts $args
        set key [list $opts(-acc) [jid norm $opts(-jid)]]
        if {[dict exists $Windows $key]} {
            set w [dict get $Windows $key]
            if {[raise_existing $w]} { return $w }
        }
        set w .groupcall[string map {. _ @ _ / _ { } _} $key]
        dict set Windows $key $w
        return [groupcallwindow $w -acc $opts(-acc) -jid [jid norm $opts(-jid)]]
    }

    constructor args {
        installhull using toplevel
        $self configurelist $args
        wm minsize $win 480 360
        wm title $win "Group call: $options(-jid)"

        ttk::frame $win.head -padding {12 8}
        ttk::label $win.head.room -text $options(-jid) \
            -font {-size 12 -weight bold}
        ttk::label $win.head.count -textvariable [myvar countVar] \
            -foreground gray40
        pack $win.head.room -side left
        pack $win.head.count -side right
        pack $win.head -fill x

        ttk::frame $win.grid -padding 8
        pack $win.grid -expand yes -fill both

        ttk::label $win.warn -textvariable [myvar warningVar] \
            -foreground red -anchor center
        pack $win.warn -fill x

        ttk::frame $win.controls -padding {12 8}
        audiodevicepicker $win.controls.devices
        ttk::checkbutton $win.controls.camera -text "Camera" \
            -variable [myvar cameraOn] -command [mymethod ToggleCamera]
        ttk::button $win.controls.leave \
            -image mate/22x22/actions/call-stop.png \
            -command [mymethod Leave]
        pack $win.controls.devices -side left
        pack $win.controls.camera -side left -padx {16 0}
        pack $win.controls.leave -side right
        pack $win.controls -fill x

        bind $win <Escape> [mymethod Leave]
        wm protocol $win WM_DELETE_WINDOW [mymethod Leave]

        foreach {event method} {
            <Session>    OnSession
            <Left>       OnLeft
            <Warning>    OnWarning
        } {
            ::tacky listen -tag $win groupcall $event \
                -acc $options(-acc) -jid $options(-jid) [mymethod $method]
        }
        foreach event {<Presence> <Unavailable> <NickChanged>} {
            ::tacky listen -tag $win muc $event \
                -acc $options(-acc) -jid $options(-jid) [mymethod Refresh]
        }
        foreach {event method} {
            <Active>       OnSessionActive
            <Ended>        OnSessionEnded
            <Failed>       OnSessionFailed
            <Warning>      OnSessionWarning
            <VideoTrack>   OnVideoTrack
            <VideoEnded>   OnVideoEnded
            <VideoPreview> OnVideoPreview
        } {
            ::tacky listen -tag $win calls $event \
                -acc $options(-acc) [mymethod $method]
        }

        $self Refresh
        ::tacky groupcall list -acc $options(-acc) -tag $win -command [mymethod SeedSessions]
    }

    destructor {
        after cancel $closeTimer
        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}
        set key [list $options(-acc) $options(-jid)]
        if {[dict exists $Windows $key] && [dict get $Windows $key] eq $win} {
            dict unset Windows $key
        }
    }

    # -- participants ---------------------------------------------------------

    # Re-read the room from muc.
    method Refresh {args} {
        ::tacky muc myNick -acc $options(-acc) -jid $options(-jid) \
            -tag $win -command [mymethod RefreshWith]
    }

    method RefreshWith {me} {
        set myNick $me
        ::tacky muc occupants -acc $options(-acc) -jid $options(-jid) \
            -tag $win -command [mymethod Sync]
    }

    # One tile per occupant in the call except us; drop the rest. The count
    # includes us.
    method Sync {occupants} {
        set count 0
        set here {}
        foreach occ $occupants {
            set call [dict get $occ call]
            if {$call eq ""} continue
            if {[dict get $call state] eq "announced"} { incr count }
            set real [dict get $occ jid]
            if {[dict get $occ nick] eq $myNick || $real eq ""} continue
            lappend here $real
            $self Tile $real [dict get $occ nick]
            if {$real ni $bound} {
                $self SetStatus $real [expr {[dict get $call state] eq "preparing"
                    ? "Joining..." : "Waiting..."}]
            }
        }
        dict for {real t} $tiles {
            if {$real in $here} continue
            destroy $t
            dict unset tiles $real
            set bound [lsearch -all -inline -not -exact $bound $real]
        }
        $self Layout
        set countVar "$count in call"
    }

    # The sessions already up when the window opens.
    method SeedSessions {rows} {
        foreach row $rows {
            if {[dict get $row jid] ne $options(-jid)} continue
            dict for {real sid} [dict get $row sessions] {
                $self Bind $real $sid
            }
        }
        ::tacky calls list -acc $options(-acc) -tag $win -command [mymethod SeedStates]
    }

    method SeedStates {rows} {
        foreach row $rows {
            set real [$self PeerOf [dict get $row sid]]
            if {$real eq ""} continue
            $self SetStatus $real [expr {[dict get $row state] eq "active"
                ? "Connected" : "Connecting..."}]
        }
    }

    # The tile for $real, created if needed, labelled $nick.
    method Tile {real nick} {
        if {![dict exists $tiles $real]} {
            set t [videotile $win.grid.t[incr Seq] -name $nick \
                -status "Waiting..."]
            dict set tiles $real $t
            set img [avatarcache track -acc $options(-acc) \
                -jid [jid bare $real] -tag $win \
                -command [list $self OnAvatar $real]]
            $t configure -avatar $img
        } else {
            [dict get $tiles $real] configure -name $nick
        }
        return [dict get $tiles $real]
    }

    # $sid is our session with $real, replacing any earlier one.
    method Bind {real sid} {
        dict for {s r} $sessions {
            if {$r eq $real} { dict unset sessions $s }
        }
        dict set sessions $sid $real
        if {$real ni $bound} { lappend bound $real }
    }

    method OnAvatar {real img} {
        if {[dict exists $tiles $real]} {
            [dict get $tiles $real] configure -avatar $img
        }
    }

    method SetStatus {real text} {
        if {[dict exists $tiles $real]} {
            [dict get $tiles $real] configure -status $text
        }
    }

    method SetStream {real name} {
        if {[dict exists $tiles $real]} {
            [dict get $tiles $real] configure -stream $name
        }
    }

    method PeerOf {sid} {
        if {[dict exists $sessions $sid]} { return [dict get $sessions $sid] }
        return ""
    }

    # Tiles in a near-square grid, the preview last.
    method Layout {} {
        set all [dict values $tiles]
        if {$preview ne ""} { lappend all $preview }
        foreach slave [grid slaves $win.grid] { grid forget $slave }
        set n [llength $all]
        if {$n == 0} return
        set cols [expr {int(ceil(sqrt($n)))}]
        set rows [expr {($n + $cols - 1) / $cols}]
        set i 0
        foreach t $all {
            grid $t -row [expr {$i / $cols}] -column [expr {$i % $cols}] \
                -sticky nsew -padx 4 -pady 4
            incr i
        }
        for {set c 0} {$c < $cols} {incr c} {
            grid columnconfigure $win.grid $c -weight 1 -uniform col
        }
        for {set r 0} {$r < $rows} {incr r} {
            grid rowconfigure $win.grid $r -weight 1 -uniform row
        }
    }

    method OnSession {ev} {
        set real [dict get $ev -peer]
        $self Bind $real [dict get $ev -sid]
        $self SetStatus $real "Connecting..."
    }

    method OnWarning {ev} {
        set warningVar [dict get $ev -reason]
    }

    method OnLeft {ev} {
        set countVar "Ended"
        foreach t [dict values $tiles] { $t configure -stream "" }
        if {$preview ne ""} { $preview configure -stream "" }
        $self CloseAfter 600
    }

    # -- sessions -------------------------------------------------------------------

    method OnSessionActive {ev} {
        $self SetStatus [$self PeerOf [dict get $ev -sid]] "Connected"
    }

    method OnSessionEnded {ev} {
        set real [$self PeerOf [dict get $ev -sid]]
        $self SetStatus $real "Ended"
        $self SetStream $real ""
    }

    method OnSessionFailed {ev} {
        set real [$self PeerOf [dict get $ev -sid]]
        $self SetStatus $real "Failed: [dict get $ev -reason]"
        $self SetStream $real ""
    }

    method OnSessionWarning {ev} {
        set real [$self PeerOf [dict get $ev -sid]]
        if {$real eq ""} return
        $self SetStatus $real [dict get $ev -reason]
    }

    method OnVideoTrack {ev} {
        if {[dict get $ev -direction] ne "incoming"} return
        if {![dict exists $ev -name]} return
        $self SetStream [$self PeerOf [dict get $ev -sid]] [dict get $ev -name]
    }

    method OnVideoEnded {ev} {
        $self SetStream [$self PeerOf [dict get $ev -sid]] ""
    }

    # Any session's preview is our camera; the first one to show is enough.
    method OnVideoPreview {ev} {
        if {[$self PeerOf [dict get $ev -sid]] eq ""} return
        if {![dict exists $ev -name] || [dict get $ev -name] eq ""} return
        if {$preview eq ""} {
            set preview [videotile $win.grid.preview -name "You" -status ""]
            $self Layout
        }
        $preview configure -stream [dict get $ev -name]
    }

    # -- controls ---------------------------------------------------------------

    method ToggleCamera {} {
        ::tacky groupcall setVideo -acc $options(-acc) -jid $options(-jid) \
            -on $cameraOn
    }

    method Leave {} {
        ::tacky groupcall leave -acc $options(-acc) -jid $options(-jid)
        # <Left> may already have run (direct mode) or never come. Running
        # OnLeft twice only re-arms the same close.
        if {[winfo exists $win]} { $self OnLeft {} }
    }

    method CloseAfter {ms} {
        after cancel $closeTimer
        set closeTimer [after $ms [mymethod Close]]
    }

    method Close {} {
        set closeTimer ""
        catch {destroy $win}
    }
}
