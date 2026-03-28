if 0 {
    tk_avatarcache - Tk implementation of avatarcache_base.

    See avatarcache_base in tacky.tcl for the full API.
}

oo::class create tk_avatarcache {
    superclass avatarcache_base

    method CreateImage {data} {
        image create photo -data $data
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
