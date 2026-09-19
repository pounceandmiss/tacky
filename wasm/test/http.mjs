/*
 * XEP-0363 up and down over the platform HTTP stack (zippy's httpx.c, chosen
 * by httpreq.tcl), against Prosody's mod_http_file_share; the bytes are
 * compared at the end.
 *
 *   tests/servers/with_prosody.sh node wasm/test/http.mjs
 *
 * node has no XMLHttpRequest, so httpx.c takes its fetch path here.
 */
import { reporter, startBackend, connect } from './harness.mjs';

const launcher = process.argv[2] ?? 'dist/wasm/tacky.mjs';
const WS_URL = process.env.XMPP_WS_URL ?? 'ws://127.0.0.1:5280/xmpp-websocket';
const DOMAIN = process.env.XMPP_DOMAIN ?? 'example.local';
const JID = `${process.env.XMPP_USER ?? 'test'}@${DOMAIN}`;
const PASS = process.env.XMPP_PASS ?? 'testpass';

const r = reporter();

const be = await startBackend(launcher,
    `-transient 1 -media-backend host -transport websocket -ws-url ${WS_URL}`
    + (process.env.XMPP_DEBUG ? ' -debug-level debug' : ''));

r.check('the session comes up', (await connect(be, JID, PASS)) !== null);

// A file in the interpreter's own filesystem.
const CONTENT = Buffer.from(
    `wasm http round trip ${Date.now()}\n` + 'x'.repeat(5000) + '\nend\n');
be.M.FS.mkdirTree?.('/tmp');
be.M.FS.writeFile('/tmp/upload.txt', CONTENT);
r.check('a file is staged in the filesystem',
    be.M.FS.readFile('/tmp/upload.txt').length === CONTENT.length);

// Slot, PUT, then the URL comes back; progress arrives as file <Update>.
be.send(['file', 'upload', { acc: JID, path: '/tmp/upload.txt' }]);
const uploaded = await be.event('file', 'Update',
    (a) => a.direction === 'upload' && a.state !== 'active', 30_000);
r.check('the upload finishes', uploaded?.[3]?.state === 'done',
    JSON.stringify(uploaded?.[3] ?? ''));

const url = uploaded?.[3]?.url ?? '';
r.check('the server gave back a URL to fetch it from',
    /^https?:\/\/[^/]+\/file_share\//.test(url), url);

if (url) {
    be.send(['file', 'download', { acc: JID, url }]);
    const got = await be.event('file', 'Update',
        (a) => a.direction === 'download' && a.state !== 'active', 30_000);
    r.check('the download finishes', got?.[3]?.state === 'done',
        JSON.stringify(got?.[3] ?? ''));

    const path = got?.[3]?.localpath ?? '';
    r.check('it landed somewhere', path !== '', path);
    if (path) {
        let back = null;
        try { back = Buffer.from(be.M.FS.readFile(path)); } catch (err) { back = null; }
        r.check('and it is byte for byte what went up',
            back !== null && back.equals(CONTENT),
            back === null ? 'unreadable' : `${back.length} of ${CONTENT.length} bytes`);
    }
}

r.check('the backend stops', (await be.stop()) === 0);
if (r.failures) be.dump();
process.exit(r.failures ? 1 : 0);
