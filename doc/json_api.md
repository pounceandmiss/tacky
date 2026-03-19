# JSON API

Non-Tcl frontends drive the taco backend over stdin/stdout using
length-prefixed JSON messages via `json_backend/json_backend.tcl`.

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
["module", "method", {args}]
["module", "method", {args}, token]
```

Without a token, the request is fire-and-forget — the client only
receives broadcast events. With a token (any integer), the backend
sends a result or error reply keyed to that token.

Argument keys use the same `-` prefix as the Tcl API.

### Examples

```json
["account", "add", {"-acc": "user@example.com", "-password": "secret", "-domain": "example.com", "-username": "user"}]
["muc", "join", {"-acc": "user@example.com", "-jid": "room@muc.example.com", "-nick": "me"}]
["account", "list", {}, 1]
["roster", "get", {"-acc": "user@example.com"}, 2]
```

## Responses (backend → client)

### Broadcast events

Pushed whenever something happens in the backend. Not tied to a request.

```json
["event", "module", "<EventName>", {args}]
```

```json
["event", "account", "<Added>", {"-acc": "user@example.com"}]
["event", "message", "<Received>", {"-acc": "user@example.com", "-jid": "room@muc", "-body": "hello", "-message": {"-timestamp": 1700000000, "-body": "hello", "-hollow": false}}]
["event", "conn", "<State>", {"-acc": "user@example.com", "-state": "connected"}]
["event", "muc", "<Joined>", {"-acc": "user@example.com", "-jid": "room@muc", "-nick": "me"}]
```

### Request/response

When a request includes a token, the backend replies with exactly one
result or error message for that token.

```json
["result", token, data]
["error", token, message]
```

```json
["result", 2, [{"-jid": "alice@example.com", "-name": "Alice"}]]
["error", 2, "Account doesn't exist: nobody@example.com"]
```

Tokens are one-shot — each token produces at most one reply.

## Launching

```sh
tclsh9.0 json_backend/json_backend.tcl
```

The backend reads JSON from stdin and writes JSON to stdout.
Pass taco_type constructor args on the command line:

```sh
tclsh9.0 json_backend/json_backend.tcl -config-dir ~/.config/tacky -cache-dir ~/.cache/tacky -transient 0
```

With `-transient 0`, accounts and messages persist to SQLite on disk.
Without it (the default), everything is in-memory.
