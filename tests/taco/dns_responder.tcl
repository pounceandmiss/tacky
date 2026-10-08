# A DNS server over TCP for tests, answering SRV queries from a dict.
#
#   set port [dnsresp::start {name answer ...}]
#     answer: a list of {priority weight port target} records, `nx` for
#     NXDOMAIN, or `hang` to never answer. Unknown names get no records.
#   dnsresp::queries   names asked, in order
#   dnsresp::stop

namespace eval dnsresp {
    variable listener ""
    variable records {}
    variable asked {}
    variable conns {}
}

proc dnsresp::start {recs} {
    variable listener
    variable records $recs
    variable asked {}
    set listener [socket -server dnsresp::Accept -myaddr 127.0.0.1 0]
    return [lindex [fconfigure $listener -sockname] 2]
}

proc dnsresp::stop {} {
    variable listener
    variable conns
    catch {close $listener}
    foreach c $conns { catch {close $c} }
    set listener ""
    set conns {}
}

proc dnsresp::queries {} {
    variable asked
    return $asked
}

proc dnsresp::Accept {chan addr port} {
    variable conns
    lappend conns $chan
    fconfigure $chan -translation binary -blocking 0
    fileevent $chan readable [list dnsresp::Read $chan]
}

proc dnsresp::Read {chan} {
    upvar #0 dnsresp::buf($chan) buf
    if {![info exists buf]} { set buf "" }
    append buf [read $chan]
    if {[eof $chan]} {
        catch {close $chan}
        unset buf
        return
    }
    while {[string length $buf] >= 2} {
        binary scan $buf S len
        set len [expr {$len & 0xffff}]
        if {[string length $buf] < $len + 2} return
        set msg [string range $buf 2 [expr {$len + 1}]]
        set buf [string range $buf [expr {$len + 2}] end]
        dnsresp::Answer $chan $msg
    }
}

proc dnsresp::Answer {chan msg} {
    variable records
    variable asked
    binary scan $msg S id
    set off 12
    set labels {}
    while {1} {
        binary scan $msg @${off}c n
        set n [expr {$n & 0xff}]
        incr off
        if {$n == 0} break
        lappend labels [string range $msg $off [expr {$off + $n - 1}]]
        incr off $n
    }
    set qend [expr {$off + 4}]
    set question [string range $msg 12 [expr {$qend - 1}]]
    set name [join $labels .]
    lappend asked $name
    set answer {}
    if {[dict exists $records $name]} { set answer [dict get $records $name] }
    if {$answer eq "hang"} return
    set rcode [expr {$answer eq "nx" ? 3 : 0}]
    if {$answer eq "nx"} { set answer {} }
    set rrs ""
    foreach r $answer {
        lassign $r prio weight port target
        set rdata [binary format SSS $prio $weight $port]
        foreach l [split [string trimright $target .] .] {
            if {$l eq ""} continue
            append rdata [binary format c [string length $l]] $l
        }
        append rdata [binary format c 0]
        append rrs [binary format SSSIS [expr {0xC00C}] 33 1 60 \
            [string length $rdata]] $rdata
    }
    set reply [binary format SSSSSS $id [expr {0x8180 | $rcode}] 1 \
        [llength $answer] 0 0]$question$rrs
    set wire [binary format S [string length $reply]]$reply
    # Split, as real resolvers' answers often arrive
    puts -nonewline $chan [string index $wire 0]
    flush $chan
    after 20 [list dnsresp::Send $chan [string range $wire 1 end]]
}

proc dnsresp::Send {chan data} {
    catch {
        puts -nonewline $chan $data
        flush $chan
    }
}
