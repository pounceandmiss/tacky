# Order keys: strings that sort in the order of the things they stand for,
# with room between any two for a third. A chat's messages sort by these
# (chat_message.pos), so a page fetched into a gap goes between the rows
# either side of it and no row ever has to be renumbered.
#
# The scheme is David Greenspan's "fractional indexing", as in
# rocicorp/fractional-indexing: a key is an integer part followed by a
# fraction. The integer's first character says how long it is ('a'..'z'
# for 1..26 digits going up, 'Z'..'A' for 1..26 going down from 'a0'), so
# appending one key after another counts up with keys that grow with the
# logarithm of their number. The fraction never ends in '0', so there is
# always room below it. The digits are 0-9A-Za-z, in ASCII order: plain
# string comparison (SQLite's BINARY collation) is key order.
#
# An empty string stands for "no bound" on either side.

namespace eval ::poskey {
    variable Digits 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz
    # The one integer nothing can go below.
    variable Smallest A[string repeat 0 26]
    namespace export between nBetween page nth valid
    namespace ensemble create
}

# A key strictly between $a and $b; either may be "" for the open end.
proc ::poskey::between {a b} {
    if {$a ne ""} { Validate $a }
    if {$b ne ""} { Validate $b }
    if {$a ne "" && $b ne "" && [string compare $a $b] >= 0} {
        error "poskey: $a is not below $b"
    }
    if {$a eq ""} {
        if {$b eq ""} { return a0 }
        set ib [IntPart $b]
        set fb [string range $b [string length $ib] end]
        variable Smallest
        if {$ib eq $Smallest} { return $ib[Mid "" $fb 1] }
        if {[string compare $ib $b] < 0} { return $ib }
        set r [Decrement $ib]
        if {$r eq ""} { error "poskey: nothing below $b" }
        return $r
    }
    set ia [IntPart $a]
    set fa [string range $a [string length $ia] end]
    if {$b eq ""} {
        set i [Increment $ia]
        if {$i eq ""} { return $ia[Mid $fa "" 0] }
        return $i
    }
    set ib [IntPart $b]
    set fb [string range $b [string length $ib] end]
    if {$ia eq $ib} { return $ia[Mid $fa $fb 1] }
    set i [Increment $ia]
    if {$i eq ""} { error "poskey: nothing above $a" }
    if {[string compare $i $b] < 0} { return $i }
    return $ia[Mid $fa "" 0]
}

# $n keys between $a and $b in ascending order, spread so that each is as
# short as it can be.
proc ::poskey::nBetween {a b n} {
    if {$n <= 0} { return {} }
    if {$n == 1} { return [list [between $a $b]] }
    if {$b eq ""} {
        set c [between $a ""]
        set out [list $c]
        for {set i 1} {$i < $n} {incr i} {
            set c [between $c ""]
            lappend out $c
        }
        return $out
    }
    if {$a eq ""} {
        set c [between "" $b]
        set out [list $c]
        for {set i 1} {$i < $n} {incr i} {
            set c [between "" $c]
            lappend out $c
        }
        return [lreverse $out]
    }
    set mid [expr {$n / 2}]
    set c [between $a $b]
    concat [nBetween $a $c $mid] [list $c] [nBetween $c $b [expr {$n - $mid - 1}]]
}

# $n keys for one page of a run that goes on into the same gap: `up` when
# the next page will go above this one (a forward fill), `down` when it
# will go below (a walk back). The page takes the near half of the gap, by
# value, and leaves the far half whole, so each further page costs about a
# bit of key length rather than a character. Ascending order either way.
proc ::poskey::page {a b n dir} {
    if {$n <= 0} { return {} }
    if {$dir ni {up down}} {
        error "poskey page: direction must be up or down, got $dir"
    }
    if {$dir eq "up" && $b eq ""} { return [nBetween $a "" $n] }
    if {$dir eq "down" && $a eq ""} { return [nBetween "" $b $n] }
    if {$a eq "" || $b eq ""} { return [nBetween $a $b $n] }
    set m [Halfway $a $b $dir]
    if {$dir eq "up"} { return [nBetween $a $m $n] }
    return [nBetween $m $b $n]
}

# A key about halfway between $a and $b by value. Between two integers it
# stays within one of them: $a's going up, $b's going down unless $b is a
# bare integer with nothing of its own below it.
proc ::poskey::Halfway {a b dir} {
    set ia [IntPart $a]
    set fa [string range $a [string length $ia] end]
    set ib [IntPart $b]
    set fb [string range $b [string length $ib] end]
    if {$ia eq $ib} {
        set m $ia[HalfFraction $fa $fb 0]
    } elseif {$dir eq "down" && $fb ne ""} {
        set m $ib[HalfFraction "" $fb 0]
    } else {
        set m $ia[HalfFraction $fa "" 1]
    }
    if {[string compare $a $m] >= 0 || [string compare $m $b] >= 0} {
        error "poskey: no key halfway between $a and $b"
    }
    return $m
}

# The fraction halfway between fractions $fa and $fb ($one: $fb is 1),
# with no trailing zero.
proc ::poskey::HalfFraction {fa fb one} {
    variable Digits
    set len [expr {max([string length $fa], [string length $fb])}]
    set sum {}
    set carry $one
    for {set i [expr {$len - 1}]} {$i >= 0} {incr i -1} {
        set da [expr {$i < [string length $fa] ? [string first [string index $fa $i] $Digits] : 0}]
        set db [expr {$i < [string length $fb] ? [string first [string index $fb $i] $Digits] : 0}]
        set v [expr {$da + $db}]
        set sum [linsert $sum 0 $v]
    }
    # Carry the sum through, right to left; what spills over the top is
    # the whole part (0 or 1, plus $one).
    for {set i [expr {$len - 1}]} {$i >= 0} {incr i -1} {
        set v [lindex $sum $i]
        if {$v >= 62} {
            lset sum $i [expr {$v - 62}]
            if {$i > 0} {
                lset sum $i-1 [expr {[lindex $sum $i-1] + 1}]
            } else {
                incr carry
            }
        }
    }
    set rem $carry
    set out ""
    foreach v $sum {
        set v [expr {$rem * 62 + $v}]
        append out [string index $Digits [expr {$v / 2}]]
        set rem [expr {$v % 2}]
    }
    if {$rem} { append out V }
    return [string trimright $out 0]
}

# The $n-th key (from 0) of the run a0, a1, ... that `between $k ""`
# counts out from nothing: how existing rows are numbered when keys are
# first given out.
proc ::poskey::nth {n} {
    variable Digits
    set width 1
    set span 62
    while {$n >= $span} {
        incr n -$span
        incr width
        set span [expr {$span * 62}]
        if {$width > 26} { error "poskey nth: out of range" }
    }
    set digits ""
    for {set i 0} {$i < $width} {incr i} {
        set digits [string index $Digits [expr {$n % 62}]]$digits
        set n [expr {$n / 62}]
    }
    return [format %c [expr {[scan a %c] + $width - 1}]]$digits
}

# Whether $key is a well-formed key.
proc ::poskey::valid {key} {
    expr {![catch {Validate $key}]}
}

proc ::poskey::Validate {key} {
    variable Smallest
    if {![regexp {^[0-9A-Za-z]+$} $key] || $key eq $Smallest} {
        error "poskey: invalid key $key"
    }
    set i [IntPart $key]
    if {[string index $key end] eq "0" && [string length $key] > [string length $i]} {
        error "poskey: invalid key $key"
    }
}

proc ::poskey::IntLen {head} {
    if {[string match {[a-z]} $head]} {
        return [expr {[scan $head %c] - [scan a %c] + 2}]
    }
    if {[string match {[A-Z]} $head]} {
        return [expr {[scan Z %c] - [scan $head %c] + 2}]
    }
    error "poskey: invalid key head $head"
}

proc ::poskey::IntPart {key} {
    set len [IntLen [string index $key 0]]
    if {$len > [string length $key]} { error "poskey: invalid key $key" }
    string range $key 0 $len-1
}

# The integer after $x, or "" past the largest.
proc ::poskey::Increment {x} {
    variable Digits
    set head [string index $x 0]
    set digs [split [string range $x 1 end] ""]
    set carry 1
    for {set i [expr {[llength $digs] - 1}]} {$carry && $i >= 0} {incr i -1} {
        set d [expr {[string first [lindex $digs $i] $Digits] + 1}]
        if {$d == 62} {
            lset digs $i 0
        } else {
            lset digs $i [string index $Digits $d]
            set carry 0
        }
    }
    if {!$carry} { return $head[join $digs ""] }
    if {$head eq "Z"} { return a0 }
    if {$head eq "z"} { return "" }
    set h [format %c [expr {[scan $head %c] + 1}]]
    if {[string compare $h a] > 0} {
        lappend digs 0
    } else {
        set digs [lrange $digs 0 end-1]
    }
    return $h[join $digs ""]
}

# The integer before $x, or "" below the smallest.
proc ::poskey::Decrement {x} {
    variable Digits
    set head [string index $x 0]
    set digs [split [string range $x 1 end] ""]
    set borrow 1
    for {set i [expr {[llength $digs] - 1}]} {$borrow && $i >= 0} {incr i -1} {
        set d [expr {[string first [lindex $digs $i] $Digits] - 1}]
        if {$d == -1} {
            lset digs $i z
        } else {
            lset digs $i [string index $Digits $d]
            set borrow 0
        }
    }
    if {!$borrow} { return $head[join $digs ""] }
    if {$head eq "a"} { return Zz }
    if {$head eq "A"} { return "" }
    set h [format %c [expr {[scan $head %c] - 1}]]
    if {[string compare $h Z] < 0} {
        lappend digs z
    } else {
        set digs [lrange $digs 0 end-1]
    }
    return $h[join $digs ""]
}

# A fraction strictly between fractions $a and $b ($hasB 0: no upper bound).
proc ::poskey::Mid {a b hasB} {
    variable Digits
    if {$hasB} {
        set n 0
        while 1 {
            set ca [string index $a $n]
            if {$ca eq ""} { set ca 0 }
            if {$ca ne [string index $b $n]} break
            incr n
        }
        if {$n > 0} {
            return [string range $b 0 $n-1][Mid [string range $a $n end] [string range $b $n end] 1]
        }
    }
    set da [expr {$a eq "" ? 0 : [string first [string index $a 0] $Digits]}]
    set db [expr {$hasB ? [string first [string index $b 0] $Digits] : 62}]
    if {$db - $da > 1} {
        return [string index $Digits [expr {($da + $db + 1) / 2}]]
    }
    if {$hasB && [string length $b] > 1} { return [string index $b 0] }
    return [string index $Digits $da][Mid [string range $a 1 end] "" 0]
}
