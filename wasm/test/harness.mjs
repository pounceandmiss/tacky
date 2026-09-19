// Shared by the node tests: the globals embed/tacky_wasm.c reaches through
// (which worker.js wires to postMessage) wired to arrays and bounded waits.
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

export function reporter() {
    const state = { failures: 0 };
    state.check = (name, ok, detail = '') => {
        console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
        if (!ok) state.failures++;
        return ok;
    };
    return state;
}

/** Boot a backend and run its loop; `args` is tacky_start's argument line. */
export async function startBackend(launcher, args) {
    const inbox = [];
    const messages = [];
    const waiters = [];
    const notes = [];
    globalThis.tackyInbox = inbox;
    globalThis.tackyStopRequested = false;
    globalThis.tackyOutbox = (json) => {
        messages.push(JSON.parse(json));
        for (const w of waiters.splice(0)) w();
    };
    globalThis.tackyReport = (line) => {
        notes.push(line);
        console.log('   [tacky]', line);
    };

    const { default: createTacky } = await import(pathToFileURL(resolve(launcher)).href);
    const M = await createTacky();
    if (M.ccall('tacky_boot', 'number', [], []) !== 0) {
        throw new Error(`tacky_boot: ${notes.at(-1)}`);
    }
    if (M.ccall('tacky_start', 'number', ['string'], [args]) !== 0) {
        throw new Error(`tacky_start: ${notes.at(-1)}`);
    }
    const running = M.ccall('tacky_run', 'number', [], [], { async: true });

    const until = async (want, ms = 20_000) => {
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
    };
    let token = 0;
    const send = (frame) => inbox.push(JSON.stringify(frame));
    return {
        M, messages, notes, until, send,
        /** A framed request with a token, awaiting its result or error. */
        request(frame, ms) {
            const id = ++token;
            send([...frame, id]);
            return until((m) => (m[0] === 'result' || m[0] === 'error') && m[1] === id, ms);
        },
        /** The next broadcast of this module and name that `match` accepts. */
        event(module, name, match = () => true, ms) {
            return until((m) => m[0] === 'event' && m[1] === module
                && m[2] === name && match(m[3]), ms);
        },
        async stop(ms = 10_000) {
            globalThis.tackyStopRequested = true;
            return Promise.race([running,
                new Promise((r) => setTimeout(() => r('timeout'), ms))]);
        },
        dump() {
            console.log('-- everything the backend said --');
            for (const m of messages) console.log('  ', JSON.stringify(m).slice(0, 300));
        },
    };
}

/** Connect an account and wait for the session to be up. */
export async function connect(be, jid, password, ms = 30_000) {
    be.send(['account', 'add', { acc: jid, password }]);
    if (!await be.event('account', 'Added')) return null;
    be.send(['account', 'enable', { acc: jid }]);
    return be.event('conn', 'State', (a) => a.state === 'connected', ms);
}
