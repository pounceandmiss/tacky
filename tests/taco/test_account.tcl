set common {
    -setup {
        tacky_type create tacky
        tacky account add -acc user@example.com
    }
    -cleanup {
        tacky destroy
    }
}

set common_empty {
    -setup {
        tacky_type create tacky
    }
    -cleanup {
        tacky destroy
    }
}

proc ::_test_cb {result} {
    lappend ::_cb $result
}

# -- exists ----------------------------------------------------------------

test account-exists-true {exists returns 1 for known account} \
    {*}$common \
    -body {
        tacky account exists -acc user@example.com
    } -result 1

test account-exists-false {exists returns 0 for unknown account} \
    {*}$common \
    -body {
        tacky account exists -acc nobody@example.com
    } -result 0

test account-exists-command {exists with -command calls back result} \
    {*}$common \
    -body {
        set ::_cb {}
        tacky account exists -acc user@example.com -command ::_test_cb
        set ::_cb
    } -result {1}

# -- list ------------------------------------------------------------------

test account-list-one {list returns JID after one add} \
    {*}$common \
    -body {
        tacky account list
    } -result {user@example.com}

test account-list-empty {list returns empty when no accounts} \
    {*}$common_empty \
    -body {
        tacky account list
    } -result {}

test account-list-command {list with -command calls back result} \
    {*}$common \
    -body {
        set ::_cb {}
        tacky account list -command ::_test_cb
        set ::_cb
    } -result {user@example.com}

# -- get -------------------------------------------------------------------

test account-get-all {get returns dict of all fields} \
    {*}$common \
    -body {
        set d [tacky account get -acc user@example.com]
        list [dict get $d jid] [dict get $d username] [dict get $d domain]
    } -result {user@example.com user example.com}

test account-get-field {get -field returns single value} \
    {*}$common \
    -body {
        tacky account get -acc user@example.com -field username
    } -result user

test account-get-noexist {get errors on nonexistent account} \
    {*}$common \
    -body {
        tacky account get -acc nobody@example.com
    } -returnCodes error -result {Account doesn't exist: nobody@example.com}

test account-get-badfield {get errors on invalid field name} \
    {*}$common \
    -body {
        tacky account get -acc user@example.com -field bogus
    } -returnCodes error -result {Invalid field: bogus}

test account-get-command-ok {get with -command calls back result} \
    {*}$common \
    -body {
        set ::_cb {}
        tacky account get -acc user@example.com -field username -command ::_test_cb
        set ::_cb
    } -result {user}

test account-get-command-noexist {get with -command emits MethodError for missing account} \
    {*}$common \
    -body {
        set ::_ev {}
        tacky listen error <MethodError> {apply {{ev} {
            lappend ::_ev [dict get $ev -message]
        }}}
        tacky account get -acc nobody@example.com -command ::_test_cb
        set ::_ev
    } -result {{Account doesn't exist: nobody@example.com}}

test account-get-command-badfield {get with -command emits MethodError for bad field} \
    {*}$common \
    -body {
        set ::_ev {}
        tacky listen error <MethodError> {apply {{ev} {
            lappend ::_ev [dict get $ev -message]
        }}}
        tacky account get -acc user@example.com -field bogus -command ::_test_cb
        set ::_ev
    } -result {{Invalid field: bogus}}
