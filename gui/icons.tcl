set _icondir [file join $::dir icons]

# All app icons are bundled in icons/ (faithful copies from the mate theme).
# Names mirror the mate theme layout; sizes match where each is drawn.
foreach {_name _file} {
    mate/22x22/status/avatar-default.png                  avatar-default-22.png
    mate/32x32/status/avatar-default.png                  avatar-default-32.png
    mate/16x16/status/stock_lock.png                      stock_lock-16.png
    mate/24x24/status/stock_lock.png                      stock_lock-24.png
    mate/24x24/status/stock_lock-open.png                 stock_lock-open-24.png
    mate/16x16/status/dialog-warning.png                  dialog-warning-16.png
    mate/22x22/status/microphone-sensitivity-high.png     microphone-sensitivity-high-22.png
    mate/22x22/status/microphone-sensitivity-muted.png    microphone-sensitivity-muted-22.png
    mate/22x22/status/audio-volume-high.png               audio-volume-high-22.png
    mate/22x22/status/audio-volume-muted.png              audio-volume-muted-22.png
    mate/22x22/actions/call-stop.png                      call-stop-22.png
    mate/22x22/actions/call-start.png                     call-start-22.png
    mate/16x16/actions/mail-reply-sender.png              mail-reply-sender-16.png
    mate/16x16/actions/contact-new.png                    contact-new-16.png
    mate/22x22/status/mail-attachment.png                 mail-attachment-22.png
    avatarcache::defaultAvatar                            avatar-default-32.png
} {
    image create photo $_name -file [file join $_icondir $_file]
}
unset _name _file

# Window icon: rasterize the bundled SVG at several sizes and publish them all
# so the WM picks the right one per context (titlebar, taskbar, alt-tab, dock).
# -default applies to every toplevel created after this point.
set _appicons {}
foreach _sz {16 32 48 128} {
    if {![catch {
        image create photo tacky/icon/$_sz \
            -file [file join $_icondir tacky.svg] \
            -format "svg -scaletoheight $_sz"
    }]} {
        lappend _appicons tacky/icon/$_sz
    }
}
if {[llength $_appicons]} {
    wm iconphoto . -default {*}$_appicons
}
unset -nocomplain _appicons _sz

unset _icondir
