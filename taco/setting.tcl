snit::type taco_setting {
    option -db -default ""
    option -taco -default ""

    constructor args {
        $self configurelist $args
        $options(-db) eval {
            CREATE TABLE IF NOT EXISTS setting(key PRIMARY KEY, value DEFAULT '');
        }
    }

    tackymethod get {args} {
        set key [dict get $args -key]
        $options(-db) eval {SELECT value FROM setting WHERE key=$key} row {
            return [list -key $key -value $row(value)]
        }
        list -key $key -value ""
    }

    method set {args} {
        set key [dict get $args -key]
        set value [dict get $args -value]
        $options(-db) eval {
            INSERT INTO setting(key, value) VALUES($key, $value)
            ON CONFLICT(key) DO UPDATE SET value=$value;
        }
        $options(-taco) emit setting <Changed> -key $key -value $value
    }

    tackymethod list {args} {
        $options(-db) eval {SELECT key FROM setting}
    }
}
