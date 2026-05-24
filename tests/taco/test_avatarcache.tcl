package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# Test-only subclass: uses simple strings as "image" handles.
oo::class create test_avatarcache {
    superclass avatarcache_base
    variable Counter

    constructor {} {
        set Counter 0
        next
    }

    method CreateImage {data} {
        return "img[incr Counter]:$data"
    }

    method DeleteImage {img} {
        lappend ::deleted_images $img
    }

    method CreateDefault {} {
        return "default[incr Counter]"
    }
}

set ac_common [tacky_env -mock conn \
    -account user@test \
    -bound-jid user@test/res \
    -avatarcache test_avatarcache \
    -extra-setup {set ::deleted_images {}}]

# -- track / untrack --------------------------------------------------------

test avatarcache-track-returns-default {track returns default image initially} \
    {*}$ac_common \
    -body {
        set img [avatarcache track \
            -acc user@test -jid c@d -tag t1 -command {apply {{img} {}}}]
        string match "default*" $img
    } -result 1

test avatarcache-track-refcount {second track for same jid bumps refcount} \
    {*}$ac_common \
    -body {
        set img1 [avatarcache track \
            -acc user@test -jid c@d -tag t1 -command {apply {{img} {}}}]
        set img2 [avatarcache track \
            -acc user@test -jid c@d -tag t2 -command {apply {{img} {}}}]
        expr {$img1 eq $img2}
    } -result 1

test avatarcache-untrack-last {untrack last ref deletes image} \
    {*}$ac_common \
    -body {
        avatarcache track \
            -acc user@test -jid c@d -tag t1 -command {apply {{img} {}}}
        set ::deleted_images {}
        avatarcache untrack -tag t1
        llength $::deleted_images
    } -result 1

test avatarcache-untrack-not-last {untrack with remaining refs does not delete} \
    {*}$ac_common \
    -body {
        avatarcache track \
            -acc user@test -jid c@d -tag t1 -command {apply {{img} {}}}
        avatarcache track \
            -acc user@test -jid c@d -tag t2 -command {apply {{img} {}}}
        set ::deleted_images {}
        avatarcache untrack -tag t1
        llength $::deleted_images
    } -result 0

test avatarcache-untrack-unknown {untrack unknown tag is a no-op} \
    {*}$ac_common \
    -body {
        avatarcache untrack -tag nonexistent
    } -result {}

# -- notify ----------------------------------------------------------------

test avatarcache-notify-disabled {disabled action reverts to default} \
    {*}$ac_common \
    -body {
        set ::notified {}
        avatarcache track \
            -acc user@test -jid c@d -tag t1 \
            -command {apply {{img} {lappend ::notified $img}}}
        set ::deleted_images {}
        tacky emit avatar <Update> -acc user@test -jid c@d -action disabled
        list \
            [llength $::notified] \
            [string match "default*" [lindex $::notified 0]] \
            [llength $::deleted_images]
    } -result {1 1 1}

test avatarcache-notify-untracked-not-called {untracked tag not notified} \
    {*}$ac_common \
    -body {
        set ::n1 {}
        set ::n2 {}
        avatarcache track \
            -acc user@test -jid c@d -tag t1 \
            -command {apply {{img} {lappend ::n1 $img}}}
        avatarcache track \
            -acc user@test -jid c@d -tag t2 \
            -command {apply {{img} {lappend ::n2 $img}}}
        avatarcache untrack -tag t1
        tacky emit avatar <Update> -acc user@test -jid c@d -action disabled
        list [llength $::n1] [llength $::n2]
    } -result {0 1}

# -- isolation -------------------------------------------------------------

test avatarcache-different-acc {same jid different acc are independent} \
    {*}[tacky_env -mock conn -extra-setup {
        set ::deleted_images {}
        tacky account add -acc a@test
        tacky account add -acc b@test
        set _ca [tacky client a@test]
        set _cb [tacky client b@test]
        $_ca.conn configure -bound-jid a@test/r
        $_cb.conn configure -bound-jid b@test/r
        $_ca.conn fire_ready 0
        $_cb.conn fire_ready 0
        test_avatarcache create avatarcache
    } -extra-cleanup {avatarcache destroy}] \
    -body {
        set img1 [avatarcache track \
            -acc a@test -jid c@d -tag t1 -command {apply {{img} {}}}]
        set img2 [avatarcache track \
            -acc b@test -jid c@d -tag t2 -command {apply {{img} {}}}]
        expr {$img1 ne $img2}
    } -result 1

test avatarcache-different-jid {same acc different jid are independent} \
    {*}$ac_common \
    -body {
        set img1 [avatarcache track \
            -acc user@test -jid c@d -tag t1 -command {apply {{img} {}}}]
        set img2 [avatarcache track \
            -acc user@test -jid e@f -tag t2 -command {apply {{img} {}}}]
        expr {$img1 ne $img2}
    } -result 1

# -- default ---------------------------------------------------------------

test avatarcache-default {default returns the shared default image} \
    {*}$ac_common \
    -body {
        string match "default*" [avatarcache default]
    } -result 1
