namespace eval ::test::helpers {}

# Wait for a fully-qualified variable to become truthy (non-zero, non-empty).
# Returns immediately if already truthy. Errors on timeout.
proc ::test::helpers::waitVar {varName {timeout 2000}} {
    set val [set $varName]
    if {$val ne "0" && $val ne ""} return

    set afterId [after $timeout [list set $varName "\x00TIMEOUT"]]
    vwait $varName
    after cancel $afterId

    if {[set $varName] eq "\x00TIMEOUT"} {
        error "waitVar: timeout after ${timeout}ms on $varName"
    }
}

# Wait for a fully-qualified variable to equal an expected string value.
# Returns immediately if already matching. Errors on timeout.
proc ::test::helpers::waitForState {stateVar expected {timeout_ms 6000}} {
    if {[set $stateVar] eq $expected} return

    variable _wfsDone 0
    set doneVar [namespace current]::_wfsDone

    set traceCmd [list apply {{sv exp dv args} {
        if {[set $sv] eq $exp} {set $dv 1}
    }} $stateVar $expected $doneVar]

    trace add variable $stateVar write $traceCmd
    set afterId [after $timeout_ms [list set $doneVar -1]]

    vwait $doneVar

    after cancel $afterId
    trace remove variable $stateVar write $traceCmd

    if {$_wfsDone == -1} {
        error "Timeout: [set $stateVar] != $expected after ${timeout_ms}ms"
    }
}

proc ::test::helpers::WaitEventsCallback args {
    variable PendingEvents
    variable PendingEventsDone
    incr PendingEvents -1
    if {$PendingEvents == 0} {
        set PendingEventsDone yes
    }
}

proc ::test::helpers::waitEvents {specs {timeout 10000}} {
    set ::test::helpers::PendingEvents [llength $specs]
    set ::test::helpers::PendingEventsDone 0
    foreach spec $specs {
        tacky listen -tag waitEvents {*}$spec \
            ::test::helpers::WaitEventsCallback
    }
    waitVar ::test::helpers::PendingEventsDone $timeout
    tacky unlisten waitEvents
}
