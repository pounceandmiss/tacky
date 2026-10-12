# groupcallwindow - a group call in a room: one videotile per participant,
# our own preview, mic/speaker/camera controls, leave. One per room;
# `groupcallwindow show` reuses the open one.
#
# Drawn from groupcall <State>: a tile per participant plus our preview,
# keyed by real JID (or /nick where the room hides it).
#
# Usage:
#   groupcallwindow show -acc $acc -jid $room

snit::widgetadaptor groupcallwindow {
    option -acc -readonly yes
    option -jid -readonly yes

    typevariable Windows {}   ;# "$acc $room" -> window
    typevariable Seq 0        ;# tile widget names, never reused

    variable tiles {}        ;# real JID, or /nick, -> videotile
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

        ::tacky observe -tag $win groupcall <State> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnState]
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

    # -- the call ---------------------------------------------------------------

    method OnState {ev} {
        if {[dict get $ev -phase] eq "ended"} {
            $self OnLeft $ev
            return
        }
        set countVar "[dict get $ev -count] in call"
        set warningVar [dict get $ev -warning]
        set cameraOn [dict get $ev -camera]
        set here {}
        foreach p [dict get $ev -participants] {
            set jid [dict get $p jid]
            set key [expr {$jid eq "" ? "/[dict get $p nick]" : $jid}]
            lappend here $key
            set t [$self Tile $key [dict get $p nick] $jid]
            $t configure -status [$self StatusOf $p] -stream [dict get $p stream]
        }
        dict for {key t} $tiles {
            if {$key in $here} continue
            destroy $t
            dict unset tiles $key
        }
        $self ShowPreview [expr {[dict exists $ev -preview name]
            ? [dict get $ev -preview name] : ""}]
        $self Layout
    }

    method StatusOf {p} {
        switch -- [dict get $p leg] {
            expected   { return [expr {[dict get $p joined] ? "Waiting..." : "Joining..."}] }
            connecting { return "Connecting..." }
            active {
                set warning [dict get $p warning]
                return [expr {$warning eq "" ? "Connected" : $warning}]
            }
            ended      { return "Ended" }
            failed     { return "Failed: [dict get $p reason]" }
        }
        return ""
    }

    method ShowPreview {name} {
        if {$name eq ""} {
            if {$preview ne ""} { $preview configure -stream "" }
            return
        }
        if {$preview eq ""} {
            set preview [videotile $win.grid.preview -name "You" -status ""]
        }
        $preview configure -stream $name
    }

    # $jid is "" when the room hides it: no avatar then.
    method Tile {key nick jid} {
        if {![dict exists $tiles $key]} {
            set t [videotile $win.grid.t[incr Seq] -name $nick \
                -status "Waiting..."]
            dict set tiles $key $t
            if {$jid ne ""} {
                set img [avatarcache track -acc $options(-acc) \
                    -jid $jid -tag $win \
                    -command [list $self OnAvatar $key]]
                $t configure -avatar $img
            }
        } else {
            [dict get $tiles $key] configure -name $nick
        }
        return [dict get $tiles $key]
    }

    method OnAvatar {key img} {
        if {[dict exists $tiles $key]} {
            [dict get $tiles $key] configure -avatar $img
        }
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

    method OnLeft {ev} {
        set countVar "Ended"
        foreach t [dict values $tiles] { $t configure -stream "" }
        if {$preview ne ""} { $preview configure -stream "" }
        $self CloseAfter 600
    }

    # -- controls ---------------------------------------------------------------

    method ToggleCamera {} {
        ::tacky groupcall setVideo -acc $options(-acc) -jid $options(-jid) \
            -on $cameraOn
    }

    method Leave {} {
        ::tacky groupcall leave -acc $options(-acc) -jid $options(-jid)
        # The ended <State> may have come already, or never will; a second
        # OnLeft only re-arms the close.
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
