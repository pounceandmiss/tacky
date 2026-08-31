set dir [file dirname [info script]]
package ifneeded tackygui 0.1 [list source [file join $dir tackygui.tcl]]
