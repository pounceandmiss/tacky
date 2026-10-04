/*
 * The backend in a Web Worker: opens the store, creates the module, and moves
 * messages between postMessage and the functions bin/tacky-web.tcl calls
 * through ::em::call. Parses nothing.
 *
 *   page -> worker  {type: 'configure', options}   first; nothing starts before it
 *                   {type: 'request', json}
 *                   {type: 'stop'}
 *   worker -> page  {type: 'storage', mode}        'opfs' | 'memory'
 *                   {type: 'ready'}
 *                   {type: 'message', json}
 *                   {type: 'fatal', message, reason?}
 *                                                  nothing follows; `reason`
 *                                                  when there is no store:
 *                                                  'unsupported' | 'refused'
 *                                                  | 'locked'
 *                   {type: 'stopped'}
 *
 * Options: transient, store, debug (see index.d.ts).
 *
 * The store is SQLite on the Origin Private File System (zippy's opfsvfs.c
 * over opfs-pool.js), durable per commit and exclusive to one tab, or memory
 * when the page asks for `transient`. Never one standing in for the other: no
 * OPFS, OPFS refused, or the store held by another tab is fatal, with the
 * pool's reason. An empty client in place of the real one would also publish
 * a new OMEMO device on every load; running without a store is the page's to
 * offer.
 */

import createTacky from './tacky.mjs';
import { createOpfsPool } from './opfs-pool.js';

const OPFS_DIR = 'tacky';
const OPFS_CAPACITY = 64;   // accounts.db + one db per account, each with a WAL

let configured;
const whenConfigured = new Promise((resolve) => { configured = resolve; });

// Requests that came before the backend was serving, and the open
// tackyServe call once it is: its progress delivers a request, its
// resolution is the stop.
const early = [];
let serving = null;
let stopRequested = false;

self.addEventListener('message', (ev) => {
    const msg = ev.data;
    if (msg?.type === 'configure') {
        configured(msg.options ?? {});
    } else if (msg?.type === 'request' && typeof msg.json === 'string') {
        if (serving) serving.ctx.progress('request', msg.json);
        else early.push(msg.json);
    } else if (msg?.type === 'stop') {
        if (serving) serving.stop();
        else stopRequested = true;
    }
});

// Nothing follows a fatal. Going away also releases whatever OPFS handles
// are held, so the tab that owns the store is not locked out by this one.
function fatal(message, reason) {
    postMessage({ type: 'fatal', message, ...(reason ? { reason } : {}) });
    close();
}

async function main() {
    const options = await whenConfigured;
    // Before the module: zippy's launcher makes the pool SQLite's default VFS
    // when it boots. Throws an OpfsPoolError carrying the reason.
    const pool = options.transient ? null
        : await createOpfsPool({ directory: OPFS_DIR, capacity: OPFS_CAPACITY });
    postMessage({ type: 'storage', mode: pool ? 'opfs' : 'memory' });

    await createTacky({
        env: {
            TACKY_TRANSIENT: pool ? '0' : '1',
            TACKY_STORE: options.store ?? '/store',
            TACKY_DEBUG: options.debug ?? '',
        },
        zippyCalls: {
            tackyPost: (json) => postMessage({ type: 'message', json }),
            tackyServe: (ctx) => new Promise((stop) => {
                serving = { ctx, stop };
                // Ready last: the `account <Added>` events taco emitted while
                // starting were already posted.
                postMessage({ type: 'ready' });
                for (const json of early.splice(0)) ctx.progress('request', json);
                if (stopRequested) stop();
            }),
            tackyStopped: async () => {
                // Release the handles so the next tab (or a reload) can open the store.
                await pool?.close_all();
                postMessage({ type: 'stopped' });
            },
            tackyFatal: (message) => fatal(message),
        },
    });
}

main().catch((err) => fatal(err instanceof Error ? err.message : String(err), err?.reason));
