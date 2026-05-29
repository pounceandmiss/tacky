# omemokeyspanel - scrollable list of one subject's OMEMO device keys.
#
# Renders the devices for a single jid: each fingerprint left-aligned across
# two monospace lines (8-char groups aligned column-wise), a Trust / Don't
# trust / Undecided radio triplet per device, and a "Set all" triplet when
# there are 2+ settable devices. When -jid is this account's own bare jid the
# current device is badged (from own_fingerprint/device_id) and excluded from
# the trust controls. A compromised device is read-only. Left-click a
# fingerprint to copy it; right-click for a Copy menu. Live-updates via the
# omemo <TrustList> event; a plain trust flip refreshes in place (no rebuild).
#
# Embedders supply their own section label; the panel is just the list.
#
# Usage:
#   omemokeyspanel $f.keys -acc romeo@montague.lit -jid juliet@capulet.lit

package require snit

snit::widget omemokeyspanel {
    hulltype ttk::frame

    option -acc -readonly yes
    option -jid -readonly yes
    option -height -default 200 -readonly yes

    variable isOwn 0
    variable content
    variable scrollCanvas
    variable OwnFp ""
    variable OwnDev ""
    variable Rows {}
    variable TrustVar -array {}
    variable SetAllVar ""
    variable RenderedSig ""
    variable rowSeq 0

    constructor args {
        $self configurelist $args
        set isOwn [expr {$options(-jid) eq [jid bare $options(-acc)]}]

        set scroll [scrollable $win.scroll]
        set scrollCanvas $scroll.canvas
        $scrollCanvas configure -height $options(-height)
        set content [ttk::frame $scroll.content -padding {8 4}]
        $scroll setwidget $content
        pack $scroll -expand yes -fill both

        ::tacky observe -tag $win omemo <TrustList> -acc $options(-acc) \
            -jid $options(-jid) [mymethod OnTrustList]
        if {$isOwn} {
            ::tacky omemo own_fingerprint -acc $options(-acc) \
                -command [mymethod OnOwnFp]
            ::tacky omemo device_id -acc $options(-acc) \
                -command [mymethod OnOwnDev]
        }
    }

    destructor {
        catch {::tacky unlisten $win}
    }

    method OnOwnFp {fp} { set OwnFp $fp; $self Update }
    method OnOwnDev {dev} { set OwnDev $dev; $self Update }
    method OnTrustList {ev} { set Rows [dict get $ev -trustList]; $self Update }

    # Full rebuild only on a structural change; a plain trust flip just
    # refreshes the bound radios, avoiding flicker and a scroll reset.
    method Update {} {
        set sig [$self StructureSig]
        if {$sig eq $RenderedSig} {
            $self SyncTrustVars
            return
        }
        set RenderedSig $sig
        $self Render
    }

    method StructureSig {} {
        set sig [list self:$isOwn:$OwnFp:$OwnDev]
        foreach dev $Rows {
            if {$isOwn && [dict get $dev device] eq $OwnDev} continue
            set comp [expr {[dict get $dev trust] eq "compromised"}]
            lappend sig "[dict get $dev device]:[dict get $dev active]:$comp"
        }
        return $sig
    }

    method SyncTrustVars {} {
        foreach dev $Rows {
            set device [dict get $dev device]
            set trust [dict get $dev trust]
            if {$trust eq "compromised"} continue
            if {[info exists TrustVar($device)]} {
                set TrustVar($device) $trust
            }
        }
        set SetAllVar [$self CommonTrust]
    }

    # Devices a "Set all" can act on: trust rows that aren't compromised
    # (and, on the own panel, not the current device).
    method SettableRows {} {
        set out {}
        foreach dev $Rows {
            if {$isOwn && [dict get $dev device] eq $OwnDev} continue
            if {[dict get $dev trust] eq "compromised"} continue
            lappend out $dev
        }
        return $out
    }

    # The shared trust state of the settable devices, or "" when they differ
    # / there are none (drives the indeterminate "Set all").
    method CommonTrust {} {
        set rows [$self SettableRows]
        if {[llength $rows] == 0} { return "" }
        set first [dict get [lindex $rows 0] trust]
        foreach dev $rows {
            if {[dict get $dev trust] ne $first} { return "" }
        }
        return $first
    }

    method Render {} {
        foreach c [winfo children $content] { destroy $c }
        set rowSeq 0

        if {$isOwn && ($OwnFp ne "" || $OwnDev ne "")} {
            $self ThisDeviceRow $OwnFp
        }
        if {[llength [$self SettableRows]] >= 2} {
            $self SetAllRow
        }
        set shown 0
        foreach dev $Rows {
            if {$isOwn && [dict get $dev device] eq $OwnDev} continue
            $self DeviceRow $dev
            incr shown
        }
        if {!$shown && !($isOwn && ($OwnFp ne "" || $OwnDev ne ""))} {
            $self Note [expr {$isOwn ? "No keys yet." : "No known devices yet."}]
        }

        # Children swallow wheel events; forward them to the scroll canvas.
        $self ForwardWheel $content
    }

    method ForwardWheel {w} {
        bind $w <MouseWheel> \
            [list event generate $scrollCanvas <MouseWheel> -delta %D]
        bind $w <Button-4> [list event generate $scrollCanvas <Button-4>]
        bind $w <Button-5> [list event generate $scrollCanvas <Button-5>]
        foreach c [winfo children $w] { $self ForwardWheel $c }
    }

    method Note {text} {
        ttk::label $content.n[incr rowSeq] -text $text -foreground gray40
        pack $content.n$rowSeq -anchor w -padx 12 -pady 2
    }

    method ThisDeviceRow {fp} {
        set row [ttk::frame $content.r[incr rowSeq]]
        ttk::label $row.fp -font {Courier 11} -justify left \
            -text [$self FormatFingerprint $fp]
        $self BindCopy $row.fp $fp
        ttk::label $row.note -text "this device" -foreground gray40
        pack $row.fp -anchor w
        pack $row.note -anchor w -padx {12 0}
        pack $row -fill x -anchor w -pady {2 8}
    }

    method DeviceRow {dev} {
        set device [dict get $dev device]
        set trust [dict get $dev trust]
        set active [dict get $dev active]

        set row [ttk::frame $content.r[incr rowSeq]]
        ttk::label $row.fp -font {Courier 11} -justify left \
            -text [$self FormatFingerprint [dict get $dev fingerprint]]
        $self BindCopy $row.fp [dict get $dev fingerprint]
        pack $row.fp -anchor w
        if {!$active} {
            ttk::label $row.inactive -text "(inactive)" -foreground gray40
            pack $row.inactive -anchor w -padx {12 0}
        }
        if {$trust eq "compromised"} {
            ttk::label $row.warn -text "Compromised - key changed" \
                -foreground red
            pack $row.warn -anchor w -padx {12 0}
        } else {
            set TrustVar($device) $trust
            set ctl [ttk::frame $row.ctl]
            foreach {state lbl} {
                trusted "Trust" untrusted "Don't trust" undecided "Undecided"
            } {
                ttk::radiobutton $ctl.$state -text $lbl \
                    -variable [myvar TrustVar($device)] -value $state \
                    -command [mymethod SetTrust $device]
                pack $ctl.$state -side left -padx {0 10}
            }
            pack $ctl -anchor w -padx {12 0} -pady {2 0}
        }
        pack $row -fill x -anchor w -pady {2 8}
    }

    method SetAllRow {} {
        set SetAllVar [$self CommonTrust]
        set row [ttk::frame $content.s[incr rowSeq]]
        ttk::label $row.lbl -text "Set all:" -foreground gray40
        pack $row.lbl -anchor w
        set ctl [ttk::frame $row.ctl]
        foreach {state lbl} {
            trusted "Trust" untrusted "Don't trust" undecided "Undecided"
        } {
            ttk::radiobutton $ctl.$state -text $lbl \
                -variable [myvar SetAllVar] -value $state \
                -command [mymethod SetAll $state]
            pack $ctl.$state -side left -padx {0 10}
        }
        pack $ctl -anchor w -padx {12 0} -pady {2 0}
        pack $row -fill x -anchor w -pady {2 8}
    }

    method SetAll {state} {
        foreach dev [$self SettableRows] {
            ::tacky omemo trust -acc $options(-acc) -jid $options(-jid) \
                -device [dict get $dev device] -state $state
        }
    }

    method SetTrust {device} {
        ::tacky omemo trust -acc $options(-acc) -jid $options(-jid) \
            -device $device -state $TrustVar($device)
    }

    # Left-click copies the fingerprint; right-click offers a Copy menu.
    method BindCopy {w hex} {
        set flat [$self FlatFingerprint $hex]
        $w configure -cursor hand2
        bind $w <Button-1> [mymethod CopyFp $flat]
        bind $w <Button-3> [mymethod FpMenu $flat %X %Y]
    }

    method CopyFp {text} {
        clipboard clear
        clipboard append $text
    }

    method FpMenu {text X Y} {
        set m $win.fpmenu
        if {![winfo exists $m]} { menu $m -tearoff 0 }
        $m delete 0 end
        $m add command -label "Copy fingerprint" \
            -command [mymethod CopyFp $text]
        tk_popup $m $X $Y
    }

    # Single-line space-grouped form, for copying.
    method FlatFingerprint {hex} {
        lassign [$self FormatFingerprintLines $hex] l1 l2
        return [string trim "$l1 $l2"]
    }

    # Two-line text for a label: 8-char groups, half per line.
    method FormatFingerprint {hex} {
        lassign [$self FormatFingerprintLines $hex] l1 l2
        if {$l2 eq ""} { return $l1 }
        return "$l1\n$l2"
    }

    # 8-char groups, half per line, as {line1 line2}. picomemo returns the
    # hex already space-grouped, so strip whitespace before regrouping.
    method FormatFingerprintLines {hex} {
        regsub -all {\s+} $hex "" hex
        if {$hex eq ""} { return [list "(unknown)" ""] }
        set groups {}
        set n [string length $hex]
        for {set i 0} {$i < $n} {incr i 8} {
            lappend groups [string range $hex $i [expr {$i + 7}]]
        }
        set half [expr {([llength $groups] + 1) / 2}]
        set line1 [join [lrange $groups 0 [expr {$half - 1}]] " "]
        set line2 [join [lrange $groups $half end] " "]
        return [list $line1 $line2]
    }
}
