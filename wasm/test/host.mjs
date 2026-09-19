/*
 * The JSON protocol in and out of the wasm backend, under node:
 *
 *   node wasm/test/host.mjs [dist/wasm/tacky.mjs]
 *
 * The same globals worker.js installs, with postMessage replaced by a
 * function call: the pulled inbox, dispatch from a Tcl event, the emit sink,
 * and a bad request answered rather than fatal.
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const launcher = process.argv[2] ?? 'dist/wasm/tacky.mjs';

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

// The worker's side of the pipe.
const inbox = [];
globalThis.tackyInbox = inbox;
globalThis.tackyStopRequested = false;
const messages = [];
const waiters = [];
globalThis.tackyOutbox = (json) => {
    messages.push(JSON.parse(json));
    for (const w of waiters.splice(0)) w();
};
const notes = [];
globalThis.tackyReport = (line) => {
    notes.push(line);
    console.log('   [tacky]', line);
};

// Wait until `want` matches an arrived frame, or give up.
async function until(want, ms = 10_000) {
    const deadline = Date.now() + ms;
    for (let seen = 0; ; ) {
        for (; seen < messages.length; seen++) {
            if (want(messages[seen])) return messages[seen];
        }
        if (Date.now() > deadline) return null;
        await Promise.race([
            new Promise((r) => waiters.push(r)),
            new Promise((r) => setTimeout(r, 50)),
        ]);
    }
}
const send = (frame) => inbox.push(JSON.stringify(frame));
const reply = (token) => until((m) => (m[0] === 'result' || m[0] === 'error') && m[1] === token);

const { default: createTacky } = await import(pathToFileURL(resolve(launcher)).href);
const M = await createTacky();

check('tacky_boot', M.ccall('tacky_boot', 'number', [], []) === 0, notes.at(-1));
check('the interpreter is Tcl 9', notes.some((n) => /^ok boot 9\./.test(n)));

check('tacky_start', M.ccall('tacky_start', 'number', ['string'], ['-transient 1 -media-backend host']) === 0, notes.at(-1));

// A request queued before the loop runs must still be served.
send(['account', 'list', {}, 1]);

const running = M.ccall('tacky_run', 'number', [], [], { async: true });

let r = await reply(1);
check('account list answers', r?.[0] === 'result', JSON.stringify(r));
check('a fresh transient store has no accounts', Array.isArray(r?.[2]) && r[2].length === 0, JSON.stringify(r?.[2]));

send(['media', 'backend', {}, 2]);
r = await reply(2);
check('the media backend is host', r?.[0] === 'result' && r[2] === 'host', JSON.stringify(r));

send(['media', 'list', {}, 3]);
r = await reply(3);
check('and rtc is not in this build', r?.[0] === 'result' && !r[2].includes('rtc'), JSON.stringify(r));

send(['no_such_module', 'nope', {}, 4]);
r = await reply(4);
check('an unknown method is an error reply, not a dead worker', r?.[0] === 'error', JSON.stringify(r));

send('this is not json');
send(['account', 'list', {}, 5]);
r = await reply(5);
check('the request after a malformed one is still served', r?.[0] === 'result', JSON.stringify(r));

globalThis.tackyStopRequested = true;
const rc = await Promise.race([running, new Promise((res) => setTimeout(() => res('timeout'), 5000))]);
check('stop ends tacky_run', rc === 0, String(rc));
check('and it said so', notes.at(-1) === 'ok stopped', notes.at(-1));

process.exit(failures ? 1 : 0);
