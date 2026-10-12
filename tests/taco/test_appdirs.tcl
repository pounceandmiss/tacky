# Tests for appdirs, the per-platform default directories.
package require tcltest
namespace import ::tcltest::*
package require taco

proc appdirs_on {os} {
    set saved $::tcl_platform(os)
    set ::tcl_platform(os) $os
    try {
        lmap which {config data cache} { appdirs $which }
    } finally {
        set ::tcl_platform(os) $saved
    }
}

test appdirs-haiku-data-writable {Haiku keeps data with config: ~/config/data is read-only} -body {
    appdirs_on Haiku
} -result [list [file join $::env(HOME) config settings tacky] \
              [file join $::env(HOME) config settings tacky] \
              [file join $::env(HOME) config cache tacky]]

test appdirs-darwin {Darwin keeps data with config} -body {
    appdirs_on Darwin
} -result [list \
    [file join $::env(HOME) Library {Application Support} tacky] \
    [file join $::env(HOME) Library {Application Support} tacky] \
    [file join $::env(HOME) Library Caches tacky]]
