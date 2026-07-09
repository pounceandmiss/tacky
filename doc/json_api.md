# JSON API

Non-Tcl frontends drive the taco backend over stdin/stdout using
length-prefixed JSON messages via `bin/tackyd-json.tcl`.

## Transport

Same length-prefixed protocol as the Tcl backend (lenpipe):

```
<char_count>\n<payload>
```

Read: `len = readline()`, then `data = read(len)`. Repeat.
Write: `write(str(len(payload)) + "\n" + payload)`. Flush.

## Requests (client → backend)

Requests are JSON arrays: module, method, a keyword-argument object,
and an optional token.

```json
["module", "method", {"arg1":"val1", ...}]
["module", "method", {"arg1":"val1", ...}, token]
```

Without a token, the request is fire-and-forget; the client only
receives broadcast events. With a token (any integer), the backend
sends a result or error reply keyed to that token.

The JSON API uses clean keys without Tcl's `-` prefix.

### Examples

```json
["account", "add",
  {"acc": "user@example.com", "password": "secret",
   "domain": "example.com", "username": "user"}]
["account", "list", {}, 1]
["roster", "get", {"acc": "user@example.com"}, 2]
```

## Events (backend → client)

Pushed whenever something happens in the backend. Not tied to a request.

```json
["event", "module", "<EventName>", {args}]
```

Example:
```json
["event", "account", "<Added>", {"acc": "user@example.com"}]
["event", "message", "<New>",
  {"acc": "user@example.com", "jid": "room@muc",
   "body": "hello",
   "message": {"timestamp": 1700000000,
               "body": "hello", "patch": false}}]
["event", "conn", "<State>",
  {"acc": "user@example.com", "state": "connected"}]
["event", "muc", "<Joined>",
  {"acc": "user@example.com",
   "jid": "room@muc", "nick": "me"}]
```

## Request/response (backend → client)

When a request includes a token, the backend replies with at most one
result or error message for that token (see the caveats below).

```json
["result", token, data]
["error", token, message]
```

```json
["result", 2, [{"jid": "alice@example.com", "name": "Alice"}]]
["error", 2, "Account doesn't exist: nobody@example.com"]
```

Tokens are one-shot; each token produces at most one reply.

Internally, the backend wires the token to both a `-command` and an
`-onerror` callback on the underlying taco method call. If the method
succeeds, `-command` fires and produces a `["result", …]` reply. If the
method fails, `-onerror` fires and produces an
`["error", token, message]` reply instead.

A token yields at most one reply: exactly one when the method runs
to a result or error, and none if request is cancelled or never completes for other reasons (e.g. unresponsive server).

Fire-and-forget requests (no token) have neither callback wired, so
any error from the underlying method is silently discarded.

Not every method uses the token contract. Action methods that report
progress through events - notably `message send` / `sendFile` / `resend` -
are event-acked, not token-acked: they emit `message <New>` on success
(even when the message is stored `server_status: failed`, e.g. an
undeliverable encryption) and report later delivery outcomes as `<Patch>`
field updates. A token on such a call gets no `result`/`error` reply. The
only unsignalled case is a hard failure before the `<New>` emit (e.g. a
malformed address); that propagates to the backend's error log.

## Attachments

Attachment semantics - sending, downloading, caching, thumbnails, the
`attachments` and `caption` message keys, `file <Update>` progress -
are documented in attachments.md and map onto the framing above like
everything else. The encoding, one example per direction:

```json
["message", "sendFile",
  {"acc": "user@example.com", "chat": "alice@example.com",
   "path": "/home/user/pic.png"}]
["file", "download",
  {"acc": "user@example.com",
   "url": "https://share.example.com/abc/pic.png"}, 7]
```

```json
["event", "file", "<Update>",
  {"acc": "user@example.com", "id": 1700000000,
   "direction": "download", "state": "done",
   "loaded": 20480, "total": 20480,
   "url": "https://share.example.com/abc/pic.png",
   "localpath": "/home/user/.cache/tacky/attachments/<hash>.png",
   "thumbpath": "/home/user/.cache/tacky/attachments/thumb/<hash>_320.png",
   "error": ""}]
```

A `download` request with a token additionally replies with the cached
file path ("" on failure).

## Launching

```sh
tclsh9.0 bin/tackyd-json.tcl
```

The backend reads JSON from stdin and writes JSON to stdout.
Pass taco_type constructor args on the command line:

```sh
tclsh9.0 bin/tackyd-json.tcl -transient 0
```

With `-transient 0`, accounts and messages persist to SQLite
on disk. Without it (the default), everything is in-memory.

Try it out in bash (see empty account list):

```sh
msg='["account", "list", {}, 1]'
printf '%d\n%s' ${#msg} "$msg" \
  | tclsh9.0 bin/tackyd-json.tcl; echo
```
