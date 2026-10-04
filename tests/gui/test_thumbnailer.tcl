# Unit tests for thumbnailer - off-thread image downscaling.
package require tcltest
namespace import ::tcltest::*
package require tclwuffs

proc th_file {name w h} {
    set path /tmp/th_${name}_[pid].png
    set px [string repeat [binary format cccc 10 120 200 255] [expr {$w * $h}]]
    set f [open $path wb]
    puts -nonewline $f [::tclwuffs::encode_png $w $h $px]
    close $f
    return $path
}

# The PNG the thumbnailer hands back for $path, as {w h}, or "" for none.
proc th_size {path max} {
    unset -nocomplain ::th_png
    thumbnailer request $path $max . {set ::th_png}
    set t [after 3000 {set ::th_png TIMEOUT}]
    vwait ::th_png
    after cancel $t
    if {$::th_png in {"" TIMEOUT}} { return $::th_png }
    set d [::tclwuffs::dims $::th_png]
    list [dict get $d width] [dict get $d height]
}

test thumbnailer-fitwithin {fit_within shrinks within max, preserves aspect, no upscale} -body {
    list [fit_within 200 100 50] [fit_within 100 200 50] \
         [fit_within 40 30 100] [fit_within 50 50 50]
} -result {{50 25} {25 50} {40 30} {50 50}}

test thumbnailer-downscales {an image is scaled to fit max, a small one is left as is} -body {
    set big [th_file big 600 360]
    set tiny [th_file tiny 32 16]
    set r [list [th_size $big 320] [th_size $tiny 320]]
    file delete $big $tiny
    set r
} -result {{320 192} {32 16}}

test thumbnailer-undecodable {a file that won't decode yields no thumbnail} -body {
    set path /tmp/th_bad_[pid].png
    set f [open $path wb]
    puts -nonewline $f "not an image"
    close $f
    set r [th_size $path 320]
    file delete $path
    set r
} -result {}
