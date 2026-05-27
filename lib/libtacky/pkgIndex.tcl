set dir [file dirname [info script]]
package ifneeded libtacky 0.1 [list source [file join $dir tacky.tcl]]
