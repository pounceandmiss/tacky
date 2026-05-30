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
["event", "message", "<Received>",
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

When a request includes a token, the backend replies with exactly one
result or error message for that token.

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
Either way, exactly one reply is sent per token.

Fire-and-forget requests (no token) have neither callback wired, so
any error from the underlying method is silently discarded.

## Attachments (XEP-0363 HTTP File Upload)

Attachments build on the request and event framing above: two
file-specific requests, an `attachments` array on message objects, and a
single transfer-progress event.

### Sending a file

Share a local file: the backend discovers the server's upload service,
PUTs the file, and sends a message whose body is the public URL plus an
XEP-0066 Out-of-Band `<x>`. Fire-and-forget; the optimistic message
appears as a `<Sent>` event immediately, and transfer progress arrives
as `file <Update>` events.

```json
["message", "sendFile",
  {"acc": "user@example.com", "chat_jid": "alice@example.com",
   "path": "/home/user/pic.png"}]
```

### Downloading and caching

Fetch (and cache) an attachment for display; for an image this also
derives a thumbnail. Progress/result arrive as `file <Update>`; an
optional token additionally returns the cached full-file path ("" on
failure):

```json
["file", "download",
  {"acc": "user@example.com",
   "url": "https://share.example.com/abc/pic.png"}, 7]
```

Other file verbs: `file uncache {url}` deletes the cached copy and its
thumbnails; `file cancel {id}` or `{url}` aborts an in-flight transfer.

### The `attachments` array

Messages with attachments carry an `attachments` array on the `message`
object. Each entry has `url`, `type` (`image` or `file`), `name`,
`size`, and `mime`; `type=image` entries are meant to render inline.

Such messages also carry `caption`: the human text to render alongside
the attachments. XEP-0066 senders duplicate the share URL into `body`
so OOB-unaware clients still see something, so `caption` is `body` with
a redundant attachment URL removed (empty when the body was only the
URL, kept verbatim when there is real text). Render `caption` if
present, else `body`.

```json
["event", "message", "<Sent>",
  {"acc": "user@example.com", "jid": "alice@example.com",
   "message": {"timestamp": 1700000000,
               "body": "https://share.example.com/abc/pic.png",
               "caption": "",
               "patch": false,
               "attachments": [
                 {"url": "https://share.example.com/abc/pic.png",
                  "type": "image", "name": "pic.png",
                  "size": 20480, "mime": "image/png"}]}}]
```

### Transfer progress (`file <Update>`)

File transfers (upload and download) report progress and completion
through a single `file <Update>` event keyed by `id`. For an outgoing
attachment `id` is the message's timestamp; for a download, correlate by
`url`. `direction` is `upload` | `download`; `state` is `active` | `done`
| `failed`. On a completed image download `thumbpath` is the inline
thumbnail and `localpath` the full file; on failure `error` explains why
(no upload service, file too large, network/PUT failure):

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
