/*
 * Tacky in a browser: the entry point of dist/wasm. Plain ES modules that
 * locate each other relative to their own URLs, so the directory can be
 * copied anywhere on an origin; no bundler. The surface is declared in
 * index.d.ts and versioned in package.json; the JSON protocol it carries is
 * doc/DOC.md.
 */
export { createClient, connect } from './client.js';
export { createMediaHost } from './media-host.js';
