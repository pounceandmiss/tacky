#!/usr/bin/env tclsh9.0
# Usage: tclsh9.0 test_all.tcl
#   NO_THREADED=1  - skip threaded (tacky_threaded_type) tests
#   XMPP_SERVER=x  - run integration tests (requires SPOOF_SSL_CERT)
package require tcltest
package require control
source [file join [file dirname [info script]] taco taco.tcl]
source tacky.tcl
namespace import ::tcltest::*
set _server [expr {[info exists ::env(XMPP_SERVER)] ? $::env(XMPP_SERVER) : ""}]

if {$_server ne "" && ![info exists ::env(SPOOF_SSL_CERT)]} {
    error "XMPP_SERVER is set but SPOOF_SSL_CERT is not. Both are required for server tests."
}
if {$_server ne ""} {
    ::tcltest::testConstraint withServer 1
    ::tcltest::testConstraint notProsody   [expr {$_server ne "prosody"}]
    ::tcltest::testConstraint notMongoose  [expr {$_server ne "mongoose"}]
    ::tcltest::testConstraint notEjabberd  [expr {$_server ne "ejabberd"}]
    foreach script [lsort [glob [file join ./ tests taco_integration *.tcl]]] {
	source $script
    }    
}



foreach script [lsort [glob [file join ./ tests taco *.tcl]]] {
    source $script
}

cleanupTests
