/*
 * Static server for the browser tests, and for opening the smoke page by hand:
 *
 *   node wasm/test/serve.mjs [port] [dist-dir] [page-dir]
 *
 * Roots overlay as one directory. http, not file://: a module Worker and
 * OPFS need a real origin, and 127.0.0.1 is a secure context.
 *
 * Under /_t/, endpoints for tests/taco/test_httpreq.tcl:
 *   PUT /_t/echo/<name>     keep the body;  GET /_t/echo/<name>  return it
 *   GET /_t/status/<code>   answer with that status
 *   GET /_t/slow            answer after 3 s
 */
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, normalize } from 'node:path';

const TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
    '.css': 'text/css; charset=utf-8',
    '.map': 'application/json',
};

const echoed = new Map();

async function testRoute(req, res, path) {
    const [, , route, arg] = path.split('/');
    if (route === 'echo' && req.method === 'PUT') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        echoed.set(arg, Buffer.concat(chunks));
        res.writeHead(201).end();
    } else if (route === 'echo' && echoed.has(arg)) {
        res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(echoed.get(arg));
    } else if (route === 'status') {
        res.writeHead(Number(arg) || 500).end(`status ${arg}`);
    } else if (route === 'slow') {
        setTimeout(() => res.writeHead(200).end('slow'), 3000);
    } else {
        res.writeHead(404).end(`no ${path}`);
    }
}

/** Listen on `port` (0 for any) and resolve to the node server. */
export function serve(roots, port = 0, host = '127.0.0.1') {
    const server = createServer(async (req, res) => {
        const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
        if (path.startsWith('/_t/')) {
            await testRoute(req, res, path);
            return;
        }
        const name = path === '/' ? '/index.html' : path;
        if (name.includes('..')) {
            res.writeHead(403).end();
            return;
        }
        for (const root of roots) {
            try {
                const body = await readFile(join(root, name));
                const ext = name.slice(name.lastIndexOf('.'));
                res.writeHead(200, {
                    'content-type': TYPES[ext] ?? 'application/octet-stream',
                    // No SharedArrayBuffer, so no COOP/COEP needed.
                    'cache-control': 'no-store',
                }).end(body);
                return;
            } catch { /* try the next root */ }
        }
        res.writeHead(404).end(`no ${name}`);
    });
    return new Promise((ok) => server.listen(port, host, () => ok(server)));
}

if (import.meta.filename === process.argv[1]) {
    const [port = '8099', dist = 'dist/wasm', page = 'wasm/test'] = process.argv.slice(2);
    const server = await serve([dist, page], Number(port));
    const { address, port: p } = server.address();
    console.log(`tacky smoke page: http://${address}:${p}/  (ctrl-c to stop)`);
}
