# omemokeyswindow - per-account OMEMO fingerprint viewer.
#
# One window per account (see the `open` typemethod): it stacks this account's
# own keys section (omemoownkeys) over a "Their keys" panel that is re-pointed
# to whichever peer the window was last opened for. The panels own all the
# fingerprint/trust rendering; this window just composes them.
#
# Usage:
#   omemokeyswindow open romeo@montague.lit juliet@capulet.lit ?fingerprint? ?note?

package require snit

snit::widget omemokeyswindow {
    hulltype toplevel

    option -acc -readonly yes
    option -jid -default "" -configuremethod SetJid
    option -highlight -default ""
    option -highlightnote -default "message origin"

    # One window per account; create it, or raise the existing one and
    # re-point its peer panel to $jid. $highlight is set first because
    # configuring -jid is what rebuilds that panel.
    typemethod open {acc jid {highlight ""} {note "message origin"}} {
        set w .omemokeys_[path_safe $acc]
        if {[raise_existing $w]} {
            $w configure -highlight $highlight -highlightnote $note
            $w configure -jid $jid
            return $w
        }
        return [omemokeyswindow $w -acc $acc -highlight $highlight \
            -highlightnote $note -jid $jid]
    }

    constructor args {
        $self configurelist $args

        ttk::button $win.close -text "Close" -command [list destroy $win]

        ttk::label $win.mylbl -text "My keys" -font {Helvetica 12 bold}
        omemoownkeys $win.mine -acc $options(-acc)
        ttk::label $win.theirlbl -text "Their keys" -font {Helvetica 12 bold}

        pack $win.close -side bottom -pady 6
        pack $win.mylbl -anchor w -padx 8 -pady {8 2}
        pack $win.mine -fill both -expand yes -padx 8
        pack $win.theirlbl -anchor w -padx 8 -pady {6 2}
        $self BuildPeer
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
            -acc $options(-acc) -jid $options(-jid) \
            -highlight $options(-highlight) \
            -highlightnote $options(-highlightnote)
        pack $win.theirs -after $win.theirlbl -fill both -expand yes \
            -padx 8 -pady {0 4}
    }
}
