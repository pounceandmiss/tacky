/*
 * Runs tacky's Tcl test suite inside the interpreter `make wasm-tcltest`
 * builds (tests/ bundled beside lib/), from a page (index.html), through
 * tcltest's own runAllTests.
 */

// The driver: tcltest's runAllTests over one directory, in this interpreter.
// Its result is 1 if any test or file failed.
export function driverScript({ dir = 'taco', file = '', match = '*',
        tacoArgs = '', accountArgs = '', server = '', httpBase = '' } = {}) {
    return `
# Emscripten's stdout translates to CRLF, and a transcript with a stray CR at
# the end of every line is one nothing can match against.
catch {fconfigure stdout -translation lf}
catch {fconfigure stderr -translation lf}

set root //zipfs:/app
lappend auto_path [file join $root lib] [file join $root tests taco] \\
    [file join $root tests taco_integration]
package require tcltest
namespace import -force ::tcltest::*

# Extra taco_type options, and extra fields for each account a test adds:
# the websocket transport, and the test server's plain-ws endpoint.
set ::tacky_test_taco_args {${tacoArgs}}
set ::tacky_test_account_args {${accountArgs}}
# Where test_httpreq.tcl finds serve.mjs's /_t/ endpoints.
set ::tacky_test_http_base {${httpBase}}

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
::tcltest::configure -testdir [file join $root tests ${dir}] \\
    -file {${file || 'test_*.tcl'}} -match {${match}} \\
    -singleproc 1 -tmpdir /tmp/tcltest -verbose {body error}
::tcltest::runAllTests
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
// Returns whether everything passed, tcltest's summary line and the failed
// tests' names, or the error if the driver itself failed.
export async function runSuite(M, lines, options = {}) {
    const from = lines.length;
    const rc = await M.ccall('zippy_eval', 'number', ['string'],
        [driverScript(options)], { async: true });
    const result = M.ccall('zippy_result', 'string', [], []);
    if (rc !== 0) return { ok: false, summary: '', failures: [], driverError: result };
    const mine = lines.slice(from);
    return {
        ok: result === '0',
        summary: mine.find((l) => /\tTotal\t/.test(l)) ?? '',
        failures: failedNames(mine),
        // tcltest's own report of each failure, for the console: from
        // "==== name ... FAILED" to "==== name FAILED".
        report: mine.filter((l, i) => {
            const open = mine.slice(0, i + 1).filter((m) => /^====.*FAILED$/.test(m)).length;
            return open % 2 === 1 || /^====.*FAILED$/.test(l);
        }),
    };
}
