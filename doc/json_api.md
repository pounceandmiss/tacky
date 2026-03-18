# JSON API

Non-Tcl frontends drive the taco backend over stdin/stdout using
length-prefixed JSON messages via `taco_json_backend.tcl`.

## Transport

Same length-prefixed protocol as the Tcl backend (lenpipe):

```
<byte_count>\n<payload>
```

Read: `len = readline()`, then `data = read(len)`. Repeat.
Write: `write(str(len(payload)) + "\n" + payload)`. Flush.

## Requests (client → backend)

Requests are JSON arrays. The first two elements are always the module
and method. The third is an object of keyword arguments. An optional
fourth element is a callback id.

```json
["module", "method", {args}]
["module", "method", {args}, id]
```

Argument keys omit the `-` prefix used in Tcl. The backend adds it
internally.

### Examples

Fire-and-forget (no response):

```json
["account", "add", {"acc": "user@example.com", "password": "secret", "domain": "example.com", "username": "user"}]
["muc", "join", {"acc": "user@example.com", "jid": "room@muc.example.com", "nick": "me"}]
```

With callback (response will carry the same id):

```json
["account", "list", {}, 1]
["message", "search", {"acc": "user@example.com", "chat": "room@muc.example.com", "query": "hello"}, 2]
["roster", "get", {"acc": "user@example.com"}, 3]
```

## Responses (backend → client)

All responses are JSON arrays. The first element is the type.

### Events

Pushed whenever something happens in the backend. Not tied to a request.

```json
["event", "module", "<EventName>", {args}]
```

Examples:

```json
["event", "account", "<Added>", {"acc": "user@example.com"}]
["event", "message", "<Received>", {"acc": "user@example.com", "jid": "room@muc", "body": "hello", "message": {"timestamp": 1700000000, "body": "hello", "hollow": false}}]
["event", "conn", "<State>", {"acc": "user@example.com", "state": "connected"}]
["event", "muc", "<Joined>", {"acc": "user@example.com", "jid": "room@muc", "nick": "me"}]
```

### Callback results

Sent in response to a request that included an id.

```json
["callback", id, result]
```

Examples:

```json
["callback", 1, []]
["callback", 2, {"messages": [{"timestamp": 1700000000, "body": "hello", "hollow": false}], "complete": true}]
["callback", 3, [{"jid": "alice@example.com", "name": "Alice", "approved": true, "groups": ["friends"]}]]
```

### Errors

Sent when a callback request fails.

```json
["error", id, "error message"]
```

Example:

```json
["error", 3, "Account doesn't exist: nobody@example.com"]
```

## Launching

```sh
tclsh9.0 taco_json_backend.tcl
```

The backend reads JSON from stdin and writes JSON to stdout.
Pass taco_type constructor args on the command line:

```sh
tclsh9.0 taco_json_backend.tcl -config-dir ~/.config/tacky -cache-dir ~/.cache/tacky -transient 0
```

With `-transient 0`, accounts and messages persist to SQLite on disk.
Without it (the default), everything is in-memory.
