package require snit

# A strip above the composer: optional leading icon, a body the caller fills,
# and a close button. Reply, edit and find all wear one.
#
# The caller packs and unpacks it; chatpanel::ShowBanner owns that, along with
# freezing the pane so a banner shrinks the chat view instead of growing the
# window.
#
# Usage:
#   composerbanner $f.replybar -icon mate/16x16/actions/mail-reply-sender.png \
#       -close-command [mymethod CancelReply]
#   ttk::label [$f.replybar body].lbl -anchor w
snit::widget composerbanner {
    hulltype ttk::frame

    option -icon -default "" -readonly yes
    option -close-command -default ""

    component body

    constructor args {
        $self configurelist $args
        if {$options(-icon) ne ""} {
            ttk::label $win.icon -image $options(-icon)
            pack $win.icon -side left -padx {4 2}
        }
        ttk::button $win.close -text "×" -style Toolbutton \
            -command [mymethod Close]
        pack $win.close -side right -padx 2
        install body using ttk::frame $win.body
        pack $win.body -side left -fill x -expand yes -padx {6 2}
    }

    # The frame callers pack their content into.
    method body {} { return $body }

    method Close {} {
        if {$options(-close-command) ne ""} {
            {*}$options(-close-command)
        }
    }
}
