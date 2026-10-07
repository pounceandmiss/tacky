# tacky-wasm

The tacky backend built to WebAssembly, running in a Web Worker.

```sh
make wasm              # needs emcc on PATH   -> dist/wasm/
make DOCKER=1 wasm     # needs only docker    -> dist/wasm/
```

`dist/wasm/` is the whole deliverable: copy it onto a site and import from it.
Files locate each other relative to their own URL, and no bundler is needed.
It is also an unpublished npm package (`package.json`, `index.d.ts`);
`npm pack dist/wasm` makes the tarball.

```js
import { createClient } from './tacky/index.js';

const client = createClient();
await client.ready;

client.send(['account', 'add', { acc: 'me@example.com', password }]);
await client.event('conn', 'State', (a) => a.state === 'connected');
```

The protocol is the same JSON one the C library carries; see
[doc/DOC.md](../doc/DOC.md).

## What the page provides

- Transport: XMPP over WebSocket (RFC 7395). The endpoint is per account, see
  `websocket_url` in DOC.md.
- File transfers: the browser's HTTP stack.
- SQLite: a VFS over the Origin Private File System, or in memory when the
  page asks for a transient store.
- WebRTC: driven by `createMediaHost` in `src/media-host.js`, which reports the
  peer's media by call `sid`.
- TLS and image decoding.

The store belongs to one tab at a time: a client started while another tab
holds it fails with `fatalReason` `locked`.

## Tests

```sh
make wasm-test                                     # headless Chromium
tests/servers/with_prosody.sh make wasm-test       # plus the networked half
```

`tests/` is bundled into the wasm interpreter, so the browser build runs the
same suite as the native one. Tests needing a thread, a process or a listening
socket carry the `!wasm` constraint.
