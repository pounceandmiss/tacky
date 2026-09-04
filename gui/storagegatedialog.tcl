# Blocking modal shown at startup when `storage status` comes back
# pending-encrypt or pending-decrypt (see app.tcl's OnStorageStatus) - the
# actual migration only ever runs here, before any account has ever
# connected in this process. Unlike StorageUnlockDialog there's always a
# safe fallback (stay in the current, not-yet-migrated state), so Cancel is
# offered. On success this just closes - no "restart required" message,
# since OnStorageStatus re-checks status and proceeds straight into normal
# boot in the same process.
proc StorageGateDialog {parent direction} {
    set w .storagegate
    catch {destroy $w}
    toplevel $w
    wm title $w [expr {$direction eq "encrypt"
        ? "Enable Encryption" : "Remove Encryption"}]
    wm resizable $w 0 0
    wm protocol $w WM_DELETE_WINDOW {}
    # A withdrawn parent (app.tcl's own "." at startup, before any account
    # window exists) isn't a usable transient-for target - several window
    # managers refuse to map a window transient for an unmapped one.
    if {$parent ne "" && [winfo exists $parent] \
            && [wm state $parent] ne "withdrawn"} {
        wm transient $w $parent
    }
    wm deiconify $w
    raise $w

    set doneVar ::_storagegate_done

    ttk::frame $w.inner -padding 16
    if {$direction eq "encrypt"} {
        ttk::label $w.inner.warn -wraplength 320 -justify left -text \
            "There is no way to recover your data if you forget this passphrase."
        ttk::label $w.inner.l -text "Passphrase:"
        showableentry $w.inner.e -width 30
    } else {
        ttk::label $w.inner.l -wraplength 320 -justify left -text \
            "Local storage will be written back out as plaintext."
    }
    ttk::label $w.inner.status -foreground red
    ttk::progressbar $w.inner.progress -mode determinate -maximum 100
    ttk::frame $w.inner.btns
    ttk::button $w.inner.btns.go \
        -text [expr {$direction eq "encrypt" ? "Encrypt" : "Remove Encryption"}] \
        -command [list StorageGateStart $w $direction $doneVar]
    ttk::button $w.inner.btns.cancel -text Cancel \
        -command [list StorageGateCancel $w $doneVar]

    if {$direction eq "encrypt"} {
        pack $w.inner.warn -anchor w -pady {0 8}
        pack $w.inner.l -anchor w
        pack $w.inner.e -fill x -pady {0 4}
    } else {
        pack $w.inner.l -anchor w -pady {0 8}
    }
    pack $w.inner.status -anchor w -fill x -pady 4
    pack $w.inner.btns -pady {8 0}
    pack $w.inner.btns.go $w.inner.btns.cancel -side left -padx 4
    pack $w.inner

    pack forget $w.inner.progress

    if {$direction eq "encrypt"} {
        focus $w.inner.e
        bind $w.inner.e <Return> [list StorageGateStart $w $direction $doneVar]
    }

    set $doneVar 0
    try {
        grab set $w
        vwait $doneVar
    } finally {
        catch {grab release $w}
    }
    unset $doneVar
    destroy $w
}

proc StorageGateCancel {w doneVar} {
    catch {::tacky storage cancelPending}
    set $doneVar 1
}

proc StorageGateStart {w direction doneVar} {
    if {$direction eq "encrypt" && [$w.inner.e get] eq ""} {
        $w.inner.status configure -text "Enter a passphrase"
        return
    }
    $w.inner.btns.go configure -state disabled -text "Working..."
    $w.inner.btns.cancel configure -state disabled
    $w.inner.status configure -text ""
    $w.inner.progress configure -value 0
    pack $w.inner.progress -fill x -pady 4 -before $w.inner.btns
    ::tacky listen -tag $w storage <MigrateProgress> \
        [list StorageGateProgress $w]
    # `storage encrypt`/`decrypt` runs SQLCipher's key derivation and, for
    # encrypt, AES-GCM over every OMEMO attachment inline - deliberately
    # expensive. In -backend direct that blocks the event loop for real, so
    # without this the button never even repaints before the freeze starts.
    update idletasks
    set cmd [list StorageGateDone $w $doneVar]
    set err [list StorageGateFailed $w]
    if {$direction eq "encrypt"} {
        ::tacky storage encrypt -passphrase [$w.inner.e get] \
            -command $cmd -onerror $err
    } else {
        ::tacky storage decrypt -command $cmd -onerror $err
    }
}

proc StorageGateProgress {w ev} {
    if {![winfo exists $w]} return
    set done [dict get $ev -done]
    set total [dict get $ev -total]
    if {$total > 0} {
        $w.inner.progress configure -value [expr {100.0 * $done / $total}]
    }
}

proc StorageGateDone {w doneVar args} {
    if {![winfo exists $w]} return
    catch {::tacky unlisten $w}
    set $doneVar 1
}

proc StorageGateFailed {w msg} {
    if {![winfo exists $w]} return
    catch {::tacky unlisten $w}
    pack forget $w.inner.progress
    $w.inner.status configure -text "Failed: $msg"
    $w.inner.btns.go configure -state normal -text "Retry"
    $w.inner.btns.cancel configure -state normal
}
