# The XML console: stanzas render, filters hide and re-show them, and the
# toolbar's search reaches the text. No connection here - stanzas are pushed
# straight in, which is what the debug tap does.

proc xs_up {} {
    mock_backend_up
    toplevel .xstop
    set ::_xs [xmlstream .xstop.xs]
    pack $::_xs -expand yes -fill both
    update
    return $::_xs
}

proc xs_down {} {
    destroy .xstop
    unset -nocomplain ::_xs
    mock_backend_down
}

proc xs_text {} { return [.xstop.xs.text get 1.0 end-1c] }

proc xs_push {xml} {
    $::_xs onStanza [list -dir in -stanza [xmppreader string $xml]]
    update
}

test xmlstream-draws-a-stanza {A pushed stanza is rendered} \
    -setup {xs_up} -body {
    xs_push {<message to='juliet@capulet.lit'><body>hi</body></message>}
    string match "*<message*juliet@capulet.lit*hi*" [xs_text]
} -cleanup {xs_down} -result 1

test xmlstream-filters-out-presence {Presence is hidden by default} \
    -setup {xs_up} -body {
    xs_push {<presence from='romeo@montague.lit'/>}
    string match "*presence*" [xs_text]
} -cleanup {xs_down} -result 0

test xmlstream-filter-toggle-redraws {Enabling a filter draws what it hid} \
    -setup {xs_up} -body {
    xs_push {<presence from='romeo@montague.lit'/>}
    set before [string match "*presence*" [xs_text]]
    .xstop.xs.toolbar.filters setFilters {iq 1 presence 1 message 1 nonza 0 ns ""}
    update
    list $before [string match "*presence*" [xs_text]]
} -cleanup {xs_down} -result {0 1}

test xmlstream-filter-off-removes {Disabling a filter takes drawn ones away} \
    -setup {xs_up} -body {
    xs_push {<message><body>hi</body></message>}
    set before [string match "*<message*" [xs_text]]
    .xstop.xs.toolbar.filters setFilters {iq 1 presence 0 message 0 nonza 0 ns ""}
    update
    list $before [string match "*<message*" [xs_text]]
} -cleanup {xs_down} -result {1 0}

test xmlstream-clear {clear empties the widget and the backlog} \
    -setup {xs_up} -body {
    xs_push {<message><body>hi</body></message>}
    $::_xs clear
    update
    string trim [xs_text]
} -cleanup {xs_down} -result {}

test xmlstream-toolbar-icons {The toolbar's images resolve} \
    -setup {xs_up} -body {
    lmap w {clearbutton godown searchlabel} {
        expr {[image height [.xstop.xs.toolbar.$w cget -image]] > 0}
    }
} -cleanup {xs_down} -result {1 1 1}

test xmlstream-focus-search {focusSearch reaches the toolbar's entry} \
    -setup {xs_up} -body {
    $::_xs FocusSearch
    update
    focus
} -cleanup {xs_down} -result {.xstop.xs.toolbar.searchentry}

test xmlstream-find-highlights {find tags the match} -setup {xs_up} -body {
    xs_push {<message><body>wherefore</body></message>}
    $::_xs find wherefore
    update
    expr {[llength [.xstop.xs.text tag ranges found]] > 0}
} -cleanup {xs_down} -result 1

test xmlstream-send-disabled-without-tap {Send is off until a tap is up} \
    -setup {xs_up} -body {
    .xstop.xs.sendbar.btn instate disabled
} -cleanup {xs_down} -result 1

test xmlstanza-viewer {The single-stanza viewer opens and reuses its window} \
    -body {
    set a [xmlstanza showxml {<iq type='get'/>} "First"]
    set b [xmlstanza showxml {<iq type='set'/>} "Second"]
    list [expr {$a eq $b}] [wm title $a] \
        [string match "*type='set'*" [$a.xs.text get 1.0 end-1c]]
} -cleanup {destroy .xml_stanza_viewer} -result {1 Second 1}
