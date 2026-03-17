# Unit tests for FormatTimestampISO (inverse of ParseTimestamp)

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
