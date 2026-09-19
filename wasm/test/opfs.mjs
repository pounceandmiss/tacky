/*
 * The store on the OPFS pool, across a simulated reload:
 *
 *   node wasm/test/opfs.mjs [dist/wasm/tacky.mjs] [zippy-dir]
 *
 * Pool first, VFS registered, then tacky_boot, as worker.js does. Node has no
 * OPFS, so the pool runs over zippy's tests/opfs-mock-dir.mjs; the second
 * half opens a fresh module and pool over the same files.
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const launcher = process.argv[2] ?? 'dist/wasm/tacky.mjs';
const zippyDir = process.argv[3] ?? 'zippy';

const { MockDirectory } = await import(
    pathToFileURL(resolve(zippyDir, 'tests/opfs-mock-dir.mjs')).href);
// The pool `make wasm` leaves beside tacky.mjs.
const { openOpfsPool } = await import(
    pathToFileURL(resolve(launcher, '../opfs-pool.js')).href);

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

const STORE = '/store';
const DIRS = `-config-dir ${STORE}/config -data-dir ${STORE}/data -cache-dir ${STORE}/cache`;

// One backend session over `dir`, in the worker's order; `stop()` drops the handles.
async function session(dir) {
    const messages = [];
    const waiters = [];
    const notes = [];
    const inbox = [];
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
    const pool = await openOpfsPool(dir, 16);
    const registered = M.ccall('opfsvfs_register', 'number', ['number'], [1]) === 0;

    if (M.ccall('tacky_boot', 'number', [], []) !== 0) {
        throw new Error(`tacky_boot: ${notes.at(-1)}`);
    }
    for (const d of [STORE, `${STORE}/config`, `${STORE}/data`, `${STORE}/cache`]) {
        try { M.FS.mkdir(d); } catch { /* already there */ }
    }
    if (M.ccall('tacky_start', 'number', ['string'],
            [`-transient 0 ${DIRS} -media-backend host`]) !== 0) {
        throw new Error(`tacky_start: ${notes.at(-1)}`);
    }
    const running = M.ccall('tacky_run', 'number', [], [], { async: true });

    const until = async (want, ms = 10_000) => {
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
    const request = (frame) => {
        const id = ++token;
        inbox.push(JSON.stringify([...frame, id]));
        return until((m) => (m[0] === 'result' || m[0] === 'error') && m[1] === id);
    };
    const send = (frame) => inbox.push(JSON.stringify(frame));
    const stop = async () => {
        globalThis.tackyStopRequested = true;
        const rc = await Promise.race([
            running, new Promise((r) => setTimeout(() => r('timeout'), 10_000))]);
        await pool.close_all();
        return rc;
    };
    return { pool, registered, request, send, until, stop, notes };
}

// -- first visit ----------------------------------------------------------

const dir = new MockDirectory();
let s = await session(dir);
check('the VFS registers before the backend boots', s.registered);
check('the backend came up on it', s.notes.some((n) => n.startsWith('ok started')));

s.send(['setting', 'set', { key: 'theme', value: 'dark' }]);
let r = await s.until((m) => m[0] === 'event' && m[1] === 'setting' && m[2] === 'Changed');
check('a setting is stored', r?.[3]?.value === 'dark', JSON.stringify(r));
r = await s.request(['setting', 'get', { key: 'theme' }]);
check('... and reads back', r?.[0] === 'result' && r[2] === 'dark', JSON.stringify(r));

check('accounts.db is a pooled file, not one in the memory filesystem',
    s.pool.exists(`${STORE}/config/accounts.db`), s.pool.list().join(' '));

check('the session stops cleanly', (await s.stop()) === 0);

// -- the reload: same files, new module and pool ----------------------------

s = await session(dir);
check('a second visit finds the database again', s.pool.exists(`${STORE}/config/accounts.db`),
    s.pool.list().join(' '));
r = await s.request(['setting', 'get', { key: 'theme' }]);
check('the setting survived the reload', r?.[0] === 'result' && r[2] === 'dark', JSON.stringify(r));
check('and this session stops cleanly too', (await s.stop()) === 0);

process.exit(failures ? 1 : 0);
