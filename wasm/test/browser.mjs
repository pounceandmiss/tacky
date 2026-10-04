/*
 * The smoke page (index.html) in headless Chromium, over http://127.0.0.1:
 *
 *   node wasm/test/browser.mjs [--scenario storage|session|call|tcl]
 *
 *   storage  the store survives a reload (the page is visited twice); no server
 *   session  an XMPP session over RFC 7395; needs with_prosody.sh
 *   call     two accounts, one call, media in the page; needs with_prosody.sh
 *   groupcall  three accounts, one hosted video call, one camera; needs with_prosody.sh
 *   tcl      tacky's Tcl suite inside the wasm interpreter
 */
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { serve } from './serve.mjs';
import { connect, launch } from './chromium.mjs';

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
    const at = argv.indexOf(`--${name}`);
    return at >= 0 ? argv[at + 1] : fallback;
};
const distDir = resolve(flag('dist', 'dist/wasm'));
const pageDir = resolve(flag('page', 'wasm/test'));
// Where `make wasm-tcltest` leaves the interpreter with tests/ in it.
const buildDir = resolve(flag('build', 'build/wasm'));

const scenario = flag('scenario', 'storage');
const DOMAIN = process.env.XMPP_DOMAIN ?? 'example.local';
const query = new URLSearchParams({ scenario });
// The tcl scenario's narrowing: one suite (taco, taco_integration), one file.
for (const name of ['dir', 'file', 'match']) {
    if (flag(name)) query.set(name, flag(name));
}
// The tcl scenario runs the integration suite too when it is given a server.
if (scenario !== 'storage' && (scenario !== 'tcl' || process.env.XMPP_SERVER)) {
    query.set('ws', flag('ws', process.env.XMPP_WS_URL
        ?? 'ws://127.0.0.1:5280/xmpp-websocket'));
    query.set('jid', flag('jid', `test@${DOMAIN}`));
    query.set('pass', flag('pass', 'testpass'));
    query.set('jid2', flag('jid2', `romeo@${DOMAIN}`));
    query.set('pass2', flag('pass2', 'romeopass'));
    query.set('jid3', flag('jid3', `juliet@${DOMAIN}`));
    query.set('pass3', flag('pass3', 'julietpass'));
    query.set('server', flag('server', process.env.XMPP_SERVER ?? ''));
}

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

// -- one visit -------------------------------------------------------------

async function visit(cdp, sessionId, url) {
    await cdp.send('Page.navigate', { url }, sessionId);
    const deadline = Date.now() + ({ tcl: 900_000, groupcall: 300_000 }[scenario] ?? 120_000);
    for (;;) {
        const { result } = await cdp.send('Runtime.evaluate', {
            expression: 'JSON.stringify(globalThis.__smoke ?? null)',
            returnByValue: true,
        }, sessionId);
        const smoke = result.value ? JSON.parse(result.value) : null;
        if (smoke?.done) {
            const { result: v } = await cdp.send('Runtime.evaluate', {
                expression: 'globalThis.__smokeVisit ?? ""',
                returnByValue: true,
            }, sessionId);
            const { result: suite } = await cdp.send('Runtime.evaluate', {
                expression: 'JSON.stringify(globalThis.__smokeSuite ?? null)',
                returnByValue: true,
            }, sessionId);
            return {
                ...smoke, visit: v.value,
                suite: suite.value ? JSON.parse(suite.value) : null,
            };
        }
        if (Date.now() > deadline) return null;
        await new Promise((r) => setTimeout(r, 250));
    }
}

// -- the run ---------------------------------------------------------------

const server = await serve([distDir, pageDir, buildDir]);
const url = `http://127.0.0.1:${server.address().port}/?${query}`;
const profile = await mkdtemp(join(tmpdir(), 'tacky-smoke-'));
const { child, endpoint } = await launch(profile);

const cdp = connect(endpoint);
await cdp.open;
cdp.on((msg) => {
    if (msg.method === 'Runtime.exceptionThrown') {
        const d = msg.params.exceptionDetails;
        console.log('   [page error]', d.exception?.description ?? d.text);
    } else if (msg.method === 'Log.entryAdded' && msg.params.entry.level !== 'verbose') {
        // The browser's own messages: blocked requests, CORS, network errors.
        console.log(`   [${msg.params.entry.source}]`, msg.params.entry.text, msg.params.entry.url ?? '');
    } else if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type !== 'debug') {
        console.log(`   [console.${msg.params.type}]`,
            msg.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
    }
});

try {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Log.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);

    console.log(`-- ${scenario} (${url}) --`);
    const first = await visit(cdp, sessionId, url);
    check('the page finished its run', first !== null, first ? '' : 'timed out');
    for (const c of first?.checks ?? []) check(c.name, c.ok, c.detail);

    if (first?.suite?.failures?.length) {
        console.log('failed in the browser:');
        for (const name of first.suite.failures) console.log(`  ${name}`);
    }

    if (scenario === 'storage') {
        check('it was the first visit to this origin', first?.visit === 'first', first?.visit);
        console.log('-- second visit, same profile: a reload --');
        const second = await visit(cdp, sessionId, url);
        check('the page finished its run again', second !== null, second ? '' : 'timed out');
        for (const c of second?.checks ?? []) check(c.name, c.ok, c.detail);
        check('the store was there the second time', second?.visit === 'second', second?.visit);
    }
} finally {
    cdp.close();
    child.kill();
    // Wait for Chromium to exit, or removing the profile fails with ENOTEMPTY.
    await new Promise((r) => child.once('exit', r));
    server.close();
    await rm(profile, { recursive: true, force: true }).catch(() => {});
}

process.exit(failures ? 1 : 0);
