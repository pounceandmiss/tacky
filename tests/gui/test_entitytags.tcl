# Unit tests for entitytags::combine — overlapping font spans -> compound tags.
# Pure function, no widgets: gui/entitytags.tcl is already sourced by test_gui.tcl.
package require tcltest
namespace import ::tcltest::*

test entitytags-empty {no spans} -body {
    entitytags::combine {}
} -result {}

test entitytags-single {one span passes through} -body {
    entitytags::combine {bold 0 4}
} -result {bold 0 4}

test entitytags-full-overlap {two styles over the same run merge into one compound} -body {
    entitytags::combine {italic 0 11 bold 0 11}
} -result {bold.italic 0 11}

test entitytags-contained {a nested style splits the run into three} -body {
    entitytags::combine {bold 0 10 italic 2 4}
} -result {bold 0 2 bold.italic 2 4 bold 6 4}

test entitytags-threeway {three styles compound in alphabetical (cross-product) order} -body {
    entitytags::combine {bold 0 5 italic 0 5 monospace 0 5}
} -result {bold.italic.monospace 0 5}
