package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set common {
    -setup {
        tacky account add -acc user@example.com
        tacky_await tacky account exists -acc user@example.com
    }
}

# -- exists ----------------------------------------------------------------

tacky_test account-exists-true {exists returns 1 for known account} \
    {*}$common \
    -body {
        tacky_await tacky account exists -acc user@example.com
    } -result 1

tacky_test account-exists-false {exists returns 0 for unknown account} \
    {*}$common \
    -body {
        tacky_await tacky account exists -acc nobody@example.com
    } -result 0

# -- list ------------------------------------------------------------------

tacky_test account-list-one {list returns JID after one add} \
    {*}$common \
    -body {
        tacky_await tacky account list
    } -result {user@example.com}

tacky_test account-list-empty {list returns empty when no accounts} \
    -body {
        tacky_await tacky account list
    } -result {}

# -- get -------------------------------------------------------------------

tacky_test account-get-all {get returns dict of all fields} \
    {*}$common \
    -body {
        set d [tacky_await tacky account get -acc user@example.com]
        list [dict get $d jid] [dict get $d username] [dict get $d domain]
    } -result {user@example.com user example.com}

tacky_test account-get-field {get -field returns single value} \
    {*}$common \
    -body {
        tacky_await tacky account get -acc user@example.com -field username
    } -result user

tacky_test account-get-noexist {get emits MethodError for missing account} \
    {*}$common \
    -body {
        tacky_await_error tacky account get -acc nobody@example.com
    } -result {Account doesn't exist: nobody@example.com}

tacky_test account-get-badfield {get emits MethodError for invalid field name} \
    {*}$common \
    -body {
        tacky_await_error tacky account get -acc user@example.com -field bogus
    } -result {Invalid field: bogus}

# -- resource --------------------------------------------------------------

tacky_test account-resource-format {resource returns tacky.<hex>} \
    {*}$common \
    -body {
        regexp {^tacky\.[0-9a-f]{8}$} [tacky_await tacky account resource -acc user@example.com]
    } -result 1

tacky_test account-resource-stable {resource is stable across calls} \
    {*}$common \
    -body {
        set a [tacky_await tacky account resource -acc user@example.com]
        set b [tacky_await tacky account resource -acc user@example.com]
        expr {$a eq $b}
    } -result 1

tacky_test account-resource-persisted {resource is stored in the resource column} \
    {*}$common \
    -body {
        set r [tacky_await tacky account resource -acc user@example.com]
        expr {$r eq [tacky_await tacky account get -acc user@example.com -field resource]}
    } -result 1

tacky_test account-reroll-changes {rerollResource yields a new persisted resource} \
    {*}$common \
    -body {
        set a [tacky_await tacky account resource -acc user@example.com]
        set b [tacky_await tacky account rerollResource -acc user@example.com]
        set c [tacky_await tacky account resource -acc user@example.com]
        expr {$a ne $b && $b eq $c}
    } -result 1
