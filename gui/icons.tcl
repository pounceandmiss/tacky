set _icondir [file join $::dir icons]

image create photo image/mate/48x48/emblems/emblem-downloads.png \
    -file [file join $_icondir emblem-downloads.png]
image create photo mate/22x22/status/avatar-default.png \
    -file [file join $_icondir avatar-default-22.png]
image create photo mate/32x32/status/avatar-default.png \
    -file [file join $_icondir avatar-default-32.png]
image create photo mate/32x32/status/stock_lock.png \
    -file [file join $_icondir stock_lock.png]

# Shared fallback avatar (used by avatarcache)
if {[catch {
    image create photo avatarcache::defaultAvatar \
        -file [file join $_icondir avatar-default-32.png]
}]} {
    image create photo avatarcache::defaultAvatar -width 32 -height 32
}

unset _icondir
