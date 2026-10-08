# omemoroomkeys - a room's OMEMO keys, member by member.
#
# A room message is encrypted for every device of every member, so the
# room's trust screen is a list of people, each with their keys. Each member
# is a header line - name, address, and a summary ("no OMEMO", "1 new key",
# "2 keys, trusted") - over that member's device rows, which are the 1:1
# key panel's (omemokeyspanel, one per member, stacked in one scroll area).
# Members who stop a send or need a decision come first and open; the rest
# are folded to their header line, so a large room stays one screen.
#
# Whether a member needs attention, and the counts the summary is worded
# from, are the backend's: each member in omemo roomStatus.
#
# One window per account and room; `open` raises the existing one.
#
# Usage:
#   omemoroomkeys open juliet@capulet.lit lab@chat.capulet.lit?join

package require snit

snit::widget omemoroomkeys {
    hulltype toplevel

    option -acc -readonly yes
    option -chat -readonly yes

    variable room ""
    # omemo roomStatus, {} until it arrives
    variable status {}
    # real bare jid -> nick, for members in the room
    variable nickOf -array {}
    # member jid -> 0|1: the user's own fold, which outlives a re-render
    variable Expanded -array {}
    variable content
    variable scrollCanvas
    variable RenderedSig ""
    variable seq 0
    # The coalesced re-render (Update); "" when none is due.
    variable UpdateToken ""

    typemethod open {acc chat} {
        set w .omemoroomkeys_[path_safe $acc]_[path_safe $chat]
        if {[raise_existing $w]} { return $w }
        return [omemoroomkeys $w -acc $acc -chat $chat]
    }

    constructor args {
        $self configurelist $args
        set room [regsub {\?join$} $options(-chat) {}]
        wm title $win "OMEMO Keys - $room"

        ttk::label $win.banner -anchor w -padding {8 6}
        set scroll [scrollable $win.scroll]
        set scrollCanvas $scroll.canvas
        $scrollCanvas configure -height 360 -width 460
        set content [ttk::frame $scroll.content -padding {8 4}]
        $scroll setwidget $content

        set bar [ttk::frame $win.bar -padding {8 6}]
        ttk::button $bar.off -text "Turn off encryption" \
            -command [mymethod TurnOff]
        ttk::button $bar.done -text "Done" -command [list destroy $win]
        pack $bar.done -side right
        pack $bar.off -side left

        pack $win.banner -side top -fill x
        pack $bar -side bottom -fill x
        pack $scroll -side top -fill both -expand yes

        ::tacky observe -tag $win omemo <RoomStatus> -acc $options(-acc) \
            -jid $options(-chat) [mymethod OnStatus]
        foreach event {<Presence> <Unavailable> <NickChanged>} {
            ::tacky listen -tag $win muc $event -acc $options(-acc) \
                -jid $room [mymethod RefreshNicks]
        }
        $self RefreshNicks
        # Keys of members never fetched yet: their devicelists and bundles.
        ::tacky omemo prepareChat -acc $options(-acc) -jid $options(-chat) \
            -tag $win
    }

    destructor {
        catch {::tacky unlisten $win}
        catch {after cancel $UpdateToken}
    }

    method OnStatus {ev} {
        set status [dict get $ev -status]
        $self Update
    }

    method RefreshNicks {args} {
        ::tacky muc occupants -acc $options(-acc) -jid $room \
            -tag $win -command [mymethod OnOccupants]
    }

    method OnOccupants {occupants} {
        array unset nickOf *
        foreach occ $occupants {
            set j [dict get $occ jid]
            if {$j eq ""} continue
            set nickOf([jid bare $j]) [dict get $occ nick]
        }
        $self Update
    }

    # --- what each member needs ---

    # Each member's keys: {jid keys trusted undecided untrusted
    # compromised attention reason}.
    method Members {} {
        if {$status eq ""} { return {} }
        return [dict get $status members]
    }

    # {attention summary} for one member, worded from its counts.
    method Summary {m} {
        set attention [dict get $m attention]
        switch -- [dict get $m reason] {
            no_devices       { return {1 "no OMEMO - can't read encrypted messages"} }
            no_usable_device { return {1 "no usable key - trust one to send"} }
        }
        set n [dict get $m keys]
        if {$n == 0} { return [list $attention "no keys known yet"] }
        if {[dict get $m compromised]} {
            return [list $attention "a key changed"]
        }
        set u [dict get $m undecided]
        if {$attention && $u} {
            return [list 1 [expr {$u == 1 ? "1 new key" : "$u new keys"}]]
        }
        set what [expr {$n == 1 ? "1 key" : "$n keys"}]
        if {[dict get $m trusted] == $n} { append what ", trusted" }
        return [list $attention $what]
    }

    method Name {jid} {
        if {[info exists nickOf($jid)]} { return $nickOf($jid) }
        return [lindex [split $jid @] 0]
    }

    # --- rendering ---

    # Re-render once things settle. Never at once: a member panel's "Set
    # all" trusts its devices one by one, each change comes back here, and
    # a rebuild then would destroy the panel in the middle of its loop.
    method Update {} {
        if {$UpdateToken ne ""} return
        set UpdateToken [after idle [mymethod DoUpdate]]
    }

    method DoUpdate {} {
        set UpdateToken ""
        set ordered [$self Sorted]
        set attention 0
        foreach m $ordered { if {[lindex $m 3]} { incr attention } }
        if {$status eq ""} {
            $win.banner configure -text ""
        } elseif {![dict get $status enabled]} {
            $win.banner configure -text "Encryption is off for this room."
        } elseif {$attention} {
            $win.banner configure -text [expr {$attention == 1
                ? "1 member needs attention"
                : "$attention members need attention"}]
        } else {
            $win.banner configure -text "Every member can read encrypted messages."
        }
        $win.bar.off configure -state [expr {$status ne ""
            && [dict get $status enabled] ? "normal" : "disabled"}]
        set sig [lmap m $ordered {lrange $m 1 4}]
        lappend sig [array get Expanded]
        if {$sig eq $RenderedSig} return
        set RenderedSig $sig
        $self Render $ordered
    }

    # {sortkey name jid attention summary}, attention first then by name.
    method Sorted {} {
        set out {}
        foreach m [$self Members] {
            set jid [dict get $m jid]
            lassign [$self Summary $m] attention summary
            lappend out [list [expr {$attention ? 0 : 1}] [$self Name $jid] \
                $jid $attention $summary]
        }
        return [lsort -command [list apply {{a b} {
            set c [expr {[lindex $a 0] - [lindex $b 0]}]
            if {$c != 0} { return $c }
            string compare -nocase [lindex $a 1] [lindex $b 1]
        }}] $out]
    }

    method IsExpanded {jid attention} {
        if {[info exists Expanded($jid)]} { return $Expanded($jid) }
        return $attention
    }

    method Render {ordered} {
        foreach c [winfo children $content] { destroy $c }
        if {![llength $ordered]} {
            ttk::label $content.none -foreground gray40 \
                -text "No members known yet."
            pack $content.none -anchor w -padx 4 -pady 4
            return
        }
        foreach m $ordered {
            lassign $m _ name jid attention summary
            set sec [ttk::frame $content.m[incr seq]]
            set head [ttk::frame $sec.head]
            set open [$self IsExpanded $jid $attention]
            ttk::button $head.fold -style Toolbutton -width 2 \
                -text [expr {$open ? "▾" : "▸"}] \
                -command [mymethod Toggle $jid $attention]
            ttk::label $head.name -text $name -font {Helvetica 11 bold}
            ttk::label $head.jid -text "($jid)" -foreground gray40
            ttk::label $head.sum -text $summary \
                -foreground [expr {$attention ? "firebrick3" : "gray40"}]
            pack $head.fold $head.name $head.jid -side left -padx {0 4}
            pack $head.sum -side right -padx 4
            pack $head -fill x
            bind $head.name <Button-1> [mymethod Toggle $jid $attention]
            if {$open} {
                omemokeyspanel $sec.keys -acc $options(-acc) -jid $jid -scroll 0
                pack $sec.keys -fill x -padx {24 0}
            }
            pack $sec -fill x -anchor w -pady {2 4}
        }
        $self ForwardWheel $content
    }

    method Toggle {jid attention} {
        set Expanded($jid) [expr {![$self IsExpanded $jid $attention]}]
        $self Update
    }

    method ForwardWheel {w} {
        bind $w <MouseWheel> \
            [list event generate $scrollCanvas <MouseWheel> -delta %D]
        bind $w <Button-4> [list event generate $scrollCanvas <Button-4>]
        bind $w <Button-5> [list event generate $scrollCanvas <Button-5>]
        foreach c [winfo children $w] { $self ForwardWheel $c }
    }

    method TurnOff {} {
        ::tacky omemo setEnabled -acc $options(-acc) -jid $options(-chat) \
            -value 0 -tag $win
    }

    # For tests: {jid open summary} per member, in display order.
    method Shown {} {
        lmap m [$self Sorted] {
            lassign $m _ name jid attention summary
            list $jid [$self IsExpanded $jid $attention] $summary
        }
    }
}
