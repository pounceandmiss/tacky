# Unit tests for changepassworddialog.
package require tcltest
namespace import ::tcltest::*

set cpd_top .chpass_[path_safe user@test.example.com]

proc cpd_open {} {
    changepassworddialog open user@test.example.com \
        -command {lappend ::cpd_done ok}
    wait
}

proc cpd_type {new} {
    $::cpd_top.d.new delete 0 end
    $::cpd_top.d.new insert 0 $new
}

# The register IQ the dialog wrote, if any.
proc cpd_written {} {
    foreach s [$::_client.conn get_written] {
        if {[xsearch $s query -get ns] eq "jabber:iq:register"} {
            return [xsearch $s query password -get body]
        }
    }
    return ""
}

proc cpd_reply {args} {
    $::_client.conn feed [j iq -from test.example.com \
        -id [xsearch [lindex [$::_client.conn get_written] end] -get @id] {*}$args]
    wait
}

test changepassworddialog-change-needs-text {Change stays disabled while the field is empty} -setup {
    mock_backend_up
    cpd_open
} -body {
    set b $::cpd_top.d.btns.change
    set r [$b instate disabled]
    cpd_type secret
    lappend r [$b instate disabled]
    cpd_type ""
    lappend r [$b instate disabled]
} -cleanup {
    destroy $::cpd_top
    mock_backend_down
} -result {1 0 1}

# Under Xvfb there is no WM to focus the window, and an unfocused window drops
# generated key events.
proc cpd_return {} {
    focus -force $::cpd_top.d.new.entry
    update
    event generate $::cpd_top.d.new.entry <Return>
    wait
}

test changepassworddialog-return-sends {Return sends the change, and only with text in the field} -setup {
    mock_backend_up
    cpd_open
} -body {
    cpd_return
    set before [cpd_written]
    cpd_type secret
    cpd_return
    list $before [cpd_written]
} -cleanup {
    destroy $::cpd_top
    mock_backend_down
} -result {{} secret}

test changepassworddialog-success-closes {a confirmed change closes the dialog and calls back} -setup {
    mock_backend_up
    set ::cpd_done {}
    cpd_open
} -body {
    cpd_type secret
    $::cpd_top.d.btns.change invoke
    wait
    set sent [cpd_written]
    cpd_reply -type result
    list $sent [winfo exists $::cpd_top] $::cpd_done \
        [tacky account get -acc user@test.example.com -field password]
} -cleanup {
    catch {destroy $::cpd_top}
    unset -nocomplain ::cpd_done
    mock_backend_down
} -result {secret 0 ok secret}

test changepassworddialog-error-stays {a rejected change keeps the dialog open with the reason} -setup {
    mock_backend_up
    set ::cpd_done {}
    cpd_open
} -body {
    cpd_type secret
    $::cpd_top.d.btns.change invoke
    wait
    cpd_reply -type error {
        j error -type modify {
            j not-acceptable -ns urn:ietf:params:xml:ns:xmpp-stanzas
            j text -ns urn:ietf:params:xml:ns:xmpp-stanzas -body "Too weak"
        }
    }
    list [winfo exists $::cpd_top] [$::cpd_top.d.msg cget -text] \
        [$::cpd_top.d.btns.change instate disabled] $::cpd_done
} -cleanup {
    destroy $::cpd_top
    unset -nocomplain ::cpd_done
    mock_backend_down
} -result {1 {Password not changed: Too weak} 0 {}}
