/*
 * Static server for the browser tests, and for opening the smoke page by hand:
 *
 *   node wasm/test/serve.mjs [port] [dist-dir] [page-dir]
 *
 * Roots overlay as one directory. http, not file://: a module Worker and
 * OPFS need a real origin, and 127.0.0.1 is a secure context.
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

/** Listen on `port` (0 for any) and resolve to the node server. */
export function serve(roots, port = 0, host = '127.0.0.1') {
    const server = createServer(async (req, res) => {
        const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
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
