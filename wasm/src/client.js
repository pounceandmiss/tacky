// The page's side of the Worker in worker.js: the JSON protocol plus the
// waiting a page needs around it. Options and shape: index.d.ts.

export function createClient(options = {}) {
    const { onEvent = null, worker: workerUrl, ...config } = options;
    // Relative to this module, not the document, so the directory can live anywhere.
    const worker = new Worker(workerUrl ?? new URL('./worker.js', import.meta.url),
        { type: 'module' });
    worker.postMessage({ type: 'configure', options: config });

    // Recent frames for `until` to look back over; bounded, `dropped` keeps
    // the numbering straight for a caller mid-wait.
    const LOG_MAX = 1000;
    const messages = [];
    let dropped = 0;
    const waiters = [];
    const client = {
        worker, messages, onEvent,
        storage: null, fatal: null, stopped: false,
    };

    let markReady;
    client.ready = new Promise((resolve) => { markReady = resolve; });

    worker.addEventListener('message', (ev) => {
        const m = ev.data;
        switch (m.type) {
        case 'storage': client.storage = m.mode; break;
        case 'ready': markReady(true); break;
        case 'fatal': client.fatal = m.message; markReady(false); break;
        case 'stopped': client.stopped = true; break;
        case 'message': {
            const frame = JSON.parse(m.json);
            messages.push(frame);
            if (messages.length > LOG_MAX) {
                dropped += messages.length - LOG_MAX;
                messages.splice(0, messages.length - LOG_MAX);
            }
            client.onEvent?.(frame);
            break;
        }
        }
        for (const w of waiters.splice(0)) w();
    });

    // Either the worker said something or a tick passed; the caller decides
    // when it has waited long enough.
    const wake = () => Promise.race([
        new Promise((r) => waiters.push(r)),
        new Promise((r) => setTimeout(r, 50)),
    ]);

    client.until = async (want, ms = 30_000) => {
        const deadline = Date.now() + ms;
        for (let at = dropped; ; ) {
            if (at < dropped) at = dropped;   /* frames fell off while waiting */
            for (; at < dropped + messages.length; at++) {
                const frame = messages[at - dropped];
                if (want(frame)) return frame;
            }
            if (client.fatal || Date.now() > deadline) return null;
            await wake();
        }
    };
    client.send = (frame) =>
        worker.postMessage({ type: 'request', json: JSON.stringify(frame) });

    let token = 0;
    client.request = (frame, ms) => {
        const id = ++token;
        client.send([...frame, id]);
        return client.until((m) => (m[0] === 'result' || m[0] === 'error') && m[1] === id, ms);
    };
    client.event = (module, name, match = () => true, ms) =>
        client.until((m) => m[0] === 'event' && m[1] === module
            && m[2] === name && match(m[3]), ms);

    client.stop = async (ms = 15_000) => {
        worker.postMessage({ type: 'stop' });
        const deadline = Date.now() + ms;
        while (!client.stopped && Date.now() < deadline) await wake();
        worker.terminate();
        return client.stopped;
    };
    return client;
}

/** Add an account and wait for its session to be up. */
export async function connect(client, jid, password, ms = 40_000) {
    client.send(['account', 'add', { acc: jid, password }]);
    if (!await client.event('account', 'Added', () => true, ms)) return null;
    client.send(['account', 'enable', { acc: jid }]);
    return client.event('conn', 'State', (a) => a.state === 'connected', ms);
}
