# omemoownkeys - this account's own device keys under the account-wide
# blind-trust toggle. Both the OMEMO keys window and the profile settings offer
# exactly this section; the embedder supplies the heading around it.
#
# Usage:
#   omemoownkeys $f.mine -acc romeo@montague.lit

package require snit

snit::widget omemoownkeys {
    hulltype ttk::frame

    option -acc -readonly yes

    variable blindTrust 0

    constructor args {
        $self configurelist $args

        ttk::checkbutton $win.bt \
            -text "Trust new devices automatically (blind trust, account-wide)" \
            -variable [myvar blindTrust] -command [mymethod ToggleBlindTrust]
        omemokeyspanel $win.keys \
            -acc $options(-acc) -jid [jid bare $options(-acc)]
        pack $win.bt -anchor w -pady {0 4}
        pack $win.keys -fill both -expand yes

        ::tacky observe -tag $win omemo <BlindTrust> -acc $options(-acc) \
            [mymethod OnBlindTrust]
    }

    destructor {
        catch {::tacky unlisten $win}
    }

    method OnBlindTrust {ev} { set blindTrust [dict get $ev -value] }

    method ToggleBlindTrust {} {
        ::tacky omemo setBlindTrust -acc $options(-acc) -value $blindTrust
    }
}
