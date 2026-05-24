set dir [file dirname [info script]]
package ifneeded tacky::testhelpers 0.1 [list source [file join $dir helpers.tcl]]
package ifneeded tacky::mockconn 0.1 [list source [file join $dir mock_conn.tcl]]
