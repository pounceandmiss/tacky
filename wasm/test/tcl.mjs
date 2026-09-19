/*
 * Tacky's Tcl test suite inside the wasm interpreter `make wasm-tcltest` builds:
 *
 *   node wasm/test/tcl.mjs [launcher] [--dir taco] [--file test_x.tcl] [--match pat]
 *
 * tcl-suite.js is the driver; index.html's `tcl` scenario runs it in a browser.
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { runSuite } from './tcl-suite.js';

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
    const at = argv.indexOf(`--${name}`);
    return at >= 0 ? argv[at + 1] : fallback;
};
// One positional argument; the rest are --name value pairs.
const launcher = (argv[0]?.startsWith('--') ? null : argv[0])
    ?? 'build/wasm/tacky-tcltest.mjs';
const dir = flag('dir', 'taco');
const file = flag('file', '');
const match = flag('match', '*');
// For the integration suite: the server's endpoint and name.
const tacoArgs = flag('taco-args', process.env.XMPP_WS_URL
    ? `-transport websocket -ws-url ${process.env.XMPP_WS_URL}` : '');
const server = flag('server', process.env.XMPP_SERVER ?? '');

/*
 * tcltest reports by printing, and its counters are reset by the
 * cleanupTests at the end of every file, so the output is the score - the
 * same thing a person reads when running the suite by hand.
 */
const lines = [];
const quiet = argv.includes('--quiet');
const { default: createInterp } = await import(pathToFileURL(resolve(launcher)).href);
const M = await createInterp({
    print(text) { lines.push(text); if (!quiet) console.log(text); },
    printErr(text) { lines.push(text); if (!quiet) console.error(text); },
});

const evaluate = async (script) => {
    const rc = await M.ccall('zippy_eval', 'number', ['string'], [script], { async: true });
    return [rc, M.ccall('zippy_result', 'string', [], [])];
};

const result = await runSuite(M, lines, { dir, file, match, tacoArgs, server });
if (result.driverError) {
    console.error(`the driver itself failed: ${result.driverError}`);
    process.exit(2);
}

console.log(`\n${result.total} tests in the wasm interpreter:`
    + ` ${result.passed} passed, ${result.skipped} skipped, ${result.failed} failed`);
if (result.failures.length) {
    console.log('failed:');
    for (const name of result.failures) console.log(`  ${name}`);
}
if (result.broken) console.log(`files that would not even load: ${result.broken}`);

process.exit(result.failed > 0 || result.broken ? 1 : 0);
