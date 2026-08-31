# Modal text input, one or more fields at a time.
#
#   input_dialog .dlg -parent $top -title "Rename" -prompt "New name:" \
#       -value $current
#       -> the string, or "" when cancelled
#
#   input_fields .dlg -parent $top -title "Invite User" \
#       -fields {"JID to invite:" "" "Reason (optional):" ""}
#       -> one value per field, or {} when cancelled
#
# -parent keeps the dialog on top of the window that raised it; without one it
# lands wherever the WM puts it.

# The engine: -fields is a flat {prompt default ...} list.
proc input_fields {w args} {
    array set opts {-title "Input" -fields {} -parent ""}
    array set opts $args

    # Per-dialog variables, so a re-entered path doesn't clobber the one in
    # flight.
    set doneVar ::_inputdlg_done($w)
    set entryVars {}

    catch {destroy $w}
    toplevel $w
    wm title $w $opts(-title)
    wm resizable $w 0 0
    wm protocol $w WM_DELETE_WINDOW [list set $doneVar 0]
    if {$opts(-parent) ne "" && [winfo exists $opts(-parent)]} {
        wm transient $w [winfo toplevel $opts(-parent)]
    }
    set $doneVar ""

    set body [ttk::frame $w.body -padding 10]
    pack $body -fill both -expand yes
    set i 0
    set first ""
    foreach {prompt default} $opts(-fields) {
        set var ::_inputdlg_val($w,$i)
        set $var $default
        lappend entryVars $var
        ttk::label $body.l$i -text $prompt
        ttk::entry $body.e$i -textvariable $var -width 30
        grid $body.l$i -row [expr {$i * 2}] -column 0 -sticky w \
            -pady [expr {$i ? {6 0} : 0}]
        grid $body.e$i -row [expr {$i * 2 + 1}] -column 0 -sticky ew -pady {2 0}
        bind $body.e$i <Return> [list set $doneVar 1]
        if {$first eq ""} { set first $body.e$i }
        incr i
    }
    grid columnconfigure $body 0 -weight 1

    ttk::frame $w.btns
    ttk::button $w.btns.ok -text OK -command [list set $doneVar 1]
    ttk::button $w.btns.cancel -text Cancel -command [list set $doneVar 0]
    pack $w.btns -pady {0 10}
    pack $w.btns.ok $w.btns.cancel -side left -padx 5

    if {$first ne ""} {
        $first selection range 0 end
        focus $first
    }
    bind $w <Escape> [list set $doneVar 0]

    try {
        grab set $w
        vwait $doneVar
    } finally {
        catch {grab release $w}
    }
    set done [set $doneVar]
    set values [lmap var $entryVars {set $var}]
    destroy $w
    unset -nocomplain $doneVar
    foreach var $entryVars { unset -nocomplain $var }
    if {$done} { return $values }
    return {}
}

# Single-field sugar: returns the string, or "" when cancelled.
proc input_dialog {w args} {
    array set opts {-title "Input" -prompt "Value:" -value "" -parent ""}
    array set opts $args
    lassign [input_fields $w -title $opts(-title) -parent $opts(-parent) \
        -fields [list $opts(-prompt) $opts(-value)]] value
    return $value
}
