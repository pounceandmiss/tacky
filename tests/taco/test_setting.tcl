package require tcltest
namespace import ::tcltest::*
package require libtacky

set common {
    -setup   {tacky_type create ::tacky}
    -cleanup {tacky destroy}
}

proc ::_test_cb {result} {
    lappend ::_cb $result
}

# -- get -------------------------------------------------------------------

test setting-get-value {get returns stored value} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        tacky setting get -key theme
    } -result {dark}

test setting-get-missing {get returns empty string for missing key} \
    {*}$common \
    -body {
        tacky setting get -key nonexistent
    } -result {}

test setting-get-command {get with -command calls back result} \
    {*}$common \
    -body {
        tacky setting set -key lang -value en
        set ::_cb {}
        tacky setting get -key lang -command ::_test_cb
        set ::_cb
    } -result {en}

test setting-get-missing-command {get with -command calls back empty string for missing key} \
    {*}$common \
    -body {
        set ::_cb {}
        tacky setting get -key missing -command ::_test_cb
        set ::_cb
    } -result {{}}

# -- set -------------------------------------------------------------------

test setting-set-insert {set inserts a new key} \
    {*}$common \
    -body {
        tacky setting set -key color -value blue
        tacky setting get -key color
    } -result {blue}

test setting-set-overwrite {set overwrites an existing key} \
    {*}$common \
    -body {
        tacky setting set -key color -value blue
        tacky setting set -key color -value red
        tacky setting get -key color
    } -result {red}

# -- list ------------------------------------------------------------------

test setting-list-empty {list returns empty when no settings} \
    {*}$common \
    -body {
        tacky setting list
    } -result {}

test setting-list-populated {list returns all keys} \
    {*}$common \
    -body {
        tacky setting set -key a -value 1
        tacky setting set -key b -value 2
        lsort [tacky setting list]
    } -result {a b}

test setting-list-command {list with -command calls back result} \
    {*}$common \
    -body {
        tacky setting set -key x -value 1
        set ::_cb {}
        tacky setting list -command ::_test_cb
        set ::_cb
    } -result {x}

# -- event -----------------------------------------------------------------

test setting-event-changed {set emits setting <Changed> with correct args} \
    {*}$common \
    -body {
        set ::_events {}
        tacky listen setting <Changed> {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky setting set -key font -value mono
        set ::_events
    } -result {{-key font -value mono}}

# -- pull ------------------------------------------------------------------

test setting-pull-emits-current {pull emits <Changed> with current value} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        set ::_events {}
        tacky listen setting <Changed> {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky setting pull -key theme
        set ::_events
    } -result {{-key theme -value dark}}

test setting-pull-missing {pull emits <Changed> with empty value for absent key} \
    {*}$common \
    -body {
        set ::_events {}
        tacky listen setting <Changed> {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky setting pull -key nope
        set ::_events
    } -result {{-key nope -value {}}}

# -- observe ---------------------------------------------------------------

test setting-observe-initial {observe fires once with the current value on subscribe} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        set ::_events {}
        tacky observe setting <Changed> -key theme {apply {{ev} {
            lappend ::_events $ev
        }}}
        set ::_events
    } -result {{-key theme -value dark}}

test setting-observe-initial-missing {observe fires with empty value for unset key} \
    {*}$common \
    -body {
        set ::_events {}
        tacky observe setting <Changed> -key blank {apply {{ev} {
            lappend ::_events $ev
        }}}
        set ::_events
    } -result {{-key blank -value {}}}

test setting-observe-subsequent {observe continues to fire on later set} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        set ::_events {}
        tacky observe setting <Changed> -key theme {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky setting set -key theme -value light
        set ::_events
    } -result {{-key theme -value dark} {-key theme -value light}}

test setting-observe-filter {observe -key filter ignores other keys} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        set ::_events {}
        tacky observe setting <Changed> -key theme {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky setting set -key lang -value en
        tacky setting set -key theme -value light
        set ::_events
    } -result {{-key theme -value dark} {-key theme -value light}}

test setting-observe-unlisten {unlisten by tag stops further dispatches} \
    {*}$common \
    -body {
        tacky setting set -key theme -value dark
        set ::_events {}
        tacky observe -tag mytag setting <Changed> -key theme {apply {{ev} {
            lappend ::_events $ev
        }}}
        tacky unlisten mytag
        tacky setting set -key theme -value light
        set ::_events
    } -result {{-key theme -value dark}}
