# groupcallwindow - a group call in a room: one videotile per participant,
# our own preview, mic/speaker/camera controls, leave. One per room;
# `groupcallwindow show` reuses the open one.
#
# groupcall events add and remove tiles; each leg's calls events drive its
# tile's status and video. Tiles are keyed by nick, legs by sid.
#
# Usage:
#   groupcallwindow show -acc $acc -jid $room

snit::widgetadaptor groupcallwindow {
    option -acc -readonly yes
    option -jid -readonly yes

    typevariable Windows {}   ;# "$acc $room" -> window

    variable tiles {}        ;# nick -> videotile
    variable legs {}         ;# sid -> nick
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
            <PeerJoined> OnPeerJoined
            <PeerLeft>   OnPeerLeft
            <Left>       OnLeft
            <Warning>    OnWarning
            <Changed>    OnChanged
        } {
            ::tacky listen -tag $win groupcall $event \
                -acc $options(-acc) -jid $options(-jid) [mymethod $method]
        }
        foreach {event method} {
            <Active>       OnLegActive
            <Ended>        OnLegEnded
            <Failed>       OnLegFailed
            <Warning>      OnLegWarning
            <VideoTrack>   OnVideoTrack
            <VideoEnded>   OnVideoEnded
            <VideoPreview> OnVideoPreview
        } {
            ::tacky listen -tag $win calls $event \
                -acc $options(-acc) [mymethod $method]
        }

        ::tacky groupcall participants -acc $options(-acc) -jid $options(-jid) \
            -tag $win -command [mymethod Seed]
        ::tacky groupcall status -acc $options(-acc) -jid $options(-jid) \
            -tag $win -command [mymethod OnStatus]
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

    # The call as it stands when the window opens: legs already up, and
    # participants we are waiting on.
    method Seed {participants} {
        foreach p $participants {
            set state [dict get $p state]
            if {$state eq "none"} continue
            set nick [dict get $p nick]
            $self Tile $nick [dict get $p jid] [dict get $p sid]
            switch -- $state {
                active   { set text "Connected" }
                expected { set text "Waiting..." }
                default  { set text "Connecting..." }
            }
            $self SetStatus $nick $text
        }
    }

    method OnStatus {st} {
        set countVar "[dict get $st count] in call"
    }

    method OnChanged {ev} {
        set countVar "[dict get $ev -count] in call"
    }

    # A tile for $nick, created on first sight; $sid (may be "") is bound
    # to it for the leg's calls events.
    method Tile {nick jid sid} {
        if {![dict exists $tiles $nick]} {
            set t [videotile $win.grid.t[dict size $tiles] -name $nick \
                -status "Connecting..."]
            dict set tiles $nick $t
            if {$jid ne ""} {
                set img [avatarcache track -acc $options(-acc) \
                    -jid [jid bare $jid] -tag $win \
                    -command [list $self OnAvatar $nick]]
                $t configure -avatar $img
            }
            $self Layout
        }
        if {$sid ne ""} { dict set legs $sid $nick }
        return [dict get $tiles $nick]
    }

    method OnAvatar {nick img} {
        if {[dict exists $tiles $nick]} {
            [dict get $tiles $nick] configure -avatar $img
        }
    }

    method SetStatus {nick text} {
        if {[dict exists $tiles $nick]} {
            [dict get $tiles $nick] configure -status $text
        }
    }

    method SetStream {nick name} {
        if {[dict exists $tiles $nick]} {
            [dict get $tiles $nick] configure -stream $name
        }
    }

    method NickOf {sid} {
        if {[dict exists $legs $sid]} { return [dict get $legs $sid] }
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

    method OnPeerJoined {ev} {
        set nick [dict get $ev -nick]
        $self Tile $nick [dict get $ev -peer] [dict get $ev -sid]
        $self SetStatus $nick "Connecting..."
    }

    method OnPeerLeft {ev} {
        set nick [dict get $ev -nick]
        set sid [dict get $ev -sid]
        if {$sid ne ""} { dict unset legs $sid }
        if {[dict get $ev -reason] eq "left the call"} {
            if {[dict exists $tiles $nick]} {
                destroy [dict get $tiles $nick]
                dict unset tiles $nick
                $self Layout
            }
            return
        }
        # Still in the call, without a leg: keep the tile and say why.
        $self SetStatus $nick [dict get $ev -reason]
        $self SetStream $nick ""
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

    # -- legs -------------------------------------------------------------------

    method OnLegActive {ev} {
        $self SetStatus [$self NickOf [dict get $ev -sid]] "Connected"
    }

    method OnLegEnded {ev} {
        set nick [$self NickOf [dict get $ev -sid]]
        $self SetStatus $nick "Ended"
        $self SetStream $nick ""
    }

    method OnLegFailed {ev} {
        set nick [$self NickOf [dict get $ev -sid]]
        $self SetStatus $nick "Failed: [dict get $ev -reason]"
        $self SetStream $nick ""
    }

    method OnLegWarning {ev} {
        set nick [$self NickOf [dict get $ev -sid]]
        if {$nick eq ""} return
        $self SetStatus $nick [dict get $ev -reason]
    }

    method OnVideoTrack {ev} {
        if {[dict get $ev -direction] ne "incoming"} return
        if {![dict exists $ev -name]} return
        $self SetStream [$self NickOf [dict get $ev -sid]] [dict get $ev -name]
    }

    method OnVideoEnded {ev} {
        $self SetStream [$self NickOf [dict get $ev -sid]] ""
    }

    # Any leg's preview is our camera; the first one to show is enough.
    method OnVideoPreview {ev} {
        if {[$self NickOf [dict get $ev -sid]] eq ""} return
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
