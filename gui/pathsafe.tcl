# A JID, SID or room name turned into something that can name a Tk widget: a
# path component can't hold a dot, and the rest of the punctuation a JID may
# carry is no friendlier. Everything that isn't alphanumeric, underscore, dash
# or plus becomes an underscore.
#
# Every window keyed on an identity goes through here, so they all agree on
# what collides - the maps this replaced disagreed five different ways.
proc path_safe {s} {
    regsub -all {[^a-zA-Z0-9_+-]} $s _
}
