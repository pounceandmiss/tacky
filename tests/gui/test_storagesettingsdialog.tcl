# Unit tests for storagesettingsdialog.
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco

# The dialog no longer drives migration or shows progress itself (that
# moved to the pre-boot gate, see storagegatedialog.tcl) - it just requests
# or cancels a pending migration, with the action button's label/state
# tracking each possible `storage status` value.
test storagesettingsdialog-button-tracks-status \
    {the action button's label and enabled state track each storage status} \
    -setup {
        tacky_type create tacky
    } -body {
        storagesettingsdialog .sswtest -tacky tacky
        pack .sswtest
        wait
        set results {}
        foreach status {plaintext pending-encrypt unlocked pending-decrypt locked} {
            .sswtest OnStatus $status
            lappend results [list $status \
                [.sswtest.inner.action cget -text] \
                [.sswtest.inner.action cget -state]]
        }
        set results
    } -cleanup {
        destroy .sswtest
        tacky destroy
    } -result [list \
        {plaintext Encrypt... normal} \
        {pending-encrypt {Cancel Pending Encryption} normal} \
        {unlocked {Remove Encryption...} normal} \
        {pending-decrypt {Cancel Pending Removal} normal} \
        {locked {Cancel Pending Removal} disabled}]

# Cancel needs no confirmation dialog (unlike Request*, which show a real
# tk_messageBox this suite doesn't drive), so it's the one Action path
# exercisable end-to-end here: a real pending-encrypt marker, Action calls
# through to the backend's cancelPending, and the dialog re-fetches and
# reflects the real resulting status.
test storagesettingsdialog-action-cancel-round-trips-through-backend \
    {Action on a pending status calls the backend's cancelPending and refreshes} \
    -setup {
        set cfg [file tempdir tacky-sswtest]
        set data [file join $cfg data]
        set cache [file join $cfg cache]
        file mkdir $data $cache
        tacky_type create tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
    } -body {
        storagesettingsdialog .sswtest2 -tacky tacky
        pack .sswtest2
        wait
        set before [tacky storage status]
        set button [.sswtest2.inner.action cget -text]
        .sswtest2 Action
        wait
        list before=$before button=$button after=[tacky storage status]
    } -cleanup {
        destroy .sswtest2
        tacky destroy
        file delete -force $cfg
    } -result {before=pending-encrypt {button=Cancel Pending Encryption} after=plaintext}
