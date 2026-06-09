set dir [file dirname [info script]]
package ifneeded emojipicker 0.1 [list source [file join $dir emojipicker.tcl]]
