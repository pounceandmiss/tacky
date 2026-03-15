proc compensate {text script} {
    # Keep the viewport on the same content when messages are inserted
    # before it. Works for scattered insertions (not just a single point).
    #
    # Why this is needed:
    # Tk's text widget keeps the same pixel offset from the start of
    # the document when content is inserted. So if the user is looking
    # at message F and we prepend messages A-E, the viewport stays at
    # the same pixel position — now showing A instead of F. The user
    # sees a visual jump. We need to scroll down by the height of the
    # inserted content to restore the view to F.
    #
    # How it works:
    # 1. Place a mark at @0,0 — the first character visible at the
    #    top-left of the viewport (may be in a partially visible line).
    #    Right gravity keeps the mark attached to the original content
    #    when text is inserted at or before it.
    # 2. Run the script (arbitrary insertions anywhere in the widget).
    # 3. Force a synchronous layout ($text sync) — without this, pixel
    #    measurements would use stale geometry from before the inserts.
    # 4. Measure how far the mark drifted from the actual viewport top.
    #    Any insertion before @0,0 — even one character before a
    #    partially visible top line — pushes the mark down. The delta
    #    is the total height of content inserted before the viewport.
    #    Scroll by that amount.
    #
    # Insertions after the first visible character don't move the mark,
    # so delta is 0 and no scrolling happens — correct, since those
    # insertions don't cause a visual jump.

    $text mark set _comp_vtop @0,0
    $text mark gravity _comp_vtop right

    uplevel $script
    $text sync

    set delta [expr {
	[$text count -ypixels 0.0 _comp_vtop]
	- [$text count -ypixels 0.0 @0,0]
    }]
    if {$delta > 0} {
	$text yview scroll $delta pixels
    }
    $text mark unset _comp_vtop
}
