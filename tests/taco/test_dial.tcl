package require tcltest
namespace import ::tcltest::*
package require taco

source [file join [file dirname [info script]] dns_responder.tcl]

# No sockets in the wasm build
testConstraint wasm [expr {$::tcl_platform(os) eq "Emscripten"}]

proc dial_with {records args} {
    set port [dnsresp::start $records]
    set ::_dial_result ""
    try {
        dial::targets -domain example.org {*}$args \
            -nameservers [list [list 127.0.0.1 $port]] \
            -command {apply {{t} { set ::_dial_result [list done $t] }}}
        if {$::_dial_result eq ""} {
            set id [after 10000 {set ::_dial_result timeout}]
            vwait ::_dial_result
            after cancel $id
        }
    } finally {
        dnsresp::stop
    }
    return [lindex $::_dial_result 1]
}

set dial_common {
    -constraints !wasm
    -setup {
        jlog configure -logproc {apply {{msg} {}}}
        set ::_saved_timeout $::dial::timeout
    }
    -cleanup {
        set ::dial::timeout $::_saved_timeout
        jlog configure -logproc ""
    }
}

test dial-srv-merges-both-kinds {direct TLS and STARTTLS records share one priority order, then the domain} \
    {*}$dial_common -body {
        dial_with {
            _xmpps-client._tcp.example.org {{5 0 443 tls.example.org}}
            _xmpp-client._tcp.example.org  {{10 0 5222 xmpp.example.org} {1 0 5222 first.example.org}}
        }
    } -result {{first.example.org 5222 starttls} {tls.example.org 443 direct} {xmpp.example.org 5222 starttls} {example.org 5222 starttls}}

test dial-srv-fallback-not-repeated {a record already naming the domain on 5222 is not added again} \
    {*}$dial_common -body {
        dial_with {
            _xmpp-client._tcp.example.org {{0 0 5222 example.org}}
        }
    } -result {{example.org 5222 starttls}}

test dial-srv-forced-tls-filters {a forced mode keeps only the records of its kind} \
    {*}$dial_common -body {
        set recs {
            _xmpps-client._tcp.example.org {{0 0 443 tls.example.org}}
            _xmpp-client._tcp.example.org  {{0 0 5222 xmpp.example.org}}
        }
        list [dial_with $recs -tls direct] [dial_with $recs -tls starttls] \
            [dial_with $recs -tls none]
    } -result {{{tls.example.org 443 direct} {example.org 5223 direct}} {{xmpp.example.org 5222 starttls} {example.org 5222 starttls}} {{xmpp.example.org 5222 none} {example.org 5222 none}}}

test dial-srv-asks-only-what-it-can-use {a forced mode does not even ask for the other kind} \
    {*}$dial_common -body {
        dial_with {} -tls direct
        dnsresp::queries
    } -result {_xmpps-client._tcp.example.org}

test dial-srv-dot-means-none {a "." target leaves only the domain} \
    {*}$dial_common -body {
        dial_with {
            _xmpps-client._tcp.example.org {{0 0 0 .}}
            _xmpp-client._tcp.example.org  {{0 0 0 .}}
        }
    } -result {{example.org 5222 starttls}}

test dial-srv-nxdomain-falls-back {no such name: the domain itself} \
    {*}$dial_common -body {
        dial_with {
            _xmpps-client._tcp.example.org nx
            _xmpp-client._tcp.example.org  nx
        }
    } -result {{example.org 5222 starttls}}

test dial-srv-timeout-falls-back {a nameserver that never answers: the domain itself} \
    {*}$dial_common -body {
        set ::dial::timeout 300
        dial_with {
            _xmpps-client._tcp.example.org hang
            _xmpp-client._tcp.example.org  hang
        }
    } -result {{example.org 5222 starttls}}

test dial-srv-refused-falls-back {a nameserver that refuses the connection: the domain itself} \
    {*}$dial_common -body {
        # A port nothing listens on: take one and give it back.
        set s [socket -server {apply {{args} {}}} -myaddr 127.0.0.1 0]
        set port [lindex [fconfigure $s -sockname] 2]
        close $s
        set ::_dial_result ""
        dial::targets -domain example.org \
            -nameservers [list [list 127.0.0.1 $port]] \
            -command {apply {{t} { set ::_dial_result [list done $t] }}}
        if {$::_dial_result eq ""} { vwait ::_dial_result }
        lindex $::_dial_result 1
    } -result {{example.org 5222 starttls}}

test dial-srv-weights {within a priority, a weight-0 record goes last almost always and weights share the first place} \
    {*}$dial_common -body {
        # In a proc: test bodies run at global scope, shared with other files.
        apply {{} {
            set recs {{0 90 a 1} {0 10 b 2} {0 0 c 3}}
            array set first {a 0 b 0 c 0}
            set cLast 0
            for {set i 0} {$i < 1000} {incr i} {
                set o [dial::Order [lmap r $recs {list {*}$r starttls}]]
                incr first([lindex $o 0 2])
                if {[lindex $o end 2] eq "c"} { incr cLast }
            }
            list [expr {$first(a) > 800 && $first(a) < 970}] \
                 [expr {$first(b) > 30 && $first(b) < 200}] \
                 [expr {$cLast > 800}]
        }}
    } -result {1 1 1}

test dial-explicit-settings-skip-srv {a host, a port or srv 0 means no lookup} \
    {*}$dial_common -body {
        set recs {_xmpp-client._tcp.example.org {{0 0 5222 xmpp.example.org}}}
        set out {}
        lappend out [dial_with $recs -host other.example.org]
        lappend out [dial_with $recs -port 5300]
        lappend out [dial_with $recs -srv 0]
        lappend out [dnsresp::queries]
    } -result {{{other.example.org 5222 starttls}} {{example.org 5300 starttls}} {{example.org 5222 starttls}} {}}

test dial-default-ports {port 0 is 5222, or 5223 for direct TLS; none stays none} \
    {*}$dial_common -body {
        list [dial_with {} -host h -tls auto] [dial_with {} -host h -tls direct] \
             [dial_with {} -host h -tls none] [dial_with {} -host h -port 5300 -tls direct]
    } -result {{{h 5222 starttls}} {{h 5223 direct}} {{h 5222 none}} {{h 5300 direct}}}

test dial-no-nameservers-no-lookup {without a resolv.conf there is nobody to ask, so no lookup and no wait} \
    {*}$dial_common -setup {
        set ::_saved_resolv $::dial::resolvConf
        set ::dial::resolvConf /nonexistent/resolv.conf
    } -cleanup {
        set ::dial::resolvConf $::_saved_resolv
    } -body {
        set ::_dial_result ""
        dial::targets -domain example.org \
            -command {apply {{t} { set ::_dial_result $t }}}
        list [dial::nameservers] $::_dial_result
    } -result {{} {{example.org 5222 starttls}}}

test dial-nameservers-from-resolv-conf {nameserver lines are read, nothing else} \
    {*}$dial_common -setup {
        set ::_saved_resolv $::dial::resolvConf
        set ::dial::resolvConf [makeFile "# comment\nsearch lan\nnameserver 10.0.0.1\nnameserver ::1\n" resolv.conf]
    } -cleanup {
        set ::dial::resolvConf $::_saved_resolv
        removeFile resolv.conf
    } -body {
        dial::nameservers
    } -result {10.0.0.1 ::1}

test dial-cancel-drops-the-answer {a cancelled lookup never calls back} \
    {*}$dial_common -body {
        set port [dnsresp::start {_xmpps-client._tcp.example.org hang _xmpp-client._tcp.example.org hang}]
        set ::_dial_result none
        set id [dial::targets -domain example.org \
            -nameservers [list [list 127.0.0.1 $port]] \
            -command {apply {{t} { set ::_dial_result called }}}]
        dial::cancel $id
        after 200 {set ::_tick 1}
        vwait ::_tick
        dnsresp::stop
        set ::_dial_result
    } -result {none}

# Real resolvers compress names
test dial-parse-compressed-target {a target given as a pointer into the question is read} \
    -body {
        set q ""
        foreach l {_xmpp-client _tcp example org} {
            append q [binary format c [string length $l]] $l
        }
        append q [binary format cSS 0 33 1]
        # "xmpp" + a pointer to "example.org" in the question
        set target [binary format c 4]xmpp[binary format S [expr {0xC000 | (12 + 13 + 5)}]]
        set rdata [binary format SSS 5 7 5222]$target
        set rr [binary format SSSIS [expr {0xC00C}] 33 1 60 [string length $rdata]]$rdata
        set msg [binary format SSSSSS 4242 [expr {0x8180}] 1 1 0 0]$q$rr
        dial::ParseSrv $msg 4242
    } -result {{5 7 xmpp.example.org 5222}}

test dial-parse-rejects-other-id {a reply to some other query is not taken} \
    -body {
        set msg [binary format SSSSSS 1 [expr {0x8180}] 0 0 0 0]
        catch {dial::ParseSrv $msg 2} err
        set err
    } -result {reply to another query}

