proc compensate {text script} {
    # Keep the viewport on the same content when messages are prepended.
    #
    # Two cases:
    # 1. Insertion is ABOVE the viewport (user scrolled down):
    #    Tk already preserves the viewport — do nothing.
    # 2. Insertion is AT the viewport top (user scrolled all the way up):
    #    Tk keeps the same pixel offset, showing the new content.
    #    We must scroll down by the height of the insertion.

    set viewTop [$text index @0,0]
    set insertAt [$text index msgins]
    set atTop [$text compare $insertAt >= $viewTop]

    $text mark set _comp_start msgins
    $text mark gravity _comp_start left

    uplevel $script
    $text sync

    if {$atTop} {
	set pixels [$text count -ypixels _comp_start msgins]
	$text yview scroll $pixels pixels
    }

    $text mark unset _comp_start
}
