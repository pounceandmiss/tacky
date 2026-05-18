# incomingcalldialog — popup shown on calls <Incoming>.
#
# Shows the caller JID and offers Accept / Reject. Accept opens a callwindow
# tracking the same sid; reject sends <message><reject/></message> back via
# the calls module. Self-destructs if the caller retracts before we choose
# (an <Ended> for the same sid arrives) or if another of our devices
# answered first.
#
# Usage:
#   incomingcalldialog open -acc $acc -sid $sid -from $jid

snit::widgetadaptor incomingcalldialog {
    option -acc -readonly yes
    option -sid -readonly yes
    option -from -readonly yes

    typemethod open {args} {
        array set opts $args
        set safe [string map {@ _ . _ / _ : _} $opts(-sid)]
        set w .incomingcall_$safe
        if {[winfo exists $w]} {
            wm deiconify $w
            raise $w
            return $w
        }
        return [incomingcalldialog $w {*}$args]
    }

    constructor args {
        installhull using toplevel
        $self configurelist $args
        wm title $win "Incoming Call"
        wm minsize $win 320 120

        ttk::frame $win.body -padding 16
        ttk::label $win.body.avatar -padding 4 -anchor center \
            -image [avatarcache default]
        ttk::label $win.body.msg -text "Incoming call from" -anchor center
        ttk::label $win.body.peer -text $options(-from) \
            -font {-weight bold} -anchor center
        pack $win.body.avatar -anchor center
        pack $win.body.msg -fill x -pady {8 0}
        pack $win.body.peer -fill x -pady {4 0}
        pack $win.body -fill both -expand yes

        set img [avatarcache track \
            -acc $options(-acc) -jid [jid bare $options(-from)] -tag $win \
            -command [mymethod OnAvatar]]
        $win.body.avatar configure -image $img

        ttk::frame $win.btns -padding {16 0 16 16}
        ttk::button $win.btns.accept \
            -image mate/22x22/actions/call-start.png \
            -command [mymethod Accept]
        ttk::button $win.btns.reject \
            -image mate/22x22/actions/call-stop.png \
            -command [mymethod Reject]
        pack $win.btns.accept -side left -padx {0 6} -expand yes
        pack $win.btns.reject -side left -padx {6 0} -expand yes
        pack $win.btns -fill x

        # Caller retracts, or another device takes it → backend emits
        # <Ended> (or <Failed> on hard error) for this sid. Tear the
        # dialog down silently.
        foreach event {<Ended> <Failed>} {
            ::tacky listen -tag $win calls $event \
                -acc $options(-acc) -sid $options(-sid) \
                [mymethod OnTerminal]
        }

        bind $win <Escape> [mymethod Reject]
        wm protocol $win WM_DELETE_WINDOW [mymethod Reject]

        raise $win
        focus $win.btns.accept
    }

    destructor {
        catch {::tacky unlisten $win}
        catch {avatarcache untrack -tag $win}
    }

    method OnAvatar {img} {
        $win.body.avatar configure -image $img
    }

    method Accept {} {
        ::tacky calls accept -acc $options(-acc) -sid $options(-sid)
        callwindow show \
            -acc $options(-acc) -sid $options(-sid) \
            -peer $options(-from) -direction incoming
        destroy $win
    }

    method Reject {} {
        ::tacky calls reject -acc $options(-acc) -sid $options(-sid)
        destroy $win
    }

    method OnTerminal {ev} {
        catch {destroy $win}
    }
}
