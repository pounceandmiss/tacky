# chatpanel's composer banners: reply, edit and find share one strip widget,
# and the pane stays frozen until the last of them goes.

proc chatpanel_up {} {
    mock_backend_up
    toplevel .cptop
    wm geometry .cptop 800x600
    set ::_cp [chatpanel .cptop.cp -acc user@test.example.com \
        -jid peer@test.example.com]
    pack $::_cp -expand yes -fill both
    update
    return $::_cp
}

proc chatpanel_down {} {
    destroy .cptop
    unset -nocomplain ::_cp
    mock_backend_down
}

# The left pane holding the chat view, composer and banners.
proc cp_leftframe {} { return $::_cp.paned.left }

proc cp_banners {} {
    lmap w [winfo children [cp_leftframe]] {
        expr {[string match *.banner_* $w] && [winfo manager $w] ne ""
            ? [string range [lindex [split $w .] end] 7 end] : [continue]}
    }
}

test chatpanel-reply-banner {StartReply raises a banner carrying the snippet} \
    -setup {chatpanel_up} -body {
    $::_cp StartReply [list 100 "Juliet" "wherefore art thou"]
    update
    list [cp_banners] [[$::_cp BannerBody reply].lbl cget -text]
} -cleanup {chatpanel_down} \
  -result {reply {Replying to Juliet: wherefore art thou}}

test chatpanel-reply-cancel {CancelReply takes the banner back down} \
    -setup {chatpanel_up} -body {
    $::_cp StartReply [list 100 "Juliet" "hi"]
    $::_cp CancelReply
    update
    list [cp_banners] [$::_cp HasBanner reply]
} -cleanup {chatpanel_down} -result {{} 0}

test chatpanel-edit-replaces-reply {Starting an edit cancels a pending reply} \
    -setup {chatpanel_up} -body {
    $::_cp StartReply [list 100 "Juliet" "hi"]
    $::_cp StartEdit [list 200 "draft body"]
    update
    cp_banners
} -cleanup {chatpanel_down} -result {edit}

test chatpanel-reply-replaces-edit {Starting a reply cancels a pending edit} \
    -setup {chatpanel_up} -body {
    $::_cp StartEdit [list 200 "draft body"]
    $::_cp StartReply [list 100 "Juliet" "hi"]
    update
    cp_banners
} -cleanup {chatpanel_down} -result {reply}

test chatpanel-find-banner {OpenFind raises a banner with an entry} \
    -setup {chatpanel_up} -body {
    $::_cp OpenFind
    update
    list [cp_banners] [winfo exists [$::_cp BannerBody find].entry]
} -cleanup {chatpanel_down} -result {find 1}

test chatpanel-find-reopen-keeps-one {Reopening find doesn't stack banners} \
    -setup {chatpanel_up} -body {
    $::_cp OpenFind
    $::_cp OpenFind
    update
    cp_banners
} -cleanup {chatpanel_down} -result {find}

test chatpanel-find-close {CloseFind takes the banner down and clears state} \
    -setup {chatpanel_up} -body {
    $::_cp OpenFind
    $::_cp CloseFind
    update
    list [cp_banners] [$::_cp BannerBody find]
} -cleanup {chatpanel_down} -result {{} {}}

# Find and reply coexist: only the second close may thaw the pane.
test chatpanel-banners-stack {Two banners can be up at once} \
    -setup {chatpanel_up} -body {
    $::_cp OpenFind
    $::_cp StartReply [list 100 "Juliet" "hi"]
    update
    lsort [cp_banners]
} -cleanup {chatpanel_down} -result {find reply}

test chatpanel-propagate-frozen {The pane stays frozen while a banner is up} \
    -setup {chatpanel_up} -body {
    $::_cp OpenFind
    $::_cp StartReply [list 100 "Juliet" "hi"]
    set both [pack propagate [cp_leftframe]]
    $::_cp CloseFind
    set one [pack propagate [cp_leftframe]]
    $::_cp CancelReply
    list $both $one [pack propagate [cp_leftframe]]
} -cleanup {chatpanel_down} -result {0 0 1}

test chatpanel-close-button {The banner's × runs its close command} \
    -setup {chatpanel_up} -body {
    $::_cp StartReply [list 100 "Juliet" "hi"]
    [$::_cp ShowBanner reply].close invoke
    update
    list [cp_banners] [$::_cp HasBanner reply]
} -cleanup {chatpanel_down} -result {{} 0}
