# Unit tests for the disclosure widget.
package require tcltest
namespace import ::tcltest::*

test disclosure-folded {closed by default: the body is not shown, the header says so} -body {
    disclosure .d -title Proxy -summary Direct
    ttk::label .d.body.x -text inside
    pack .d.body.x
    list [winfo manager .d.body] [.d.head.fold cget -text] \
        [.d.head.title cget -text] [.d.head.summary cget -text]
} -cleanup {
    destroy .d
} -result {{} ▸ Proxy Direct}

test disclosure-click-opens {a click on the title opens it and tells -command} -body {
    set ::_disc {}
    disclosure .d -title Proxy -command {lappend ::_disc}
    event generate .d.head.title <Button-1>
    set opened [list [.d cget -open] [winfo manager .d.body] [.d.head.fold cget -text]]
    .d.head.fold invoke
    list $opened [.d cget -open] $::_disc
} -cleanup {
    destroy .d
    unset ::_disc
} -result {{1 pack ▾} 0 {1 0}}

test disclosure-configure-is-quiet {configuring -open shows or hides without running -command} -body {
    set ::_disc {}
    disclosure .d -title Proxy -command {lappend ::_disc}
    .d configure -open 1
    list [winfo manager .d.body] $::_disc
} -cleanup {
    destroy .d
    unset ::_disc
} -result {pack {}}

test disclosure-summary-updates {-summary and its colour change in place} -body {
    disclosure .d -title Proxy -summary Direct
    .d configure -summary "Tor, 127.0.0.1:9050" -summaryforeground firebrick3
    list [.d.head.summary cget -text] [.d.head.summary cget -foreground]
} -cleanup {
    destroy .d
} -result {{Tor, 127.0.0.1:9050} firebrick3}
