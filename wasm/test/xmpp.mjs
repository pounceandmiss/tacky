/*
 * An XMPP session over RFC 7395 (wsframing.tcl + zippy's wschan.c) against
 * Prosody's mod_websocket, under node; browser.mjs runs the same in Chromium.
 *
 *   tests/servers/with_prosody.sh node wasm/test/xmpp.mjs
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const launcher = process.argv[2] ?? 'dist/wasm/tacky.mjs';
const WS_URL = process.env.XMPP_WS_URL ?? 'ws://127.0.0.1:5280/xmpp-websocket';
const DOMAIN = process.env.XMPP_DOMAIN ?? 'example.local';
const USER = process.env.XMPP_USER ?? 'test';
const PASS = process.env.XMPP_PASS ?? 'testpass';
const JID = `${USER}@${DOMAIN}`;
// Messaging our own bare JID: the server delivers it back to this resource.
const PEER = process.env.XMPP_PEER ?? JID;

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

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

async function until(want, ms = 20_000) {
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
let token = 0;
const send = (frame) => inbox.push(JSON.stringify(frame));
const request = (frame, ms) => {
    const id = ++token;
    send([...frame, id]);
    return until((m) => (m[0] === 'result' || m[0] === 'error') && m[1] === id, ms);
};
const event = (module, name, match = () => true, ms) =>
    until((m) => m[0] === 'event' && m[1] === module && m[2] === name && match(m[3]), ms);

const { default: createTacky } = await import(pathToFileURL(resolve(launcher)).href);
const M = await createTacky();

check('tacky_boot', M.ccall('tacky_boot', 'number', [], []) === 0, notes.at(-1));

// The test server is plain ws on its own port, so -ws-url is needed.
const args = `-transient 1 -media-backend host -transport websocket -ws-url ${WS_URL}`
    + (process.env.XMPP_DEBUG ? ' -debug-level debug' : '');
check('tacky_start on the websocket transport',
    M.ccall('tacky_start', 'number', ['string'], [args]) === 0, notes.at(-1));

const running = M.ccall('tacky_run', 'number', [], [], { async: true });

send(['account', 'add', { acc: JID, password: PASS }]);
check('the account is added', (await event('account', 'Added')) !== null);

send(['account', 'enable', { acc: JID }]);
let ev = await event('conn', 'State', (a) => a.state === 'connecting');
check('the connection starts', ev !== null, JSON.stringify(ev?.[3] ?? ev));

// <open/>, features, SASL, restart, bind, session/SM all happen over the WebSocket here.
ev = await event('conn', 'State', (a) => a.state === 'connected', 30_000);
check('SASL, the stream restart and bind all complete', ev !== null,
    JSON.stringify(ev?.[3] ?? messages.filter((m) => m[1] === 'conn').at(-1)));

if (ev !== null) {
    let r = await request(['roster', 'get', { acc: JID }]);
    check('an IQ round-trips through the server', r?.[0] === 'result',
        JSON.stringify(r)?.slice(0, 120));

    // OMEMO off: there is no second device to encrypt to.
    send(['omemo', 'setEnabled', { acc: JID, jid: PEER, value: 0 }]);
    check('encryption is off for this chat',
        (await event('omemo', 'Enabled', (a) => a.jid === PEER)) !== null);

    const body = `hello from wasm ${Date.now()}`;
    send(['message', 'send', { acc: JID, chat: PEER, body }]);
    const sent = await event('message', 'New', (a) =>
        (a?.message?.content?.body ?? '') === body);
    check('a message is sent', sent !== null, body);

    // The store matched the returning copy to the one it sent.
    const confirmed = await event('message', 'Confirmed', () => true, 15_000);
    check('the server sends it back, and it is matched to what was sent',
        confirmed !== null, JSON.stringify(confirmed?.[3] ?? ''));

    send(['account', 'disable', { acc: JID }]);
    ev = await event('conn', 'State', (a) => a.state === 'disconnected', 15_000);
    check('the stream closes cleanly', ev !== null, JSON.stringify(ev?.[3] ?? ''));
}

globalThis.tackyStopRequested = true;
const rc = await Promise.race([running, new Promise((r) => setTimeout(() => r('timeout'), 10_000))]);
check('the backend stops', rc === 0, String(rc));

// On failure, print the traffic.
if (failures || process.env.XMPP_DEBUG) {
    console.log('-- everything the backend said --');
    for (const m of messages) console.log('  ', JSON.stringify(m).slice(0, 300));
}

process.exit(failures ? 1 : 0);
