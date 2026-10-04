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
