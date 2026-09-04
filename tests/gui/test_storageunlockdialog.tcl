# Unit tests for StorageUnlockDialog.
package require tcltest
namespace import ::tcltest::*

# Regression: the dialog set `wm transient` against its -parent whenever
# that parent existed, even when it was app.tcl's own withdrawn "." at
# startup (no account window exists yet while locked). Several window
# managers refuse to map a window transient for an unmapped one, which left
# the dialog invisible and the app looking hung with no error at all.
#
# Runs the assertion from an `after idle` callback scheduled before the
# call: StorageUnlockDialog's own vwait services it while still blocked, so
# the window's real wm state can be inspected before the dialog closes -
# and setting the done var from there stands in for a user unlocking, with
# no real backend/passphrase needed to exercise the windowing behavior.
test storageunlockdialog-no-transient-for-withdrawn-parent \
    {a withdrawn "." parent is never set as wm transient, and the dialog still reaches state normal} \
    -setup {
        wm withdraw .
        set ::_sud_state ""
        set ::_sud_transient ""
        after idle {
            set ::_sud_state [wm state .storageunlock]
            set ::_sud_transient [wm transient .storageunlock]
            set ::_storageunlock_done 1
        }
    } -cleanup {
        wm deiconify .
        wm attributes . -topmost 1
        raise .
        unset -nocomplain ::_sud_state ::_sud_transient
    } -body {
        StorageUnlockDialog .
        list $::_sud_state $::_sud_transient
    } -result {normal {}}

# A real (mapped) parent is still used as transient-for - only a withdrawn
# one is skipped.
test storageunlockdialog-transient-for-mapped-parent \
    {a real, mapped parent is set as wm transient} \
    -setup {
        toplevel .sudtestparent
        wm deiconify .sudtestparent
        set ::_sud_transient ""
        after idle {
            set ::_sud_transient [wm transient .storageunlock]
            set ::_storageunlock_done 1
        }
    } -cleanup {
        catch {destroy .sudtestparent}
        unset -nocomplain ::_sud_transient
    } -body {
        StorageUnlockDialog .sudtestparent
        set ::_sud_transient
    } -result {.sudtestparent}
