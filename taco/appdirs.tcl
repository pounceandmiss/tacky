# AI-generated. Works on Linux, hope it works on other platforms too.
proc appdirs {which} {
    switch -- $::tcl_platform(os) {
        Linux {
            if {$which eq "config"} {
                set base [expr {[info exists ::env(XDG_CONFIG_HOME)]
                    ? $::env(XDG_CONFIG_HOME)
                    : [file join $::env(HOME) .config]}]
            } else {
                set base [expr {[info exists ::env(XDG_CACHE_HOME)]
                    ? $::env(XDG_CACHE_HOME)
                    : [file join $::env(HOME) .cache]}]
            }
        }
        Darwin {
            if {$which eq "config"} {
                set base [file join $::env(HOME) Library {Application Support}]
            } else {
                set base [file join $::env(HOME) Library Caches]
            }
        }
        default {
            if {$which eq "config"} {
                return [file join $::env(APPDATA) tacky]
            } else {
                return [file join $::env(LOCALAPPDATA) tacky cache]
            }
        }
    }
    return [file join $base tacky]
}
