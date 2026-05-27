set dir [file dirname [info script]]
package ifneeded tackyd-json 0.1 [list source [file join $dir tackyd-json.tcl]]
