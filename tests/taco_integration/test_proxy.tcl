package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# An account behind a real SOCKS5 proxy (Dante). Run jailed, by
#
#   tests/servers/with_prosody.sh tests/servers/with_socks5.sh <suite>
#
# which leaves the proxy the only address the suite can reach: the server, its
# HTTP upload service and any DNS are all refused, so a test passing here went
# through the proxy and nowhere else.

::tcltest::testConstraint socks5Jail \
    [expr {[info exists ::env(SOCKS5_PROXY)] && $::env(SOCKS5_PROXY) ne ""}]

namespace eval ::test::proxy {
    variable HOST "example.local"
    variable ACC "romeo@example.local"
    variable TIMEOUT 30000

    proc proxy {} { return $::env(SOCKS5_PROXY) }

    # The jail's proxy with the password changed
    proc wrongProxy {} {
        regsub {:[^:@]*@} [proxy] {:wrongpass@} wrong
        return $wrong
    }

    proc setup {{proxy ""}} {
        variable HOST
        variable ACC
        if {$proxy eq ""} { set proxy [proxy] }
        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ACC \
            -password romeopass -domain $HOST -username romeo -proxy $proxy
    }

    proc online {} {
        variable ACC
        setup
        tacky account enable -acc $ACC
        wait_events [list [list conn <State> -acc $ACC -state connected]] 20000
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    # As test_upload.tcl's: the first file <Update> in $direction that is no
    # longer active
    proc finished {direction script} {
        variable ACC
        variable TIMEOUT
        set var [namespace current]::_done
        set $var ""
        set tag [tacky listen file <Update> -acc $ACC -direction $direction \
            [list apply {{var argsL} {
                if {[dict get $argsL -state] ne "active" && [set $var] eq ""} {
                    set $var $argsL
                }
            }} $var]]
        uplevel 1 $script
        try {
            wait_var $var $TIMEOUT
        } finally {
            tacky unlisten $tag
        }
        return [set $var]
    }

    # The next conn <Error> message
    proc nextError {script} {
        variable ACC
        set var [namespace current]::_err
        set $var ""
        set tag [tacky listen conn <ConnError> -acc $ACC [list apply {{var argsL} {
            if {[set $var] eq ""} { set $var [dict get $argsL -message] }
        }} $var]]
        uplevel 1 $script
        try {
            wait_var $var 20000
        } finally {
            tacky unlisten $tag
        }
        return [set $var]
    }
}

test proxy-int-connects {the account comes online through the proxy} \
    -constraints {withServer && socks5Jail} \
    -setup ::test::proxy::online -cleanup ::test::proxy::cleanup -body {
        [tacky client $::test::proxy::ACC] conn state
    } -result connected

test proxy-int-upload-round-trip {a file goes up and comes back down through the proxy} \
    -constraints {withServer && socks5Jail && notMongoose} \
    -setup ::test::proxy::online -cleanup ::test::proxy::cleanup -body {
        set acc $::test::proxy::ACC
        set data "proxied [clock milliseconds]\n[string repeat y 70000]\nend\n"
        set path [file join [temporaryDirectory] proxy-upload.txt]
        set f [open $path wb]
        puts -nonewline $f $data
        close $f
        set up [::test::proxy::finished upload {
            tacky file upload -acc $acc -path $path
        }]
        set down [::test::proxy::finished download {
            tacky file download -acc $acc -url [dict get $up -url]
        }]
        file delete $path
        set local [dict get $down -localpath]
        set f [open $local rb]
        set got [read $f]
        close $f
        list [dict get $up -state] [dict get $up -error] \
            [dict get $down -state] [dict get $down -error] [expr {$got eq $data}]
    } -result {done {} done {} 1}

test proxy-int-bad-credentials {a proxy refusing the credentials fails the link} \
    -constraints {withServer && socks5Jail} \
    -setup {::test::proxy::setup [::test::proxy::wrongProxy]} \
    -cleanup ::test::proxy::cleanup -body {
        ::test::proxy::nextError {
            tacky account enable -acc $::test::proxy::ACC
        }
    } -result {Connect failed: proxy rejected credentials}

test proxy-int-change-drops-link {a new proxy takes the live link down with it} \
    -constraints {withServer && socks5Jail} \
    -setup ::test::proxy::online -cleanup ::test::proxy::cleanup -body {
        set seen [expect_events [list \
            [list conn <State> -acc $::test::proxy::ACC -state disconnected]]]
        set err [::test::proxy::nextError {
            tacky account set -acc $::test::proxy::ACC \
                -proxy [::test::proxy::wrongProxy]
        }]
        wait_expected $seen
        set err
    } -result {Connect failed: proxy rejected credentials}

test proxy-int-change-is-a-new-session {back on a working proxy, the same client logs in afresh rather than resuming} \
    -constraints {withServer && socks5Jail} \
    -setup ::test::proxy::online -cleanup ::test::proxy::cleanup -body {
        set acc $::test::proxy::ACC
        set old [namespace qualifiers [lindex [[tacky client $acc] info vars] 0]]
        ::test::proxy::nextError {
            tacky account set -acc $acc -proxy [::test::proxy::wrongProxy]
        }
        tacky account set -acc $acc -proxy [::test::proxy::proxy]
        wait_events [list [list conn <State> -acc $acc -state connected]] 20000
        set c [tacky client $acc]
        list [expr {[namespace qualifiers [lindex [$c info vars] 0]] eq $old}] \
            [dict get [[$c conn sm] getInfo] resumed]
    } -result {1 0}

test proxy-int-no-calls {calls are refused while a proxy is set} \
    -constraints {withServer && socks5Jail} \
    -setup ::test::proxy::online -cleanup ::test::proxy::cleanup -body {
        set ::_proxyMethodError ""
        set tag [tacky listen error <MethodError> {apply {{a} {
            set ::_proxyMethodError [dict get $a -message]
        }}}]
        [tacky client $::test::proxy::ACC] calls start -to juliet@example.local
        wait_var ::_proxyMethodError 5000
        tacky unlisten $tag
        set ::_proxyMethodError
    } -result {Calls are disabled while a proxy is configured}
