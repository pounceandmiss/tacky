# config: accounts.db. data: per-account databases and downloaded attachments.
# cache: regenerable files only. On Darwin config and data are one directory.
# Unixes other than Darwin and Haiku get the XDG layout.
proc appdirs {which} {
    switch -glob -- $::tcl_platform(os) {
        Darwin {
            if {$which in {config data}} {
                set base [file join $::env(HOME) Library {Application Support}]
            } else {
                set base [file join $::env(HOME) Library Caches]
            }
        }
        Haiku {
            set base [file join $::env(HOME) config \
                [dict get {config settings data data cache cache} $which]]
        }
        Windows* {
            # Data is not roaming: the OMEMO identity key is per-device.
            switch -- $which {
                config  { return [file join $::env(APPDATA) tacky] }
                data    { return [file join $::env(LOCALAPPDATA) tacky data] }
                default { return [file join $::env(LOCALAPPDATA) tacky cache] }
            }
        }
        default {
            switch -- $which {
                config {
                    set base [expr {[info exists ::env(XDG_CONFIG_HOME)]
                        ? $::env(XDG_CONFIG_HOME)
                        : [file join $::env(HOME) .config]}]
                }
                data {
                    set base [expr {[info exists ::env(XDG_DATA_HOME)]
                        ? $::env(XDG_DATA_HOME)
                        : [file join $::env(HOME) .local share]}]
                }
                default {
                    set base [expr {[info exists ::env(XDG_CACHE_HOME)]
                        ? $::env(XDG_CACHE_HOME)
                        : [file join $::env(HOME) .cache]}]
                }
            }
        }
    }
    return [file join $base tacky]
}

# Only the leaf is restricted; parents like ~/.local/share are shared.
proc appdirs_mkprivate {dir} {
    file mkdir $dir
    if {$::tcl_platform(platform) eq "unix"
            && [catch {file attributes $dir -permissions 0700} err]} {
        jlog inform "could not restrict $dir: $err"
    }
}
