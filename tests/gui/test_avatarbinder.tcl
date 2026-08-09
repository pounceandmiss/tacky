# avatarbinder owns which avatar image belongs to which JID for as long as that
# JID is drawn. No widget here: a fake host records the repaints it is told to
# make, which is the whole of its output.

proc ab_new {} {
    catch {ab destroy}
    set ::ab_repaints {}
    avatarbinder ab -acc user@test.example.com -tag ab_test \
        -repaint-command {apply {{jid image} {
            lappend ::ab_repaints $jid
        }}}
    return ab
}

proc ab_cleanup {} {
    catch {ab destroy}
    unset -nocomplain ::ab_repaints
    mock_backend_down
}

set ab_common {
    -setup   { mock_backend_up; ab_new }
    -cleanup { ab_cleanup }
}

test avatarbinder-knows-nothing-until-told {an untracked JID has no image of its own} \
    {*}$ab_common \
    -body {
        ab image alice@example.com
    } -result {}

test avatarbinder-track-yields-an-image {tracking a JID produces an image and one repaint} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        list [expr {[ab image alice@example.com] ne ""}] $::ab_repaints
    } -result {1 alice@example.com}

test avatarbinder-track-is-idempotent {every message by one author tracks, but only the first does anything} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        ab track alice@example.com
        ab track alice@example.com
        set ::ab_repaints
    } -result {alice@example.com}

test avatarbinder-release-forgets-the-image {a released JID goes back to having no image} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        set held [expr {[ab image alice@example.com] ne ""}]
        ab release alice@example.com
        list $held [ab image alice@example.com]
    } -result {1 {}}

test avatarbinder-release-then-track-again {a JID scrolled away and back is tracked afresh} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        ab release alice@example.com
        ab track alice@example.com
        list [expr {[ab image alice@example.com] ne ""}] $::ab_repaints
    } -result {1 {alice@example.com alice@example.com}}

test avatarbinder-release-of-an-untracked-jid-is-quiet {releasing what was never tracked does nothing} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        ab release bob@example.com
        ab release bob@example.com
        list [expr {[ab image alice@example.com] ne ""}] $::ab_repaints
    } -result {1 alice@example.com}

test avatarbinder-releaseall-drops-every-jid {tearing down releases each tracked JID} \
    {*}$ab_common \
    -body {
        ab track alice@example.com
        ab track bob@example.com
        ab releaseAll
        list [ab image alice@example.com] [ab image bob@example.com]
    } -result {{} {}}
