// tackyHttp: taco_http's browser backend (lib/taco/modules/httpreq.tcl),
// reached through zippy's ::em::call. Linked with --pre-js, so it can use
// the module's FS.
//
//   tackyHttp(method, url, outfile, infile, timeoutMs, name, value, ..., ctx)
//
// The request body is read from infile and the response written to outfile
// (Emscripten paths; either may be ""). Always resolves with a Tcl list
// "status code message": status is ok, error, timeout or reset, code is the
// HTTP status or 0 when there was none. ctx.signal cancels, ctx.progress
// reports (total, loaded) in either direction.
//
// XMLHttpRequest where there is one, for upload progress; fetch elsewhere
// (node, where the tests run), which reports download progress only.

Module.zippyCalls = Module.zippyCalls || {};

Module.zippyCalls.tackyHttp = (method, url, outfile, infile, timeout, ...rest) => {
    const ctx = rest.pop();
    const headers = rest;
    const ms = Number(timeout) || 0;
    const quote = (s) => '{' + String(s).replace(/[{}\\]/g, '') + '}';
    const result = (status, code, message) => `${status} ${code} ${quote(message)}`;

    let body = null;
    if (infile) {
        try {
            body = FS.readFile(infile);
        } catch (err) {
            return result('error', 0, `cannot read ${infile}: ${err}`);
        }
    }
    const save = (bytes) => {
        if (outfile) FS.writeFile(outfile, bytes);
    };

    if (typeof XMLHttpRequest !== 'undefined') {
        return new Promise((resolve) => {
            const xhr = new XMLHttpRequest();
            const done = (...r) => resolve(result(...r));
            try {
                xhr.open(method, url, true);
            } catch (err) {
                done('error', 0, String(err));
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
                    done('error', xhr.status, `cannot write ${outfile}: ${err}`);
                    return;
                }
                done('ok', xhr.status, '');
            };
            // A page is not told why a cross-origin request failed.
            xhr.onerror = () => done('error', xhr.status, 'network error');
            xhr.ontimeout = () => done('timeout', 0, 'timed out');
            xhr.onabort = () => done('reset', 0, 'aborted');
            ctx.signal.addEventListener('abort', () => xhr.abort());
            try {
                xhr.send(body);
            } catch (err) {
                done('error', 0, String(err));
            }
        });
    }

    return (async () => {
        let expired = false;
        const control = new AbortController();
        ctx.signal.addEventListener('abort', () => control.abort());
        const timer = ms > 0 ? setTimeout(() => { expired = true; control.abort(); }, ms) : 0;
        try {
            const head = {};
            for (let i = 0; i + 1 < headers.length; i += 2) head[headers[i]] = headers[i + 1];
            const res = await fetch(url, { method, headers: head, body, signal: control.signal });
            const total = Number(res.headers.get('content-length') ?? 0);
            const chunks = [];
            let loaded = 0;
            if (res.body) {
                const reader = res.body.getReader();
                for (;;) {
                    const piece = await reader.read();
                    if (piece.done) break;
                    chunks.push(piece.value);
                    loaded += piece.value.length;
                    ctx.progress(total, loaded);
                }
            }
            const all = new Uint8Array(loaded);
            let at = 0;
            for (const chunk of chunks) { all.set(chunk, at); at += chunk.length; }
            save(all);
            return result('ok', res.status, '');
        } catch (err) {
            if (expired) return result('timeout', 0, 'timed out');
            if (err && err.name === 'AbortError') return result('reset', 0, 'aborted');
            return result('error', 0, (err && err.message) || String(err));
        } finally {
            clearTimeout(timer);
        }
    })();
};
