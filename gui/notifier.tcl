package require snit

# notifier - presents notify <Notify> as a toast in the corner of the screen.
#
# One toast per chat, rewritten in place by the next message rather than stacked
# on. These are Tk toplevels, not desktop notifications, so the notification
# centre and do-not-disturb never see them.
#
# Nothing here watches window focus: the backend gates on the read watermark, so
# a chat being read never alerts, and message <OwnRead> retracts whatever is
# still on screen.
snit::type notifier {
    option -controller -readonly yes

    # {acc jid} -> {win W timer TOKEN timestamp TS command CMD}
    variable Toasts
    # Stacking order, first element nearest the screen corner.
    variable Order

    typevariable Width 330
    typevariable Margin 16
    typevariable Gap 8
    typevariable LifeMs 8000

    typevariable Card    #ffffff
    typevariable Border  #b8b8b8
    typevariable Dim     #666666
    typevariable Accent  #4a76c8
    typevariable Mention #d08b18

    constructor args {
        $self configurelist $args
        set Toasts [dict create]
        set Order [list]
        ::tacky listen -tag $self notify <Notify> [mymethod OnNotify]
        ::tacky listen -tag $self message <OwnRead> [mymethod OnOwnRead]
    }

    destructor {
        catch {::tacky unlisten $self}
        foreach key [dict keys $Toasts] { $self Drop $key }
    }

    method OnNotify {ev} {
        set acc [dict get $ev -acc]
        set jid [dict get $ev -jid]
        $self post -key [list $acc $jid] \
            -title [dict get $ev -nick] \
            -subtitle [BareChat $jid] \
            -body [dict get $ev -body] \
            -count [dict get $ev -unread] \
            -mention [dict get $ev -mention] \
            -timestamp [dict get $ev -timestamp] \
            -command [list $options(-controller) OpenChatFor $acc $jid]
    }

    # Reading the chat - here or on another device - takes the alert down. A
    # watermark behind the message we announced leaves it up.
    method OnOwnRead {ev} {
        set key [list [dict get $ev -acc] [dict get $ev -jid]]
        if {![dict exists $Toasts $key]} return
        if {[dict get $ev -timestamp] < [dict get $Toasts $key timestamp]} return
        $self Dismiss $key
    }

    # Show an alert, or refresh the one already up for that chat.
    method post {args} {
        set opts [dict merge {-title "" -subtitle "" -body "" -count 0 \
            -mention 0 -timestamp 0 -command ""} $args]
        set key [dict get $opts -key]
        if {![dict exists $Toasts $key]} {
            $self Create $key
            lappend Order $key
        }
        $self Fill $key $opts
        dict set Toasts $key timestamp [dict get $opts -timestamp]
        dict set Toasts $key command [dict get $opts -command]
        $self Arm $key
        $self Layout
    }

    method Create {key} {
        lassign $key acc jid
        set w [WindowPath $key]
        toplevel $w -background $Border
        wm overrideredirect $w 1
        catch {wm attributes $w -type notification}
        catch {wm attributes $w -topmost 1}
        # Parked off the corner until Layout has a height to place it by.
        wm geometry $w +[winfo screenwidth .]+[winfo screenheight .]

        frame $w.stripe -width 4 -background $Accent
        pack $w.stripe -side left -fill y -padx {1 0} -pady 1
        frame $w.c -background $Card -padx 10 -pady 8
        pack $w.c -side left -fill both -expand yes -padx {0 1} -pady 1

        label $w.c.icon -background $Card -image [avatarcache default]
        label $w.c.title -background $Card -anchor w -font {-weight bold}
        label $w.c.count -background $Card -foreground $Dim -anchor e
        label $w.c.close -background $Card -cursor hand2 \
            -image mate/16x16/actions/window-close.png
        label $w.c.sub -background $Card -foreground $Dim -anchor w
        message $w.c.body -background $Card -anchor w -justify left \
            -width [expr {$Width - 70}]

        grid $w.c.icon  -row 0 -column 0 -rowspan 3 -sticky n -padx {0 8}
        grid $w.c.title -row 0 -column 1 -sticky ew
        grid $w.c.count -row 0 -column 2 -sticky e -padx {6 0}
        grid $w.c.close -row 0 -column 3 -sticky ne -padx {6 0}
        grid $w.c.sub   -row 1 -column 1 -columnspan 3 -sticky ew
        grid columnconfigure $w.c 1 -weight 1

        bind $w.c.close <Button-1> [mymethod Dismiss $key]
        foreach child [list $w.c $w.c.icon $w.c.title $w.c.count $w.c.sub \
                            $w.c.body] {
            bind $child <Button-1> [mymethod Activate $key]
            $child configure -cursor hand2
        }

        dict set Toasts $key [dict create win $w timer ""]
        $w.c.icon configure -image [avatarcache track \
            -acc $acc -jid [BareChat $jid] -tag $w \
            -command [mymethod OnAvatar $key]]
    }

    method Fill {key opts} {
        set w [dict get $Toasts $key win]
        $w.c.title configure -text [dict get $opts -title]
        $w.c.sub configure -text [dict get $opts -subtitle]
        $w.c.count configure -text [CountLabel [dict get $opts -count]]
        $w.stripe configure -background \
            [expr {[dict get $opts -mention] ? $Mention : $Accent}]
        set body [Preview [dict get $opts -body]]
        if {$body eq ""} {
            grid remove $w.c.body
        } else {
            $w.c.body configure -text $body
            grid $w.c.body -row 2 -column 1 -columnspan 3 -sticky ew -pady {2 0}
        }
    }

    method OnAvatar {key img} {
        if {![dict exists $Toasts $key]} return
        [dict get $Toasts $key win].c.icon configure -image $img
    }

    method Arm {key} {
        after cancel [dict get $Toasts $key timer]
        dict set Toasts $key timer [after $LifeMs [mymethod Dismiss $key]]
    }

    method Activate {key} {
        set command [dict get $Toasts $key command]
        $self Dismiss $key
        if {$command ne ""} { {*}$command }
    }

    method Dismiss {key} {
        $self Drop $key
        $self Layout
    }

    method Drop {key} {
        if {![dict exists $Toasts $key]} return
        set win [dict get $Toasts $key win]
        after cancel [dict get $Toasts $key timer]
        catch {avatarcache untrack -tag $win}
        destroy $win
        dict unset Toasts $key
        set idx [lsearch -exact $Order $key]
        set Order [lreplace $Order $idx $idx]
    }

    # Stacked up from the bottom-right corner, so dismissing one out of order
    # closes the gap it leaves.
    method Layout {} {
        update idletasks
        set x [expr {[winfo screenwidth .] - $Width - $Margin}]
        set y [expr {[winfo screenheight .] - $Margin}]
        foreach key $Order {
            set w [dict get $Toasts $key win]
            set h [winfo reqheight $w]
            incr y -$h
            wm geometry $w ${Width}x${h}+${x}+${y}
            incr y -$Gap
        }
    }

    method windowOf {key} {
        if {![dict exists $Toasts $key]} { return "" }
        return [dict get $Toasts $key win]
    }

    method keys {} { return $Order }

    proc WindowPath {key} {
        return .toast_[string map {@ _ . _ / _ ? _} [join $key _]]
    }

    # A chat jid carries ?join for a room; neither the avatar nor the label
    # wants it.
    proc BareChat {jid} {
        return [regsub {\?join$} $jid ""]
    }

    proc CountLabel {n} {
        return [expr {$n > 1 ? "($n)" : ""}]
    }

    # One line of the message; the rest is in the chat.
    proc Preview {text {limit 140}} {
        set text [string trim [regsub -all {\s+} $text " "]]
        if {[string length $text] <= $limit} { return $text }
        return "[string range $text 0 [expr {$limit - 1}]]..."
    }
}
