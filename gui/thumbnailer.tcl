package require snit
package require Thread

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

# thumbnailer - downscaled PNGs of image files, decoded on a worker thread so a
# large image never stalls the event loop. Requests for the same file and size
# in flight share one decode.
snit::type thumbnailer {
    pragma -hastypeinfo no -hasinstances no

    typevariable Tid ""
    # {path max} -> list of {owner cmd} waiting on that decode.
    typevariable Waiting {}

    # {*}$cmd $png once the thumbnail of $path, at most $max pixels on its long
    # side, is ready; $png is "" when the file won't decode. Dropped if the
    # $owner window is gone by then.
    typemethod request {path max owner cmd} {
        set key [list $path $max]
        set first [expr {![dict exists $Waiting $key]}]
        dict lappend Waiting $key [list $owner $cmd]
        if {!$first} return
        thread::send -async [$type Worker] \
            [list thumb [thread::id] $path $max]
    }

    typemethod Worker {} {
        if {$Tid ne ""} { return $Tid }
        set Tid [thread::create]
        thread::send $Tid [list set auto_path $::auto_path]
        thread::send $Tid {package require tclwuffs}
        thread::send $Tid [list proc fit_within {w h max} [info body fit_within]]
        thread::send $Tid {
            proc thumb {main path max} {
                set code [catch {
                    set fh [open $path rb]
                    try { set raw [read $fh] } finally { close $fh }
                    set d [::tclwuffs::dims $raw]
                    lassign [fit_within [dict get $d width] \
                        [dict get $d height] $max] w h
                    ::tclwuffs::resize_bytes $raw $w $h
                } res]
                thread::send -async $main \
                    [list thumbnailer Done $path $max $code $res]
            }
        }
        return $Tid
    }

    typemethod Done {path max code res} {
        set key [list $path $max]
        set waiting [dict getdef $Waiting $key {}]
        dict unset Waiting $key
        set png [expr {$code ? "" : $res}]
        foreach w $waiting {
            lassign $w owner cmd
            if {[winfo exists $owner]} { {*}$cmd $png }
        }
    }
}
