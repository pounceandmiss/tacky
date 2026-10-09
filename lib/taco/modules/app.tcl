snit::type taco_app {
    option -taco -default ""

    # Whether the user is using the app, as the frontend reports it. Without
    # a report (no frontend attached) it counts as active.
    variable active 1
    # When the app last became inactive (clock seconds), for idleSeconds.
    variable inactiveSince 0

    constructor args {
        $self configurelist $args
    }

    tackymethod -noreturn setActive {args} {
        set now [string is true -strict [dict get $args -active]]
        if {$now == $active} return
        set active $now
        if {!$active} { set inactiveSince [clock seconds] }
        foreach client [$options(-taco) clients] {
            catch {$client conn csiUpdate}
            if {$active} {
                catch {$client conn probe}
                catch {$client chat ApplyHeld}
            }
        }
    }

    tackymethod isActive {args} {
        return $active
    }

    # Seconds since the user last used the app: 0 while active.
    tackymethod idleSeconds {args} {
        if {$active} { return 0 }
        expr {max(0, [clock seconds] - $inactiveSince)}
    }
}
