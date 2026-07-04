if 0 {
    accountpanel - per-account container wrapping a chatlistview.

    Created by accountwindow as the per-window account view.

    Layout:
        ┌─────────────────────┐
        │ profilebar          │  pack -fill x
        ├─────────────────────┤
        │ chatlistview        │  pack -fill both -expand yes
        └─────────────────────┘

    Usage:
        accountpanel .panel -account romeo@montague.lit
}

snit::widget accountpanel {
    hulltype ttk::frame

    option -account -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -open-chat-command -default ""
    option -new-chat-command -default ""
    option -menubar -default "" -readonly yes

    delegate option -width to hull
    delegate option -height to hull

    constructor args {
        $self configurelist $args

        if {$options(-account) eq ""} {
            error "accountpanel requires -account"
        }

        profilebar $win.profile \
            -acc $options(-account) \
            -tacky $options(-tacky) \
            -command [list profilesettings open $options(-account)]
        pack $win.profile -fill x

        chatlistview $win.clv \
            -acc $options(-account) \
            -tacky $options(-tacky) \
            -open-chat-command $options(-open-chat-command) \
            -new-chat-command $options(-new-chat-command)
        pack $win.clv -fill both -expand yes
    }
}
