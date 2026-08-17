# Microsecond stamps are what the backend speaks; every display of one goes
# through here.
proc FormatTimestamp {us {format "%Y-%m-%d %H:%M:%S"}} {
    if {$us eq ""} { return "(empty)" }
    return [clock format [expr {$us / 1000000}] -format $format]
}
