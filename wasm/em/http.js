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
        if (ms > 0) xhr.timeout = ms;
        for (let i = 0; i + 1 < headers.length; i += 2) {
            try { xhr.setRequestHeader(headers[i], headers[i + 1]); } catch (err) { /* forbidden */ }
        }
        xhr.onprogress = (ev) => ctx.progress(ev.total || 0, ev.loaded || 0);
        if (xhr.upload) xhr.upload.onprogress = (ev) => ctx.progress(ev.total || 0, ev.loaded || 0);
        xhr.onload = () => {
            try {
                save(new Uint8Array(xhr.response ?? new ArrayBuffer(0)));
            } catch (err) {
                fail(`cannot write ${outfile}: ${err}`);
                return;
            }
            resolve(String(xhr.status));
        };
        // A page is not told why a cross-origin request failed.
        xhr.onerror = () => fail('network error');
        xhr.ontimeout = () => fail('timed out');
        xhr.onabort = () => fail('aborted');
        ctx.signal.addEventListener('abort', () => xhr.abort());
        try {
            xhr.send(body);
        } catch (err) {
            fail(String(err));
        }
    });
};
