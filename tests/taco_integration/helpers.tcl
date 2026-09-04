package provide tacky::testhelpers::integration 0.1

# The wait helpers this file used to carry now live with every other way a
# test blocks, in tests/taco/wait.tcl (wait_var / wait_value / wait_events).
package require tacky::testwait

namespace eval ::test::helpers {}

# Displayed text of a derived message dict: the text body or a media caption.
# "" for a retracted tombstone, which carries no content.
proc ::test::helpers::msgText {msg} {
    if {![dict exists $msg content]} { return "" }
    set content [dict get $msg content]
    switch -- [dict get $content type] {
        media { return [dict get $content caption] }
        text  { return [dict get $content body] }
    }
    return ""
}
