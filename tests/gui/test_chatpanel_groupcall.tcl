# chatpanel in a room: the group-call banner and menu entry follow the
# room's call, which the backend reads off the occupants' presences.

set ::cpg_acc user@test.example.com
set ::cpg_room room@muc.example.com

proc cpg_presence {nick args} {
    array set opts {-self 0 -muji 0 -jid ""}
    array set opts $args
    set itemAttrs {-role participant -affiliation member}
    if {$opts(-jid) ne ""} { lappend itemAttrs -jid $opts(-jid) }
    return [j presence -from $::cpg_room/$nick {
        j x -ns http://jabber.org/protocol/muc#user {
            j item {*}$itemAttrs
            if {$opts(-self)} { j status -code 110 }
        }
        if {$opts(-muji)} {
            j muji -ns urn:xmpp:jingle:muji:0 {
                j content -ns urn:xmpp:jingle:1 -creator initiator -name audio {
                    j description -ns urn:xmpp:jingle:apps:rtp:1 -media audio {
                        j payload-type -id 111 -name opus -clockrate 48000 -channels 2
                    }
                }
            }
        }
    }]
}

proc cpg_up {} {
    mock_backend_up
    tacky muc join -acc $::cpg_acc -jid $::cpg_room -nick me
    $::_client.conn feed [cpg_presence me -self 1 -jid $::cpg_acc/res1]
    $::_client.conn clear
    toplevel .cpgtop
    wm geometry .cpgtop 800x600
    menu .cpgtop.mb
    set ::_cpg [chatpanel .cpgtop.cp -acc $::cpg_acc -jid $::cpg_room \
        -groupchat 1 -menubar .cpgtop.mb]
    pack $::_cpg -expand yes -fill both
    update
    return $::_cpg
}

proc cpg_down {} {
    destroy .cpgtop
    unset -nocomplain ::_cpg
    mock_backend_down
}

proc cpg_banners {} {
    lmap w [winfo children $::_cpg.paned.left] {
        expr {[string match *.banner_* $w] && [winfo manager $w] ne ""
            ? [string range [lindex [split $w .] end] 7 end] : [continue]}
    }
}

proc cpg_menu_label {} {
    set mb .cpgtop.mb.chat
    foreach pattern {"Join Group Call*" "Start Group Call"} {
        if {![catch {$mb index $pattern} idx]} {
            return [$mb entrycget $idx -label]
        }
    }
    return ""
}

test chatpanel-groupcall-idle {a room with no call has no banner and offers to start one} \
    -setup {cpg_up} -body {
    list [cpg_banners] [cpg_menu_label]
} -cleanup {cpg_down} -result {{} {Start Group Call}}

test chatpanel-groupcall-banner {an occupant announcing a call raises the join banner} \
    -setup {cpg_up} -body {
    $::_client.conn feed [cpg_presence bob -muji 1 -jid bob@example.com/desk]
    update
    list [cpg_banners] [[$::_cpg BannerBody groupcall].lbl cget -text] \
        [cpg_menu_label]
} -cleanup {cpg_down} -result {groupcall {Call in progress (1)} {Join Group Call (1)}}

test chatpanel-groupcall-banner-clears {the call ending takes the banner down} \
    -setup {cpg_up} -body {
    $::_client.conn feed [cpg_presence bob -muji 1 -jid bob@example.com/desk]
    update
    $::_client.conn feed [cpg_presence bob -jid bob@example.com/desk]
    update
    list [cpg_banners] [cpg_menu_label]
} -cleanup {cpg_down} -result {{} {Start Group Call}}

test chatpanel-groupcall-join-button {the banner's join button joins the room's call} \
    -setup {cpg_up} -body {
    $::_client.conn feed [cpg_presence bob -muji 1 -jid bob@example.com/desk]
    update
    [$::_cpg BannerBody groupcall].join invoke
    update
    set w [lindex [$::_client.conn get_written] end]
    list [dict get $w tag] [xsearch $w -get @to] \
        [expr {[xsearch $w muji preparing -get node] ne ""}]
} -cleanup {cpg_down} -result [list presence $::cpg_room/me 1]

test chatpanel-groupcall-start-hosted {with no call on, the menu starts one in a room of its own} \
    -setup {cpg_up} -body {
    $::_cpg JoinGroupCall
    update
    set w [lindex [$::_client.conn get_written] end]
    set to [xsearch $w -get @to]
    list [dict get $w tag] [expr {[jid bare $to] ne $::cpg_room}] \
        [expr {[jid domain $to] eq [jid domain $::cpg_room]}] \
        [expr {[xsearch $w x -ns http://jabber.org/protocol/muc -get node] ne ""}]
} -cleanup {cpg_down} -result {presence 1 1 1}
