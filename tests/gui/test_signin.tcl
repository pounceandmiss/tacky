# Unit tests for the sign-in dialog.
package require tcltest
namespace import ::tcltest::*

test signin-connerror-ends-attempt {a connection error stops the spinner, shows why, and drops the account} -setup {
    mock_backend_up
} -body {
    signin .si
    set data [.si info vars Data]
    set ${data}(jid) new@unreachable.example.com
    set ${data}(password) pw
    .si Proceed
    tacky emit conn <ConnError> -acc new@unreachable.example.com -message unreachable
    wait
    list [.si.statuslabel cget -text] [.si.proceed cget -text] \
        [tacky account exists -acc new@unreachable.example.com]
} -cleanup {
    destroy .si
    mock_backend_down
} -result {unreachable Proceed 0}

proc si_conn {w var value} {
    set [$w info vars $var] $value
}

test signin-custom-address-reaches-account {a custom host, port and security are stored with the account} -setup {
    mock_backend_up
} -body {
    signin .si
    set data [.si info vars Data]
    set ${data}(jid) new@example.com
    set ${data}(password) pw
    si_conn .si.connection custom 1
    si_conn .si.connection host xmpp.example.com
    si_conn .si.connection port 5223
    si_conn .si.connection mode "Direct TLS"
    .si Proceed
    wait
    set d [tacky account get -acc new@example.com]
    list [dict get $d host] [dict get $d port] [dict get $d tls]
} -cleanup {
    destroy .si
    catch {tacky account remove -acc new@example.com}
    mock_backend_down
} -result {xmpp.example.com 5223 direct}

test signin-plain-address-is-automatic {with the box unticked, nothing is set} -setup {
    mock_backend_up
} -body {
    signin .si
    set data [.si info vars Data]
    set ${data}(jid) new@example.com
    set ${data}(password) pw
    si_conn .si.connection host ignored.example.com
    .si Proceed
    wait
    set d [tacky account get -acc new@example.com]
    list [dict get $d host] [dict get $d port] [dict get $d tls]
} -cleanup {
    destroy .si
    catch {tacky account remove -acc new@example.com}
    mock_backend_down
} -result {{} 0 auto}

test signin-bad-host-says-why {a host the backend refuses is shown, and no account is left} -setup {
    mock_backend_up
} -body {
    signin .si
    set data [.si info vars Data]
    set ${data}(jid) new@example.com
    set ${data}(password) pw
    si_conn .si.connection custom 1
    si_conn .si.connection host https://x
    .si Proceed
    wait
    list [.si.statuslabel cget -text] [.si.proceed cget -text] \
        [tacky account exists -acc new@example.com]
} -cleanup {
    destroy .si
    mock_backend_down
} -result {{Invalid host: https://x} Proceed 0}

test signin-none-warns {choosing no encryption shows the warning} -setup {
    mock_backend_up
} -body {
    signin .si
    si_conn .si.connection custom 1
    set before [winfo manager .si.connection.fields.warning]
    si_conn .si.connection mode "None (unencrypted)"
    list $before [winfo manager .si.connection.fields.warning]
} -cleanup {
    destroy .si
    mock_backend_down
} -result {{} grid}
