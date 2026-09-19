/*
 * The backend in a Web Worker: moves messages between postMessage and the
 * globals embed/tacky_wasm.c reaches through, and picks where the store
 * lives. Parses nothing.
 *
 *   page -> worker  {type: 'configure', options}   first; nothing starts before it
 *                   {type: 'request', json}
 *                   {type: 'stop'}
 *   worker -> page  {type: 'storage', mode}        'opfs' | 'idbfs' | 'memory'
 *                   {type: 'ready'}
 *                   {type: 'message', json}
 *                   {type: 'fatal', message}       nothing follows
 *                   {type: 'stopped'}
 *
 * Options: ws, transient, store, debug (see index.d.ts).
 */

import createTacky from './tacky.mjs';
import { createOpfsPool } from './opfs-pool.js';

// Requests wait here; the pump in tacky_wasm.c drains it on Tcl's schedule.
const inbox = [];
globalThis.tackyInbox = inbox;
globalThis.tackyStopRequested = false;

globalThis.tackyOutbox = (json) => {
    postMessage({ type: 'message', json });
};

// The shim's progress lines; a FAIL line means the backend will not start.
globalThis.tackyReport = (line) => {
    if (line.startsWith('FAIL')) {
        postMessage({ type: 'fatal', message: line.slice(5) });
    } else {
        console.debug('[tacky]', line);
    }
};

// Set by the configure message.
let OPTIONS = {};
let STORE = '/store';
let configured;
const whenConfigured = new Promise((resolve) => { configured = resolve; });

self.addEventListener('message', (ev) => {
    const msg = ev.data;
    if (msg?.type === 'configure') {
        OPTIONS = msg.options ?? {};
        if (OPTIONS.store) {
            STORE = OPTIONS.store;
        }
        configured();
    } else if (msg?.type === 'request' && typeof msg.json === 'string') {
        inbox.push(msg.json);
    } else if (msg?.type === 'stop') {
        globalThis.tackyStopRequested = true;
    }
});

/*
 * Storage, tried in order:
 *   opfs    SQLite on the Origin Private File System (zippy's opfsvfs.c +
 *           opfs-pool.js); durable per commit, exclusive to one tab
 *   idbfs   Emscripten's IndexedDB filesystem, snapshotted every few seconds
 *           by tacky_persist
 *   memory  -transient 1; lasts as long as the tab
 */

// Quote one word of the Tcl list tacky_start takes apart.
function tclWord(value) {
    const s = String(value);
    if (s === '') return '{}';
    if (!/[\s\\{}"[\]$;]/.test(s)) return s;
    return s.replace(/[\s\\{}"[\]$;]/g, (c) =>
        c === '\n' ? '\\n' : c === '\t' ? '\\t' : `\\${c}`);
}

const PERSIST_SECONDS = 5;
const OPFS_DIR = 'tacky';
const OPFS_CAPACITY = 64;   // accounts.db + one db per account, each with a WAL

// Open the pool and register the VFS before tacky_boot opens any database.
// Failure (no OPFS, storage refused, another tab holding the handles) is
// ordinary: the caller falls through to IndexedDB.
let opfsPool = null;

async function registerOpfs(Module) {
    let pool;
    try {
        pool = await createOpfsPool({ directory: OPFS_DIR, capacity: OPFS_CAPACITY });
    } catch (err) {
        console.warn(`tacky: no OPFS store (${err.reason ?? 'failed'}):`, err.message);
        return false;
    }
    if (Module.ccall('opfsvfs_register', 'number', ['number'], [1]) !== 0) {
        console.warn('tacky: the OPFS pool is up but the VFS would not register');
        // Release the handles, or this store is locked to other tabs for nothing.
        await pool.close_all();
        return false;
    }
    opfsPool = pool;
    return true;
}

async function mountIdbfs(Module) {
    if (typeof indexedDB === 'undefined' || !Module.IDBFS) {
        return false;
    }
    try {
        Module.FS.mkdir(STORE);
        Module.FS.mount(Module.IDBFS, {}, STORE);
        // `true` reads IndexedDB into the filesystem; must finish before boot.
        await new Promise((resolve, reject) => {
            Module.FS.syncfs(true, (err) => (err ? reject(err) : resolve()));
        });
        return true;
    } catch (err) {
        console.warn('tacky: no IndexedDB store, this session is memory only:', err);
        return false;
    }
}

function makeStoreDirs(Module) {
    for (const dir of [STORE, `${STORE}/config`, `${STORE}/data`, `${STORE}/cache`]) {
        try {
            Module.FS.mkdir(dir);
        } catch {
            // already there
        }
    }
}

async function chooseStorage(Module) {
    if (OPTIONS.transient) {
        return 'memory';
    }
    if (await registerOpfs(Module)) {
        return 'opfs';
    }
    if (await mountIdbfs(Module)) {
        return 'idbfs';
    }
    return 'memory';
}

async function main() {
    await whenConfigured;
    const Module = await createTacky();
    const storage = await chooseStorage(Module);
    makeStoreDirs(Module);
    postMessage({ type: 'storage', mode: storage });

    if (Module.ccall('tacky_boot', 'number', [], []) !== 0) {
        return; // tackyReport has already said what went wrong
    }

    // host media (the page's RTCPeerConnection, media-host.js) and RFC 7395:
    // a page has neither an rtc stack nor a socket.
    const args = [
        ...(storage === 'memory'
            ? ['-transient', '1']
            : ['-transient', '0',
               '-config-dir', `${STORE}/config`,
               '-data-dir', `${STORE}/data`,
               '-cache-dir', `${STORE}/cache`]),
        '-media-backend', 'host',
        '-transport', 'websocket',
        ...(OPTIONS.ws ? ['-ws-url', OPTIONS.ws] : []),
        ...(OPTIONS.debug ? ['-debug-level', OPTIONS.debug] : []),
    ].map(tclWord).join(' ');
    if (Module.ccall('tacky_start', 'number', ['string'], [args]) !== 0) {
        return;
    }
    if (storage === 'idbfs') {
        Module.ccall('tacky_persist', 'number', ['number'], [PERSIST_SECONDS]);
    }

    // Ready last. The `account <Added>` events taco emits while starting were
    // already posted; the page listens before it starts the worker.
    postMessage({ type: 'ready' });

    // The event loop: Asyncify unwinds inside vwait, so this is async and
    // settles only when the page asks us to stop.
    await Module.ccall('tacky_run', 'number', [], [], { async: true });

    // Release the OPFS handles so the next tab (or a reload) can open the store.
    if (opfsPool) {
        await opfsPool.close_all();
        opfsPool = null;
    }
    postMessage({ type: 'stopped' });
}

main().catch((err) => {
    postMessage({ type: 'fatal', message: err instanceof Error ? err.message : String(err) });
});
