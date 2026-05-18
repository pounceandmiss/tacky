# audiodevicepicker — mic + speaker icon buttons with mute, volume, and devices.
#
# Two audiobuttons sit side-by-side (capture, playback). For each:
#   left-click icon  → toggle mute (volume=0 / restore prior level)
#   left-click caret → vertical volume slider popover
#   right-click      → device-selection context menu
#
# State syncs through the backend so sibling pickers in other windows stay
# aligned: ::tacky audio enumerateDevices + getPreferredDevice on init,
# <PreferredDevice> / <Volume> listeners, setPreferredDevice / setVolume on
# user input.
#
# Usage:
#   audiodevicepicker $w.devices

snit::widgetadaptor audiobutton {
    option -kind -readonly yes   ;# capture | playback

    component button
    component caret

    variable currentValue  0     ;# last observed backend volume
    variable lastVolume    1.0   ;# value to restore on unmute
    variable applying      0     ;# guard while we drive the slider externally
    variable popover       ""
    variable devices       {}    ;# list of {name d default d id d}
    variable currentDevice ""    ;# id of preferred device (bound to -variable)

    constructor args {
        installhull using ttk::frame
        $self configurelist $args

        install button using ttk::button $win.icon \
            -style Toolbutton -command [mymethod ToggleMute]
        install caret using ttk::button $win.caret -text "▾" -width 2 \
            -style Toolbutton -command [mymethod OpenPopover]
        grid $button $caret -padx 1 -sticky ns

        foreach w [list $button $caret] {
            bind $w <Button-3> [mymethod PopDeviceMenu %X %Y]
        }

        $self Redraw

        ::tacky audio getVolume -kind $options(-kind) -tag $win \
            -command [mymethod OnInitialVolume]
        ::tacky listen -tag $win audio <Volume> \
            -kind $options(-kind) [mymethod OnVolumeChanged]

        ::tacky audio enumerateDevices -tag $win \
            -command [mymethod OnDevices]
        ::tacky audio getPreferredDevice \
            -kind $options(-kind) -tag $win \
            -command [mymethod OnInitialDevice]
        ::tacky listen -tag $win audio <PreferredDevice> \
            -kind $options(-kind) [mymethod OnDeviceChanged]
    }

    destructor {
        catch {::tacky unlisten $win}
        catch {destroy $popover}
        catch {destroy $win.devmenu}
    }

    # --- mute / volume ---

    method OnInitialVolume {v} {
        set currentValue $v
        if {$v > 0} { set lastVolume $v }
        $self Redraw
    }

    method OnVolumeChanged {ev} {
        set v [dict get $ev -volume]
        set currentValue $v
        if {$v > 0} { set lastVolume $v }
        $self Redraw
        # Mirror external changes into the popover slider, if it's open.
        if {$popover ne "" && [winfo exists $popover.f.scale]} {
            set applying 1
            $popover.f.scale set $v
            set applying 0
        }
    }

    method ToggleMute {} {
        if {$currentValue > 0} {
            ::tacky audio setVolume -kind $options(-kind) -volume 0.0
        } else {
            ::tacky audio setVolume -kind $options(-kind) -volume $lastVolume
        }
    }

    method Redraw {} {
        set muted [expr {$currentValue <= 0}]
        set img [dict get {
            capture-on   mate/22x22/status/microphone-sensitivity-high.png
            capture-off  mate/22x22/status/microphone-sensitivity-muted.png
            playback-on  mate/22x22/status/audio-volume-high.png
            playback-off mate/22x22/status/audio-volume-muted.png
        } "$options(-kind)-[expr {$muted ? {off} : {on}}]"]
        $button configure -image $img
    }

    # --- vertical volume popover ---
    #
    # Borderless transient toplevel anchored below the caret with just a
    # vertical ttk::scale. Global grab funnels button presses here so a click
    # outside the popover closes it (standard Tk popup-menu dismissal).

    method OpenPopover {} {
        if {$popover ne "" && [winfo exists $popover]} {
            destroy $popover
            return
        }
        set popover $win.popover
        toplevel $popover -borderwidth 1 -relief solid
        wm overrideredirect $popover 1
        wm transient $popover [winfo toplevel $win]

        ttk::frame $popover.f -padding 6
        pack $popover.f
        ttk::scale $popover.f.scale \
            -orient vertical -from 1.0 -to 0.0 -length 120 \
            -value $currentValue \
            -command [mymethod OnScale]
        pack $popover.f.scale

        update idletasks
        set x [winfo rootx $caret]
        set y [expr {[winfo rooty $caret] + [winfo height $caret] + 2}]
        wm geometry $popover "+$x+$y"

        grab -global $popover
        focus $popover
        bind $popover <Escape>      [list destroy $popover]
        bind $popover <ButtonPress> [mymethod MaybeClosePopover %X %Y]
        bind $popover <Destroy>     [list catch [list grab release $popover]]
    }

    # ttk::scale fires -command on every pixel of drag; coalesce to 3 decimal
    # places (~0.1%) so we don't spam setVolume. Also skip self-echo while we
    # drive the slider in OnVolumeChanged.
    method OnScale {value} {
        if {$applying} return
        set rounded [format %.3f $value]
        if {$rounded eq [format %.3f $currentValue]} return
        ::tacky audio setVolume -kind $options(-kind) -volume $rounded
    }

    method MaybeClosePopover {X Y} {
        if {![winfo exists $popover]} return
        set x1 [winfo rootx $popover]
        set y1 [winfo rooty $popover]
        set x2 [expr {$x1 + [winfo width $popover]}]
        set y2 [expr {$y1 + [winfo height $popover]}]
        if {$X < $x1 || $X >= $x2 || $Y < $y1 || $Y >= $y2} {
            destroy $popover
        }
    }

    # --- device selection (right-click context menu) ---

    method OnDevices {devs} {
        set devices [dict get $devs $options(-kind)]
    }

    method OnInitialDevice {id} {
        set currentDevice $id
    }

    method OnDeviceChanged {ev} {
        set currentDevice [dict get $ev -id]
    }

    method PopDeviceMenu {X Y} {
        set m $win.devmenu
        if {![winfo exists $m]} { menu $m -tearoff 0 }
        $m delete 0 end
        $m add radiobutton -label "(System default)" \
            -value "" -variable [myvar currentDevice] \
            -command [mymethod SelectDevice ""]
        if {[llength $devices] > 0} { $m add separator }
        foreach entry $devices {
            set name [dict get $entry name]
            if {[dict get $entry default]} { set name "$name (default)" }
            set id [dict get $entry id]
            $m add radiobutton -label $name \
                -value $id -variable [myvar currentDevice] \
                -command [mymethod SelectDevice $id]
        }
        tk_popup $m $X $Y
    }

    method SelectDevice {id} {
        ::tacky audio setPreferredDevice -kind $options(-kind) -id $id
    }
}

# ---------------------------------------------------------------------------

snit::widgetadaptor audiodevicepicker {
    delegate option * to hull

    component micButton
    component spkButton

    constructor args {
        installhull using ttk::frame
        $self configurelist $args
        install micButton using audiobutton $win.mic -kind capture
        install spkButton using audiobutton $win.spk -kind playback
        pack $micButton -side left -padx 6
        pack $spkButton -side left -padx 6
    }
}
