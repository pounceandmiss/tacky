# Blocking modal passphrase prompt shown at startup when `storage status`
# comes back locked (see app.tcl's OnStorageStatus). Wrong passphrase
# retries in place - `storage unlock` is a normal tokened call, not a
# process respawn, so there's nothing to restart between attempts.
proc StorageUnlockDialog {parent} {
    set w .storageunlock
    catch {destroy $w}
    toplevel $w
    wm title $w "Unlock Tacky"
    wm resizable $w 0 0
    # No cancelling out of this: there is nothing else the app can do with
    # local storage still locked.
    wm protocol $w WM_DELETE_WINDOW {}
    # A withdrawn parent (app.tcl's own "." at startup, before any account
    # window exists) isn't a usable transient-for target - several window
    # managers refuse to map a window transient for an unmapped one, which
    # left this dialog invisible and the app looking hung.
    if {$parent ne "" && [winfo exists $parent] \
            && [wm state $parent] ne "withdrawn"} {
        wm transient $w $parent
    }
    wm deiconify $w
    raise $w

    set doneVar ::_storageunlock_done

    ttk::frame $w.inner -padding 16
    ttk::label $w.inner.l -text "Enter your passphrase to unlock local storage:"
    showableentry $w.inner.e -width 30
    ttk::label $w.inner.status -foreground red
    ttk::button $w.inner.unlock -text "Unlock" \
        -command [list StorageUnlockAttempt $w $doneVar]

    pack $w.inner.l -anchor w -pady {0 4}
    pack $w.inner.e -fill x -pady 4
    pack $w.inner.status -anchor w -fill x -pady 4
    pack $w.inner.unlock -pady {8 0}
    pack $w.inner -expand yes -fill both

    bind $w.inner.e <Return> [list StorageUnlockAttempt $w $doneVar]
    focus $w.inner.e

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

proc StorageUnlockAttempt {w doneVar} {
    set pw [$w.inner.e get]
    if {$pw eq ""} {
        $w.inner.status configure -text "Enter a passphrase"
        return
    }
    $w.inner.unlock configure -state disabled -text "Unlocking..."
    $w.inner.status configure -text ""
    # In -backend direct, `storage unlock` below runs SQLCipher's key
    # derivation (deliberately expensive) inline on this same thread - one
    # pass for accounts.db, then one more per account as it connects. That
    # blocks the event loop for real, so without this the button never even
    # repaints "Unlocking..." before the freeze starts.
    update idletasks
    ::tacky storage unlock -passphrase $pw \
        -command [list StorageUnlockDone $w $doneVar] \
        -onerror [list StorageUnlockFailed $w]
}

proc StorageUnlockDone {w doneVar args} {
    if {![winfo exists $w]} return
    set $doneVar 1
}

proc StorageUnlockFailed {w msg} {
    if {![winfo exists $w]} return
    $w.inner.unlock configure -state normal -text "Unlock"
    $w.inner.status configure -text $msg
    $w.inner.e selection range 0 end
    focus $w.inner.e
}
