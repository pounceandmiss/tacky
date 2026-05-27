set dir [file dirname [info script]]
package ifneeded jid 0.1 [list source [file join $dir jid.tcl]]
