if 0 {
    tk_avatarcache - Tk implementation of avatarcache_base.

    See avatarcache_base in tacky.tcl for the full API.
}

package require tkwuffs

# Decode master bytes (any format tkwuffs handles), center-crop to a square,
# and scale to a $size x $size photo. Returns "" when the data won't decode.
proc square_photo {data size} {
    set src [image create photo]
    if {[catch {::tkwuffs::decode_to_photo $data $src}]} {
        image delete $src
        return ""
    }
    set w [image width $src]
    set h [image height $src]
    set side [expr {min($w, $h)}]
    set out [image create photo]
    if {$side <= 0} {
        image delete $src
        return $out
    }
    set x [expr {($w - $side) / 2}]
    set y [expr {($h - $side) / 2}]
    ::tkwuffs::crop_photo $src $out $x $y $side $side
    image delete $src
    ::tkwuffs::resize_photo $out $out $size $size
    return $out
}

oo::class create tk_avatarcache {
    superclass avatarcache_base

    # Undecodable data falls back to the placeholder.
    method CreateImage {data size} {
        set img [square_photo $data $size]
        if {$img eq ""} { return [my CreateDefault] }
        return $img
    }

    method DeleteImage {img} {
        image delete $img
    }

    method CreateDefault {} {
        set img [image create photo]
        $img copy avatarcache::defaultAvatar
        return $img
    }
}
