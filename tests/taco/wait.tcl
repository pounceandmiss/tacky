# Every way a test blocks on the event loop, in one place.
#
# There used to be two vocabularies: tacky_await/_error/_methoderror here, on
# ::_await_* globals with no timeout at all, and ::test::helpers::waitVar/
# waitForState/waitEvents over in the integration helpers, each with its own
# timeout and its own sentinel. A missed callback on the first set hung the
# whole suite with no clue which test was stuck.
#
# The rule now: every wait has a deadline, and every timeout error names what
# it was waiting for. Wrappers differ only in what they arm before blocking.
package provide tacky::testwait 0.1

namespace eval testwait {
    variable Seq 0

    # A callback that never arrives is a stalled test, not a stalled suite.
    # Generous enough not to trip on a loaded machine.
    variable CallTimeout 10000
}

# A fresh global flag variable, so nested and concurrent waits cannot land on
# each other's done flag (the old waitForState reused one namespace variable).
proc testwait::Flag {{value 0}} {
    variable Seq
    set name [namespace current]::flag[incr Seq]
    set $name $value
    return $name
}

proc testwait::Truthy {val} {
    return [expr {$val ne "0" && $val ne ""}]
}

# The one blocking primitive: enter the event loop until $doneVar is truthy, or
# fail after $timeout ms naming $what. The caller arms whatever writes it.
#
# Falsy writes are ignored rather than ending the wait, so a variable that goes
# 0 -> 0 -> 1 is waited out instead of returning early on the first write.
proc testwait::Block {doneVar timeout what} {
    upvar #0 $doneVar done
    if {[info exists done] && [Truthy $done]} return

    set timer [after $timeout [list set $doneVar "\x00TIMEOUT"]]
    try {
        while 1 {
            vwait $doneVar
            if {[Truthy $done]} break
        }
    } finally {
        after cancel $timer
    }

    if {$done eq "\x00TIMEOUT"} {
        error "timeout after ${timeout}ms waiting for $what"
    }
}

# -- waiting on a variable --------------------------------------------------

# Block until a fully-qualified variable is truthy.
proc wait_var {varName {timeout 2000}} {
    testwait::Block $varName $timeout $varName
}

# Block until a fully-qualified variable equals a value.
proc wait_value {varName expected {timeout 6000}} {
    upvar #0 $varName target
    if {[info exists target] && $target eq $expected} return

    set flag [testwait::Flag]
    set watch [list apply {{var exp flag args} {
        if {[set $var] eq $exp} { set $flag 1 }
    }} $varName $expected $flag]

    trace add variable $varName write $watch
    try {
        testwait::Block $flag $timeout "$varName to become \"$expected\""
    } finally {
        trace remove variable $varName write $watch
        unset -nocomplain $flag
    }
}

# -- waiting on tacky events -----------------------------------------------

proc testwait::Counted {counter flag args} {
    upvar #0 $counter n
    if {[incr n -1] <= 0} { set $flag 1 }
}

# Block until one event has arrived for each spec, e.g.
#   wait_events {{roster <Push>} {message <Sent>}}
proc wait_events {specs {timeout 10000}} {
    if {![llength $specs]} return

    set flag [testwait::Flag]
    set counter [testwait::Flag [llength $specs]]
    # The flag name doubles as the listen tag: unique per wait, so a nested
    # wait_events cannot unlisten the outer one's specs.
    set tag [namespace tail $flag]

    foreach spec $specs {
        tacky listen -tag $tag {*}$spec \
            [list ::testwait::Counted $counter $flag]
    }
    try {
        testwait::Block $flag $timeout "events: $specs"
    } finally {
        tacky unlisten $tag
        unset -nocomplain $flag $counter
    }
}

# -- waiting on a tacky command's callback ---------------------------------

# Run a tacky command with -command, block for the result, return it. Works
# for both the synchronous and the async front ends.
proc wait_call {args} {
    set timeout $::testwait::CallTimeout
    set flag [testwait::Flag]
    set out [testwait::Flag]

    {*}$args -command [list apply {{r f res} {
        set $r $res
        set $f 1
    }} $out $flag]

    try {
        testwait::Block $flag $timeout "a reply to: $args"
        return [set $out]
    } finally {
        unset -nocomplain $flag $out
    }
}

# Same, for a command expected to fail: returns the -onerror message.
proc wait_call_error {args} {
    set timeout $::testwait::CallTimeout
    set flag [testwait::Flag]
    set out [testwait::Flag]

    {*}$args \
        -command {apply {{result} {}}} \
        -onerror [list apply {{r f msg} {
            set $r $msg
            set $f 1
        }} $out $flag]

    try {
        testwait::Block $flag $timeout "an error from: $args"
        return [set $out]
    } finally {
        unset -nocomplain $flag $out
    }
}

# The `error <MethodError>` event a failing call emits when it has a -command
# but no -onerror. wait_call_error can't see this path: it supplies -onerror,
# which takes the error to the callback instead.
proc wait_call_methoderror {args} {
    set timeout $::testwait::CallTimeout
    set flag [testwait::Flag]
    set out [testwait::Flag]

    set tag [tacky listen error <MethodError> [list apply {{r f eargs} {
        set $r $eargs
        set $f 1
    }} $out $flag]]

    {*}$args -command {apply {{result} {}}}

    try {
        testwait::Block $flag $timeout "a <MethodError> from: $args"
        return [set $out]
    } finally {
        tacky unlisten $tag
        unset -nocomplain $flag $out
    }
}
