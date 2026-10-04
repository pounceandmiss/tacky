/*
 * Runs tacky's Tcl test suite - test_all.tcl, as natively - in the
 * interpreter `make wasm-tcltest` builds, from a page (index.html). tcltest's
 * transcript goes to the console, as it goes to the terminal natively.
 */

// `env` is test_all.tcl's environment variables. Returns whether everything
// passed, or the error if test_all.tcl itself failed.
export async function runSuite(env) {
    const { default: createInterp } = await import('./tacky-tcltest.mjs');
    const M = await createInterp({ env, print: console.log, printErr: console.log });
    const rc = await M.ccall('zippy_eval', 'number', ['string'],
        ['source //zipfs:/app/test_all.tcl'], { async: true });
    const result = M.ccall('zippy_result', 'string', [], []);
    return rc === 0 ? { ok: result === '0' } : { ok: false, error: result };
}
