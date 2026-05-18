# callwindow — single-instance toplevel for the current call.
#
# Lives as a singleton at .callwindow. Use `callwindow show` (not the
# constructor directly) to bring it up; if a previous call's window is
# still around (e.g. left visible after a Failed retry), show rewires it
# in-place to the new -acc/-sid/-peer rather than spawning a second window.
#
# Listens to calls <Ringing>/<Active>/<Ended>/<Failed>/<Warning> filtered
# by sid: transitions the status label, surfaces non-fatal warnings,
# self-destructs on <Ended>, and on <Failed> stays open with the hangup
# button swapped for a green call-start "call again" button.
#
# Usage:
#   callwindow show -acc $acc -sid $sid -peer $jid -direction outgoing
#
# Direction is informational (labels only). Hangup works in any state — the
# backend distinguishes proposed/ringing/active and emits the right stanza.

snit::widgetadaptor callwindow {
    option -acc
    option -sid
    option -peer
    option -direction -default outgoing

    component stateLabel
    variable statusVar ""
    variable warningVar ""

    # Single global entry point. Creates the window on first call; on
    # subsequent calls it reuses the existing toplevel via Reset (new sid,
    # new peer, freshly bound listeners) so we never have two call windows
    # competing for attention.
    typemethod show {args} {
        set w .callwindow
        if {[winfo exists $w]} {
            $w Reset {*}$args
            wm deiconify $w
            raise $w
            return $w
        }
        return [callwindow $w {*}$args]
    }

    constructor args {
        installhull using toplevel
        wm minsize $win 360 200

        ttk::frame $win.body -padding 12
        pack $win.body -expand yes -fill both

        ttk::label $win.body.avatar -padding 4 -anchor center
        ttk::label $win.body.peer \
            -font {-size 14 -weight bold} -anchor center
        install stateLabel using ttk::label $win.body.status \
            -textvariable [myvar statusVar] \
            -anchor center -foreground gray40
        ttk::label $win.body.warn \
            -textvariable [myvar warningVar] \
            -foreground red -anchor center

        pack $win.body.avatar
        pack $win.body.peer   -fill x
        pack $win.body.status -fill x -pady {2 0}
        pack $win.body.warn   -fill x -pady {4 0}

        ttk::frame $win.controls
        audiodevicepicker $win.controls.devices
        ttk::button $win.controls.hangup -command [mymethod Hangup]
        pack $win.controls.devices -side left
        pack $win.controls.hangup  -side left -padx {16 0}
        pack $win.controls -anchor center

        bind $win <Escape> [mymethod Hangup]
        wm protocol $win WM_DELETE_WINDOW [mymethod Hangup]

        $self Reset {*}$args
    }

    destructor {
        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}
    }

    # Apply new call parameters and wipe transient state. Used by the
    # constructor for first wiring and by show on each subsequent call so a
    # retried/incoming call lands in the same window.
    method Reset args {
        $self configurelist $args

        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}

        set warningVar ""
        set statusVar [expr {
            $options(-direction) eq "outgoing" ? "Calling..." : "Connecting..."
        }]

        wm title $win "Call — $options(-peer)"
        $win.body.peer configure -text $options(-peer)

        set img [avatarcache track \
            -acc $options(-acc) -jid [jid bare $options(-peer)] -tag $win \
            -command [mymethod OnAvatar]]
        $win.body.avatar configure -image $img

        $win.controls.hangup configure \
            -image mate/22x22/actions/call-stop.png \
            -command [mymethod Hangup]

        foreach {event method} {
            <Ringing> OnRinging
            <Active>  OnActive
            <Ended>   OnEnded
            <Failed>  OnFailed
            <Warning> OnWarning
        } {
            ::tacky listen -tag $win calls $event \
                -acc $options(-acc) -sid $options(-sid) \
                [mymethod $method]
        }
    }

    method OnAvatar {img} {
        $win.body.avatar configure -image $img
    }

    method Hangup {} {
        ::tacky calls hangup -acc $options(-acc) -sid $options(-sid)
        # If the backend has already ended the call (e.g. peer-initiated
        # terminate beat us here), <Ended> already fired and the window
        # is destroyed. Otherwise let the <Ended> handler close us.
        # Belt-and-braces: ensure we always go away.
        if {[winfo exists $win]} {
            after 100 [list catch [list destroy $win]]
        }
    }

    method OnRinging {ev} { set statusVar "Ringing..." }
    method OnActive  {ev} { set statusVar "Connected"  }

    method OnEnded {ev} {
        set statusVar "Ended"
        after 600 [list catch [list destroy $win]]
    }

    method OnFailed {ev} {
        set reason [dict get $ev -reason]
        set statusVar "Failed: $reason"
        # Stay open and offer a retry. The new outgoing call will land
        # right here via app.tcl's <Outgoing> handler calling `show` again.
        $win.controls.hangup configure \
            -image mate/22x22/actions/call-start.png \
            -command [mymethod CallAgain]
    }

    method CallAgain {} {
        ::tacky calls start -acc $options(-acc) \
            -to [jid bare $options(-peer)]
    }

    method OnWarning {ev} {
        set warningVar [dict get $ev -reason]
    }
}
