set dir [file dirname [info script]]
package ifneeded taco 0.1 [list source [file join $dir taco.tcl]]
package ifneeded taco::redact 0.1 [list source [file join $dir redact.tcl]]
