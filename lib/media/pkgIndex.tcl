set dir [file dirname [info script]]
package ifneeded tacky::media 0.1 [list source [file join $dir media.tcl]]
package ifneeded tacky::media::rtc 0.1 [list source [file join $dir media_rtc.tcl]]
package ifneeded tacky::media::host 0.1 [list source [file join $dir media_host.tcl]]
