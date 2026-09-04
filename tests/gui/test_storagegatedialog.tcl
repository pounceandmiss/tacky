# Unit tests for StorageGateDialog.
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco

# Same withdrawn-parent hazard as StorageUnlockDialog (see
# test_storageunlockdialog.tcl) - OnStorageStatus can show this dialog while
# "." is still withdrawn too.
test storagegatedialog-no-transient-for-withdrawn-parent \
    {a withdrawn "." parent is never set as wm transient, and the dialog still reaches state normal} \
    -setup {
        wm withdraw .
        set ::_sgd_state ""
        set ::_sgd_transient ""
        after idle {
            set ::_sgd_state [wm state .storagegate]
            set ::_sgd_transient [wm transient .storagegate]
            set ::_storagegate_done 1
        }
    } -cleanup {
        wm deiconify .
        wm attributes . -topmost 1
        raise .
        unset -nocomplain ::_sgd_state ::_sgd_transient
    } -body {
        StorageGateDialog . encrypt
        list $::_sgd_state $::_sgd_transient
    } -result {normal {}}

# Unlike StorageUnlockDialog, there's always a safe fallback here (stay in
# the current, not-yet-migrated state), so Cancel is offered and must
# actually call the backend's cancelPending rather than just closing.
test storagegatedialog-cancel-calls-cancelpending-without-migrating \
    {Cancel calls the backend's cancelPending and closes without ever migrating} \
    -setup {
        set cfg [file tempdir tacky-sgdtest]
        set data [file join $cfg data]
        set cache [file join $cfg cache]
        file mkdir $data $cache
        tacky_type create tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
        after idle {
            .storagegate.inner.btns.cancel invoke
        }
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        StorageGateDialog . encrypt
        tacky storage status
    } -result {plaintext}

# The passphrase entry only makes sense for encrypt (a fresh passphrase is
# being set); decrypt already has one in memory from the unlock that
# revealed pending-decrypt.
test storagegatedialog-passphrase-widget-only-for-encrypt \
    {the passphrase entry is present for encrypt and absent for decrypt} \
    -setup {
        after idle {
            set ::_sgd_has_entry [winfo exists .storagegate.inner.e]
            set ::_storagegate_done 1
        }
    } -cleanup {
        unset -nocomplain ::_sgd_has_entry
    } -body {
        StorageGateDialog . encrypt
        set encryptHasEntry $::_sgd_has_entry
        after idle {
            set ::_sgd_has_entry [winfo exists .storagegate.inner.e]
            set ::_storagegate_done 1
        }
        StorageGateDialog . decrypt
        list encrypt=$encryptHasEntry decrypt=$::_sgd_has_entry
    } -result {encrypt=1 decrypt=0}
