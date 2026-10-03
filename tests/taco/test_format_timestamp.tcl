# Unit tests for FormatTimestampISO (inverse of ParseTimestamp)
package require tcltest
namespace import ::tcltest::*
package require taco

test format-timestamp-roundtrip {round-trip with fractional seconds} -body {
    set stamp "2024-06-15T12:30:00.123456Z"
    FormatTimestampISO [ParseTimestamp $stamp]
} -result {2024-06-15T12:30:00.123456Z}

test format-timestamp-no-fraction {zero fractional seconds omits decimal} -body {
    set stamp "2024-06-15T12:30:00Z"
    FormatTimestampISO [ParseTimestamp $stamp]
} -result {2024-06-15T12:30:00Z}

test format-timestamp-roundtrip-midnight {round-trip at midnight} -body {
    set stamp "2024-01-01T00:00:00Z"
    FormatTimestampISO [ParseTimestamp $stamp]
} -result {2024-01-01T00:00:00Z}

test parse-timestamp-numeric-zone {a numeric zone offset is applied} -body {
    list [FormatTimestampISO [ParseTimestamp 2024-06-15T14:30:00+02:00]] \
         [FormatTimestampISO [ParseTimestamp 2024-06-15T07:00:00.5-05:30]] \
         [FormatTimestampISO [ParseTimestamp 2024-06-15T12:30:00+0000]]
} -result {2024-06-15T12:30:00Z 2024-06-15T12:30:00.500000Z 2024-06-15T12:30:00Z}
