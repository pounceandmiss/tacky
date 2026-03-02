if 0 {
    accountpanel - per-account container wrapping a chatlistview.

    Created by accountnotebook for each enabled account tab.

    Layout:
        ┌─────────────────────┐
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
    option -open-bookmark-command -default ""
    option -menubar -default "" -readonly yes

    constructor args {
	$self configurelist $args

	if {$options(-account) eq ""} {
	    error "accountpanel requires -account"
	}

	chatlistview $win.clv \
	    -acc $options(-account) \
	    -tacky $options(-tacky) \
	    -open-chat-command $options(-open-chat-command) \
	    -open-bookmark-command $options(-open-bookmark-command) \
	    -menubar $options(-menubar)
	pack $win.clv -fill both -expand yes
    }
}
