// Headless Chromium over the DevTools protocol, through node's own WebSocket.
// wacky's smoke test carries a copy.
import { spawn } from 'node:child_process';

const CHROME = process.env.CHROMIUM ?? 'chromium';

export async function launch(profile) {
    const child = spawn(CHROME, [
        '--headless=new',
        '--remote-debugging-port=0',
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--disable-extensions',
        // A call needs a mic; the fake device is a generated tone.
        '--use-fake-device-for-media-stream',
        '--use-fake-ui-for-media-stream',
        '--autoplay-policy=no-user-gesture-required',
        'about:blank',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });

    // Chromium prints its DevTools endpoint on stderr once it is listening.
    const endpoint = await new Promise((ok, fail) => {
        let buf = '';
        const timer = setTimeout(() => fail(new Error(`no DevTools endpoint:\n${buf}`)), 30_000);
        child.stderr.on('data', (d) => {
            buf += d;
            const m = buf.match(/ws:\/\/[^\s]+/);
            if (m) { clearTimeout(timer); ok(m[0]); }
        });
        child.on('exit', (code) => {
            clearTimeout(timer);
            fail(new Error(`${CHROME} exited with ${code}:\n${buf}`));
        });
    });
    return { child, endpoint };
}

// The slice of CDP this needs.
export function connect(url) {
    const ws = new WebSocket(url);
    const pending = new Map();
    const listeners = [];
    let seq = 0;
    ws.addEventListener('message', (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.id !== undefined) {
            const p = pending.get(msg.id);
            pending.delete(msg.id);
            if (p) msg.error ? p.fail(new Error(JSON.stringify(msg.error))) : p.ok(msg.result);
        } else {
            for (const l of listeners) l(msg);
        }
    });
    const open = new Promise((ok, fail) => {
        ws.addEventListener('open', ok, { once: true });
        ws.addEventListener('error', () => fail(new Error(`cannot reach ${url}`)), { once: true });
    });
    return {
        open,
        on: (fn) => listeners.push(fn),
        close: () => ws.close(),
        send(method, params = {}, sessionId) {
            const id = ++seq;
            return new Promise((ok, fail) => {
                pending.set(id, { ok, fail });
                ws.send(JSON.stringify({ id, method, params, sessionId }));
            });
        },
    };
}
