# Bring an already-open window forward, reporting whether there was one. The
# windows keyed on an account, chat or call are singletons, so their entry
# points all open with:
#
#   if {[raise_existing $w]} { return $w }
proc raise_existing {w} {
    if {![winfo exists $w]} { return 0 }
    wm deiconify $w
    raise $w
    return 1
}
