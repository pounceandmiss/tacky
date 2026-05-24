set dir [file dirname [info script]]
package ifneeded tacky::testhelpers::integration 0.1 [list source [file join $dir helpers.tcl]]
