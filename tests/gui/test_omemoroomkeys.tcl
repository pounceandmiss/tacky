# OMEMO in a room, in the GUI: the chat panel's lock and its "not sent"
# banner, and the room's key screen (omemoroomkeys), member by member.

set ::ork_acc   user@test.example.com
set ::ork_room  lab@muc.example.com
set ::ork_chat  lab@muc.example.com?join
set ::ork_PRIVATE {http://jabber.org/protocol/muc muc_membersonly muc_nonanonymous}

proc ork_presence {nick args} {
    set o [dict merge {jid "" affiliation member self 0} $args]
    j presence -from $::ork_room/$nick {
        j x -ns http://jabber.org/protocol/muc#user {
            set attrs [list -role participant -affiliation [dict get $o affiliation]]
            if {[dict get $o jid] ne ""} { lappend attrs -jid [dict get $o jid] }
            j item {*}$attrs
            if {[dict get $o self]} { j status -code 110 }
        }
    }
}

proc ork_written {pred} {
    foreach w [lreverse [$::_client.conn get_written]] {
        if {[apply [list w $pred] $w]} { return $w }
    }
    return ""
}

proc ork_reply {req payload} {
    $::_client.conn feed [j iq -type result -id [xsearch $req -get @id] \
        -from [xsearch $req -get @to] { j #as-is $payload }]
}

# Join the room, which then says what it is and (if private) who its
# members are: $members is {jid affiliation ...}.
proc ork_join {features members} {
    tacky muc join -acc $::ork_acc -jid $::ork_room -nick me
    $::_client.conn feed [ork_presence me self 1 jid $::ork_acc/res1]
    ork_reply [ork_written {expr {[xsearch $w query -ns http://jabber.org/protocol/disco#info -get tag] ne ""}}] \
        [j query -ns http://jabber.org/protocol/disco#info {
            foreach f $features { j feature -var $f }
        }]
    if {"muc_membersonly" ni $features} return
    foreach affil {owner admin member} {
        set ::ork_affil $affil
        set req [ork_written {expr {[xsearch $w query -ns http://jabber.org/protocol/muc#admin item -get @affiliation] eq $::ork_affil}}]
        ork_reply $req [j query -ns http://jabber.org/protocol/muc#admin {
            foreach {jid a} $members {
                if {$a eq $::ork_affil} { j item -jid $jid -affiliation $a }
            }
        }]
    }
}

# Our own devicelist: this device alone.
proc ork_own_devicelist {} {
    $::_client omemo OnDevicelist [j message -from $::ork_acc {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node eu.siacs.conversations.axolotl.devicelist {
                j item {
                    j list -ns eu.siacs.conversations.axolotl {
                        j device -id [$::_client omemo device_id]
                    }
                }
            }
        }
    }]
}

# A trust row for $jid/$dev, told as the client tells any.
proc ork_key {jid dev trust} {
    set ik [binary format H* [string repeat [format %02x $dev] 32]]
    $::_client db eval {INSERT INTO omemo_trust(account_jid, peer_jid,
        peer_device, identity_pk, trust, active, last_activation)
        VALUES($::ork_acc, $jid, $dev, $ik, $trust, 1, 0)}
    $::_client omemo EmitTrustList $jid
}

proc ork_panel_up {features members} {
    mock_backend_up
    ork_join $features $members
    toplevel .orktop
    wm geometry .orktop 800x600
    menu .orktop.mb
    set ::_ork [chatpanel .orktop.cp -acc $::ork_acc -jid $::ork_chat \
        -groupchat 1 -menubar .orktop.mb]
    pack $::_ork -expand yes -fill both
    wait
}

proc ork_panel_down {} {
    destroy .orktop
    foreach w [winfo children .] {
        if {[string match .omemoroomkeys_* $w]} { destroy $w }
    }
    unset -nocomplain ::_ork
    mock_backend_down
}

proc ork_lock_shown {} {
    expr {[winfo manager [$::_ork.paned.left.entry accessory].lock] ne ""}
}

proc ork_menu_state {label} {
    .orktop.mb.chat entrycget [.orktop.mb.chat index $label] -state
}

proc ork_window {} {
    lindex [lmap w [winfo children .] {
        expr {[string match .omemoroomkeys_* $w] ? $w : [continue]}
    }] 0
}

test omemoroomkeys-lock-hidden-in-public-room {a room that cannot use OMEMO shows no lock and greys its menu entries} \
    -setup {ork_panel_up {http://jabber.org/protocol/muc muc_open muc_nonanonymous} {}} -body {
    list [ork_lock_shown] [ork_menu_state "Encrypt with OMEMO"] \
        [ork_menu_state "OMEMO Keys..."]
} -cleanup {ork_panel_down} -result {0 disabled disabled}

test omemoroomkeys-lock-shown-in-private-room {a private room shows the lock, off} \
    -setup {ork_panel_up $::ork_PRIVATE [list romeo@montague.lit member]} -body {
    list [ork_lock_shown] [$::_ork cget -jid] \
        [set [[$::_ork.paned.left.entry accessory].lock cget -variable]] \
        [ork_menu_state "Encrypt with OMEMO"]
} -cleanup {ork_panel_down} -result [list 1 $::ork_chat 0 normal]

test omemoroomkeys-lock-turns-room-on {the lock switches the room on} \
    -setup {ork_panel_up $::ork_PRIVATE [list romeo@montague.lit member]} -body {
    [$::_ork.paned.left.entry accessory].lock invoke
    wait
    tacky omemo isEnabled -acc $::ork_acc -jid $::ork_chat
} -cleanup {ork_panel_down} -result 1

test omemoroomkeys-unreachable-banner {a send stopped by a member raises a banner naming them, and the room's keys} \
    -setup {ork_panel_up $::ork_PRIVATE [list romeo@montague.lit member]} -body {
    tacky omemo setEnabled -acc $::ork_acc -jid $::ork_chat -value 1
    ork_own_devicelist
    $::_client omemo UpdatePeerDevicelist romeo@montague.lit {}
    tacky message send -acc $::ork_acc -chat $::ork_chat -body secret
    wait
    set lbl [[$::_ork BannerBody omemo].lbl cget -text]
    set w [ork_window]
    list $lbl [expr {$w ne ""}] [lindex [$w Shown] 0]
} -cleanup {ork_panel_down} -result [list \
    "Not sent: no usable OMEMO device for romeo@montague.lit" 1 \
    [list romeo@montague.lit 1 "no OMEMO - can't read encrypted messages"]]

test omemoroomkeys-banner-off-turns-room-off {the banner's "Turn off encryption" switches the room off and goes} \
    -setup {ork_panel_up $::ork_PRIVATE [list romeo@montague.lit member]} -body {
    tacky omemo setEnabled -acc $::ork_acc -jid $::ork_chat -value 1
    $::_ork ShowUnreachable romeo@montague.lit
    [$::_ork BannerBody omemo].off invoke
    wait
    list [tacky omemo isEnabled -acc $::ork_acc -jid $::ork_chat] \
        [$::_ork HasBanner omemo]
} -cleanup {ork_panel_down} -result {0 0}

proc ork_keys_up {members} {
    mock_backend_up
    ork_join $::ork_PRIVATE $members
    tacky omemo setEnabled -acc $::ork_acc -jid $::ork_chat -value 1
    set ::_orkw [omemoroomkeys open $::ork_acc $::ork_chat]
    wait
}

proc ork_keys_down {} {
    catch {destroy $::_orkw}
    unset -nocomplain ::_orkw
    mock_backend_down
}

# The key panel shown for $jid in the window, "" when folded.
proc ork_member_panel {jid} {
    foreach sec [winfo children $::_orkw.scroll.content] {
        if {![winfo exists $sec.keys]} continue
        if {[$sec.keys cget -jid] eq $jid} { return $sec.keys }
    }
    return ""
}

test omemoroomkeys-attention-first {members needing attention come first and open; the rest are folded} \
    -setup {ork_keys_up [list romeo@montague.lit member mercutio@verona.lit member \
        tybalt@capulet.lit member]} -body {
    tacky omemo setBlindTrust -acc $::ork_acc -value 0
    ork_key romeo@montague.lit 11 trusted
    ork_key tybalt@capulet.lit 31 undecided
    wait
    list [$::_orkw Shown] [winfo exists [ork_member_panel tybalt@capulet.lit]] \
        [ork_member_panel romeo@montague.lit]
} -cleanup {ork_keys_down} -result [list [list \
    [list mercutio@verona.lit 1 "no keys known yet"] \
    [list tybalt@capulet.lit 1 "1 new key"] \
    [list romeo@montague.lit 0 "1 key, trusted"]] 1 {}]

test omemoroomkeys-blind-trust-calms-new-keys {with blind trust on, an undecided key needs no decision} \
    -setup {ork_keys_up [list tybalt@capulet.lit member]} -body {
    tacky omemo setBlindTrust -acc $::ork_acc -value 1
    ork_key tybalt@capulet.lit 31 undecided
    wait
    list [$::_orkw Shown] [$::_orkw.banner cget -text]
} -cleanup {ork_keys_down} -result [list [list [list tybalt@capulet.lit 0 "1 key"]] \
    "Every member can read encrypted messages."]

test omemoroomkeys-set-all-is-per-member {trusting all of one member's devices touches only that member} \
    -setup {ork_keys_up [list romeo@montague.lit member tybalt@capulet.lit member]} -body {
    tacky omemo setBlindTrust -acc $::ork_acc -value 0
    ork_key romeo@montague.lit 11 undecided
    ork_key romeo@montague.lit 12 undecided
    ork_key tybalt@capulet.lit 31 undecided
    wait
    [ork_member_panel romeo@montague.lit] SetAll trusted
    wait
    list [$::_client db eval {SELECT peer_jid, peer_device, trust FROM omemo_trust
            ORDER BY peer_jid, peer_device}] \
        [lmap m [$::_orkw Shown] {lindex $m 0}]
} -cleanup {ork_keys_down} -result [list \
    {romeo@montague.lit 11 trusted romeo@montague.lit 12 trusted tybalt@capulet.lit 31 undecided} \
    {tybalt@capulet.lit romeo@montague.lit}]

test omemoroomkeys-fold-is-kept {a member the user folds stays folded as the list updates} \
    -setup {ork_keys_up [list mercutio@verona.lit member]} -body {
    set before [lindex [$::_orkw Shown] 0 1]
    $::_orkw Toggle mercutio@verona.lit 1
    ork_key mercutio@verona.lit 21 compromised
    wait
    list $before [lindex [$::_orkw Shown] 0] \
        [ork_member_panel mercutio@verona.lit]
} -cleanup {ork_keys_down} -result [list 1 \
    [list mercutio@verona.lit 0 "a key changed"] {}]

test omemoroomkeys-turn-off {"Turn off encryption" switches the room off} \
    -setup {ork_keys_up [list romeo@montague.lit member]} -body {
    $::_orkw.bar.off invoke
    wait
    list [tacky omemo isEnabled -acc $::ork_acc -jid $::ork_chat] \
        [$::_orkw.banner cget -text] [$::_orkw.bar.off cget -state]
} -cleanup {ork_keys_down} -result {0 {Encryption is off for this room.} disabled}

test omemoroomkeys-many-members {a room of 40 members draws one header line each, folded} \
    -setup {
        set ::ork_many {}
        for {set i 0} {$i < 40} {incr i} { lappend ::ork_many m$i@example.org member }
        ork_keys_up $::ork_many
        for {set i 0} {$i < 40} {incr i} { ork_key m$i@example.org [expr {100 + $i}] trusted }
        wait
    } -body {
    list [llength [winfo children $::_orkw.scroll.content]] \
        [llength [lmap m [$::_orkw Shown] {expr {[lindex $m 1] ? $m : [continue]}}]]
} -cleanup {ork_keys_down; unset -nocomplain ::ork_many} -result {40 0}
