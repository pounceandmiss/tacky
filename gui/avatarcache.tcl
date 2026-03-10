if 0 {
    tk_avatarcache - Tk implementation of avatarcache_base.

    See avatarcache_base in tacky.tcl for the full API.
}

# Shared fallback avatar (32x32)
if {[catch {
    image create photo avatarcache::defaultAvatar \
	-file /usr/share/icons/mate/32x32/status/avatar-default.png
}]} {
    image create photo avatarcache::defaultAvatar -width 32 -height 32
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
