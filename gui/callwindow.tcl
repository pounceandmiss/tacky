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
# Also <VideoTrack>/<VideoPreview>/<VideoEnded>: renders the named shm
# ring via ::rtcmv::view::* on an `after` poll. -name is empty on
# Android (no shm path here yet), so those tracks are skipped.
#
# Usage:
#   callwindow show -acc $acc -sid $sid -peer $jid -direction outgoing
#
# Direction is informational (labels only). Hangup works in any state — the
# backend distinguishes proposed/ringing/active and emits the right stanza.

package require rtcmv_tk

snit::widgetadaptor callwindow {
    option -acc
    option -sid
    option -peer
    option -direction -default outgoing

    # ~30fps; faster just burns idle CPU re-checking for a new frame.
    typevariable VIDEO_POLL_MS 33

    component stateLabel
    variable statusVar ""
    variable warningVar ""
    variable closeTimer ""

    variable remoteView  ""
    variable remotePhoto ""
    variable remoteTimer ""
    variable previewView  ""
    variable previewPhoto ""
    variable previewTimer ""

    # Single global entry point. Creates the window on first call; on
    # subsequent calls it reuses the existing toplevel via Reset (new sid,
    # new peer, freshly bound listeners) so we never have two call windows
    # competing for attention.
    typemethod show {args} {
        set w .callwindow
        if {[raise_existing $w]} {
            $w Reset {*}$args
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
        # Video/preview: left unpacked until an event actually shows one.
        ttk::label $win.body.video -anchor center
        ttk::label $win.body.preview -anchor center \
            -relief solid -borderwidth 1
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
        after cancel $closeTimer
        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}
        $self StopRemoteVideo
        $self StopPreview
    }

    # Apply new call parameters and wipe transient state. Used by the
    # constructor for first wiring and by show on each subsequent call so a
    # retried/incoming call lands in the same window.
    method Reset args {
        $self configurelist $args

        after cancel $closeTimer
        set closeTimer ""
        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}
        $self StopRemoteVideo
        $self StopPreview

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
            <Ringing>       OnRinging
            <Active>        OnActive
            <Ended>         OnEnded
            <Failed>        OnFailed
            <Warning>       OnWarning
            <VideoTrack>    OnVideoTrack
            <VideoPreview>  OnVideoPreview
            <VideoEnded>    OnVideoEnded
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
        # <Ended> closes us; this only fires if the backend never sends one.
        if {[winfo exists $win]} { $self CloseAfter 3000 }
    }

    # One pending close at a time: a stale timer would outlive the window and
    # close the next call that reuses it.
    method CloseAfter {ms} {
        after cancel $closeTimer
        set closeTimer [after $ms [mymethod Close]]
    }

    method Close {} {
        set closeTimer ""
        catch {destroy $win}
    }

    method OnRinging {ev} { set statusVar "Ringing..." }
    method OnActive  {ev} { set statusVar "Connected"  }

    method OnEnded {ev} {
        set statusVar "Ended"
        $self StopRemoteVideo
        $self StopPreview
        $self CloseAfter 600
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

    # -- video: ::rtcmv::view::* over the shm ring named in the event -----

    method OnVideoTrack {ev} {
        if {[dict get $ev -direction] ne "incoming"} return
        $self StopRemoteVideo
        set name [dict get $ev -name]
        if {$name eq ""} return
        if {[catch {::rtcmv::view::open $name} view]} return
        set remoteView $view
        set remotePhoto [image create photo]
        $win.body.video configure -image $remotePhoto
        pack forget $win.body.avatar
        pack $win.body.video -before $win.body.peer
        $self PumpRemoteVideo
    }

    method OnVideoPreview {ev} {
        $self StopPreview
        set name [dict get $ev -name]
        if {$name eq ""} return
        if {[catch {::rtcmv::view::open $name} view]} return
        set previewView $view
        set previewPhoto [image create photo]
        $win.body.preview configure -image $previewPhoto
        pack $win.body.preview -after $win.body.video -pady {6 0}
        $self PumpPreview
    }

    method OnVideoEnded {ev} {
        $self StopRemoteVideo
        $self StopPreview
    }

    method PumpRemoteVideo {} {
        catch {::rtcmv::view::update $remoteView $remotePhoto}
        set remoteTimer [after $VIDEO_POLL_MS [mymethod PumpRemoteVideo]]
    }

    method PumpPreview {} {
        catch {::rtcmv::view::update $previewView $previewPhoto}
        set previewTimer [after $VIDEO_POLL_MS [mymethod PumpPreview]]
    }

    method StopRemoteVideo {} {
        after cancel $remoteTimer
        set remoteTimer ""
        if {$remoteView ne ""} {
            catch {::rtcmv::view::close $remoteView}
            set remoteView ""
        }
        if {$remotePhoto ne ""} {
            catch {image delete $remotePhoto}
            set remotePhoto ""
        }
        catch {
            pack forget $win.body.video
            pack $win.body.avatar -before $win.body.peer
        }
    }

    method StopPreview {} {
        after cancel $previewTimer
        set previewTimer ""
        if {$previewView ne ""} {
            catch {::rtcmv::view::close $previewView}
            set previewView ""
        }
        if {$previewPhoto ne ""} {
            catch {image delete $previewPhoto}
            set previewPhoto ""
        }
        catch { pack forget $win.body.preview }
    }
}
