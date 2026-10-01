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
# Also <VideoTrack>/<VideoPreview>/<VideoEnded>: ::rtcmv::view::* connects
# to the frame stream named in the event and updates a photo as frames
# arrive. A host-rendered track has no -name and is skipped.
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

    component stateLabel
    variable statusVar ""
    variable warningVar ""
    variable closeTimer ""

    variable remoteView  ""
    variable remotePhoto ""
    variable previewView  ""
    variable previewPhoto ""

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
        # Close now: a forgotten call never emits <Ended>. Running OnEnded
        # twice only re-arms the same close.
        if {[winfo exists $win]} { $self OnEnded {} }
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

    # Video: ::rtcmv::view::* over the frame stream named in the event.

    method OnVideoTrack {ev} {
        if {[dict get $ev -direction] ne "incoming"} return
        $self StopRemoteVideo
        if {![dict exists $ev -name]} return
        set photo [image create photo]
        if {[catch {::rtcmv::view::open [dict get $ev -name] $photo} view]} {
            image delete $photo
            return
        }
        set remoteView $view
        set remotePhoto $photo
        $win.body.video configure -image $remotePhoto
        pack forget $win.body.avatar
        pack $win.body.video -before $win.body.peer
    }

    method OnVideoPreview {ev} {
        $self StopPreview
        if {![dict exists $ev -name]} return
        set photo [image create photo]
        if {[catch {::rtcmv::view::open [dict get $ev -name] $photo} view]} {
            image delete $photo
            return
        }
        set previewView $view
        set previewPhoto $photo
        $win.body.preview configure -image $previewPhoto
        pack $win.body.preview -after $win.body.video -pady {6 0}
    }

    method OnVideoEnded {ev} {
        $self StopRemoteVideo
        $self StopPreview
    }

    method StopRemoteVideo {} {
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
