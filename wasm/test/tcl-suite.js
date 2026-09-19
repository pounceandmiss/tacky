/*
 * Runs tacky's Tcl test suite inside the interpreter `make wasm-tcltest`
 * builds (tests/ bundled beside lib/), from node (tcl.mjs) or a page
 * (index.html). tcltest reports by printing, so the transcript is the score.
 */

// The driver, in the shape of test_all.tcl. Returns the files that would not load.
export function driverScript({ dir = 'taco', file = '', match = '*',
        tacoArgs = '', server = '' } = {}) {
    return `
# Emscripten's stdout translates to CRLF, and a transcript with a stray CR at
# the end of every line is one nothing can match against.
catch {fconfigure stdout -translation lf}
catch {fconfigure stderr -translation lf}

set root //zipfs:/app
lappend auto_path [file join $root lib] [file join $root tests taco] \\
    [file join $root tests taco_integration]
package require tcltest
# tcltest's counters are reset by every cleanupTests, and its per-file
# summary lines are running totals that stop counting a file which never
# calls one - so neither is the score. Accumulate it here instead, where
# nothing resets it.
namespace eval ::suite {
    variable n
    array set n {Total 0 Passed 0 Skipped 0 Failed 0}
}
# The replacement stays inside ::tcltest: the original resolves its own
# helpers unqualified, and a copy living anywhere else cannot find them.
rename ::tcltest::cleanupTests ::tcltest::cleanupTestsInner
proc ::tcltest::cleanupTests {args} {
    variable numTests
    foreach key {Total Passed Skipped Failed} {
        incr ::suite::n($key) $numTests($key)
    }
    uplevel 1 [list ::tcltest::cleanupTestsInner {*}$args]
}

namespace import -force ::tcltest::*

# Extra taco_type options for every environment the fixture builds. A page has
# no socket, so the integration tests reach a server the only way a page can.
set ::tacky_test_taco_args {${tacoArgs}}

# The integration suite is gated on a live server, and on which one it is.
set server {${server}}
::tcltest::testConstraint withServer [expr {$server ne ""}]
foreach {c name} {notProsody prosody notMongoose mongoose notEjabberd ejabberd} {
    ::tcltest::testConstraint $c [expr {$server ne $name}]
}
# Somewhere writable for makeFile and friends: the bundle is read-only.
file mkdir /tmp/tcltest
# And into it: a test that makes a directory and then names a file inside it
# relatively - tcltest's own viewFile does - is looking in the working
# directory, which natively is where the suite was started.
cd /tmp/tcltest
::tcltest::configure -tmpdir /tmp/tcltest -testdir /tmp/tcltest \\
    -match {${match}} -verbose {body error}

set files [lsort [glob -nocomplain [file join $root tests ${dir} ${file || 'test_*.tcl'}]]]
if {[llength $files] == 0} { error "no test files under $root/tests/${dir}" }
set broken {}
foreach f $files {
    if {[catch {source $f} err]} {
        lappend broken "[file tail $f]: $err"
    }
}
# Not every file ends with one, and what it counts is only what has run
# since the last: one here takes in whatever the final files left.
catch {::tcltest::cleanupTests}
list total $::suite::n(Total) passed $::suite::n(Passed) \
     skipped $::suite::n(Skipped) failed $::suite::n(Failed) \
     broken [join $broken " | "]
`;
}

// The names of the failed tests, read from the transcript.
export function failedNames(lines) {
    const names = [];
    for (const raw of lines) {
        const line = raw.replace(/\r$/, '');
        // "==== name description FAILED", and later a bare "==== name FAILED".
        const bad = line.match(/^====\s+(\S+)(\s+.*)?\s+FAILED$/);
        if (bad && !names.includes(bad[1])) names.push(bad[1]);
    }
    return names;
}

// `M` is an interpreter module whose print output is collected into `lines`.
export async function runSuite(M, lines, options = {}) {
    const rc = await M.ccall('zippy_eval', 'number', ['string'],
        [driverScript(options)], { async: true });
    const result = M.ccall('zippy_result', 'string', [], []);
    if (rc !== 0) {
        return { total: 0, passed: 0, skipped: 0, failed: 0,
            failures: [], driverError: result };
    }
    // A flat Tcl list of key/value; `broken` is last and may be braced.
    const words = result.match(/^total (\d+) passed (\d+) skipped (\d+) failed (\d+) broken (.*)$/s);
    const broken = words ? words[5].replace(/^\{|\}$/g, '') : '';
    return {
        total: Number(words?.[1] ?? 0),
        passed: Number(words?.[2] ?? 0),
        skipped: Number(words?.[3] ?? 0),
        failed: Number(words?.[4] ?? 0),
        failures: failedNames(lines),
        broken,
    };
}
