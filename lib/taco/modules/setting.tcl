snit::type taco_setting {
    option -db -default ""
    option -taco -default ""

    constructor args {
        $self configurelist $args
    }

    tackymethod get {args} {
        set key [dict get $args -key]
        $options(-db) eval {SELECT value FROM setting WHERE key=$key} row {
            return $row(value)
        }
        return ""
    }

    tackymethod -noreturn set {args} {
        array set opts $args
        $options(-db) eval {
            INSERT INTO setting(key, value) VALUES($opts(-key), $opts(-value))
            ON CONFLICT(key) DO UPDATE SET value=$opts(-value);
        }
        $options(-taco) emit setting <Changed> -key $opts(-key) -value $opts(-value)
        # Some disco features follow a setting (caps addFeature -if). The
        # taco-level store refreshes every client; a per-account one, whose
        # -taco is its client, just that client.
        if {[catch {$options(-taco) clients} clients]} {
            set clients [list $options(-taco)]
        }
        foreach client $clients { catch {$client caps refresh} }
    }

    # pull -event <Changed> -key K  (-event ignored - setting has one event)
    tackymethod pull {args} {
        set key [dict get $args -key]
        $options(-taco) emit setting <Changed> \
            -key $key -value [$self get -key $key]
    }

    tackymethod list {args} {
        $options(-db) eval {SELECT key FROM setting}
    }
}

# The taco-level (per-process, not per-account) setting a client module reads
# through its client's taco object: $default when unset or unreadable.
proc taco_setting_get {client key {default ""}} {
    if {[catch {[$client cget -taco] setting get -key $key} value]} {
        return $default
    }
    if {$value eq ""} { return $default }
    return $value
}

# The same, from the client's own (per-account) store.
proc client_setting_get {client key {default ""}} {
    if {[catch {$client setting get -key $key} value]} {
        return $default
    }
    if {$value eq ""} { return $default }
    return $value
}
