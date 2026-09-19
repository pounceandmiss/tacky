# chatrows draws chat-list rows on a canvas: the caller hands it rows in
# order, it owns selection and hit-testing.

proc cr_row {key args} {
    dict merge [dict create key $key name $key preview "" unread 0 time 0 image ""] $args
}

proc cr_create {rows args} {
    chatrows .cr {*}$args
    pack .cr -fill both -expand yes
    .cr set $rows
    update
}

proc cr_cleanup {} {
    destroy .cr
    update
}

test chatrows-keys-in-order {keys come back in the order they were set} -body {
    cr_create [list [cr_row b] [cr_row a] [cr_row c]]
    .cr keys
} -cleanup cr_cleanup -result {b a c}

test chatrows-row-is-what-was-set {a row reads back as given} -body {
    cr_create [list [cr_row a name Alice preview hi unread 2]]
    set r [.cr row a]
    list [dict get $r name] [dict get $r preview] [dict get $r unread] [.cr exists a] [.cr exists z]
} -cleanup cr_cleanup -result {Alice hi 2 1 0}

test chatrows-draws-name-preview-badge {the canvas holds the name, the preview and the badge} -body {
    cr_create [list [cr_row a name Alice preview "hey there" unread 3]]
    set c .cr.canvas
    lmap part {name preview badge.label} { $c itemcget [$c find withtag $part] -text }
} -cleanup cr_cleanup -result {Alice {hey there} 3}

test chatrows-mention-colours-the-badge {a mention paints the badge in the mention colour} -body {
    cr_create [list [cr_row a name Alice preview hi unread 3 mention 1] \
                    [cr_row b name Bob preview hi unread 1]]
    set c .cr.canvas
    list [expr {[$c itemcget "row.0 && badge" -fill] eq [palette mention]}] \
         [expr {[$c itemcget "row.1 && badge" -fill] eq [palette accent]}]
} -cleanup cr_cleanup -result {1 1}

test chatrows-name-styles-apply {a configured tag restyles the name} -body {
    cr_create [list [cr_row a name Alice tags {muc_idle}]]
    .cr tag configure muc_idle -foreground gray60 -font ""
    .cr set [list [cr_row a name Alice tags {muc_idle}]]
    set c .cr.canvas
    list [$c itemcget name -fill] [$c itemcget name -font]
} -cleanup cr_cleanup -result {gray60 ChatrowsName}

test chatrows-select-highlights-and-reports {selecting a row tags it and fires the select command} -body {
    set got {}
    cr_create [list [cr_row a] [cr_row b]] \
        -select-command {apply {{k} { lappend ::got $k }}}
    .cr select b
    list [.cr selected] [llength [.cr.canvas find withtag selected]] $got
} -cleanup cr_cleanup -result {b 1 {}}

test chatrows-select-unknown-clears {selecting a key that is not there clears the selection} -body {
    cr_create [list [cr_row a]]
    .cr select a
    .cr select zz
    .cr selected
} -cleanup cr_cleanup -result {}

test chatrows-set-keeps-selection {a redraw keeps the selected row, or drops it when gone} -body {
    cr_create [list [cr_row a] [cr_row b]]
    .cr select b
    .cr set [list [cr_row b name Bobby] [cr_row a]]
    set kept [.cr selected]
    .cr set [list [cr_row a]]
    list $kept [.cr selected]
} -cleanup cr_cleanup -result {b {}}

test chatrows-keyboard-moves-selection {Up and Down walk the rows and report each move} -body {
    set got {}
    cr_create [list [cr_row a] [cr_row b] [cr_row c]] \
        -select-command {apply {{k} { lappend ::got $k }}}
    .cr Move 1
    .cr Move 1
    .cr Move 1
    .cr Move 1
    .cr Move -1
    set got
} -cleanup cr_cleanup -result {a b c c b}

test chatrows-return-activates {Return opens the selected row} -body {
    set got {}
    cr_create [list [cr_row a] [cr_row b]] \
        -activate-command {apply {{k} { lappend ::got $k }}}
    .cr Activate
    .cr select b
    .cr Activate
    set got
} -cleanup cr_cleanup -result {b}

test chatrows-click-hits-the-row {a click on a row's pixels selects it; empty space selects nothing} -body {
    cr_create [list [cr_row a preview one] [cr_row b preview two]]
    set c .cr.canvas
    lassign [$c bbox row.1] x y
    .cr OnClick [expr {$x + 2}] [expr {$y + 2}]
    set hit [.cr selected]
    .cr select ""
    .cr OnClick 5 [expr {[winfo height $c] - 2}]
    list $hit [.cr selected]
} -cleanup cr_cleanup -result {b {}}

test chatrows-right-click-reports-screen-coords {a right-click selects the row and hands the menu its screen position} -body {
    set got {}
    cr_create [list [cr_row a preview one]] \
        -menu-command {apply {{k X Y} { set ::got [list $k $X $Y] }}}
    lassign [.cr.canvas bbox row.0] x y
    .cr OnRightClick [expr {$x + 2}] [expr {$y + 2}] 100 200
    list [.cr selected] $got
} -cleanup cr_cleanup -result {a {a 100 200}}

test chatrows-image-swaps-in-place {a new avatar replaces the embedded one without a redraw} -body {
    set i1 [image create photo -width 8 -height 8]
    set i2 [image create photo -width 8 -height 8]
    cr_create [list [cr_row a image $i1]]
    .cr image a $i2
    expr {[.cr.canvas itemcget avatar -image] eq $i2}
} -cleanup {
    cr_cleanup
    image delete $i1 $i2
} -result 1

test chatrows-when-today {a stamp from today is the time} -body {
    set now [clock scan "2026-09-19 14:00:00" -format "%Y-%m-%d %H:%M:%S"]
    set then [clock scan "2026-09-19 09:05:00" -format "%Y-%m-%d %H:%M:%S"]
    chatrows_when [expr {$then * 1000000}] $now
} -result 09:05

test chatrows-when-this-year {a stamp from this year is the day} -body {
    set now [clock scan "2026-09-19 14:00:00" -format "%Y-%m-%d %H:%M:%S"]
    set then [clock scan "2026-06-15 09:05:00" -format "%Y-%m-%d %H:%M:%S"]
    chatrows_when [expr {$then * 1000000}] $now
} -result {15 Jun}

test chatrows-when-older {an older stamp is the date, and never is nothing} -body {
    set now [clock scan "2026-09-19 14:00:00" -format "%Y-%m-%d %H:%M:%S"]
    set then [clock scan "2024-06-15 09:05:00" -format "%Y-%m-%d %H:%M:%S"]
    list [chatrows_when [expr {$then * 1000000}] $now] [chatrows_when 0 $now]
} -result {2024-06-15 {}}
