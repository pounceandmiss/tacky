set dir [file dirname [info script]]
package ifneeded tackyd 0.1 [list source [file join $dir tackyd.tcl]]
