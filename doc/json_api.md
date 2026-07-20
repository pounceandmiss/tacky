# JSON API

Non-Tcl frontends drive the backend with JSON messages. Two ways
to host it: a C library or a subprocess stdin/stdout with length-prefixes.

Only three things go over the wire: requests, replies, and events.
The frontend sends requests to the backend; the backend optionally
sends replies and pushes events.

## Requests (frontend to backend)

Requests are JSON arrays: module, method, a keyword-argument object,
and an optional token. Keys are clean, without Tcl's `-` prefix.

```json
["module", "method", {"arg1":"val1", ...}]
["module", "method", {"arg1":"val1", ...}, token]
```

The token (any integer) asks for a reply keyed to it (see Replies).
Without one the request is fire-and-forget: no reply, and any error
from the method is silently discarded.

```json
["account", "add",
  {"acc": "user@example.com", "password": "secret",
   "domain": "example.com", "username": "user"}]
["account", "list", {}, 1]
["roster", "get", {"acc": "user@example.com"}, 2]
```

## Events (backend to frontend)

Pushed whenever something happens in the backend. Not tied to a request.

```json
["event", "module", "<EventName>", {args}]
```

Examples:
```json
["event", "account", "<Added>", {"acc": "user@example.com"}]
["event", "message", "<New>",
  {"acc": "user@example.com", "jid": "room@muc",
   "body": "hello",
   "message": {"timestamp": 1700000000,
               "body": "hello", "patch": false}}]
```

## Replies (backend to frontend)

A tokened request gets at most one reply: a result if the method
succeeds, an error if it fails, and none if it never completes
(cancelled, unresponsive server).

```json
["result", token, data]
["error", token, message]
```

```json
["result", 2, [{"jid": "alice@example.com", "name": "Alice"}]]
["error", 2, "Account doesn't exist: nobody@example.com"]
```

Not all methods reply. E.g. `message send` won't reply even if called with a token - the effect is instead observed through the normal event stream.

## Subprocess mode

```sh
tclsh9.0 bin/tackyd-json.tcl
```

The backend reads JSON from stdin and writes JSON to stdout, each
message length-prefixed:

```
<byte_count>\n<payload>
```

The payload is UTF-8.

Read: `len = readline()`, then `data = read(len)`, then decode UTF-8. Repeat.
Write: `body = payload.encode("utf-8")`, then
`write(str(len(body)) + "\n" + body)`. Flush.

Try it out in bash (see empty account list):

```sh
msg='["account", "list", {}, 1]'
printf '%d\n%s' ${#msg} "$msg" \
  | tclsh9.0 bin/tackyd-json.tcl; echo
```

## C library mode

`make lib` builds `dist/libtacky.a` (and `make win-lib` cross-compiles the
MinGW `dist/libtacky-win.a`). The ABI is `embed/tacky.h`:

```c
tacky *tacky_create(const char *const *taco_args,
                    tacky_emit_fn emit, void *ud);
void tacky_send(tacky *t, const char *json, size_t len);
void tacky_destroy(tacky *t);
```

`tacky_create` starts the backend on a dedicated thread and blocks
until it is ready. `taco_args` is a NULL-terminated array of taco_type
constructor args (e.g. `"-transient", "0"`), or NULL. Each
`tacky_send` carries one complete JSON request; each emit callback
delivers one complete JSON reply or event. No length prefixes -
message boundaries are the call boundaries.

Threading: `tacky_send` is safe from any thread and returns
immediately. The emit callback fires on the backend thread - copy the
bytes out (they are invalid after the callback returns), hand them to
your own loop, and return promptly; do not block or re-enter tacky
from inside it. `tests/lib_driver.c` is a minimal complete host
(`make test-lib` builds and runs it against the library).
