set _icondir [file join $::dir icons]

image create photo image/mate/48x48/emblems/emblem-downloads.png \
    -file [file join $_icondir emblem-downloads.png]
image create photo mate/22x22/status/avatar-default.png \
    -file [file join $_icondir avatar-default-22.png]
image create photo mate/32x32/status/avatar-default.png \
    -file [file join $_icondir avatar-default-32.png]
image create photo mate/32x32/status/stock_lock.png \
    -file [file join $_icondir stock_lock.png]
image create photo mate/22x22/status/microphone-sensitivity-high.png \
    -file [file join $_icondir microphone-sensitivity-high-22.png]
image create photo mate/22x22/status/microphone-sensitivity-muted.png \
    -file [file join $_icondir microphone-sensitivity-muted-22.png]
image create photo mate/22x22/status/audio-volume-high.png \
    -file [file join $_icondir audio-volume-high-22.png]
image create photo mate/22x22/status/audio-volume-muted.png \
    -file [file join $_icondir audio-volume-muted-22.png]
image create photo mate/22x22/actions/call-stop.png \
    -file [file join $_icondir call-stop-22.png]
image create photo mate/22x22/actions/call-start.png \
    -file [file join $_icondir call-start-22.png]
image create photo mate/16x16/actions/mail-reply-sender.png \
    -file [file join $_icondir mail-reply-sender-16.png]
image create photo mate/16x16/actions/contact-new.png \
    -file [file join $_icondir contact-new-16.png]

image create photo mate/22x22/status/mail-attachment.png \
    -file [file join $_icondir mail-attachment-22.png]

# OMEMO lock icons pulled from the system mate theme; fall back to the
# bundled 32x32 lock if the theme isn't installed.
foreach {_name _rel} {
    mate/16x16/status/stock_lock.png      16x16/status/stock_lock.png
    mate/24x24/status/stock_lock.png      24x24/status/stock_lock.png
    mate/24x24/status/stock_lock-open.png 24x24/status/stock_lock-open.png
} {
    if {[catch {
        image create photo $_name -file /usr/share/icons/mate/$_rel
    }]} {
        image create photo $_name -file [file join $_icondir stock_lock.png]
    }
}
unset _name _rel

# Shared fallback avatar (used by avatarcache)
if {[catch {
    image create photo avatarcache::defaultAvatar \
        -file [file join $_icondir avatar-default-32.png]
}]} {
    image create photo avatarcache::defaultAvatar -width 32 -height 32
}

unset _icondir
