set dir [file dirname [info script]]
package ifneeded lenpipe 0.1 [list source [file join $dir lenpipe.tcl]]
