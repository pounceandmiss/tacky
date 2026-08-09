package require snit

# Overlays placed over the chat text widget.

# Scroll-to-bottom button overlay.
snit::widgetadaptor chatscrollbtn {
    option -parent -readonly yes
    delegate option -command to hull
    delegate method * to hull

    variable Visible 0

    constructor args {
        installhull using ttk::button \
            -image mate/22x22/actions/go-down -style Toolbutton
        $self configurelist $args

        # Wheel events on the button are forwarded to the text widget
        # so the user can keep scrolling if the cursor comes over it.
        bind $win <Button-4> \
            [list event generate $options(-parent) <Button-4>]
        bind $win <Button-5> \
            [list event generate $options(-parent) <Button-5>]
        bind $win <MouseWheel> \
            [list event generate $options(-parent) <MouseWheel> -delta %D]
    }

    method show {} {
        if {$Visible} return
        set Visible 1
        place $win -in $options(-parent) \
            -relx 1.0 -rely 1.0 -anchor se -x -24 -y -8
        raise $win
    }

    method hide {} {
        if {!$Visible} return
        set Visible 0
        place forget $win
    }
}

# Overlay strip with an optional Cancel button - cancellable for requests
# the view owns (goto), not for a backend sync.
snit::widget chatloading {
    hulltype ttk::frame
    component cancel
    option -parent -readonly yes
    option -text -default "Loading…" -configuremethod SetText
    option -cancellable -default 1 -configuremethod SetCancellable
    delegate option -cancel-command to cancel as -command

    constructor args {
        ttk::label $win.lbl -text "Loading…"
        install cancel using ttk::button $win.cancel \
            -text "Cancel" -style Toolbutton
        pack $win.lbl -side left -padx 4
        $self configurelist $args
        if {$options(-cancellable)} { pack $win.cancel -side left -padx 4 }
    }

    method SetText {opt val} {
        set options($opt) $val
        $win.lbl configure -text $val
    }

    method SetCancellable {opt val} {
        set options($opt) $val
        if {$val} {
            pack $win.cancel -side left -padx 4
        } else {
            pack forget $win.cancel
        }
    }

    method show {} {
        place $win -in $options(-parent) -relx 0.5 -y 8 -anchor n
    }

    method hide {} {
        place forget $win
    }
}
