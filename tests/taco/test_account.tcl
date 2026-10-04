package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set common {
    -setup {
        tacky account add -acc user@example.com
        wait_call tacky account exists -acc user@example.com
    }
}

# -- exists ----------------------------------------------------------------

tacky_test account-exists-true {exists returns 1 for known account} \
    {*}$common \
    -body {
        wait_call tacky account exists -acc user@example.com
    } -result 1

tacky_test account-exists-false {exists returns 0 for unknown account} \
    {*}$common \
    -body {
        wait_call tacky account exists -acc nobody@example.com
    } -result 0

# -- list ------------------------------------------------------------------

tacky_test account-list-one {list returns JID after one add} \
    {*}$common \
    -body {
        wait_call tacky account list
    } -result {user@example.com}

tacky_test account-list-empty {list returns empty when no accounts} \
    -body {
        wait_call tacky account list
    } -result {}

# -- get -------------------------------------------------------------------

tacky_test account-get-all {get returns dict of all fields} \
    {*}$common \
    -body {
        set d [wait_call tacky account get -acc user@example.com]
        list [dict get $d jid] [dict get $d username] [dict get $d domain]
    } -result {user@example.com user example.com}

tacky_test account-get-field {get -field returns single value} \
    {*}$common \
    -body {
        wait_call tacky account get -acc user@example.com -field username
    } -result user

tacky_test account-get-noexist {get routes missing account to -onerror} \
    {*}$common \
    -body {
        wait_call_error tacky account get -acc nobody@example.com
    } -result {Account doesn't exist: nobody@example.com}

tacky_test account-get-badfield {get routes invalid field name to -onerror} \
    {*}$common \
    -body {
        wait_call_error tacky account get -acc user@example.com -field bogus
    } -result {Invalid field: bogus}

# -- token bookkeeping -----------------------------------------------------
# Only one of -command/-onerror fires, and a caller gating on `listening $tag`
# never asks again if the other is left behind.

tacky_test account-listening-clears-after-a-result \
    {a result releases the tag even though -onerror was supplied} \
    {*}$common \
    -body {
        set ::_done 0
        tacky account list -tag probe \
            -command {apply {{r} { set ::_done 1 }}} \
            -onerror {apply {{m} { set ::_done 1 }}}
        if {!$::_done} { vwait ::_done }
        tacky listening probe
    } -result 0

tacky_test account-listening-clears-after-an-error \
    {an error releases the tag even though -command was supplied} \
    {*}$common \
    -body {
        set ::_done 0
        tacky account get -acc user@example.com -field bogus -tag probe \
            -command {apply {{r} { set ::_done 1 }}} \
            -onerror {apply {{m} { set ::_done 1 }}}
        if {!$::_done} { vwait ::_done }
        tacky listening probe
    } -result 0

# -- MethodError -----------------------------------------------------------
# Must behave identically in all three transports; process used to swallow it.

tacky_test account-methoderror-fields {-command without -onerror emits MethodError} \
    {*}$common \
    -body {
        set e [wait_call_methoderror tacky account get -acc nobody@example.com]
        list [dict get $e -module] [dict get $e -method] \
            [dict get $e -acc] [dict get $e -message]
    } -result {account get nobody@example.com {Account doesn't exist: nobody@example.com}}

tacky_test account-methoderror-no-acc {MethodError omits -acc when the call had none} \
    {*}$common \
    -body {
        set e [wait_call_methoderror tacky account get]
        list [dict get $e -module] [dict exists $e -acc]
    } -result {account 0}

# -- resource --------------------------------------------------------------

tacky_test account-resource-format {resource returns tacky.<hex>} \
    {*}$common \
    -body {
        regexp {^tacky\.[0-9a-f]{8}$} [wait_call tacky account resource -acc user@example.com]
    } -result 1

tacky_test account-resource-stable {resource is stable across calls} \
    {*}$common \
    -body {
        set a [wait_call tacky account resource -acc user@example.com]
        set b [wait_call tacky account resource -acc user@example.com]
        expr {$a eq $b}
    } -result 1

tacky_test account-resource-persisted {resource is stored in the resource column} \
    {*}$common \
    -body {
        set r [wait_call tacky account resource -acc user@example.com]
        expr {$r eq [wait_call tacky account get -acc user@example.com -field resource]}
    } -result 1

tacky_test account-reroll-changes {rerollResource yields a new persisted resource} \
    {*}$common \
    -body {
        set a [wait_call tacky account resource -acc user@example.com]
        set b [wait_call tacky account rerollResource -acc user@example.com]
        set c [wait_call tacky account resource -acc user@example.com]
        expr {$a ne $b && $b eq $c}
    } -result 1

# -- add validation --------------------------------------------------------

tacky_test account-add-rejects-bad-domain {a comma for a dot is rejected, not silently added} \
    -body {
        catch {tacky account add -acc wusspuss@draugr,de}
        wait_call tacky account list
    } -result {}

tacky_test account-add-rejects-non-bare {a JID carrying a resource is rejected} \
    -body {
        catch {tacky account add -acc user@example.com/phone}
        wait_call tacky account list
    } -result {}

tacky_test account-add-rejects-no-localpart {a bare domain is not an account JID} \
    -body {
        catch {tacky account add -acc example.com}
        wait_call tacky account list
    } -result {}

tacky_test account-add-single-label-domain {a single-label domain is accepted} \
    -body {
        tacky account add -acc a@test
        wait_call tacky account list
    } -result {a@test}

# -- a plain method's synchronous error reaches the caller ------------------
#
# `add` is not a tackymethod, so before taco_call its error escaped the
# transport: it threw at the call site in direct mode and vanished into a
# background handler in the others, leaving the caller waiting forever. A
# regression is a failure rather than a hung suite because the wait itself has
# a deadline — these tests used to arm an `after` guard by hand for that.

tacky_test account-add-error-to-onerror {a plain method's error answers -onerror} \
    -body {
        wait_call_error tacky account add -acc "user@example,com"
    } -match glob -result {Invalid JID:*}

tacky_test account-add-error-methoderror {with -command alone the error becomes <MethodError>} \
    -body {
        set ev [wait_call_methoderror tacky account add -acc "user@example,com"]
        list [dict get $ev -module] [dict get $ev -method] \
            [string match {Invalid JID:*} [dict get $ev -message]]
    } -result {account add 1}

# -- port ------------------------------------------------------------------

tacky_test account-port-bad {only 1-65535 is taken} \
    {*}$common \
    -body {
        list [wait_call_error tacky account set -acc user@example.com -port 0] \
             [wait_call_error tacky account set -acc user@example.com -port 70000] \
             [wait_call_error tacky account set -acc user@example.com -port abc] \
             [wait_call tacky account get -acc user@example.com -field port]
    } -result {{Invalid port: 0} {Invalid port: 70000} {Invalid port: abc} 5222}

tacky_test account-port-reaches-client {the client dials the account's port, and enable carries a change} \
    -modes direct -mock conn \
    -body {
        tacky account add -acc a@example.com -port 5223
        tacky account add -acc b@example.com
        set before [list [[tacky client a@example.com] cget -port] \
                        [[tacky client b@example.com] cget -port]]
        tacky account set -acc b@example.com -port 15222
        tacky account enable -acc b@example.com
        list {*}$before [[tacky client b@example.com] cget -port]
    } -result {5223 5222 15222}

# -- websocket_url ---------------------------------------------------------

tacky_test account-websocket-url-default {a new account has none} \
    {*}$common \
    -body {
        set d [wait_call tacky account get -acc user@example.com]
        list [dict exists $d websocket_url] [dict get $d websocket_url]
    } -result {1 {}}

tacky_test account-websocket-url-on-add {it is taken on add, as the password is} \
    -body {
        tacky account add -acc a@example.com -password pw \
            -websocket_url ws://127.0.0.1:5280/xmpp-websocket
        wait_call tacky account get -acc a@example.com -field websocket_url
    } -result {ws://127.0.0.1:5280/xmpp-websocket}

tacky_test account-websocket-url-set {set changes it, and "" clears it} \
    {*}$common \
    -body {
        tacky account set -acc user@example.com -websocket_url wss://ws.example.com/x
        set a [wait_call tacky account get -acc user@example.com -field websocket_url]
        tacky account set -acc user@example.com -websocket_url ""
        list $a [wait_call tacky account get -acc user@example.com -field websocket_url]
    } -result {wss://ws.example.com/x {}}

tacky_test account-websocket-url-bad {anything but ws:// or wss:// is refused} \
    {*}$common \
    -body {
        list [wait_call_error tacky account set -acc user@example.com \
                  -websocket_url https://example.com/ws] \
             [wait_call_error tacky account set -acc user@example.com -websocket_url wss://] \
             [wait_call tacky account get -acc user@example.com -field websocket_url]
    } -result {{Invalid websocket_url: https://example.com/ws} {Invalid websocket_url: wss://} {}}

tacky_test account-websocket-url-reaches-client {the client dials the account's own endpoint} \
    -modes direct -mock conn \
    -body {
        tacky account add -acc a@example.com -websocket_url wss://ws.example.com/x
        tacky account add -acc b@example.com
        list [[tacky client a@example.com] cget -ws-url] [[tacky client b@example.com] cget -ws-url]
    } -result {wss://ws.example.com/x {}}

tacky_test account-websocket-url-enable-updates {enable carries a changed one to a client already made} \
    -modes direct -mock conn \
    -body {
        tacky account add -acc a@example.com
        set before [[tacky client a@example.com] cget -ws-url]
        tacky account set -acc a@example.com -websocket_url wss://ws.example.com/x
        tacky account enable -acc a@example.com
        list $before [[tacky client a@example.com] cget -ws-url]
    } -result {{} wss://ws.example.com/x}

test account-schema-upgrade {an accounts.db from before port and websocket_url gains both, rows intact} \
    -setup {
        sqlite3 ::_olddb :memory:
        ::_olddb eval {
            CREATE TABLE account(jid PRIMARY KEY, username, domain, password,
                                 resource, enabled INTEGER DEFAULT 0);
            INSERT INTO account(jid, username, domain, password, enabled)
                VALUES('old@example.com', 'old', 'example.com', 'secret', 1);
        }
    } -cleanup {
        catch {::_oldaccount destroy}
        ::_olddb close
    } -body {
        taco_account ::_oldaccount -db ::_olddb
        ::_olddb eval {SELECT password, enabled, port, websocket_url FROM account WHERE jid='old@example.com'}
    } -result {secret 1 5222 {}}
