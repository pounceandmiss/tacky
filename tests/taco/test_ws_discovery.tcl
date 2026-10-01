package require tcltest
namespace import ::tcltest::*
package require taco
package require xmpprw

# XEP-0156 lookup before a websocket dial. ::wschan and taco_http are faked
# and restored after each test (the wasm suite has the real ::wschan).

namespace eval ::test::wsdisc {
    variable Opened {}
    variable Asked {}
    variable Reset {}
    variable Pending
    variable Seq 0
    variable Saved {}
    variable Hosts 0

    # A fresh host name: answers are cached per host.
    proc host {} {
        variable Hosts
        return "h[incr Hosts]-[clock microseconds].example"
    }

    proc fake {} {
        variable Opened {}
        variable Asked {}
        variable Reset {}
        variable Pending
        variable Saved {}
        array unset Pending
        if {![namespace exists ::wschan]} {
            namespace eval ::wschan {}
            lappend Saved namespace
        }
        foreach cmd {::wschan::open ::wschan::close ::wschan::destroy ::taco_http} {
            if {[llength [info commands $cmd]]} {
                rename $cmd ${cmd}.real
                lappend Saved $cmd
            }
        }
        if {![info exists ::wschan::available]} {
            set ::wschan::available 1
            lappend Saved available
        }
        proc ::wschan::open {url args} {
            lappend ::test::wsdisc::Opened $url
            return ws[incr ::test::wsdisc::Seq]
        }
        proc ::wschan::close {args} {}
        proc ::wschan::destroy {args} {}
        proc ::taco_http {op args} { ::test::wsdisc::Http $op {*}$args }
    }

    proc restore {} {
        variable Saved
        foreach cmd {::wschan::open ::wschan::close ::wschan::destroy ::taco_http} {
            catch {rename $cmd {}}
        }
        foreach cmd [lreverse $Saved] {
            if {$cmd eq "available"} {
                unset ::wschan::available
            } elseif {$cmd eq "namespace"} {
                namespace delete ::wschan
            } else {
                rename ${cmd}.real $cmd
            }
        }
        set Saved {}
    }

    proc Http {op args} {
        variable Asked
        variable Reset
        variable Pending
        variable Seq
        switch -- $op {
            get {
                set url [lindex $args 0]
                array set o [lrange $args 1 end]
                if {[info exists ::test::wsdisc::Refuse]} {
                    error $::test::wsdisc::Refuse
                }
                lappend Asked $url
                set token tok[incr Seq]
                set Pending($token) [dict create file $o(-outfile) \
                    command $o(-command) status "" ncode 0]
                return $token
            }
            status { return [dict get $Pending([lindex $args 0]) status] }
            ncode  { return [dict get $Pending([lindex $args 0]) ncode] }
            reset  { lappend Reset [lindex $args 0] }
            cleanup {}
        }
    }

    # Complete lookup $token with $status, $code and $body.
    proc answer {token status code {body ""}} {
        variable Pending
        dict set Pending($token) status $status
        dict set Pending($token) ncode $code
        set f [open [dict get $Pending($token) file] w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $body
        close $f
        {*}[dict get $Pending($token) command] $token
    }

    proc lastToken {} {
        variable Seq
        return tok$Seq
    }

    proc conn {args} {
        baseconn create ::test::wsdisc::bc -transport websocket {*}$args
    }

    proc done {} {
        catch {::test::wsdisc::bc destroy}
        restore
    }

    variable DRAUGR {<?xml version='1.0' encoding='utf-8'?>
<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
  <Link rel="urn:xmpp:alt-connections:xbosh"
        href="https://www.draugr.de/bosh/" />
  <Link rel="urn:xmpp:alt-connections:websocket"
        href="wss://www.draugr.de/websocket/" />
</XRD>}
}

# -- reading host-meta --------------------------------------------------------

test ws-discovery-hostmeta-url {where a host publishes its endpoints} -body {
    ::wsframing::hostMetaUrl draugr.de
} -result {https://draugr.de/.well-known/host-meta}

test ws-discovery-reads-xrd {the websocket link of a real host-meta, declaration and all} -body {
    ::wsframing::fromHostMeta $::test::wsdisc::DRAUGR
} -result {wss://www.draugr.de/websocket/}

test ws-discovery-first-wss {the first wss link wins; a plaintext ws one is passed over} -body {
    ::wsframing::fromHostMeta {<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
        <Link rel='urn:xmpp:alt-connections:websocket' href='ws://plain.example/ws'/>
        <Link rel='urn:xmpp:alt-connections:websocket' href='wss://one.example/ws'/>
        <Link rel='urn:xmpp:alt-connections:websocket' href='wss://two.example/ws'/>
    </XRD>}
} -result {wss://one.example/ws}

test ws-discovery-none-named {a host-meta with no websocket link, or only ws, names nothing} -body {
    list [::wsframing::fromHostMeta {<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
              <Link rel='urn:xmpp:alt-connections:xbosh' href='https://x.example/bosh'/></XRD>}] \
         [::wsframing::fromHostMeta {<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
              <Link rel='urn:xmpp:alt-connections:websocket' href='ws://x.example/ws'/></XRD>}]
} -result {{} {}}

test ws-discovery-not-xrd {an error page, or nothing at all, names nothing} -body {
    list [::wsframing::fromHostMeta {<!DOCTYPE html><html><body><h1>404</h1></body></html>}] \
         [::wsframing::fromHostMeta {<html><body>Not Found</body></html>}] \
         [::wsframing::fromHostMeta {}] \
         [::wsframing::fromHostMeta {{"links": []}}]
} -result {{} {} {} {}}

# -- asking before dialling -----------------------------------------------------

test ws-discovery-asks-then-dials {the host is asked first, and its endpoint dialled} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        set before [list $::test::wsdisc::Asked $::test::wsdisc::Opened [::test::wsdisc::bc state]]
        ::test::wsdisc::answer [::test::wsdisc::lastToken] ok 200 $::test::wsdisc::DRAUGR
        list [string map [list $host HOST] $before] $::test::wsdisc::Opened
    } -result {{https://HOST/.well-known/host-meta {} connecting} wss://www.draugr.de/websocket/}

test ws-discovery-none-takes-convention {a host-meta that names none: the convention} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] ok 200 \
            {<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'/>}
        string map [list $host HOST] $::test::wsdisc::Opened
    } -result {wss://HOST/xmpp-websocket}

test ws-discovery-answer-is-kept {an answer is kept: a reconnect dials without asking} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] ok 200 $::test::wsdisc::DRAUGR
        ::test::wsdisc::bc close
        ::test::wsdisc::bc connect $host 5222
        list [llength $::test::wsdisc::Asked] $::test::wsdisc::Opened
    } -result {1 {wss://www.draugr.de/websocket/ wss://www.draugr.de/websocket/}}

test ws-discovery-404-is-an-answer {a 404 is the host saying it publishes nothing, and is kept} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] ok 404 {<html>Not Found</html>}
        ::test::wsdisc::bc close
        ::test::wsdisc::bc connect $host 5222
        list [llength $::test::wsdisc::Asked] [string map [list $host HOST] $::test::wsdisc::Opened]
    } -result {1 {wss://HOST/xmpp-websocket wss://HOST/xmpp-websocket}}

test ws-discovery-failure-not-kept {a lookup that failed dials the convention, and is asked again next time} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] timeout 0
        ::test::wsdisc::bc close
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] error 0
        ::test::wsdisc::bc close
        ::test::wsdisc::bc connect $host 5222
        ::test::wsdisc::answer [::test::wsdisc::lastToken] ok 503 {}
        list [llength $::test::wsdisc::Asked] [string map [list $host HOST] $::test::wsdisc::Opened]
    } -result {3 {wss://HOST/xmpp-websocket wss://HOST/xmpp-websocket wss://HOST/xmpp-websocket}}

test ws-discovery-refused-request {a request that cannot even be made: the convention} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake; set ::test::wsdisc::Refuse "no client" } \
    -cleanup { unset -nocomplain ::test::wsdisc::Refuse; ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        string map [list $host HOST] $::test::wsdisc::Opened
    } -result {wss://HOST/xmpp-websocket}

test ws-discovery-explicit-url {-ws-url is dialled as given; nobody is asked} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        ::test::wsdisc::conn -ws-url ws://127.0.0.1:5280/xmpp-websocket
        ::test::wsdisc::bc connect [::test::wsdisc::host] 5222
        list $::test::wsdisc::Asked $::test::wsdisc::Opened
    } -result {{} ws://127.0.0.1:5280/xmpp-websocket}

test ws-discovery-close-while-asking {closed while asking: the lookup is cancelled, and a late answer dials nothing} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        set host [::test::wsdisc::host]
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect $host 5222
        set token [::test::wsdisc::lastToken]
        ::test::wsdisc::bc close
        ::test::wsdisc::answer $token ok 200 $::test::wsdisc::DRAUGR
        list $::test::wsdisc::Reset $::test::wsdisc::Opened [::test::wsdisc::bc state]
    } -result {tok* {} disconnected} -match glob

test ws-discovery-reset-calls-back {a reset that answers on the spot dials nothing either} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        # Tcl's http calls -command from inside reset.
        proc ::taco_http {op args} {
            if {$op eq "reset"} {
                ::test::wsdisc::answer [lindex $args 0] reset 0
                return
            }
            ::test::wsdisc::Http $op {*}$args
        }
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect [::test::wsdisc::host] 5222
        ::test::wsdisc::bc close
        list $::test::wsdisc::Opened [::test::wsdisc::bc state]
    } -result {{} disconnected}

test ws-discovery-cleans-up {the file the answer landed in is removed} \
    -constraints !wasm \
    -setup { ::test::wsdisc::fake } -cleanup { ::test::wsdisc::done } -body {
        ::test::wsdisc::conn
        ::test::wsdisc::bc connect [::test::wsdisc::host] 5222
        set token [::test::wsdisc::lastToken]
        set file [dict get $::test::wsdisc::Pending($token) file]
        ::test::wsdisc::answer $token ok 200 $::test::wsdisc::DRAUGR
        file exists $file
    } -result 0
