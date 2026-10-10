// tackyHttp: taco_http's browser backend (lib/taco/modules/httpreq.tcl),
// reached through zippy's ::em::call. Linked with --pre-js, so it can use
// the module's FS.
//
//   tackyHttp(method, url, outfile, infile, timeoutMs, name, value, ..., ctx)
//
// The request body is read from infile and the response written to outfile
// (Emscripten paths; either may be ""). Resolves with the HTTP status code of
// a completed request; rejects with "timed out", "aborted" or what went
// wrong. ctx.signal cancels, ctx.progress reports (total, loaded).
// timeoutMs is how long it may go without moving a byte, not how long it may
// take, so it is our own timer, re-armed on each progress event, rather than
// xhr.timeout, which is a deadline on the whole request.
//
// XMLHttpRequest rather than fetch, for upload progress.

Module.zippyCalls = Module.zippyCalls || {};

Module.zippyCalls.tackyHttp = (method, url, outfile, infile, timeout, ...rest) => {
    const ctx = rest.pop();
    const headers = rest;
    const ms = Number(timeout) || 0;

    let body = null;
    if (infile) {
        try {
            body = FS.readFile(infile);
        } catch (err) {
            return Promise.reject(new Error(`cannot read ${infile}: ${err}`));
        }
    }
    const save = (bytes) => {
        if (outfile) FS.writeFile(outfile, bytes);
    };

    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        const fail = (message) => reject(new Error(message));
        try {
            xhr.open(method, url, true);
        } catch (err) {
            fail(String(err));
            return;
        }
        xhr.responseType = 'arraybuffer';
        let idle = null;
        let timedOut = false;
        const quiet = () => {
            if (ms <= 0) return;
            clearTimeout(idle);
            idle = setTimeout(() => {
                timedOut = true;
                xhr.abort();
            }, ms);
        };
        const settle = (then) => (...args) => {
            clearTimeout(idle);
            then(...args);
        };
        for (let i = 0; i + 1 < headers.length; i += 2) {
            try { xhr.setRequestHeader(headers[i], headers[i + 1]); } catch (err) { /* forbidden */ }
        }
        const progress = (ev) => {
            quiet();
            ctx.progress(ev.total || 0, ev.loaded || 0);
        };
        xhr.onprogress = progress;
        if (xhr.upload) xhr.upload.onprogress = progress;
        xhr.onload = settle(() => {
            try {
                save(new Uint8Array(xhr.response ?? new ArrayBuffer(0)));
            } catch (err) {
                fail(`cannot write ${outfile}: ${err}`);
                return;
            }
            resolve(String(xhr.status));
        });
        // A page is not told why a cross-origin request failed.
        xhr.onerror = settle(() => fail('network error'));
        xhr.onabort = settle(() => fail(timedOut ? 'timed out' : 'aborted'));
        ctx.signal.addEventListener('abort', () => xhr.abort());
        try {
            quiet();
            xhr.send(body);
        } catch (err) {
            clearTimeout(idle);
            fail(String(err));
        }
    });
};
