# input_dialog / input_fields are modal (vwait), so each test drives the
# dialog from an after-idle script and lets the vwait return normally.

# Drive the dialog at $w once it is up. The idle handler runs inside the
# dialog's own vwait, so the window is always there by then; the watchdog is
# only so a regression fails the test instead of wedging the whole suite.
proc after_dialog {w script} {
    set guard [after 5000 [list set ::_inputdlg_done($w) 0]]
    after idle [list apply {{w script guard} {
        after cancel $guard
        # Under Xvfb there is no WM, so nothing maps or focuses the dialog on
        # its own - and an unfocused window drops generated key events.
        update
        uplevel #0 $script
    }} $w $script $guard]
}

test inputdialog-ok {OK returns what was typed} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e0 delete 0 end
        .t_dlg.body.e0 insert 0 "Juliet Capulet"
        .t_dlg.btns.ok invoke
    }
    input_dialog .t_dlg -title T -prompt "Name:"
} -result {Juliet Capulet}

test inputdialog-cancel {Cancel returns empty even with text typed} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e0 insert 0 "discard me"
        .t_dlg.btns.cancel invoke
    }
    input_dialog .t_dlg -title T -prompt "Name:" -value "seed"
} -result {}

test inputdialog-default {The default value seeds the entry} -body {
    after_dialog .t_dlg {
        set ::_seen [.t_dlg.body.e0 get]
        .t_dlg.btns.ok invoke
    }
    input_dialog .t_dlg -title T -prompt "Name:" -value "Romeo"
    set ::_seen
} -cleanup {unset -nocomplain ::_seen} -result {Romeo}

test inputdialog-escape {Escape cancels} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e0 insert 0 "nope"
        focus -force .t_dlg.body.e0
        event generate .t_dlg.body.e0 <Escape>
    }
    input_dialog .t_dlg -title T -prompt "Name:"
} -result {}

test inputdialog-destroyed {The toplevel is gone once it returns} -body {
    after_dialog .t_dlg {.t_dlg.btns.ok invoke}
    input_dialog .t_dlg -title T -prompt "Name:"
    winfo exists .t_dlg
} -result 0

test inputdialog-no-leaked-globals {Its scratch variables don't outlive it} -body {
    after_dialog .t_dlg {.t_dlg.btns.ok invoke}
    input_dialog .t_dlg -title T -prompt "Name:"
    list [info exists ::_inputdlg_done(.t_dlg)] \
         [info exists ::_inputdlg_val(.t_dlg,0)]
} -result {0 0}

test inputfields-two {Two fields come back in order} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e0 insert 0 "romeo@montague.lit"
        .t_dlg.body.e1 insert 0 "come over"
        .t_dlg.btns.ok invoke
    }
    input_fields .t_dlg -title T -fields {"JID:" "" "Reason:" ""}
} -result {romeo@montague.lit {come over}}

test inputfields-cancel {Cancelling a multi-field dialog yields nothing} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e0 insert 0 "romeo@montague.lit"
        .t_dlg.btns.cancel invoke
    }
    input_fields .t_dlg -title T -fields {"JID:" "" "Reason:" ""}
} -result {}

test inputfields-defaults {Per-field defaults land in their own entries} -body {
    after_dialog .t_dlg {
        set ::_seen [list [.t_dlg.body.e0 get] [.t_dlg.body.e1 get]]
        .t_dlg.btns.ok invoke
    }
    input_fields .t_dlg -title T -fields {"A:" "one" "B:" "two"}
    set ::_seen
} -cleanup {unset -nocomplain ::_seen} -result {one two}

test inputfields-return-key {Return in any field accepts} -body {
    after_dialog .t_dlg {
        .t_dlg.body.e1 insert 0 "via return"
        focus -force .t_dlg.body.e1
        event generate .t_dlg.body.e1 <Return>
    }
    lindex [input_fields .t_dlg -title T -fields {"A:" "" "B:" ""}] 1
} -result {via return}

test inputdialog-parent-transient {A -parent makes the dialog transient for it} \
    -setup {toplevel .t_parent; update} -body {
    after_dialog .t_dlg {
        set ::_seen [wm transient .t_dlg]
        .t_dlg.btns.ok invoke
    }
    input_dialog .t_dlg -title T -prompt "Name:" -parent .t_parent
    set ::_seen
} -cleanup {destroy .t_parent; unset -nocomplain ::_seen} -result {.t_parent}
