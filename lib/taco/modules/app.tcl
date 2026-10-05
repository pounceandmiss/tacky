snit::type taco_app {
    option -taco -default ""

    # Whether the user is using the app, as the frontend reports it. Without
    # a report (no frontend attached) it counts as active.
    variable active 1

    constructor args {
        $self configurelist $args
    }

    method setActive {args} {
        set now [string is true -strict [dict get $args -active]]
        if {$now == $active} return
        set active $now
        if {$active} {
            foreach client [$options(-taco) clients] {
                catch {$client conn probe}
            }
        }
    }

    tackymethod isActive {args} {
        return $active
    }
}
