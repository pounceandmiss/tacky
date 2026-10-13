set dir [file dirname [info script]]
package ifneeded socks5 0.1 [list source [file join $dir socks5.tcl]]
