set dir [file dirname [info script]]
package ifneeded xmpprw 0.1 [list source [file join $dir xmpprw.tcl]]
