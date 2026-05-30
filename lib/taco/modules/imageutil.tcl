# Shared image geometry helpers, used by the avatar and file modules.

# Largest dimensions fitting within max*max, preserving aspect, never
# upscaling. Returns {w h}.
proc fit_within {w h max} {
    if {$w <= $max && $h <= $max} {
        return [list $w $h]
    }
    if {$w >= $h} {
        set nw $max
        set nh [expr {int(round(double($h) * $max / $w))}]
    } else {
        set nh $max
        set nw [expr {int(round(double($w) * $max / $h))}]
    }
    return [list [expr {max($nw, 1)}] [expr {max($nh, 1)}]]
}
