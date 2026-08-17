# True when a click at root coordinates X,Y landed outside $w. The popovers
# that take a global grab dismiss themselves on one.
proc click_outside {w X Y} {
    set x0 [winfo rootx $w]
    set y0 [winfo rooty $w]
    expr {$X < $x0 || $X >= $x0 + [winfo width $w]
       || $Y < $y0 || $Y >= $y0 + [winfo height $w]}
}
