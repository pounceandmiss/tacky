snit::widgetadaptor chatwindow {
    option -acc -readonly yes
    option -jid -readonly yes

    typemethod open {w args} {
        if {[winfo exists $w]} {
            wm deiconify $w
            raise $w
            return $w
        }
        return [chatwindow $w {*}$args]
    }

    constructor args {
        installhull using toplevel
        $self configurelist $args
        wm title $win "Chat with $options(-jid)"

        # Menubar
        menu $win.menubar -tearoff 0
        menu $win.menubar.file -tearoff 0
        $win.menubar.file add command -label "MAM Info..." \
            -command [list maminfo open $options(-acc) -target $options(-jid)]
        $win.menubar.file add separator
        $win.menubar.file add command -label "Close" \
            -command [list destroy $win] -accelerator "Ctrl+W"
        $win.menubar add cascade -label "File" -menu $win.menubar.file
        $hull configure -menu $win.menubar
        bind $win <Control-w> [list destroy $win]
        bind $win <Control-W> [list destroy $win]

        # Chat widgets
        chatpanel $win.cp -acc $options(-acc) -jid $options(-jid) \
            -menubar $win.menubar
        pack $win.cp -expand yes -fill both
    }
}
