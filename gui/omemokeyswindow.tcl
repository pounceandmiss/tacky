# omemokeyswindow - per-account OMEMO fingerprint viewer.
#
# One window per account (see the `open` typemethod): it stacks this
# account's own device keys (omemokeyspanel for the bare account jid) under
# an account-wide blind-trust toggle, plus a "Their keys" panel that is
# re-pointed to whichever peer the window was last opened for. The panels
# own all the fingerprint/trust rendering; this window just composes them.
#
# Usage:
#   omemokeyswindow open romeo@montague.lit juliet@capulet.lit

package require snit

snit::widget omemokeyswindow {
    hulltype toplevel

    option -acc -readonly yes
    option -jid -default "" -configuremethod SetJid

    variable blindTrust 0

    # One window per account; create it, or raise the existing one and
    # re-point its peer panel to $jid.
    typemethod open {acc jid} {
        set w .omemokeys_[string map {@ _ . _ / _} $acc]
        if {[winfo exists $w]} {
            $w configure -jid $jid
            wm deiconify $w
            raise $w
            return $w
        }
        return [omemokeyswindow $w -acc $acc -jid $jid]
    }

    constructor args {
        $self configurelist $args

        ttk::checkbutton $win.bt \
            -text "Trust new devices automatically (blind trust)" \
            -variable [myvar blindTrust] -command [mymethod ToggleBlindTrust]
        ttk::button $win.close -text "Close" -command [list destroy $win]

        ttk::label $win.mylbl -text "My keys" -font {Helvetica 12 bold}
        omemokeyspanel $win.mine \
            -acc $options(-acc) -jid [jid bare $options(-acc)]
        ttk::label $win.theirlbl -text "Their keys" -font {Helvetica 12 bold}

        pack $win.bt -anchor w -padx 8 -pady {8 4}
        pack $win.close -side bottom -pady 6
        pack $win.mylbl -anchor w -padx 8 -pady {6 2}
        pack $win.mine -fill both -expand yes -padx 8
        pack $win.theirlbl -anchor w -padx 8 -pady {6 2}
        $self BuildPeer

        ::tacky observe -tag $win omemo <BlindTrust> -acc $options(-acc) \
            [mymethod OnBlindTrust]
    }

    destructor {
        catch {::tacky unlisten $win}
    }

    # Re-point the peer panel when -jid changes (skipped during the initial
    # configurelist, before the widgets exist; the constructor builds it).
    method SetJid {option value} {
        set options($option) $value
        if {[winfo exists $win.theirlbl]} { $self BuildPeer }
    }

    method BuildPeer {} {
        catch {destroy $win.theirs}
        wm title $win "OMEMO Keys - [jid bare $options(-jid)]"
        omemokeyspanel $win.theirs \
            -acc $options(-acc) -jid $options(-jid)
        pack $win.theirs -after $win.theirlbl -fill both -expand yes \
            -padx 8 -pady {0 4}
    }

    method OnBlindTrust {ev} { set blindTrust [dict get $ev -value] }

    method ToggleBlindTrust {} {
        ::tacky omemo setBlindTrust -value $blindTrust
    }
}
