# App-level (not per-account) storage encryption settings: current status
# plus the one action available from it. Encrypt/Remove Encryption only ever
# request a migration (see taco_storage's requestEncrypt/requestDecrypt) -
# the actual migration runs at the pre-boot gate on the next launch (see
# app.tcl's OnStorageStatus / StorageGateDialog), not from here.
snit::widget storagesettingsdialog {
    hulltype ttk::frame
    option -tacky -default ::tacky -readonly yes

    variable Status ""

    typemethod open {parent} {
        set top .storagesettings
        if {[winfo exists $top]} {
            raise $top
            return
        }
        toplevel $top
        wm title $top "Local Storage"
        wm resizable $top 0 0
        if {$parent ne "" && [winfo exists $parent]} {
            wm transient $top $parent
        }
        pack [storagesettingsdialog $top.content] -expand yes -fill both
    }

    constructor args {
        $self configurelist $args

        ttk::frame $win.inner -padding 16
        ttk::label $win.inner.status -text "Checking..."
        ttk::label $win.inner.detail -wraplength 320 -justify left
        ttk::button $win.inner.action -text "..." -state disabled \
            -command [mymethod Action]

        pack $win.inner.status -anchor w -pady {0 4}
        pack $win.inner.detail -anchor w -fill x -pady 4
        pack $win.inner.action -pady {8 0}
        pack $win.inner -expand yes -fill both

        $options(-tacky) storage status -command [mymethod OnStatus]
    }

    destructor {
        catch {$options(-tacky) unlisten $win}
    }

    method OnStatus {status} {
        set Status $status
        switch -- $status {
            plaintext {
                $win.inner.status configure -text "Local storage is not encrypted."
                $win.inner.detail configure -text \
                    "Encrypting sets a passphrase you'll need to enter every time Tacky starts. There is no way to recover the data if you forget it. Takes effect the next time Tacky starts."
                $win.inner.action configure -text "Encrypt..." -state normal
            }
            unlocked {
                $win.inner.status configure -text "Local storage is encrypted."
                $win.inner.detail configure -text \
                    "Removing encryption writes everything back out as plaintext. Takes effect the next time Tacky starts."
                $win.inner.action configure -text "Remove Encryption..." -state normal
            }
            pending-encrypt {
                $win.inner.status configure -text "Local storage is not encrypted."
                $win.inner.detail configure -text \
                    "Encryption is set to be enabled the next time Tacky starts."
                $win.inner.action configure -text "Cancel Pending Encryption" -state normal
            }
            pending-decrypt {
                $win.inner.status configure -text "Local storage is encrypted."
                $win.inner.detail configure -text \
                    "Removing encryption is set to happen the next time Tacky starts."
                $win.inner.action configure -text "Cancel Pending Removal" -state normal
            }
            default {
                # locked: unreachable in practice, app.tcl's gate runs first.
                $win.inner.status configure -text "Local storage is locked."
                $win.inner.detail configure -text ""
                $win.inner.action configure -state disabled
            }
        }
    }

    method Action {} {
        switch -- $Status {
            plaintext { $self RequestEncrypt }
            unlocked  { $self RequestDecrypt }
            pending-encrypt - pending-decrypt { $self CancelPending }
        }
    }

    method RequestEncrypt {} {
        set args [list -type okcancel -icon warning -title "Encrypt Local Storage" \
            -message "You'll be asked to set a passphrase the next time Tacky starts. There is no way to recover your data if you forget it. Continue?" \
            -parent [winfo toplevel $win]]
        if {[tk_messageBox {*}$args] ne "ok"} return
        $options(-tacky) storage requestEncrypt \
            -command [mymethod OnRequestDone] -onerror [mymethod OnActionFailed]
    }

    method RequestDecrypt {} {
        set args [list -type yesno -icon warning -title "Remove Encryption" \
            -message "Local storage will be written back out as plaintext the next time Tacky starts. Continue?" \
            -parent [winfo toplevel $win]]
        if {[tk_messageBox {*}$args] ne "yes"} return
        $options(-tacky) storage requestDecrypt \
            -command [mymethod OnRequestDone] -onerror [mymethod OnActionFailed]
    }

    method CancelPending {} {
        $options(-tacky) storage cancelPending \
            -command [mymethod OnRequestDone] -onerror [mymethod OnActionFailed]
    }

    method OnRequestDone {args} {
        $options(-tacky) storage status -command [mymethod OnStatus]
    }

    method OnActionFailed {msg} {
        $win.inner.detail configure -text "Failed: $msg"
    }
}
