# Where to connect for an XMPP domain: the {host port tls} targets a
# baseconn tries in order. Shared by conn and register.
#
# dial::targets -domain D ?-host H? ?-port P? ?-tls T? ?-srv 0|1?
#               ?-nameservers N? -command cb
#   tls: auto | starttls | direct | none; port 0 is automatic.
#   -nameservers: addresses or {address port} pairs, for tests.
#   Calls {*}$cb $targets once. Returns an id for dial::cancel, or "" when
#   it has already called back.
#
# A host, a port or -srv 0 skips SRV. Otherwise _xmpps-client and
# _xmpp-client records come first, in RFC 2782 order, then the domain. auto
# is never none.
#
# The query goes over TCP (UDP needs an extension we don't build) by the
# client at the end of this file: tcllib's dns fails on an answer split
# across reads. No nameserver (Android has no resolv.conf) means no lookup,
# and a failed lookup leaves just the domain.

namespace eval dial {
    variable timeout 3000
    variable resolvConf /etc/resolv.conf
    variable lookups {}
    variable seq 0
    variable queries {}
    variable qseq 0
}

proc dial::defaultPort {tls} {
    expr {$tls eq "direct" ? 5223 : 5222}
}

proc dial::effectiveTls {tls} {
    expr {$tls in {"" auto} ? "starttls" : $tls}
}

# Not tcllib's on Unix: it falls back to 127.0.0.1, where usually nothing
# answers and the lookup only waits for its timeout.
proc dial::nameservers {} {
    variable resolvConf
    if {$::tcl_platform(platform) eq "unix"} {
        set out {}
        if {![catch {open $resolvConf r} f]} {
            while {[gets $f line] >= 0} {
                if {[regexp {^\s*nameserver\s+(\S+)} $line -> ns]} {
                    lappend out $ns
                }
            }
            close $f
        }
        return $out
    }
    # Windows: from the registry
    if {[catch {package require dns} ] || [catch {::dns::nameservers} out]} {
        return {}
    }
    return $out
}

proc dial::targets {args} {
    variable lookups
    variable seq
    set o [dict merge {-host "" -port 0 -tls auto -srv 1 -nameservers ""} $args]
    set domain [dict get $o -domain]
    set host [dict get $o -host]
    set port [dict get $o -port]
    set tls [dict get $o -tls]
    set cb [dict get $o -command]
    if {$port eq ""} { set port 0 }

    if {$host ne "" || $port != 0 || ![dict get $o -srv]} {
        if {$host eq ""} { set host $domain }
        set t [effectiveTls $tls]
        if {$port == 0} { set port [defaultPort $t] }
        {*}$cb [list [list $host $port $t]]
        return ""
    }
    set ns [dict get $o -nameservers]
    if {$ns eq ""} { set ns [nameservers] }
    if {![llength $ns]} {
        set t [effectiveTls $tls]
        {*}$cb [list [list $domain [defaultPort $t] $t]]
        return ""
    }

    switch -- $tls {
        direct  { set kinds {direct} }
        starttls - none { set kinds {starttls} }
        default { set kinds {direct starttls} }
    }
    set id [incr seq]
    dict set lookups $id [dict create domain $domain tls $tls cb $cb \
        pending [llength $kinds] records {} queries {}]
    lassign [lindex $ns 0] nsHost nsPort
    if {$nsPort eq ""} { set nsPort 53 }
    foreach kind $kinds {
        set service [expr {$kind eq "direct" ? "_xmpps-client" : "_xmpp-client"}]
        set qid [Query $nsHost $nsPort $service._tcp.$domain \
            [list dial::OnAnswer $id $kind]]
        if {[dict exists $lookups $id]} {
            set st [dict get $lookups $id]
            dict lappend st queries $qid
            dict set lookups $id $st
        }
    }
    return $id
}

proc dial::OnAnswer {id kind outcome} {
    lassign $outcome status result
    if {$status ne "ok"} {
        jlog debug "SRV ($kind): $result"
        set result {}
    }
    Done $id $kind $result
}

# records: {priority weight target port}
proc dial::Done {id kind records} {
    variable lookups
    if {![dict exists $lookups $id]} return
    set st [dict get $lookups $id]
    # A lone "." target: RFC 2782 "decidedly not available"
    if {[llength $records] == 1 && [lindex $records 0 2] eq ""} {
        set records {}
    }
    foreach r $records {
        lassign $r prio weight target port
        if {$target eq ""} continue
        dict lappend st records [list $prio $weight $target $port $kind]
    }
    dict incr st pending -1
    dict set lookups $id $st
    if {[dict get $st pending] > 0} return
    dict unset lookups $id
    set tls [dict get $st tls]
    set domain [dict get $st domain]
    set out {}
    foreach r [Order [dict get $st records]] {
        lassign $r prio weight target port kind
        set t [expr {$tls eq "none" ? "none" : $kind}]
        lappend out [list $target $port $t]
    }
    set t [effectiveTls $tls]
    set fallback [list $domain [defaultPort $t] $t]
    if {$fallback ni $out} { lappend out $fallback }
    {*}[dict get $st cb] $out
}

# RFC 2782: by priority, then weighted random within one. Both record kinds
# share one order (XEP-0368).
proc dial::Order {records} {
    set out {}
    foreach prio [lsort -integer -unique [lmap r $records {lindex $r 0}]] {
        set group [lsearch -all -inline -index 0 -integer $records $prio]
        while {[llength $group]} {
            set total 0
            foreach r $group { incr total [lindex $r 1] }
            set pick [expr {$total > 0 ? int(rand() * ($total + 1)) : 0}]
            set i 0
            set running 0
            foreach r $group {
                incr running [lindex $r 1]
                if {$running >= $pick} break
                incr i
            }
            if {$i >= [llength $group]} { set i 0 }
            lappend out [lindex $group $i]
            set group [lreplace $group $i $i]
        }
    }
    return $out
}

# Its callback never runs
proc dial::cancel {id} {
    variable lookups
    if {![dict exists $lookups $id]} return
    set qids [dict get $lookups $id queries]
    dict unset lookups $id
    foreach qid $qids { DropQuery $qid }
}

# --- SRV over TCP (RFC 1035 4.2.2) -------------------------------------

# Calls {*}$cb once, later, with {ok records} (none for NXDOMAIN) or
# {error message}.
proc dial::Query {server port name cb} {
    variable queries
    variable qseq
    variable timeout
    set qid [incr qseq]
    set dnsid [expr {int(rand() * 0x10000)}]
    set msg [binary format SSSSSS $dnsid 0x0100 1 0 0 0]
    foreach label [split [string trimright $name .] .] {
        append msg [binary format c [string length $label]] $label
    }
    append msg [binary format cSS 0 33 1]
    set st [dict create cb $cb dnsid $dnsid name $name buf "" sock "" \
        request [binary format S [string length $msg]]$msg \
        timer [after $timeout [list dial::QueryDone $qid error "timed out"]]]
    dict set queries $qid $st
    if {[catch {socket -async $server $port} sock]} {
        after idle [list dial::QueryDone $qid error $sock]
        return $qid
    }
    dict set queries $qid sock $sock
    fconfigure $sock -blocking 0 -translation binary -buffering none
    fileevent $sock writable [list dial::QueryConnected $qid]
    return $qid
}

proc dial::QueryConnected {qid} {
    variable queries
    if {![dict exists $queries $qid]} return
    set sock [dict get $queries $qid sock]
    fileevent $sock writable {}
    set err [fconfigure $sock -error]
    if {$err ne ""} {
        QueryDone $qid error $err
        return
    }
    if {[catch {puts -nonewline $sock [dict get $queries $qid request]} err]} {
        QueryDone $qid error $err
        return
    }
    fileevent $sock readable [list dial::QueryRead $qid]
}

# The answer can arrive over several reads
proc dial::QueryRead {qid} {
    variable queries
    if {![dict exists $queries $qid]} return
    set sock [dict get $queries $qid sock]
    if {[catch {read $sock} data]} {
        QueryDone $qid error $data
        return
    }
    set buf [dict get $queries $qid buf]$data
    dict set queries $qid buf $buf
    if {[string length $buf] >= 2} {
        binary scan $buf Su len
        if {[string length $buf] >= $len + 2} {
            set reply [string range $buf 2 [expr {$len + 1}]]
            if {[catch {ParseSrv $reply [dict get $queries $qid dnsid]} result]} {
                QueryDone $qid error $result
            } else {
                QueryDone $qid ok $result
            }
            return
        }
    }
    if {[eof $sock]} {
        QueryDone $qid error "connection closed"
    }
}

proc dial::QueryDone {qid status result} {
    variable queries
    if {![dict exists $queries $qid]} return
    set cb [dict get $queries $qid cb]
    DropQuery $qid
    {*}$cb [list $status $result]
}

proc dial::DropQuery {qid} {
    variable queries
    if {![dict exists $queries $qid]} return
    after cancel [dict get $queries $qid timer]
    set sock [dict get $queries $qid sock]
    if {$sock ne ""} { catch {close $sock} }
    dict unset queries $qid
}

proc dial::ParseSrv {msg dnsid} {
    if {[string length $msg] < 12} { error "short reply" }
    binary scan $msg SuSuSuSu id flags qd an
    if {$id != $dnsid} { error "reply to another query" }
    set rcode [expr {$flags & 0xF}]
    if {$rcode == 3} { return {} }
    if {$rcode != 0} { error "server failure (rcode $rcode)" }
    set off 12
    for {set i 0} {$i < $qd} {incr i} {
        set off [lindex [ReadName $msg $off] 1]
        incr off 4
    }
    set out {}
    for {set i 0} {$i < $an} {incr i} {
        set off [lindex [ReadName $msg $off] 1]
        if {[binary scan $msg @${off}SuSuIuSu type class ttl rdlen] != 4} {
            error "truncated answer"
        }
        incr off 10
        if {$type == 33 && $rdlen >= 7} {
            binary scan $msg @${off}SuSuSu prio weight port
            set target [lindex [ReadName $msg [expr {$off + 6}]] 0]
            lappend out [list $prio $weight $target $port]
        }
        incr off $rdlen
    }
    return $out
}

# {name next-offset}, following compression pointers; the root is ""
proc dial::ReadName {msg off} {
    set labels {}
    set next ""
    set hops 0
    while {1} {
        if {[binary scan $msg @${off}cu n] != 1} { error "truncated name" }
        if {($n & 0xC0) == 0xC0} {
            binary scan $msg @${off}Su ptr
            if {$next eq ""} { set next [expr {$off + 2}] }
            set off [expr {$ptr & 0x3FFF}]
            if {[incr hops] > 32} { error "name pointer loop" }
            continue
        }
        incr off
        if {$n == 0} break
        lappend labels [string range $msg $off [expr {$off + $n - 1}]]
        incr off $n
    }
    if {$next eq ""} { set next $off }
    list [join $labels .] $next
}
