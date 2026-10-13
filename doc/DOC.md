# Tacky backend API

The tacky backend is a headless XMPP client. You drive it with requests
and get back replies and events.

## Contents

- [Using the backend](#using-the-backend)
  - [Ways to run it](#ways-to-run-it)
    - [JSON subprocess](#json-subprocess)
    - [C library](#c-library)
    - [Tcl command](#tcl-command)
  - [Storage layout](#storage-layout)
  - [Requests, replies, events](#requests-replies-events)
- [Reference](#reference)
  - [account](#account)
  - [register](#register)
  - [conn](#conn)
  - [app](#app)
  - [setting](#setting)
  - [storage](#storage)
  - [chatlist](#chatlist)
  - [chat](#chat)
  - [bookmarks](#bookmarks)
  - [roster](#roster)
  - [blocking](#blocking)
  - [presence](#presence)
  - [caps](#caps)
  - [message](#message)
  - [muc](#muc)
  - [notify](#notify)
  - [mam](#mam)
  - [omemo](#omemo)
  - [avatar](#avatar)
  - [nick](#nick)
  - [author](#author)
  - [file](#file)
  - [calls](#calls)
  - [groupcall](#groupcall)
  - [media](#media)
  - [audio](#audio)
  - [video](#video)
  - [debugtap](#debugtap)
  - [log](#log)
  - [error](#error)
- [Guides](#guides)
  - [Accounts and sign-in](#accounts-and-sign-in)
  - [The chat list](#the-chat-list)
  - [The chat window](#the-chat-window)
  - [Read state and alerts](#read-state-and-alerts)
  - [Attachments](#attachments)
  - [OMEMO](#omemo-1)
  - [Voice and video calls](#voice-and-video-calls)
  - [Group calls](#group-calls)

# Using the backend

## Ways to run it

Three ways to run the backend. All of them speak the same requests and
events, so the rest of this doc applies whichever you pick.

### JSON subprocess

`tclsh9.0 bin/tackyd-json.tcl` reads JSON from stdin and writes JSON to
stdout, each message length-prefixed:

    <byte_count>\n<payload>

The payload is UTF-8. Read: `len = readline()`, `data = read(len)`, decode
UTF-8; repeat. Write: `body = payload.encode("utf-8")`, then
`write(str(len(body)) + "\n" + body)`; flush.

    msg='["account", "list", {}, 1]'
    printf '%d\n%s' ${#msg} "$msg" | tclsh9.0 bin/tackyd-json.tcl; echo

### C library

`make lib` builds a static library (the README lists the per-platform
targets). Everything is merged into one archive, so link order doesn't
matter; it contains C++, so link the host app with `g++`. The ABI is
`embed/tacky.h`:

    tacky *tacky_create(const char *const *backend_args, tacky_emit_fn emit, void *ud);
    void tacky_send(tacky *t, const char *json, size_t len);
    void tacky_destroy(tacky *t);

- `tacky_create` starts the backend on its own thread and returns right away.
  `backend_args` is a NULL-terminated array of backend constructor options
  (e.g. `"-transient", "0"`), or NULL. The backend defaults to `-transient 1`
  however it is run, so an app that keeps its data passes `"-transient", "0"`.
  Pass `-config-dir`, `-data-dir` and `-cache-dir` to override the defaults in
  [Storage layout](#storage-layout), and `-transport websocket` to have every
  account dial over WebSocket (RFC 7395, see `websocket_url` in
  [account](#account)) instead of TCP, as the browser build does.
  It also takes `-debug-level` and `-debug-file` from [log](#log) - without a
  file the backend logs to the host's stderr, which a service process usually
  discards.
- `tacky_send` carries one complete JSON request; each emit callback delivers
  one complete JSON reply or event.
- Threading: `tacky_send` is callable from any thread. The emit callback fires
  on the backend thread - copy the bytes out before returning (they're invalid
  afterward), hand them to your own loop, don't block.
- Startup failure: the backend emits
  `["event","backend","Dead",{"error":"..."}]` and goes dead - no replies
  arrive, and the handle still has to be destroyed.

`tests/lib_driver.c` is a minimal host (`make test-lib`).

### Tcl command

The `tacky` command runs the backend in the same or a separate thread/process
transparently. Keyword args only; `-command` and `-onerror` are command
prefixes run on the result and on an error, `-tag` groups calls so they can
be cancelled together:

    tacky module method ?...args? ?-tag $tag? ?-command $cb? ?-onerror $ecb?

A call with `-command` or `-onerror` is answered on a later turn of the event
loop, whichever way the backend runs - in the same thread too, where it waits
in a queue as it would in a pipe. A call with neither runs at once; in the same
thread it returns the method's value, which is handy in scripts and tests.

The two transports line up directly:

    JSON                                Tcl
    ["mod","method",{"k":"v"}]          tacky mod method -k v
    ...with a token for a reply         ...-command $cb ?-onerror $ecb?
    ["result", token, data]             $cb data
    ["error", token, message]           $ecb message
    ["event","mod","E",{...}]           a fired listen/observe callback

Tcl keys take a `-` and event names take `<>` (Tk binding style); the JSON
wire carries both bare, in both directions. Values match either way except
binary ones: JSON carries them base64, Tcl carries raw bytes. An error goes
to `-onerror`, or to an `error <MethodError>` event if only `-command` was
given, or is re-thrown if neither was. On top of the raw firehose the binding
adds frontend-side sugar - `tacky listen` / `observe` / `unlisten`, filtered
callbacks under a cancellable tag.

## Storage layout

Three roots, set with `-config-dir`, `-data-dir` and `-cache-dir`; with
`-transient 0` each falls back to a platform default. All three are created
mode 0700 on platforms with file modes. The XDG variables below fall back to
`~/.config`, `~/.local/share` and `~/.cache`; other Unixes use the Linux
column, except Haiku, which keeps config and data in `~/config/settings/tacky`
and cache in `~/config/cache/tacky`.

|        | Linux                    | macOS                                 | Windows                      |
| ------ | ------------------------ | ------------------------------------- | ---------------------------- |
| config | `$XDG_CONFIG_HOME/tacky` | `~/Library/Application Support/tacky` | `%APPDATA%\tacky`            |
| data   | `$XDG_DATA_HOME/tacky`   | `~/Library/Application Support/tacky` | `%LOCALAPPDATA%\tacky\data`  |
| cache  | `$XDG_CACHE_HOME/tacky`  | `~/Library/Caches/tacky`              | `%LOCALAPPDATA%\tacky\cache` |

config holds `accounts.db`. data holds one `<jid>.db` per account - its state
and message history with downloaded attachments. cache holds only what can
be regenerated: upload staging, video frame streams, the log file
`log setenabled` picks, and decrypted scratch copies of attachments where
`/dev/shm` isn't available.

`-transient 1`, the default, keeps the per-account databases in RAM, and
`accounts.db` too unless `-config-dir` is given. With no `-data-dir` or
`-cache-dir`, those go to a temporary directory that is removed on shutdown;
platform defaults are never used.

Local storage can be encrypted (see [storage](#storage)) - off by default.
When it is, every db above is SQLCipher-encrypted with the same passphrase.
Attachments are handled differently: only ones fetched over OMEMO media
sharing (XEP-0454, `aesgcm://`) are ever encrypted at rest, with the key
recorded in the owning account's db - one downloaded while encryption is on
is kept as its OMEMO ciphertext, and one already on disk when it is turned on
is encrypted under a fresh key. A plain (non-OMEMO) attachment is never
encrypted at rest, in either mode.
Cache stays unencrypted, since everything in it is regenerable.
`-transient yes` skips all of this - nothing persists to touch.

## Requests, replies, events

A request is a JSON array: a module, a method, an object of keyword
arguments, and an optional token.

    ["module", "method", {"arg1": "val1", ...}]
    ["module", "method", {"arg1": "val1", ...}, token]

The token (any integer) asks for a reply tagged with that same token.
Leave it off and the request is fire-and-forget: no reply, and an error it
raises at once (a bad argument, say) arrives as an
[`error <Background>`](#error) event. Argument values go through untouched - the backend is untyped,
so `5` and `"5"` mean the same thing on the way in. The exceptions are
arguments typed `base64`, decoded to bytes before dispatch, and `bool`, where
`true`/`false`, `1`/`0` and their string forms all work. A bad value of
either comes back as an error reply.

    ["account", "add", {"acc": "user@example.com", "password": "secret"}]
    ["account", "list", {}, 1]

A request with a token gets exactly one reply: a result if it worked, an
error if it didn't. A method shown here without `->` replies `""` once it
has done its part - which for most of them is to start something whose
outcome arrives as events. A request cancelled through its module's `cancel`
(`message`, `avatar`, `file`) is answered with the error `cancelled`, and
disabling or removing an account answers the requests still waiting on it
with an error.

A request that needs the server waits for one minute of connected time
before giving up with an error. The clock stops while the account is
offline and starts a fresh minute on reconnect, so a request left pending
across a disconnect still completes then.

    ["result", token, data]
    ["error", token, message]

    ["result", 1, ["alice@example.com", "bob@example.com"]]
    ["error", 1, "Account doesn't exist: nobody@example.com"]

Events get pushed whenever something happens; they aren't tied to a
request.

    ["event", "module", "EventName", {payload}]
    ["event", "message", "New",
      {"acc": "me@host", "jid": "peer@host",
       "message": {"timestamp": 1700000000, "is_outgoing": false,
                   "content": {"type": "text", "body": "hi"}}}]

Event subscription and filtering is up to the frontend. Per-account events
carry an `acc` - you'll almost always want to filter based on that. When
you want the current state instead of waiting for the next change, call a
getter or the module's `pull` method - `pull` re-fires the relevant event
with the value as it stands now.

    ["module", "pull", {"event": "EventName", ...args}]
    ["omemo", "pull", {"event": "TrustList", "acc": "me@host", "jid": "peer@host"}]

In the json api, `pull` names its event bare. Only the events marked
`pullable` in the reference below accept it; anything else errors. The
remaining arguments are whatever the event is keyed on - `acc` for any
per-account module, plus `jid` for the per-chat events, or `key` for
`setting`.

# Reference

Event names are written `<LikeThis>` throughout, to set them apart from
methods at a glance - `account list` is a method, `account <Added>` is an
event. The brackets are notation, not part of the name: on the JSON wire
every event name is bare, both in an `["event", ...]` message and as a
`pull` argument. The Tcl binding does use the bracketed form literally.

`account`, `register`, `app`, `setting`, `storage`, `media`, `audio`,
`video`, `debugtap` and `log` are global. Every other module is per-account: each of its methods
takes `acc`, the account's bare JID, which most signatures below leave out.

## account

    account list {enabled?: bool}                   -> [string]   account bare JIDs
    account exists {acc: string}                    -> bool
    account get {acc: string, field?: string}       -> account_fields  (or one field's value)
    account add {acc: string, password?: string, username?: string, domain?: string,
                 host?: string, port?: int, tls?: string, srv?: bool,
                 websocket_url?: string, proxy?: string, enabled?: bool}
    account set {acc: string, password?: string, username?: string, domain?: string,
                 host?: string, port?: int, tls?: string, srv?: bool,
                 websocket_url?: string, proxy?: string, enabled?: bool}
    account remove {acc: string}
    account enable {acc: string}
    account disable {acc: string}
    account changePassword {acc: string, password: string}   -> ""

    account_fields = {jid: string, username: string, domain: string, host: string,
                      port: int, tls: string, srv: bool, password: string,
                      resource: string, enabled: bool, websocket_url: string,
                      proxy: string}

`add` creates or updates. On create, `username` and `domain` default to the
pieces of the JID. `enable` saves the flag and connects; on an enabled
account that is offline it is also how to reconnect. `disable` saves it and
ends everything the account had going (see "Ending an account's activity"
below); the account stays, offline (see "A disabled account" below).
`remove` ends everything too, then
deletes the account row and its per-account database. Downloaded attachments
are shared across accounts and are left alone. `set` with `password` changes
only the stored password Tacky logs in with: a running client takes it at
once, and an enabled account that is offline (after an auth error, say)
connects again with it; an online one keeps its session. `changePassword`
changes the password on the server (XEP-0077) and, if that works, updates
the stored one - the reply is `""` on success or an `["error", ...]`.
`enabled` on `add` or `set` does what `enable` or `disable` does. See
[Accounts and sign-in](#accounts-and-sign-in).

`resource` is the account's XMPP resource, `tacky.<hex>`, made on first use and
kept across reconnects; the backend picks a new one by itself when the server
reports a resource conflict at bind.

The connection fields. `host`, `port`, `tls` and `srv` apply on the tcp
transport, `websocket_url` on the websocket one:

- `domain`: the XMPP domain; the server's certificate must name it.
- `host` (default `""`): a DNS name or IP address to dial instead.
- `port` (default 0): 0 means 5222, or 5223 with `tls` `direct`.
- `tls` (default `auto`): `starttls`, `direct` (XEP-0368, ALPN
  `xmpp-client`), or `none`, which sends the password and messages
  unencrypted. `auto` is STARTTLS unless an SRV record says direct.
- `srv` (default true): with no `host` and no `port`, try the
  `_xmpps-client._tcp` and `_xmpp-client._tcp` records for `domain` in
  RFC 2782 order, then `domain` on 5222. SRV needs a nameserver in
  `/etc/resolv.conf` (the registry on Windows), so Android skips it.
- `websocket_url` (default `""`): `ws://` or `wss://`. Empty, it is
  discovered: the `urn:xmpp:alt-connections:websocket` link in
  `https://<domain>/.well-known/host-meta` (XEP-0156), else
  `wss://<domain>/xmpp-websocket`.

Setting `domain`, `host`, `port`, `tls`, `srv` or `websocket_url` reconnects
an enabled account that is offline, as `password` does; an online one uses them
next time. Changing `proxy` ends everything the account had going, online or
not, as `disable` does, with reason `proxy changed` (see "Ending an account's
activity" below); an enabled account then connects again on the new route,
in a new session.

`proxy` (default `""`) is a SOCKS5 proxy,
`socks5://[user:pass@]host:port` (an IPv6 `host` in brackets), that carries
every connection the account makes: the XMPP link, and HTTP uploads and
downloads. A malformed value is refused.
With a proxy set:
- No SRV query is sent, and the account dials `host` (or `domain`) on `port` (or the `tls` default).
- Attempts to place a call fail with `error <MethodError>` or `<StartFailed>`. An incoming call is declined without ringing.
- The websocket transport refuses work.

Events:

    account <Added>    {acc: string}
    account <Enabled>  {acc: string}
    account <Disabled> {acc: string}
    account <Removed>  {acc: string}

`<Added>` fires for a new account, and for every stored account once at
startup (after an unlock, when storage is encrypted), so a frontend can build
its account list from the events alone. `<Removed>` and `<Enabled>` fire once
per actual change - enabling an account that's already enabled emits nothing,
though it still reconnects it. `<Disabled>` fires on every `disable` call,
so treat it as idempotent.

**Ending an account's activity.** `disable`, a `proxy` change and `remove`
end everything the account has going, in this order:

1. Calls end, and the peer is told: a ringing call is declined, a call we
   placed is retracted, and the rest are terminated. Group calls are left,
   and their camera previews closed.
2. Uploads and downloads stop, failing with the reason. An upload's message
   is marked failed.
3. The stream closes, without resumption, so the next connection is a new
   session.
4. Requests still waiting are answered with an error carrying the reason.

You hear of each through its own module's events, as when the link drops:
`calls <Ended>`, `file <Update>`, rooms left. What you told the account
about your own display stays as it was: the avatars marked `visible` and the
chats marked `open` (see [chat](#chat)).

**A disabled account** is offline on purpose, and still there to read:
chats, history, search and other stored state answer as usual. It touches
no network until `enable`:

- A message sent is stored `pending`, and goes out after the next login.
- A request that needs the server fails at once with `account disabled`.
- Calls, downloads, uploads and room joins are refused, and so are edits
  that publish: bookmarks, `nick set`, accepting an invite. An automatic
  download is held back (`idle`), not failed. A room with autojoin is joined
  at the next login.

## register

In-band registration (XEP-0077) over a throwaway connection, kept separate
from the account store. Each session is identified by a `token` (any unique
string; `""` when omitted, enough for one session at a time).

    register connect {domain: string, host?: string, port?: int, tls?: string,
                      srv?: bool, websocket_url?: string, proxy?: string,
                      token?: string}
    register form {token?: string}                 -> form
    register media {token?: string, var: string}   -> base64
    register submit {token?: string, values: {*: string}}
    register cancel {token?: string}

    form       = {type: string, title?: string, instructions?: string,
                  fields: [form_field]}
    form_field = {var: string, type: string, label: string, required: bool,
                  value: [string], options?: [{label: string, value: string}],
                  media?: {cid: string, type: string}}

Events:

    register <Form>       {token: string}           form ready to fetch
    register <MediaReady> {token: string, var: string}   CAPTCHA image bytes for a field
    register <Success>    {token: string}
    register <Error>      {token: string, message: string}

`domain` is the server to register on (formerly `host`). The other options
work as an account's do; pass the same ones to the `account add` that
follows. See [Accounts and sign-in](#accounts-and-sign-in)
for the flow.

A server may close an idle registration stream while the user fills in the
form. `submit` then dials again, fetches the form anew and sends the values
into it; only when the new form needs the user again (a fresh CAPTCHA, a
required field left empty) does it fire `<Form>` instead.

## conn

The per-account connection lifecycle. `<State>` and `<ConnError>` are
pullable (use Tcl `observe`, or just track the last event you saw).

    conn probe {}

`probe` checks that the link is alive now. It does nothing unless the
account is connected, idle for 10s and not already being checked; if
nothing answers within 10s the connection is dropped and reconnects. The
backend also probes by itself after the machine wakes from suspend and
when the app becomes active (see [app](#app)). Setting `conn_probe` to `0`
turns all of these off.

Events:

    conn <State>        {acc: string, state: string}     every transition
    conn <ConnError>    {acc: string, message: string}   transport failure
    conn <AuthError>    {acc: string, message: string}   credentials rejected
    conn <Disconnected> {acc: string, message: string}   gave up; no retry

`state` is one of `disconnected`/`connecting`/`authenticating`/`binding`/
`connected`/`waiting`. A transport failure retries forever with backoff:
`<ConnError>` gives the reason, `state: "waiting"` is the gap between
tries, and `connected` clears it.

Two things end that loop, and the backend then stops until the account is
re-enabled or a [connection field](#account) is changed. `<AuthError>` is
rejected credentials, a `not-authorized` stream error included.
`<Disconnected>`, after a `<ConnError>` with the reason, is a stream error
retrying would not cure: `conflict` (another client took the session),
`host-unknown`, `host-gone`, `improper-addressing`, `invalid-from` or
`unsupported-version`. A resource conflict at bind is not one of these: the
backend picks a new resource and connects again.

## app

Facts the frontend reports about the app as a whole.

    app setActive {active: bool}
    app isActive {}                -> bool
    app idleSeconds {}             -> int

`active` is whether the user is using the app: focused on the desktop, in
the foreground on mobile. Until a frontend reports otherwise it counts as
active. On becoming active, connected accounts check their link
(`conn probe`). Accounts whose server supports Client State Indication
(XEP-0352) also tell it each change, so while the app is inactive the
server can hold back presence updates and typing notifications.
`idleSeconds` is how long the app has been inactive, 0 while active.
Becoming active also applies views [chat](#chat) held.

## setting

A global key/value store - not tied to any account.

    setting get {key: string}                  -> string   stored value ("" if unset)
    setting set {key: string, value: string}
    setting list {}                            -> [string]  known keys

Event:

    setting <Changed> {key: string, value: string}

Keys the backend reads, besides `conn_probe` (see [conn](#conn)):

- `answer_time`: `1` answers Entity Time queries (XEP-0202) with the local
  time and timezone offset.
- `answer_last_activity`: `1` answers Last Activity queries (XEP-0012)
  with `app idleSeconds`.

Both are off when unset. When on, they are answered only to the account's
own resources and to contacts with a presence subscription to it (`from`
or `both`); anyone else gets `service-unavailable`, as when off. Their
disco features are advertised only while on, and changing either sends
updated caps.

- `send_chat_markers`: `0` stops every delivery receipt and read marker this
  device would send (XEP-0184 `<received>`, XEP-0333 `<received>` and
  `<displayed>`). Unset means on. It never affects what the read watermark
  does locally.

## storage

Local storage encryption - off by default.

    storage status         {}                    -> string   plaintext|pending-encrypt|locked|pending-decrypt|unlocked
    storage unlock         {passphrase: string}
    storage requestEncrypt {}
    storage requestDecrypt {}
    storage cancelPending  {}
    storage encrypt        {passphrase: string}
    storage decrypt        {}

Events:

    storage <Unlocked>
    storage <MigrateProgress>   {done: int, total: int}
    storage <MigrationComplete> {direction: string}

`locked` blocks every other module but `app`, `account` included, until
`unlock` verifies the passphrase - retryable in place on failure, no restart.
`<Unlocked>` follows a successful `unlock`, and an `encrypt`.

Turning encryption on/off is two-step, not live: `requestEncrypt`/
`requestDecrypt` (from `plaintext`/`unlocked`) just flag intent - no
passphrase yet, nothing on disk changes - reflected as `pending-encrypt`/
`pending-decrypt`; `cancelPending` reverts it. The actual migration
(`encrypt {passphrase}` / `decrypt {}`) belongs at the next startup, before
any account connects, when status shows the pending request - `encrypt`
collects the passphrase there (never persisted from the request) and drops
straight into normal operation in that same process, no further restart.
They run only there: with the matching request pending and before normal
boot. Called at any other time they error and change nothing; a request takes
effect at the next launch, never in the session that made it.

`requestEncrypt` and `requestDecrypt` error without a config dir (storage is
transient, so there is nothing to encrypt) and when a request is already
pending; `cancelPending` errors when none is.
Cancelling at that startup gate also drops into normal operation: the
remaining modules come up and the enabled accounts connect.

Both stage every db plus every OMEMO/XEP-0454 attachment (a plain one is
never touched) before swapping anything into place; `<MigrateProgress>`
fires while that runs, `<MigrationComplete>` once it's done. They hold the
backend for their whole run: requests sent meanwhile wait and are answered
afterwards. A request made from inside a `<MigrateProgress>` listener in the
same thread gets the error `storage migration in progress`, unless it carries
`-command`/`-onerror`, which makes it wait like any other. If the swap
itself fails part-way, the error says to restart: the next launch completes
it, and another `encrypt`/`decrypt` until then is refused.

## chatlist

    chatlist get       {}                         -> [chat_entry]
    chatlist pin       {jid: string, pinned: bool}
    chatlist setPinned {jids: [string]}

The entire chat list as one flat, unordered array: the roster, bookmarked
rooms, any chat that has message history, any pinned chat, and the chat
with your own bare JID (even with no history), all merged. No querying.

    chat_entry = {jid: string, name: string, source: string,
                  groupchat: bool, is_self: bool, pinned: bool,
                  order: int, autojoin: bool, last_activity: int,
                  last_message?: message,
                  unread: int, unread_mentions: int, muted: bool,
                  mentions: bool, invited: bool, blocked: bool}

`jid` is the chat JID, used verbatim when you open it: `contact@host` for
1:1, `room@muc?join` for a group, `room@muc/nick` for a MUC private
message. `groupchat` is `true` when the jid has `?join`. `is_self` is
`true` for the chat with your own bare JID (notes to yourself). `source` is
`roster` (a roster contact, bare JID), `bookmarks` (a bookmarked room), or
`free` (came from chat history, with no roster or bookmark entry). `name`
can be `""` (always is for `free`). `last_message` is the chat's newest
message, whole, in the shape [message](#message) `history` returns; absent
when the chat has no history. `last_activity` is that message's time in
microseconds, or `0`. `unread` counts the other side's messages past
your read watermark (see [Read state](#read-state)); your own messages and
retracted tombstones never count. `unread_mentions` is how many of those
named you (see [notify](#notify)), and is always `0` outside group chats.
`muted` and `mentions` are the chat's [notify](#notify) policy, the derived
default when it was never set; a `notify set` arrives as `<Item>`.
`invited` is `true` on a group chat you are not in (no `autojoin`) holding a
`pending` invite, usually why an unjoined room is listed at all (see
[muc](#muc)). `blocked` is `true` when the chat JID is on the
[blocking](#blocking) list; a change arrives as `<Item>`.

`order` is opaque: sort entries by it, largest first, and break ties by
`jid`. It changes with a new message, a pin or a reorder, each arriving as
an `<Item>`. Pinned chats always sort above unpinned ones. It stays below
2^53, so a JSON reader that parses numbers as doubles keeps it exact.

`pinned` is `true` for a chat you pinned. Pins are local to this device.
`pin` pins a chat on top of the others, or unpins it; pinning a pinned
chat does nothing. `setPinned` takes the whole pinned list, top first: a
pinned chat left out of it is unpinned,
and naming a chat twice is an error (`TACO_CHATLIST_DUPLICATE`). A pinned
chat stays listed with no history or source; unpinned, such a chat is
removed. The chat with your own JID is listed regardless, and isn't
pinned unless you pin it.

`last_message` lets a chat list preview each chat without a `history` call
per row; see [The chat list](#the-chat-list) for drawing it.

Per source, an entry carries extra fields:

    roster      subscription: string (none|to|from|both), ask: string (subscribe|""),
                approved: bool, groups: [string]
    bookmarks   nick: string, password: string, room_state: string, room_reason: string

`room_state` is `joined`, `joining`, `error` (see `room_reason`),
`disconnected` (dropped from an autojoin room), or `idle`. `room_reason`
is `""` except on `error`, where it's a readable sentence rather than the
raw stanza condition.

Events:

    chatlist <Item>    {jid: string, item: chat_entry}
    chatlist <Remove>  {jid: string}
    chatlist <Changed> {}

`<Item>` upserts (an add, rename, new message, read-watermark move, source
change, room_state change, pin or reorder, block or unblock, notify policy
change, or an edit, retraction, status move or confirmation of the newest
message - not of an older one). `<Remove>` deletes - except a removed roster contact
that still has history, which comes back as an `<Item>` with
`source: "free"`. `<Changed>` means a whole source was swapped out (first
fetch, reconnect); refetch with `get`. The module funnels the roster,
bookmarks, room_state, message, read-watermark, blocking and notify-policy
signals into just these three events, so you only need to subscribe to
`chatlist`. The raw `bookmarks <Changed>`
and `bookmarks <RoomState>` signals are still there, but a frontend
normally sticks with the funneled ones.

## chat

Which chats the frontend shows, and how far down.

    chat open  {acc, chat}
    chat close {acc, chat}
    chat view  {acc, chat, timestamp}
    chat isOpen    {acc, chat}   -> bool
    chat isLooking {acc, chat}   -> bool
    chat setClientData {acc, chat, data: string}
    chat clientData    {acc, chat}   -> string

`open`/`close` are membership, not a count: open a chat once however many
windows show it. A chat is looked at (`isLooking`) while open and the
[app](#app) is active.

`view` gives the newest message on screen. While the chat is looked at it
reads up to there: `markOwnRead`, plus `markDisplayed` in a 1:1. Call it on
every scroll and arrival; stamps at or behind the watermark are ignored.
Views sent while the app is inactive are held until it is active again;
views of a chat that isn't open are dropped.

[notify](#notify) never alerts for a chat being looked at. Messages below the
fold stay unread, so `chatlist`'s `unread` counts them until scrolled to.

`setClientData` stores an opaque per-chat string for the frontend (scroll
position, drafts); the chat need not be open. `clientData` returns it, `""` if
none; storing `""` deletes it. It lives in the account's database: encrypted
with it, removed with the account and when the chat's history is forgotten.

## bookmarks

    bookmarks item {jid: string, name?: string, autojoin?: bool,
                    nick?: string, password?: string}
    bookmarks leave {jid: string}
    bookmarks remove {jid: string, leave?: bool}
    bookmarks forceJoin {jid: string}
    bookmarks nick {jid: string, nick: string}
    bookmarks autojoin {jid: string}         -> bool     that room's flag
    bookmarks defaultNick {nick?: string}    -> string   read, or set with `nick`
    bookmarks request {}                                 refetch from the server

XEP-0402 room membership, and the write side of the room half of
`chatlist`. Read rooms through `chatlist` - this is how you change them.
`jid` is the bare room JID; a chat JID's `?join` suffix is stripped for you.

`item` upserts and is how a room is joined: omitted fields keep their stored
values, a new bookmark with no `nick` takes `defaultNick`, and setting
`autojoin: true` joins the room as a side effect. `leave` is the inverse pair -
clear autojoin and part - while `remove` parts, deletes the bookmark, and
retracts it from the server; `leave: false` keeps you in the room. `forceJoin` re-sends the join with the stored nick
and password without touching autojoin, for a room dropped underneath you (an
IRC gateway going down). `nick` renames you in one room and stores it - in a
joined room only once the room accepts the new nick, so a refused one is never
stored; `defaultNick` is the account-wide fallback for new bookmarks, itself
falling back to the JID's localpart. `autojoin` reads one room's flag, for a menu that
has to show its state before it opens.

Changes made on another device are applied the same way: autojoin turned on
joins the room, autojoin turned off leaves it, a changed `nick` is taken in a
joined room, and a removed bookmark, or every bookmark on a purge or a node
delete, leaves its room. The echoes of this device's own changes are
recognised and change nothing.

Changes emit `bookmarks <Changed>`, but a frontend watches `chatlist <Item>` /
`<Remove>` instead - the funneled events carry the room state too.

## roster

    roster get {}                                                 -> [roster_item]
    roster request {}                                                refetch from the server
    roster item {jid: string, name?: string, groups?: [string]}
    roster add {jid: string, name?: string, groups?: [string]}        item + subscribe
    roster remove {jid: string}
    roster subscription {jid: string}   -> string   none|to|from|both, "" if absent
    roster subscribe {jid: string}
    roster approve {jid: string}
    roster unsubscribe {jid: string}
    roster deny {jid: string}

    roster_item = {jid: string, name: string, subscription: string,
                   ask: string, approved: bool, groups: [string]}

The contact list, and the subscription handshake around it. `chatlist` merges
the roster into its entries, so a frontend reads contacts there and changes
them here.

`item` upserts one contact as an atomic replace (RFC 6121 2.4): omitting
`groups` keeps the stored groups, passing `[]` clears them, but omitting
`name` clears the name - pass the current one to keep it. `add` is `item`
plus `subscribe`. `remove` deletes the item and cancels the subscription in
both directions.

`subscribe` asks to see a contact's presence and `unsubscribe` gives that up;
`approve` and `deny` answer someone asking about yours (a `<Subscribe>` event
with `type: "subscribe"`). None of them wait: the outcome arrives as a later
`<Subscribe>` or `<Changed>`.

Events:

    roster <Changed>   {acc: string, action: string, jid?: string}
    roster <Subscribe> {acc: string, jid: string, type: string}

`action` is `add`, `update`, `remove` (each with a `jid`), or `clear` - the
whole roster was replaced, so refetch. `type` is `subscribe`, `subscribed`,
`unsubscribe`, or `unsubscribed`.

## blocking

    blocking supported {}               -> bool
    blocking list {}                    -> [string]
    blocking block {jid: [string]}
    blocking unblock {jid?: [string]}
    blocking unblockAll {}

XEP-0191: the server drops everything from a blocked JID. The list is
per account and kept on its server.

`supported` is checked on every connect and is `false` while offline.
`list` is sorted, fetched on connect and kept while offline. Items may be
bare JIDs, full JIDs or domains, stored case-folded.

`block` and `unblock` call `-command` with `""` once the server accepts, or
`-onerror` with its error text. `unblock` with no `jid` empties the list.

Events:

    blocking <Changed> {acc: string, list: [string]}

The whole list after any change, including ones made by the account's other
clients.

## presence

    presence get {jid: string}         -> presence      best resource
    presence resources {jid: string}   -> {*: presence}  per-resource
    presence isOnline {jid: string}    -> bool

    presence = {show: string, status: string, priority: int,
                idle_since: int, client: client_info}

    client_info = {node: string, ver: string, name: string,
                   category: string, type: string, features: [string]}

`jid` is a bare JID; `resources` is keyed by resource, and the key is `""` for
a contact whose presence came from a bare JID. `get` picks the highest-priority
resource, or reports `show: "offline"` when none are known.

`idle_since` is when the resource went idle (XEP-0319), in microseconds, or `0`
if it said nothing. `client` is the software behind the resource, from its
entity capabilities (XEP-0115): `node` and `ver` come off the presence, the rest
off the disco#info reply that hash resolves to. It is `{}` until that reply
arrives, which fires another `<Changed>`, and stays `{}` for a client that
advertises no caps or whose caps can't be resolved (an error reply, or one
that fails the hash check).

Event:

    presence <Changed> {acc: string, jid?: string, action?: string}

`jid` names the contact whose presence moved. On disconnect it is
`action: "clear"` with no `jid`: all presence is dropped, and re-received on the
next connect.

## caps

    caps softwareVersion {to: string} -> {name: string, version: string,
                                          os: string}

XEP-0092: what software an entity runs, self-reported as a free-text name and
version. `to` is a full JID - a bare one answers for the account itself,
omitting it asks your own server. An entity that will not answer is an error
reply, with the reason it gave.

One round trip per resource, so it is a request rather than something the
backend collects. What a resource supports needs no call: `presence resources`
carries it in `client`.

## message

    message send {chat: string, body: string, reply_to_ts?: int}            -> int   the new row's timestamp
    message sendFile {chat: string, path: string}                           -> int   the new row's timestamp
    message history {chat: string, limit?: int, before?: int, after?: int, tag?: string}           -> [message]
    message goto {chat: string, date: int, source?: "local" | "remote", limit?: int, tag?: string} -> goto_result
    message gotoReply {chat: string, reply_id: string, reply_to?: string, limit?: int, tag?: string} -> goto_result
    message search {chat?: string, query: string, source?: "local" | "remote" | "both", limit?: int,
                    before?: int, before_chat_jid?: string, before_id?: string,
                    field?: string, tag?: string}                                       -> search_result
    message edit {chat: string, timestamp: int, body: string}
    message retract {chat: string, timestamp: int}
    message moderate {chat: string, timestamp: int, reason?: string}
    message react {chat: string, timestamp: int, emoji: string}
    message reactClear {chat: string, timestamp: int}
    message resend {chat: string, timestamp: int, plaintext?: bool}
    message retryUpload {chat: string, timestamp: int}
    message cancel {tag: string}
    message rawxml {chat: string, timestamp: int} -> string  raw stanza (debug)
    message markDisplayed {chat: string, timestamp: int, after?: int}
    message markOwnRead {chat: string, timestamp: int}
    message ownRead {chat: string} -> {timestamp: int, unread: int}

    message = {timestamp: int, chat_jid: string, from_jid: string,
               from_resource: string, is_outgoing: bool,
               server_id: string, own_id: string, occupant_id: string,
               server_status: string, remote_status: string,
               encryption: string, sender_fp: string, fail_reason: string,
               edited: bool, edited_ts: int, retracted: bool,
               content?: content,
               reply_id?: string, reply_to?: string,
               reply_author_jid?: string, reply_body?: string,
               reply_to_ts?: int,
               reactions?: {*: {reactors: [string], mine: bool}}}

    content = {type: "text",  body: string, formatting?: formatting, matches?: matches}
            | {type: "media", attachments: [attachment], caption: string, formatting?: formatting, matches?: matches}
            | {type: "invite", room: string, inviter: string, reason: string, state: invite_state, body: string, formatting?: formatting, matches?: matches}
            | {type: "call", room: string, id: string, inviter: string, video: bool, state: call_state, active: bool, live?: bool, body: string, formatting?: formatting, matches?: matches}

    invite_state = "pending" | "joined" | "declined"
    call_state   = "pending" | "joined" | "declined" | "missed" | "elsewhere" | "ended"

    formatting = [{type: span_type, offset: int, length: int}]
    span_type  = "bold" | "italic" | "overstrike" | "monospace"
               | "preformatted" | "quote" | "link"
    matches    = [{offset: int, length: int}]
    attachment = {url: string, path: string, type: "image" | "file", name: string, size: int, mime: string}

    goto_result   = {messages: [message], anchor: int, bounded_before: bool, bounded_after: bool}
    search_result = {messages: [message], complete: bool,
                     last: int, last_chat_jid: string, last_id: string}

An incoming text message, as it arrives on `<New>`:

    ["event", "message", "New",
     {"acc": "me@example.com", "jid": "peer@example.com",
      "message": {
        "timestamp": 1786637183834216,
        "chat_jid": "peer@example.com",
        "from_jid": "peer@example.com", "from_resource": "phone",
        "is_outgoing": false,
        "server_id": "kR3nQ8vP", "own_id": "", "occupant_id": "",
        "server_status": "", "remote_status": "none",
        "encryption": "omemo", "sender_fp": "05a1b2c3d4e5f6...", "fail_reason": "",
        "edited": false, "edited_ts": 0, "retracted": false,
        "content": {"type": "text", "body": "hey, look at this"}}}]

The same message carrying a photo instead. Only `content` differs: the body
becomes `caption`, and the files are listed in `attachments`.

    "content": {
      "type": "media",
      "caption": "the roof, this morning",
      "attachments": [
        {"url": "https://upload.example.com/8f2a/roof.jpg", "type": "image",
         "name": "roof.jpg", "size": 184320, "mime": "image/jpeg"}]}

- `timestamp` doubles as the row id - unique within a chat, and the backend
  bumps it by a microsecond if two would collide. `before`/`after` on
  `history` are exclusive cursors. `limit` defaults to 50 on `history`,
  `goto` and `gotoReply`, and to 20 on `search`; `goto`'s `source` defaults
  to `local`.
- `from_resource` is the sender's resource. `server_id` is the XEP-0359
  stanza-id the server (or room) gave the message, `""` until it has one;
  `own_id` is the id the sending client put on it; `occupant_id` is the
  sender's XEP-0421 id in a room, `""` elsewhere. They are wire data, for
  debugging and matching, not for display.
- `server_status` tracks the hop to your own server: `""` (it has the
  message), `pending`, `uploading`, or `failed`. Without XEP-0198 on the
  server, only a MUC echo or the next archive catch-up confirms a send, so a
  1:1 message can stay `pending` after `remote_status` reaches `delivered`.
- `remote_status` is the hop after that, what the far end has done with it:
  `none` (nothing back yet), `delivered` (XEP-0184 or XEP-0333 `<received>`),
  or `read` (XEP-0333 `<displayed>`). It only ever moves forward along that
  order, so a duplicate or out-of-order marker never walks it back, and it
  stays `none` on incoming messages. A `<displayed>` marker means every message
  up to its target, so it takes each earlier outgoing message in the chat to
  `read` too, one `<Status>` per row; an XEP-0184 receipt moves only the message
  it names. The two are independent axes - read
  `server_status` first, since a message that hasn't reached your server yet
  has nothing to say about the far end.
- `encryption` is `"omemo"` or `""`.
- `sender_fp` is the identity-key fingerprint of the peer device whose OMEMO
  session decrypted the message; `""` on a cleartext row and on your own sends.
  It matches the `fingerprint` of an `omemo trustList` row, which is how you
  resolve it to a device id and its trust state.
- `content` is the typed payload: `type: "text"` carries a `body`,
  `type: "media"` carries an `attachments` list plus a `caption` (grouped
  attachments are just more than one entry). Each `attachment` has a `type` of
  `"image"` (render inline) or `"file"` (a download chip). `type: "invite"`
  invites you to the group chat `room` (bare JID) from `inviter` (bare JID,
  `""` when unknown), with an optional `reason`; see [muc](#muc).
  `type: "call"` is an XEP-0482 invite to a group call in `room`; see
  [groupcall](#groupcall). Both carry a plain-text fallback in `body`.
  Deletion is a message-level state rather than a content type, so future
  kinds extend this union - switch on `type` and tolerate unknown ones.
- A `type: "text"` message's `body` may be `""`: the sender sent a message
  with nothing in it (an empty `<body/>`, or an OMEMO payload that opened to
  nothing). It is kept so you learn a message came; show it as such (the Tk
  GUI reads "Empty message") rather than as a blank bubble. A correction can
  empty a message the same way.
- `formatting` (XEP-0393 styling spans) indexes into whichever of
  `body`/`caption` the variant carries, with the inline styling characters
  and a code block's fence lines already removed from that string. A block
  quote keeps its `> ` markers, and its `quote` span covers them. Spans may overlap: two styles over the same run
  are two separate single-type entries, combined by the renderer.
- A `link` span is not XEP-0393 styling: nothing on the wire marks links, so
  tacky finds them in the text. It covers a URL written with an `http://`,
  `https://`, `mailto:` or `geo:` scheme (a bare `www.` is not one), minus
  sentence punctuation after it and a closing bracket it never opened. The
  covered text is the target, so the span carries no href. Text inside a
  `monospace` or `preformatted` span is never a link. The scheme list is
  tacky's choice, not a promise: a renderer still checks the scheme before
  opening anything.
- `matches` appears on `message search` results only: one entry per occurrence
  of the query, in the same offsets as `formatting`.
- A retracted message carries no `content` - the `retracted` flag is the
  signal. The row itself is deliberately kept, so pagination anchors and reply
  resolution keep working.

See [The chat window](#the-chat-window), [Attachments](#attachments),
[OMEMO](#omemo-1).

Events:

    message <New>         {jid: string, message: message}
    message <Status>      {jid: string, timestamp: int, server_status?: string, remote_status?: string, fail_reason?: string, encryption?: string}
    message <Confirmed>   {jid: string, timestamp: int, newtimestamp: int, server_status: string}
    message <Reactions>   {jid: string, timestamp: int, reactions: {*: {reactors: [string], mine: bool}}}
    message <Edited>      {jid: string, message: message}
    message <Retracted>   {jid: string, timestamp: int}
    message <OwnRead>     {jid: string, timestamp: int}
    message <CatchupStarted> {jid: string}
    message <CatchupDone> {jid: string, count: int}
    message <Tail>        {jid: string, timestamp: int}               pullable

`<Status>`, `<Confirmed>`, `<Reactions>`, `<Edited>` and `<Retracted>` each
change a message already on screen, found by `timestamp` - drop one whose
target isn't displayed. `<Status>` carries only the fields that changed, plus
`encryption` when a resend rewrote the row to cleartext. `<Confirmed>` always
carries `newtimestamp` and is the only event that clears `server_status` to
`""`, and the only one that can move a message's slot. What to do with each is
in [The chat window](#the-chat-window).

### Read state

The read watermark is how far you have read a chat: one timestamp per chat,
not a per-message flag, so backfilled history landing behind it does not
become unread. (`remote_status` on a message is the other direction, the
peer's read state of something you sent.)

`markOwnRead` sets it, forward-only - an older-or-equal stamp is ignored. It is
local state and applies to group chats; `markDisplayed` is the separate wire
half (a XEP-0333 `<displayed>`, 1:1 only, only to a contact who may see
our presence, as for delivery receipts, and never with the
[`send_chat_markers`](#setting) setting at `0`). It names the newest of the peer's
messages at or before `timestamp` and past `after`, so ours on screen below
theirs still marks theirs read; with none in that range it sends nothing. The
watermark also advances on its own on [chat](#chat) `view`, when you send a
message from any of your devices, and when another device's `<displayed>`
marker reaches this one.

`<OwnRead>` fires on every move, from any of those sources. `ownRead` gives one
chat's watermark and unread count. See [Read state and
alerts](#read-state-and-alerts).

## muc

    muc acceptInvite  {chat: string, timestamp: int}
    muc declineInvite {chat: string, timestamp: int, reason?: string}
    muc invite        {jid: string, to: string, reason?: string}
    muc requestVoice  {jid: string}
    muc kick          {jid: string, nick: string, reason?: string}
    muc role          {jid: string, nick: string, role: string, reason?: string}
    muc affiliation   {jid: string, target: string, affiliation: string, reason?: string, nick?: string}
    muc createInstant {jid: string}        create the room with its default config
    muc destroyRoom   {jid: string, reason?: string, altRoom?: string, password?: string}
    muc discoverRooms {jid: string}     -> [room_item]   rooms a service lists
    muc roomInfo      {jid: string} -> muc_room_info
    muc roomPrivacy   {jid: string} -> [string]   why its readers are not known; [] when they are
    muc members       {jid: string} -> {list: string, members: {jid: affiliation}}
    muc people        {jid: string} -> {list: string, groups: {group: int},
                                        me: room_caps, people: [person]}
    muc occupants     {jid: string} -> [occupant]
    muc occupant      {jid: string, nick: string} -> occupant   ({} if not there)
    muc myNick        {jid: string} -> string     your nick in the room
    muc myRole        {jid: string} -> string     your role in the room
    muc myAffiliation {jid: string} -> string     your affiliation with it
    muc getSubject    {jid: string} -> string     the room's subject

    muc_room_info = {known: bool, live: bool, members_only: bool,
                     non_anonymous: bool, occupant_id: bool}
    person    = {key: string, nick: string, jid: string, occupant: string,
                 present: bool, self: bool, group: string, role: string,
                 affiliation: string, show: string, status: string,
                 occupant_id: string, caps: {...},
                 keys: member_keys | {}}
    room_caps = {request_voice: bool, destroy: bool}
    room_item = {jid: string, name: string, occupants: int | null}
    occupant  = {nick: string, jid: string, jids: [string], role: string,
                 affiliation: string, show: string, status: string,
                 occupant_id: string, caps: occupant_caps}
    occupant_caps = {kick: bool, ban: bool, make_moderator: bool,
                     grant_voice: bool, revoke_voice: bool,
                     grant_membership: bool, revoke_membership: bool}

Events:

    muc <RoomInfo>       {jid: string, info: muc_room_info}
    muc <MembersChanged> {jid: string}
    muc <PeopleChanged>  {jid: string}
    muc <Presence>       {jid: string, nick: string, occupant: occupant, replay?: bool}
    muc <Unavailable>    {jid: string, nick: string, reason: string, codes: [int], occupant: occupant}
    muc <NickChanged>    {jid: string, oldNick: string, newNick: string, self: bool, occupant: occupant}
    muc <Joined>         {jid: string, nick: string}
    muc <RoomCreated>    {jid: string}
    muc <Left>           {jid: string, nick: string, involuntary: bool, codes: [int],
                          disconnected?: bool, destroyed?: bool}
    muc <Error>          {jid: string, error: string}
    muc <NickError>      {jid: string, nick: string, error: string}
    muc <Kicked>         {jid: string, nick: string, actor: string, reason: string}
    muc <Banned>         {jid: string, nick: string, actor: string, reason: string}
    muc <Destroyed>      {jid: string, altRoom: string, reason: string}
    muc <Subject>        {jid: string, nick: string, subject: string}
    muc <Decline>        {jid: string, from: string, reason: string}
    muc <VoiceRequest>   {jid: string, from: string, nick: string, form: form}

You join and leave rooms through [bookmarks](#bookmarks); these report how
that goes. `<Joined>` is the room letting you in (after `<RoomCreated>` when
you made it), `<Error>` a join the room refused, with the stanza condition.
`<Left>` is you out of the room: `involuntary` when the room put you out,
`disconnected` when the connection dropped, `destroyed` when the room was
destroyed. `<Destroyed>` follows it with the owner's `reason` and `altRoom`,
where they point you, if anywhere. `<Kicked>` and `<Banned>` name any occupant
the room put out, you included, with the `actor` who did it and why. `<NickError>` is a nick change the room refused while you stay in.

`<Subject>` is the room's subject, on join and when someone (`nick`) changes
it. `<Decline>` is `from` turning down an invite you sent. `<VoiceRequest>`
reaches a moderator when a visitor asks for voice (`requestVoice`): `from` and
`nick` are who, and `form` (as in [register](#register)) is the room's
approval form.

`affiliation`'s `nick` names the occupant the change is about, for a room that
wants one. `kick`, `role`, `affiliation`, `createInstant` and `destroyRoom` answer
`""` once the room has accepted, and an error reply with a reason when it
refuses.

`roomInfo` is what the room's disco#info said: on this connection (`live`),
or the last time it was asked (`known`). `members` is everyone with an
owner, admin or member affiliation, by real JID, whether in the room or not:
asked of the room at each join of a private room and kept current from
then on. `list` says how far that got: `pending` while asking, `complete`,
`partial` when the room refused some of its lists, `presence` when it refused
all of them (the members are then those its presences show), `none` for a
room not private or not joined.

`people` is who to show for a room, already in the order to show them:
everyone in it, then every member who is not. An occupant is matched to a
member by the real JID its presence carries. `group` is `moderator`,
`participant`, `visitor`, `other` (no role yet) or `absent`; people are
sorted by group, then by nick, the absent by JID, and `groups` counts each.
`key` stays the same for one person across reads (their real JID, or
`nick:<nick>` where the room shows none), `jid` is the bare real JID and
`occupant` the room/nick JID, "" for someone absent. `caps` are an
occupant's as below, all off for the absent and for yourself; `me` is what
you may do about the room itself. `keys` is the person's
[OMEMO keys](#group-chats) as `roomStatus` gives them, for a member of a
room that can be encrypted, else `{}` (and always `{}` for yourself). `list` is the member list's state
as for `members`: where the room refused the lists, the absent are not
known and only those present are listed. `<PeopleChanged>` says the answer
changed - once per burst, so a join is one event - for the frontend to read
it again; a room you are not in answers `list: none` and no people.

Group chat invitations arrive as messages with `content.type` `"invite"`
(see [message](#message)). These two answer one, named by that message's
chat and timestamp as for `edit` and `react`. Both answer `""` and ignore a
row that isn't an invite.

Where an invite sits depends on who sent it:

- **Direct** (XEP-0249): from the inviter, in your 1:1 chat with them, with
  them as `from_jid`.
- **Relayed** (XEP-0045): passed on by the room, in `room?join` with the room
  as `from_jid`; `inviter` is the room's claim of who asked. It counts as a
  mention (`unread_mentions`, and a `notify` alert although rooms default to
  muted). If nothing else is stored there, the room is listed as a `free`
  group chat marked `invited`.

`content.state` is `joined` while you are a member of the room (bookmarked
with `autojoin`, through this invite or not), else `declined` if you turned
it down, else `pending`. A change arrives as `message <Edited>` with the
whole row, for every invite to the room at once when membership changes.

`acceptInvite` bookmarks the room with `autojoin` and the invite's password
(never shown to the frontend), undoing any earlier decline. `declineInvite`
marks it `declined` and, for a relayed invite, sends a decline through the
room (a direct invite has none to send). The row stays as a record, unless
the room's chat then holds only declined invites (a room you never joined):
that chat is dropped with a `chatlist <Remove>`.

`occupants` is who is in a joined room now, `occupant` one of them by nick.
`jid` is the real JID if the room shows it; `jids`
lists every JID sharing the nick; `occupant_id` is its XEP-0421 id, "" when
the room gives none. `<NickChanged>` carries the occupant under its new nick;
`<Unavailable>`'s occupant has no `caps`. A
`<Presence>` with `replay: true` only refreshes `caps` after your role
changed.

## notify

    notify get {chat: string} -> {muted: bool, mentions: bool}
    notify set {chat: string, muted?: bool, mentions?: bool}

Events:

    notify <Notify>     {jid: string, timestamp: int, nick: string, from: string,
                         body: string, unread: int, mention: bool}
    notify <MissedCall> {jid: string, timestamp: int, nick: string, video: bool}
    notify <Settings>   {jid: string, muted: bool, mentions: bool}

`<Notify>` means this message is worth telling the user about even if they are
not looking at the app; how to tell them is the frontend's job.

- `nick` is who sent it, resolved the way `author get` does; `from` is the
  sender's JID (the occupant JID in a room), for an avatar.
- `body` is the full message text - trimming it for display is the frontend's
  job. For an attachment it is the caption, empty when there was none.
- `unread` is the chat's total at that moment, so a burst can collapse into a
  single "Name (12)" alert.
- `mention` marks a group-chat message that named you.

A chat being looked at (see [chat](#chat)) never alerts. Otherwise a message
alerts only while past the read watermark, held for `notify_delay_ms`
(default `500`) so a read from another device landing just after still
cancels it.

Messages that arrived while you were offline alert once catch-up settles,
capped at 10 per chat per catch-up, with `unread` still reporting the true
total. `notify_floor` is stamped at the account's first connection, so nothing
older ever alerts and the opening archive fetch is silent. Both are `setting`
keys.

`<MissedCall>` alerts a [`calls <Missed>`](#calls): `jid` is the caller,
`nick` as for `<Notify>`. It goes out at once and follows the chat's `muted`
policy like a message without a mention.

`muted` and `mentions` are the per-chat policy: alert when
`(mention && mentions) || !muted`, so a mention pierces a mute unless
`mentions` is false too. Unconfigured chats take a derived default - group
chats start muted, 1:1 chats do not, `mentions` starts on for both.

## mam

    mam fulltextSupported {chat: string}  -> bool    archive can run a text search
    mam metadata {to?: string}            -> {start_id: string, start_timestamp: int,
                                              end_id: string, end_timestamp: int}
    mam formfields {to?: string}          -> [string]   query fields the archive offers

What the archive itself can do, for gating a UI on it. Nothing here fetches
messages - history and search go through `message`, which drives MAM for you.

`chat` is a chat JID (`room@host?join` for a room), which `fulltextSupported`
resolves to whichever archive would answer it: the room's own, or yours. `to`
names an archive directly and defaults to yours, so pass a room JID for that
room's.

- `fulltextSupported` - whether a server-side search is worth offering (see
  [The chat window](#the-chat-window)).
- `metadata` - the oldest and newest entries. For an empty archive the ids
  are `""` and the timestamps `null` (`""` in Tcl).
- `formfields` - the filter fields the archive advertises. A fulltext field
  among them is what `fulltextSupported` checks for.

An archive that refuses or can't be reached is an error reply for all three.

## omemo

    omemo device_id {}                -> int
    omemo account_jid {}              -> string
    omemo own_fingerprint {}          -> string    hex identity-key fingerprint
    omemo devicelist {jid: string}    -> [int]      raw PEP devicelist cache
    omemo trustList {jid: string}     -> [omemo_trust]
    omemo blindTrust {}               -> bool
    omemo trust {jid: string, device: int, state: string}      validates the transition; emits <TrustChanged>, <TrustList>
    omemo setBlindTrust {value: bool}            -> bool   emits <BlindTrust>
    omemo setEnabled {jid: string, value: bool}  -> bool   emits <Enabled>
    omemo isEnabled {jid: string}                -> bool   on for a 1:1 chat never set, off for a room or a room PM
    omemo prepareChat {jid: string}   -> ""    warm devicelist + bundles
    omemo roomStatus {jid: string}    -> omemo_room_status   jid is a room chat (room?join)

    omemo_trust = {device: int, trust: string, active: bool, fingerprint: string}
    omemo_room_status = {jid: string, eligible: bool, reasons: [string],
                         enabled: bool, offered: bool, member_list: string,
                         members: [member_keys], attention: int,
                         unreachable: [{jid: string, reason: string}]}
    member_keys = {jid: string, keys: int, trusted: int, undecided: int,
                   untrusted: int, compromised: int, attention: bool,
                   reason: string}

`trust` moves freely between `undecided`, `trusted`, and `untrusted`. Only
the system can move a device to `compromised`, and nothing moves it back. A
bad transition errors with `OMEMO TRUST_TRANSITION`; a `(jid, device)` pair
that doesn't exist errors with `OMEMO TRUST_NO_DEVICE`. Those codes are the
Tcl binding's `-errorcode`; a JSON error reply carries only the message.
`device` is an opaque row handle from `trustList` - don't show it to the user.
`prepareChat` replies once the devicelist is in and the bundle fetches have
started (for a room, at once), not when they finish. See
[OMEMO](#omemo-1).

`trustList`, `isEnabled`, `setEnabled` and `prepareChat` take a room chat
(`room?join`) too; see [Group chats](#group-chats). For a room, each
`trustList` row also has `jid`, the member whose device it is - pass that,
not the room, as `trust`'s `jid` - and
`setEnabled {value: true}` on a room that doesn't qualify errors with
`OMEMO ROOM_NOT_ELIGIBLE`.

Events:

    omemo <TrustList>          {jid: string, trustList: [omemo_trust]}   pullable
    omemo <BlindTrust>         {value: bool}                             pullable
    omemo <Enabled>            {jid: string, value: bool}                pullable
    omemo <TrustChanged>       {jid: string, device: int, state: string}
    omemo <FingerprintChanged> {jid: string, device: int, fingerprint: string}
    omemo <DecryptFailed>      {jid: string, device: int, reason: string, room?: string}
    omemo <RoomStatus>         {jid: string, status: omemo_room_status}  pullable
    omemo <MembersUnreachable> {jid: string, members: [{jid: string, reason: string}]}

Every change to a peer's devices ends with a fresh `<TrustList>` for that
peer (and for each room listing them): a `trust` call (`<TrustChanged>`,
then `<TrustList>`), a rotated identity key (`<FingerprintChanged>`,
`<TrustChanged>` to `compromised`, then `<TrustList>`), and a new or
dropped device (`<TrustList>` alone). A key panel needs only `<TrustList>`;
the other two say what happened, for a notice.

## avatar

    avatar metadata {jid: string}   -> avatar_meta   ({} if none)
    avatar data {hash: string}      -> base64        ("" if not cached)
    avatar visible {jid: string}
    avatar invisible {jid: string}
    avatar publish {data: base64, type?: string, width?: int, height?: int, tag?: string}  -> ""
    avatar disable {tag?: string}   -> ""
    avatar cancel {tag: string}
    avatar refresh {jid: string}
    avatar inject {jid: string, data: base64, type?: string, width?: int, height?: int}  -> string

    avatar_meta = {hash: string, type: string, bytes: int, width: int, height: int}

The full-size image is content-addressed by hash: `metadata` maps a JID to its
current hash, and `data` gives you the bytes as they were published. The
backend fetches bytes for JIDs you've marked `visible`. The marks are a set,
not counted references: marking twice is the same as marking once, one
`invisible` clears the mark however many trackers you had, and the set outlives
a dropped connection. Collapsing your own trackers into one mark is yours to
do; releasing is optional, and a mark left standing only keeps that avatar
current.

Every `visible` re-emits `<Update>` for an already-cached avatar, not only the
first, so listening is enough and re-marking is how you ask again - a frontend
rebuilt over a backend that kept running has no other route back to the cache.
A mark also re-fetches the bytes when the cached hash has none behind it (a
download that failed, or one the process did not outlive), as does a session
coming up under marks already placed. That re-fetch runs once per connection
per hash, so re-marking a JID whose bytes the server will not serve costs
nothing.

Any chat JID may be passed: the `?join` suffix is not part of the JID an avatar
lives under (the resource is, so MUC occupants stay distinct). `<Update>`
reports that cut form, and it is what to key a cache by.

A hash whose bytes never arrived is why `metadata` can name a hash `data`
answers "" for: only `<Update>` waits for the bytes, so a frontend that builds
an image out of a hash wants that one, not the read. `refresh`
re-requests a JID's metadata node instead of trusting the cached hash, for when
no notification arrived; it still only fetches bytes for a `visible` JID, leaves
the cache alone if that JID publishes no avatar, and reports nothing on an IQ
error.

`publish` sends `data` as-is. A ~128px PNG is a safe size. `publish` and
`disable` update your own cached entry and emit `<Update>` for your JID as soon
as the server confirms, without waiting for the PEP echo.

Avatars come from XEP-0084 (PEP) or XEP-0153 (vCard, for group chats and
occupants). PEP wins: a JID with a PEP avatar ignores its vCard hash.

For tests and fixtures: `inject` seeds the local cache for any JID with no
server round-trip. It writes what a PEP arrival would, emits `<Update>`, and
returns the hash. Empty `data` clears the JID and returns `""`. Nothing is
published.

Events:

    avatar <Update>   {acc: string, jid: string, hash: string}   changed, arrived, removed (hash ""), or any `visible`
    avatar <Progress> {acc: string, message: string}             during your own publish

## nick

    nick get {jid: string}                  -> string   cached nick ("" if none)
    nick set {nick: string, bookmarks?: "skip"} -> ""   publish + vcard + bookmarks
    nick publish {nick: string}             -> ""       PEP only
    nick fetch {jid: string}                            refresh from the server

XEP-0172 user nicknames over PEP. `get` is a local cache read; `fetch`
pulls a JID's published nick and caches it, and `set` publishes your own
(PEP node, vcard-temp, and every bookmark's nick - renaming you in each room
you are in - unless you pass `bookmarks: skip`, in which case only the
default nick for new bookmarks is updated).
`publish` is the PEP-only slice of `set`.

Event:

    nick <Changed> {jid: string}   a JID's nick arrived; re-read with `nick get`

`<Changed>` fires on every fetch and every published nick that reaches you,
whether or not it differs from the cached one.

## author

    author get {chat: string} -> {*: string}   from_jid -> display name

The name to show for each sender in one chat, keyed by a row's `from_jid`: in
a MUC the participant nick, in a 1:1 the roster name, then the PEP nick, then
the bare JID. Built on the first `get` for a chat and kept current after.

Event:

    author <Changed> {chat: string, from: string, name: string}   one sender's name changed, or a new one appeared

## file

    file download {acc: string, url?: string, path?: string, auto?: bool,
                   from?: string}
                                                -> string  local path ("" when held back)
    file cancel {acc: string, id: int}
    file cancel {acc: string, url?: string, path?: string}
    file uncache {acc: string, url?: string, path?: string}

`download` produces a local copy of an attachment. Pass whichever of `url` and
`path` the attachment carries - both, when it has both. A `path` is one of your
own files and is used where it lies; a `url` is fetched into the data dir, or
served from the copy already there. A `url` is never opened as a path, and only
`http`, `https` and `aesgcm` are fetched; anything else fails. An attachment
with both is served from its `path` while that file exists and from its `url`
once it does not. Two downloads of the same source collapse into one. It
handles the `aesgcm://` scheme (XEP-0454) for you. A download that fails is
an error reply; one that `auto` holds back (autofetch policy or size) answers
`""`. `cancel` aborts a transfer in either direction - it ends `idle`, and a
download waiting on it is answered with the error `cancelled`. Cancel an upload by `id`, a download by
the source you gave it - which stops the coalesced fetch for every caller
waiting on it. `uncache` deletes the downloaded file; it only
ever touches the cache, never the file a `path` names. See
[Attachments](#attachments).

Set `auto` for a fetch you start yourself, such as rendering an inline image,
and pass the message's sender as `from`. Those two subject it to the autofetch
policy and size cap; without them a download always proceeds. A fetch the
sender policy declines never opens a socket; one over the size cap is dropped
as the bytes arrive. Either ends `idle`.

Event:

    file <Update> {id: int, direction: string, state: string,
                   loaded: int, total: int, url: string,
                   localpath: string, error: string}

`direction` is `upload` or `download`; `state` is `active`, `done`, `failed`
or `idle`. `idle` is the neutral end - nothing transferring, nothing on disk,
a fetch will start it - and covers a declined autofetch, a size-capped abort
and a cancel. `error` is only ever set on `failed`. For an upload, `id` is the
message timestamp; for a download, match on `url`, which echoes back the
source: the `url` you passed, or the `path` when you passed no `url`.

## calls

    calls start {to: string, video?: bool}                         -> string   sid
    calls accept {sid: string}
    calls reject {sid: string, reason?: string}                    reason default: decline
    calls hangup {sid: string, reason?: string}                    reason default: success
    calls setDevices {sid: string, input?: string, output?: string}
    calls setVideo {sid: string, on?: bool}                        on default: true
    calls list {}                                                  -> [call_row]

    call_row = {sid: string, peer: string, direction: string, state: string,
                peer_ringing: bool, group: string, video_local: bool,
                video_remote: bool, verified: bool, fingerprint: string,
                active_since: int}

`start` rings the peer; `video: true` offers a video track alongside audio.
Take the session id from `<Outgoing>`.
`setDevices` overrides the mic and speaker for a single call; an empty id means the system default.
`setVideo` mutes or unmutes the local camera on a call that already
negotiated video - it doesn't add video to a call that didn't. See
[Voice and video calls](#voice-and-video-calls) below.

`list` is every call the account has in flight, and the only way to learn a sid
you didn't see `<Outgoing>` or `<Incoming>` for. A call leaves it the moment
`<Ended>`/`<Failed>` goes out, so `state` is one of `proposed`, `ringing`,
`proceeded`, `new`, `connecting` or `active`, never a terminal one. `direction`
is `outgoing` or `incoming`. Note that `ringing` means *you* are being rung, the
callee side of `<Incoming>`; the caller side is `peer_ringing`, set once a peer
device has answered `<Ringing>`. `peer` is bare, as the events report it, even
after the session has latched a full JID. `video_local` is whether this side
offered/is sending video; `video_remote` is whether the peer did. `group` is
the room JID when the call is one of a [group call](#groupcall)'s sessions, else `""`.
Group-call sessions are listed like any call, so a restarted frontend finds them, but they
raise `groupcall <Session>` instead of `<Outgoing>`/`<Incoming>`.
`verified` and `fingerprint` are as in the last `<Verified>`. `active_since` is
the `since` of the call's `<Active>`, `0` until then.

Events:

    calls <Outgoing>     {sid: string, to: string, video: bool}
    calls <Incoming>     {sid: string, from: string, video: bool}
    calls <Ringing>      {sid: string}
    calls <Active>       {sid: string, since: int}
    calls <Ended>        {sid: string, reason: string}
    calls <Missed>       {sid: string, from: string, video: bool, reason: string}
    calls <Failed>       {sid: string, reason: string}
    calls <Warning>      {sid: string, reason: string}
    calls <Verified>     {sid: string, verified: bool, fingerprint: string}
    calls <VideoTrack>   {sid: string, mid: string, direction: string} & frame_stream
    calls <VideoPreview> {sid: string, direction: string}            & frame_stream
    calls <VideoEnded>   {sid: string, mid: string}

    frame_stream = {name: string}

A call ends on exactly one of `<Ended>` or `<Failed>`. `<Warning>` is just
informational and doesn't end anything.

`<Active>`'s `since` is when media first connected, in microseconds; an ICE
restart can emit `<Active>` again with the same `since`.

`<Ended>`'s `reason`:

| reason | |
|---|---|
| `hangup` | ended normally after ringing, either side |
| `declined` | the callee said no, you or the peer |
| `busy` | the peer was on another call |
| `retracted` | the caller gave up before an answer, you or the peer |
| `elsewhere` | another of your devices answered or declined |
| `timeout` | nobody answered within a minute |
| `replaced` | your call and the peer's crossed, and theirs won |
| `reset` | a fresh stream ended every call |

`<Missed>` is a ring nobody here answered: `retracted` or `timeout` (after its
`<Ended>`), or `busy`, turned away while another call was up, with no
`<Incoming>` or `<Ended>`. [`notify <MissedCall>`](#notify) alerts it.

`<Verified>` says whether to show the call as secure (see [Voice and video
calls](#voice-and-video-calls) for how a call is verified). `verified`
is true when the peer's device is one we would encrypt messages to: trusted,
or undecided while [blind trust](#omemo) is on. `fingerprint` is that
device's OMEMO key in the format [`omemo trustList`](#omemo) uses, or `""`
for a plain call (OMEMO off for the chat, or the peer doesn't support
this). The event comes before `<Active>` and again whenever the result
changes during the call: the key gets trusted or distrusted, another of the
peer's keys gets verified (which ends blind trust for the rest), or blind
trust is switched. If the fingerprint should be encrypted but isn't,
doesn't decrypt, or comes from an untrusted key, the call ends with
`<Failed>`. Group-call sessions don't use this.

`<VideoTrack>` (`direction: "incoming"`) and `<VideoPreview>`
(`direction: "preview"`, the local camera) each name a stream of I420 frames
the frontend connects to. `<VideoEnded>` (its `mid` always `video`) fires
alongside `<Ended>`/`<Failed>` for any call that had video negotiated - `setVideo` only mutes the camera, it doesn't
tear the video half down on its own. See
[Voice and video calls](#voice-and-video-calls) for the stream's format.

## groupcall

    groupcall start    {chat: string, video?: bool}            a hosted call for a chat
    groupcall join     {jid: string, video?: bool, chat?: string, id?: string}
    groupcall join     {chat: string, timestamp: int, video?: bool}   answer an invite
    groupcall decline  {chat: string, timestamp: int}
    groupcall leave    {jid: string}
    groupcall setVideo {jid: string, on?: bool}                on default: true
    groupcall invite   {jid: string, to: string}               XEP-0482, to a bare JID
    groupcall get      {jid?: string, chat?: string}           -> [call_state]
    groupcall inCall   {jid: string}                           -> bool

    call_state  = {jid: string, chat: string, hosted: bool,
                   phase: "idle" | "joining" | "live" | "ended",
                   reason: string, warning: string, since: int,
                   video: bool, camera: bool, preview: frame_stream | {},
                   count: int, participants: [participant]}
    participant = {nick: string, jid: string, joined: bool, video: bool,
                   leg: "expected" | "connecting" | "active" | "ended" | "failed",
                   reason: string, warning: string, stream: string}

Events:

    groupcall <State>        call_state                                       pullable
    groupcall <Invited>      {jid: string, from: string, chat: string, timestamp: int, video: bool}
    groupcall <StartFailed>  {chat: string, reason: string}

`jid` is the call's room: a hosted call's own (Dino's way: `start` makes it
and invites the chat), or a group chat holding the call (Movim's, joined but
never started by tacky). `chat` is the chat it belongs to.

`<State>` is the whole call, sent at most once per room per event-loop turn
when it changed; replace what you had. `get` returns every call with something
to show, `pull` re-sends one.

- `phase`: `idle` is a call in one of your group chats you are not in (a
  banner). `joining` until you are in, then `live`; `ended` is sent once,
  with `reason` (`""` for your own `leave`). A last `idle` with `count` 0
  means drop it.
- `since` is when you went live, in microseconds. `video`: you joined with a
  camera; `camera`: it is on now. `preview` is your self-view (`{id}` on the
  host backend).
- `count` includes you; `participants` is everyone else. `jid` is bare, `""`
  when the room hides it.
- `leg` is your session with them: `expected`, `connecting`, `active`, or
  `ended` / `failed` while they stay - nothing redials. Out of a call
  everyone is `expected`; once you are in, a hidden participant is `failed`.
  `stream` is their video: its frame stream, or on the host backend the
  track `id` the leg's `calls <VideoTrack>` carries.

`<Invited>` is when to ring (live invites only); answer with `join` by `chat`
and `timestamp`, or `decline`. `start` in a chat whose last call is still
going joins it. `leave` tells a hosted call's chat, or retracts the invite if
nobody came. `invite` sends a contact the invite, first letting them into
the room when the call is hosted.

Each invite is also a row in its chat, `content.type` `"call"` (see
[message](#message)). `inviter` is `""` when the room hides it, and `video`
says the call started with video. `state` is `pending` until you answer,
then `joined`, `declined`, `elsewhere` (another device of yours answered),
`missed` (retracted before you answered) or `ended` (over when you tried);
your own call reads `joined`. `active` is whether you are in the call now,
`live` whether anyone is. `live` comes from a disco#info to the room (a
hosted call's room vanishes once empty), asked only for a chat's newest call
(older ones read `false`) and again on each accept, left or retract; it is
absent until the room answers. Every change arrives as `message <Edited>`.

`<State>` is built from `<Started>`, `<Joined>`, `<Session>`, `<Left>`,
`<Warning>` and `<VideoPreview>`, with `list` as their snapshot; frontends
need none of them. See [Group calls](#group-calls).

## media

    media backend      {}                                  -> string   active backend
    media list         {}                                  -> [string] backends this build has
    media capabilities {}                                  -> {string: bool}
    media hostEvent    {pc: string, type: string, ...}     host backend only
    media payloadTypes {}                                  -> {audio: [payload], video: [payload]}

    payload = {id: int, name: string, clockrate: int, channels?: int}

A media backend owns the media half of a call; [Voice and video
calls](#voice-and-video-calls) explains the split. One serves every account,
from these:

    rtc     libdatachannel + rtc-ma + rtc-mv, in this process. In every
            native build (not the browser one); Opus and VP8 only.
    webrtc  libwebrtc, in libtacky_webrtc.so. Only where that ships.
    host    the frontend's own peer connection, driven through the messages
            below. Always present, and inert until the frontend answers.

The `media_backend` setting picks one, written with `setting set` like any
other. Unset, tacky takes `webrtc` where the build carries its library and
`rtc` everywhere else, quietly - a build without the library is the ordinary
case, not a fault. The setting is read once at startup, so a change applies at
the next one. `-media-backend` overrides it for a single run without storing
anything, and `-webrtc-lib` says where `libtacky_webrtc.so` is (default:
beside the executable). A backend that was named and is missing or won't start
is the case that warrants a `<Warning>`: tacky runs `rtc` instead (`host` where
there is no `rtc`) and leaves the setting as it was.

`capabilities` is what the active backend can do. A frontend needs them only
to grey out a control it would otherwise offer:

    audioDevices  `audio enumerateDevices` lists anything, and
                  `setPreferredDevice` reaches live calls
    audioVolume   `audio setVolume` reaches live calls
    cameras       `video enumerateCameras` returns anything
    videoDevice   `video setPreferredCamera` reaches live calls
    videoChannel  video arrives as `<VideoTrack>` / `<VideoPreview>`
    preview       a group call keeps a self-view of its own (`groupcall
                  <VideoPreview>`), on one camera shared by every session

An absent capability breaks nothing: the setter still stores the preference
and emits its event, enumeration comes back empty, and a frontend that ignores
all this shows an empty picker. The result also carries `autoAnswer`,
`sdpSanitize` and `trickleIce`, which tacky's own signalling reads; a
frontend can ignore them.

Events:

    media <Warning>     {name: string, reason: string}   requested backend unavailable
    media <HostCommand> {op: string, pc: string, ...}    host backend only

`<Warning>` fires at startup only; `name` is the backend that was asked for
and did not run. Nothing announces the ordinary case - ask `media backend`.

### The host backend

On `host`, tacky has no peer connection: every step it would have taken
leaves as a `<HostCommand>` event, and everything the frontend's own peer
connection reports comes back as a `hostEvent` request. Both carry flat
dicts of strings and numbers, so the same conversation works over the JSON
channel, JNI or JS.

    op                     keys besides pc
    createPeer             iceServers: [string], sid: string
    closePeer              -
    addTrack               track, kind: audio|video, direction
    setLocalDescription    sdp, sdpType: offer|answer ("" = your stack decides)
    setRemoteDescription   sdp, sdpType
    addRemoteCandidate     candidate, mid
    attachAudio            track, input, output, inputVolume, outputVolume
    attachVideoSender      track, deviceId
    attachVideoReceiver    track
    setVideoEnabled        on: bool
    openPreview            deviceId   (pc names the preview, not a peer connection)
    closePreview           -
    close                  -   (no pc: the backend is shutting down)

`pc` is tacky's name for a peer connection, `track` its name for a track it
added; keep a map from both to your own objects. `sid` on `createPeer` is the
call the pc serves, so that what the peer sends can be put on the right
screen; every later command names only the pc. Commands are not questions:
none is answered, and nothing waits.

    type              keys besides pc
    localDescription  sdp, sdpType
    iceCandidate      candidate, mid (an empty one means the audio m-line)
    gatheringState    state: new|gathering|complete
    connectionState   state: new|connecting|connected|disconnected|failed|closed
    track             track, kind, mid   your name for a track the peer added
    deviceFallback    kind: capture|playback|camera, id, reason
    error             op, reason, fatal: bool

Report every track the peer adds: that is what makes tacky attach it, and the
`attachAudio` or `attachVideoReceiver` that follows says what it is for.
Those two also produce `calls <VideoTrack>` / `<VideoPreview>`, carrying the
track handle as `id` in place of a frame stream name.

An answerer gets no `addTrack`; it sends on the offer's m-lines. The
`attachAudio` and `attachVideoSender` that follow name the peer's track, by
the name its `track` event gave it.

`openPreview` opens the camera with no peer connection, for a group call's
self-view from joining to leaving; `closePreview` releases it. `groupcall
<VideoPreview>` carries the preview's `pc` as its `id`. A camera that fails
to open is an `error` on the preview with `op` openPreview and `fatal: true`.
`fatal` is required on every `error`.

An event for a call that has ended is dropped; one with an unknown `type` or
a missing key comes back as a `calls <Warning>` on that call; one with no
`pc` or no `type` is an error reply.

Devices stay yours, so `audio` and `video` enumerate empty. An offer is
answered by the `setLocalDescription` that follows it, and your SDP goes on
the wire as it stands.

## audio

    audio enumerateDevices {}                              -> {capture: [audio_device], playback: [audio_device]}
    audio getPreferredDevice {kind: string}                -> string   device id ("" = system default)
    audio setPreferredDevice {kind: string, id: string}    -> ""
    audio getVolume {kind: string}                         -> double   linear gain, 1.0 if unset
    audio setVolume {kind: string, volume: double}         -> ""

    audio_device = {name: string, id: string, default: bool}

Machine-wide capture (mic) and playback (speaker) selection and gain -
these belong to the host, not an account, so they live here rather than on
`calls`. `kind` is `capture` or `playback`. Setting a device or volume
persists it and hot-swaps every live call on every account. Volume is a
linear gain in `[0.0, 1.0]`. Per-call device overrides are
`calls setDevices`; there's no per-call volume.

A preference outlives the backend that produced the id in it. One the active
backend doesn't recognise falls back to that backend's default device, and
the call it happens on gets a `calls <Warning>`; the stored preference is
left alone. On a backend without the `audioDevices` / `audioVolume`
capability, enumeration comes back empty and the setters only store the
preference.

Events:

    audio <PreferredDevice> {kind: string, id: string}       preferred device changed
    audio <Volume>          {kind: string, volume: double}   gain changed

## video

    video enumerateCameras {}                              -> [camera]
    video getPreferredCamera {}                            -> string   camera id ("" = let the backend pick)
    video setPreferredCamera {id: string}                  -> ""

    camera = {name: string, id: string, facing: int}

Machine-wide camera selection, the video equivalent of `audio` - one
preference for the machine, not per account. Setting a camera persists it
and hot-swaps every live video call on every account. An id the active
backend doesn't recognise falls back to its default camera, exactly as an
audio device does; without the `cameras` / `videoDevice` capability
enumeration is empty and the setter only stores the preference.

Events:

    video <PreferredCamera> {id: string}   preferred camera changed

## debugtap

    debugtap on    {acc?: string, token?: string}   -> int   tap id
    debugtap off   {tap: int}
    debugtap write {tap: int, stanza: string}

A debug console's view of one stream: an account's (`acc`) or a
[register](#register) session's (`token`). `on` returns a tap, and every stanza
in or out of that stream is then sent as `<Stanza>` until `off`. `write`
sends a raw stanza, given as XML text, down the tapped stream; one that
doesn't parse is an error.

Event:

    debugtap <Stanza> {tap: int, dir: "in" | "out", stanza}

`stanza` is the parsed node, in the Tcl binding's form.

## log

    log write    {level: string, text: string, obj?: string, acc?: string}  -> ""
    log setlevel {level: string, obj?: string}                              -> ""
    log getlevel {obj?: string}                                             -> string
    log setnativelevel {level: string, source?: string}                     -> ""
    log getnativelevel {source: string}                                     -> string   "none" when off
    log setfile    {path: string}                                           -> ""
    log setenabled {enabled: boolean}                                       -> ""
    log getfile    {}                                                       -> string   "" when logging to stderr
    log setredact  {enabled: boolean}                                       -> ""
    log getredact  {}                                                       -> boolean

The backend's logger. The frontend's lines land in the same file as the backend's
own, set by `--debug-file` at startup, otherwise to stderr. 

Levels, least to most severe:

    verbose  debug  info  warning  error  fatal  none

The default is `warning`, or `--debug-level` cli arg value. It is enough to see
why a connection failed: `conn` logs the reason a link dropped or never came up
at `warning`, and a SASL or bind failure at `error`. What it dialled and when it
will retry next are `info`.

`obj` names the source, as a dotted hierarchy: an object with no level of its
own inherits from its nearest ancestor, so `setlevel {obj: "gui", level:
"debug"}` covers `gui.chatlist` and everything else under `gui`. Omit `obj` to
read or move the default the rest inherit. Backend objects are already named
this way (`::taco.client(<jid>)`, `libdatachannel`, `rtcma`, `rtcmv`, `webrtc`). `write` without `obj` records `frontend`.

`setnativelevel` drives the native loggers, `libdatachannel`, `rtcma`,
`rtcmv` and `webrtc` (libwebrtc, when that media backend is loaded); omit
`source` to set all four. They start off, and `none` turns one off again;
`--libdatachannel-debug-level`, `--rtcma-debug-level`, `--rtcmv-debug-level` and
`--webrtc-debug-level` set them at startup.
Their output is voluminous, so the ordinary level does not affect them, and jlog
does not re-filter what the library already did. `getnativelevel` takes one
`source`, since the three can differ.

`setfile` moves the sink at runtime, for a debug toggle or an export; an empty
`path` goes back to stderr. The file is held open only for the length of one
record, so it can be truncated underneath the backend and the next record
recreates it.

At 4 MB the log rotates to `<path>.1`, replacing any previous one; both are 0600.

`setenabled` is the same switch by boolean, with the backend choosing the path:
`tacky.log` in the cache directory taco was given, created 0600 in a 0700
directory. An embedded host's sandbox and `-transient`'s temp root both apply.

`getfile` returns that path, the same handoff as an attachment's `localpath`. It
is `""` whenever records are going to stderr.

All the setters are per process and not persisted; see
[Accounts and sign-in](#accounts-and-sign-in) for keeping them.

`none` is a threshold, never a severity: `write` drops a record at that level, so
a caller may pipe a level straight from `getlevel` back into `write`.

At `debug` and below every stanza in and out is logged. Credentials are always
replaced: SASL exchanges, `<password/>`, password and secret form fields, and
upload slot headers. `setredact` (default on) also replaces message content:
`<body>` and `<subject>` text (as `[redacted N chars]`), reactions, XHTML-IM,
out-of-band URLs and upload slot URLs. This is best effort; JIDs, nicks, the
roster, presence, room names and the IP addresses in call candidates and native
logs stay, so treat a log as private.

`write` is non-blocking, so the log may not be written by the time it returns.

## error

Backend failures that no reply can carry. Events only, no methods, nothing
pullable.

    error <MethodError> {module: string, method: string, message: string,
                         errorinfo?: string, acc?: string}
    error <Background>  {message: string, errorinfo?: string}

`<MethodError>` is a request that failed while carrying a `-command` but no
`-onerror`, so the error had nowhere else to go; over JSON, where both are
always wired, a token gets an error reply instead and this never fires.

`<Background>` is a failure with no request behind it at all - a timer, a
socket handler, the stanza loop. The backend has already written the trace to
its log by the time you get it; the event exists so a frontend can tell the
user something broke rather than leaving it to the log alone. It is advisory
and says nothing about whether the session is still healthy. Identical
messages are collapsed to one event per five seconds, so a repeating failure
does not flood the wire; the log still keeps every occurrence.

`errorinfo` is a Tcl stack trace, a debug aid only. Do not parse it, do not
show it to users, and expect it to be absent.

# Guides

## Accounts and sign-in

**Startup.** Check `storage status` first: `locked` means no other module
but `app` works yet, so gate everything below on `storage unlock` succeeding;
`pending-encrypt`/`pending-decrypt` mean a requested migration needs to run
before anything else does (see [storage](#storage)) - after either gate
resolves, check `status` again, since unlocking can itself reveal a pending
decrypt. Once `plaintext` or `unlocked`, the backend connects every enabled
account at init; there is no connect call. That is also when `setting` becomes
readable, so reapply the [log](#log) choices the frontend keeps there, except
one whose command-line flag (`--debug-file`, `--debug-level`, ...) was given
for this run - the Tk GUI keeps them as `log_to_file`, `log_redact_content`,
`log_level` and `log_native`. Run `account list` and open the main UI if it
returns anything (on an enabled account, if any; a disabled one can still be
read), setup if it doesn't.

**Sign-in.** Creating the account is the credential check. Subscribe to
`conn <State>`, `<AuthError>` and `<ConnError>` for the account, then call
`account add` and `account enable`. Keep the account when `state` reaches
`connected`. On failure, show the `message` and call `account remove`:
`account add` stores the account before anything validates it, so an
abandoned sign-in leaves a row behind.
`<ConnError>` alone is retried by the backend; `<AuthError>` and
`<Disconnected>` are terminal.

**Sign-up.** XEP-0077 registration runs through the `register` module, keyed
by a `token`:

1. `register connect`, then wait for `<Form>`.
2. `register form` for the field list, and render it. `username` and
   `password` are the usual fields, but the server picks the set.
   `<MediaReady>` carries CAPTCHA bytes, fetched with `register media`.
3. `register submit` with the filled-in values.

`<Error>` can fire at either step, and a failed submit may need the form
re-fetched, since a CAPTCHA expires. `<Success>` means the account exists on
the server but not locally, so finish with `account add` and `account enable`
as above. `register cancel` or dropping the session tears it down.

## The chat list

Call `chatlist get` once the account is up and again on `chatlist <Changed>`,
then keep the rows current from `<Item>` (replace the row with that `jid`) and
`<Remove>`. Draw them by `order`, largest first, ties by `jid`; nothing else
needs sorting.

**A row.** Each entry has what a row shows:

- **Name** - `name`, which is `""` for every `free` chat and for a contact
  you never named. For a 1:1 fall back to the contact's own nick (`nick get`,
  refreshed on `nick <Changed>`), then the JID.
- **Avatar** - mark each row on screen `avatar visible` with its `jid` and
  draw from `avatar <Update>`; see [avatar](#avatar).
- **Presence** - for a 1:1, `presence get` and `presence <Changed>`.
- **Badges** - `unread`, and `unread_mentions` in a group chat; `pinned`;
  `muted`; `is_self` for notes to yourself; `blocked`; `invited` for a room
  you were invited to but are not in; a room's `room_state`, with
  `room_reason` to show on `error`.

**Preview.** Draw `last_message` as one line. A `retracted` row is a deleted
message. Otherwise switch on `content.type`: `text` shows `body`, and an empty
`body` is a message sent with nothing in it; `media` shows `caption`, or names
the attachments when it is empty (a photo, the file's `name`, a count);
`invite` and `call` carry a readable `body`. Prefix it with "You:" when
`is_outgoing`, or with the sender's nick (the resource of `from_jid`) in a
group chat, then collapse whitespace and trim it to fit.

## The chat window

A chat view is a sliding window over the conversation, fetched on demand
and culled under memory pressure. The conversation behind it is not bounded.
Three things have to stay true:

- **Order** - "A B C", never "A C B".
- **Contiguity** - the window is an unbroken run of the conversation:
  "A B C", never "A B F".
- **No stale displays** - never apply a result whose cursor has been
  invalidated (the user culled or jumped away).

**Data model.** A message is keyed by its chat plus its `timestamp`, which is
unique within that chat and doubles as the sort key. Equal timestamps in
different chats are ordinary, so anything spanning chats keys on both. The
backend keeps one ordered timeline per chat and hands back contiguous batches
for pagination queries. Pending outgoing messages sort in by timestamp like
everything else.

**Reaching the tail.** Track whether the window reaches the end of the
conversation; an empty window counts as reaching it. Live events may only be
applied while that holds - otherwise a `<New>` lands beside a message it does
not belong next to, and contiguity is gone. Culling the newer end or jumping
with `goto` ends it; a newer-page result whose newest timestamp matches the
last `<Tail>` restores it.

Requests carry a `tag`, and cancelling by tag (`message cancel`) is what keeps
a result that outlived its cursor from being applied: each pending request
under the tag is answered at once with the error `cancelled`, and its result
never arrives. The pagination cursors are just the
first and last timestamps in the window, passed as `before` and `after`.

**Paging.** `message history` with no cursor gives you the newest page.
`before` (exclusive) pages older, `after` (exclusive) pages newer, always
oldest-first, capped at `limit` (default 50). It's local-first: it returns
local rows right away and reaches for the server (MAM) only when a cursor
anchors the fill and the local read came up empty, or short of `limit` at a
hole. An `after` page past the newest stored row, with no hole, never asks:
there is nothing newer to fetch. When the archive fails and there is nothing
local to show, the request answers `onerror` with a readable reason rather
than an empty page, which would read as "no more history". A cursorless
initial load shows only the contiguous local tail and won't auto-fetch
older history - scrolling up (a `before` page) pulls the next page
from MAM. When the user scrolls toward an edge, fire a tagged `history` for
that direction, unless one is already in flight there. When the window
culls an end, cancel any in-flight request on that end, since its cursor
just moved and the result would be stale. Culling the newer end also gives up
the tail. Subscribe to `message <Tail>`, which pushes the chat's newest
real-message timestamp whenever it changes. On a newer-page result, a window
whose newest timestamp matches the last `<Tail>` has reached it again.

**Initial load.** When the chat opens, call `message history` with no cursor;
the newest page comes back, local if it's stored and from MAM if not. That
empty-local fetch is the one time a cursorless load hits the server, and it
has no timeout - treat the callback as best-effort and let live `<New>` events
and the catchup reconcile below fill an empty window once you're connected.
"Scroll to bottom" cancels in-flight requests, clears the window, gives up the
tail, and re-runs this.

**Jumping.** `message goto` returns an `anchor`: scroll to it if it's already
in the window, otherwise clear and apply `messages`. A jump gives up the tail
until the user returns to it. `bounded_before` and `bounded_after` mark a side
cut off at a hole - there's more history that way, and paging fills it in.
`gotoReply` (XEP-0461) jumps to a reply's target and returns the same shape.

**Replies.** `message send` takes an optional `reply_to_ts` - the `timestamp`
of the message being answered. The backend resolves that row to the id a peer
resolves against - stanza-id in a room, origin-id in a 1:1, since peers never
see our server id - and prefixes the wire body with a `> ` quote of the target
marked as a XEP-0428 fallback span. Pass the reply text alone: the quote is
added on the way out and stripped on the way in, so a stored `body` never
contains it.
A `reply_to_ts` naming a row that isn't stored, or a room message the room
hasn't given an id yet, sends as an ordinary message rather than failing. A
cleartext reply to an OMEMO message carries no quote, so the target's text
doesn't leak. Under OMEMO the quote is skipped and `<reply>` carries the
context alone: a fallback span indexes the cleartext warning body a peer strips
against before it decrypts, so no offset into the encrypted text is publishable.

A message that is a reply carries five fields. `reply_id` is the wire id it
answers and `reply_to` the JID it was addressed to, both as they appeared on
the wire. `reply_to_ts` is the `timestamp` of the target row, and `reply_body` a
shortened preview of it for rendering the quote inline; both are absent when the
target isn't in the store. `reply_author_jid` is the target's author normalized
the way `from_jid` is - an occupant JID in a room, a bare JID in a 1:1 - so it
resolves through `author get` like any other author. It is read off the resolved
row rather than off `reply_to`, which peers get wrong; with no row to read it
falls back to `reply_to`. Jump to it by passing `reply_id` and `reply_to` to
`gotoReply`, which resolves the id locally and then behaves like `goto`. An
uncached target comes back with no `messages` and an empty `anchor` - there is
no fetch-by-stanza-id, so a target beyond a hole is not reachable this way.

**Catchup.** On connect the backend syncs your account archive; on joining a
room it syncs that room's archive, which is the only sync a room gets, since
the account archive holds no groupchat. Catchup writes to the store without
emitting `<New>` - nothing arrived, it was backfilled. In-place corrections
still arrive as their own events, so a row already on screen stays current.

A sync is bracketed by `<CatchupStarted>` and `<CatchupDone>`, both carrying a
`jid`: the room's for a room sync, empty for the account sync. A disconnect
closes an open bracket with a zero `count`, so the pair always completes.

An account sync emits an extra `<CatchupDone>` per chat that gained messages,
carrying that chat's own `jid` and `count`, before the empty-`jid` one with
the total. A room sync emits only the bracketing one, whose `count` is that
room's. Those per-chat counts are what unread or notification UI should read;
`<New>` is not, since it also fires for your own outgoing messages.

Take the bracket that matches your chat - its own `jid`, or the empty one if
it isn't a room - and reconcile when it closes: if your newest displayed
timestamp differs from the last `<Tail>`, request an `after` page from it.
Discard a page whose newest doesn't reach that `<Tail>`, since a hole sits
between you and the tail and appending would only walk the user backwards;
leave them the scroll-to-bottom path instead.

**Live messages.** On `<New>`, insert it at its timestamp-sorted spot if the
window reaches the tail, otherwise drop it. Drop it inside an open catchup
bracket too: the archive may hold history you don't have yet, so reaching the
tail is a claim you can't check, and the reconcile above places the message
once the sync settles.

**Updates to a shown message.** Five events change a message already on
screen rather than adding one. All find their target by `timestamp` and drop
silently if it isn't displayed. `<Status>` updates the send/receipt state where the row
sits. `<Reactions>` swaps the reaction map. `<Edited>` carries a full
`message` row to redraw in place, for a content edit or a change to an invite's
or call's `state`. `<Retracted>` flips the
row to a tombstone in place - it carries only `timestamp`, so redraw the
placeholder from the header you already hold. `<Confirmed>` acknowledges a
pending send: update its checkmark in place when `newtimestamp == timestamp`,
or rekey to `newtimestamp` and re-sort when the server relocated it - the
only one that shifts a message's slot.

**Causing those updates.** Five calls, all naming their target by `timestamp`
and all doing nothing when it isn't stored (`moderate` says so through
`onerror`). `edit` (XEP-0308) sends a
correction of one of your own messages and swaps the stored body immediately,
so `<Edited>` arrives without waiting for the echo - except in an OMEMO chat
whose encryption can't go out now, where it does nothing at all. `react` (XEP-0444) toggles
one emoji in your own reaction set rather than adding it; call it again with
the same emoji to take it back. The set is sent whole because the
protocol has no delta, and `reactClear` drops all of yours at once.

Deleting splits by chat kind, so pick by chat rather than offering both.
`retract` (XEP-0424) withdraws one of your own 1:1 messages and tombstones it
locally at once; called on a room it does nothing. `moderate` (XEP-0425) is the
room path, and asks the room to retract anyone's message. It deliberately does
not tombstone locally: the room's own broadcast drives the change through the
receive path, so a rejected request leaves the message intact and no
`<Retracted>` ever arrives. The service enforces moderator role, so a rejection
is normal - pass `onerror` to hear about it, since success is silent. It
also answers `onerror` for a message the room hasn't given an id yet (your own
send before its echo).

**Outgoing.** Your own messages show up right away on `<New>`
(optimistically) at their pending timestamp. Once they're confirmed - a MUC
echo, or your own message coming back via MAM - a `<Confirmed>` clears
`server_status` and, if the server relocated the row, moves it to
`newtimestamp`. `send` is fire-and-forget, so
`<New>` is its acknowledgement, and it fires on every send - even one
that's stored `failed` immediately, like an encryption that can't go
through. The only send that gives you nothing is one that throws before
`<New>` (a malformed request). `server_status` tracks whether the server
has this exact message, moving through `<Status>` events: `""`
(it has it), `pending`, `uploading`, `failed` (with the error in
`fail_reason`).

A send interrupted by a restart is settled from the archive on the next
connection. The reconnect catchup confirms whatever the server really
stored; a 1:1 row still pending afterwards is re-sent if it falls inside the
span catchup covered (the server demonstrably never got it), and marked
`failed` with `fail_reason: "delivery"` if it predates that span, where
the archive can no longer say either way. A room's pending rows wait for that
room's own catchup and are re-sent after it. `fail_reason: "delivery"` also
marks a message the far side bounced, even after your server took it.

A message larger than the server takes in one stanza (the XEP-0478 limit
it advertises, else 1 MiB) is never written: it goes straight to `failed`
with `fail_reason: "too-large"`, and no retry sends it. Shorten it and send
again.

**Search.** `message search` takes a `source`, mirroring `goto`. `source:
local` (the default) runs over the bodies already stored for one chat, with
`before` as an exclusive timestamp cursor. Each query word matches a body word
from its start and every word must match, in any order: `нужн` finds `нужный`,
`needle haystack` finds a body carrying both, and `eedle` finds nothing -
mid-word text isn't findable. Case and diacritics are ignored.
Retracted messages never match.

`source: remote` is server-side MAM full-text (XEP-0431): page through it with
`before_id: last_id`, the archive's own cursor.
Few servers implement the field, so check first with `mam fulltextSupported
{chat: string} -> bool`; a search against an archive that advertises none is an
error reply rather than a silent match of everything. `field` names the
archive's full-text form field outright, skipping the lookup of which one it
advertises.

`source: both` runs the remote leg for its cache-filling effect - hits are
stored on the way through - and then answers from the store, so one matching
rule covers the whole result. It falls back to the store alone when the archive
can't run the search, and pages locally: passing `before` means walking a result
set already fetched, so it skips the remote leg and fetches one server page per
search.

Omitting `chat` searches every chat in the account. MAM queries one archive, so
that is local-only: a remote `source` without a `chat` is an error. Each result
carries the `chat_jid` it came from.

Each source pages with its own cursor and refuses the others: `before`
(exclusive) walks the store, `before_id` walks the archive. An account-wide
search pairs `before` with `before_chat_jid`, since two chats can share a
timestamp. Cursor fields a search doesn't page with come back empty.

Every hit carries `content.matches`: where the query matched, in the offsets
`formatting` uses - into `body`, or `caption` for a media message. One entry
per matched word, covering the typed prefix rather than the whole word.
Highlight from it rather than re-matching the query yourself. It is empty when
the match isn't literally in that string: an attachment URL the caption drops,
a styling character stripped on the way out, a diacritic the matcher ignored
(`grun` finding `GRÜN`), or a stem the archive matched remotely.

Jump to a hit with `message goto {date: ts, source: remote}`, which fills the
context around a hit stored as an isolated island. Whichever source found it,
the results aren't chat-view content - show them somewhere separate.

**Sender names.** A message row carries a `from_jid`, not a display name.
[author](#author) `get` resolves the names for one chat. Fetch it once when
the chat opens, key rows off `from_jid`, and follow `author <Changed>` to
re-resolve a single sender in place (a roster edit, a nick change, a new
occupant) without refetching the whole map.

**Rendering a message.** Draw a row in this order. If `retracted` is set, the
row is a tombstone - show the deleted-message placeholder from the header
(sender and timestamp) and stop, there is no `content`. Otherwise switch on
`content.type`. A `text` message draws `body`, applying each `formatting` span
over its offset range, and opens a `link` span's covered text when it is
clicked. A `media` message draws every entry in `attachments` by
its `type` - an `image` inline, a `file` as a download chip - then the
`caption` beneath, styled from its own `formatting` the same way (see
[Attachments](#attachments)). Around the content go the parts covered
elsewhere in this section: the sender name, the reaction row from `reactions`,
and for your own messages the send state in `server_status` and delivery or
read state in `remote_status`.

## Read state and alerts

What the user has read is one watermark per chat, and the backend moves it
for you as long as it knows what is on screen.

**A chat on screen.** `chat open` it once however many windows show it,
`chat close` it when the last one goes, and call `chat view` with the newest
message on screen on every scroll and arrival. While the app is active that
reads the chat up to there - the watermark, plus a `<displayed>` to a 1:1
peer - and keeps [notify](#notify) quiet for it. Report focus with `app
setActive`, so a chat left on screen behind another window isn't read.
Messages below the fold stay unread until scrolled to.

**A chat not on screen.** To mark one read from a menu, call `message
markOwnRead` with its newest timestamp, plus `markDisplayed` in a 1:1. Both
are safe to repeat.

**The chat list.** Each `chatlist` entry carries `unread` and
`unread_mentions`, and a `chatlist <Item>` follows every watermark move, so
the list needs no calls of its own.

**Alerts.** Show each `notify <Notify>`; the backend has already left out
chats being looked at, muted ones and messages already read. Dismiss it when
`message <OwnRead>` for its chat moves past its `timestamp` - that covers
reads on your other devices too.

## Attachments

A message with attachments has `content.type: "media"`, carrying an
`attachments` list and a `caption` (see the `message` type). Render each
attachment `type: "image"` inline and `type: "file"` as a chip; more than one
entry is a grouped/album message under a single `caption`. `caption` is the
text to show: senders copy the share URL into the body for clients that don't
understand OOB, so `caption` is `""` when the body was nothing but that URL, and
the body verbatim otherwise. `path`, `size` and `mime` are only set on outgoing
attachments; on received ones they're `""`, `null` (`""` in Tcl) and `""`.

`url` is wire data and `path` is a local file, and the two never stand in for
one another: a received `url` is fetched, never opened off disk, and one we
cannot fetch is not an attachment at all - the message arrives as plain text.
`name` is the sender's filename with control characters and bidi overrides
stripped, so it is safe to display; `url` keeps the wire bytes.

**Sending.** `message sendFile` is optimistic: the message shows up right
away via `<New>` with `server_status: "uploading"`, the attachment's `path`
set to the local file and its `url` still empty. The backend uploads the file,
sends the real message with the public URL, and confirmation carries on like
any other send. A failed upload marks the row `failed` with `fail_reason:
"upload"` - so does one a restart cut off, since a PUT can't resume - and
`message retryUpload` runs it again from the `path` it recorded. Each
upload transition rides `message <Status>` as a `server_status` change:
`uploading -> pending` on success, `uploading -> failed` on error, and
`failed -> uploading` on retry. Byte-level progress and terminal state come
on `file <Update>` (keyed by the message `timestamp`), which is also where
the attachment's public URL lands - the row keeps its `path`, so it still
renders from the local file, and gains the `url` that anyone else needs. In an
OMEMO chat the file is AES-256-GCM
encrypted before the PUT and the `url` is an `aesgcm://` URL (XEP-0454);
`file download` grabs the `https://` version and decrypts it for you.

**Downloading.** `file download` pulls the file into the data dir. Progress
and the final state come on `file <Update>`: the last event carries
`localpath` on `done`, or an `error` on `failed` - the server refused or the
network died (`http error`), an unsupported URL scheme, a file that couldn't
be read or decrypted. With local storage encrypted, an OMEMO attachment stays
encrypted in the data dir and `localpath` names a decrypted copy kept in
`/dev/shm` (or the cache dir) instead. A transfer the user cancelled or the autofetch settings
held back ends `idle` instead. No thumbnail is made: a client that shows
images inline scales `localpath` itself.

**Autofetch.** Two settings bound what gets pulled without the user asking.
`attachment_autofetch` is `contacts` (a roster subscription of `to`, `from` or
`both`), `everyone`, or `never`; a room JID is not a roster entry, so under
`contacts` group chats don't autofetch. It defaults to `contacts` because a
fetch is an outbound request to a host the sender chose: on `everyone` a
stranger's message reports the user's IP on arrival.
`attachment_autofetch_max` is a byte cap, default `5242880`, `0` for
unlimited, checked against `Content-Length` and again against the bytes
actually arriving. Both apply only to `download` calls made with `auto`, so a
held-back image still loads on click - it ends `idle`, not `failed`, since
nothing went wrong. Leave `auto` off when redrawing the user's own sends:
upload swaps the local path for the public URL, making a reload from history a
real fetch.

## OMEMO

OMEMO 0.3 (XEP-0384) for 1:1 chats, and for group chats that allow it (see
[Group chats](#group-chats)). Three concepts:

**Trust** - each device has one of four states: `undecided` (where new
devices start), `trusted` and `untrusted` (set by the user, and freely
swappable), and `compromised` (set by the system when an identity key
rotates; it sticks). The account-wide `blindTrust` decides whether
`undecided` devices can be sent to: on (the default), new devices are
included as recipients (TOFU/BTBV); off, they're left out until you've
`trusted` them yourself.

**Per-chat toggle** - every 1:1 chat has an OMEMO on/off switch, on by
default (off for a room's private chat, whose keys can't be found). It doesn't check whether the peer can actually do OMEMO; sending
to one who can't fails outright instead of quietly downgrading. The chat
with yourself is the exception: it is keyed for your other devices, and
with none it still goes out encrypted, keyed for no one.

**Intent vs outcome** - a row carries `encryption` (the intent: `"omemo"`
or `""`), and on a `failed` row, `fail_reason`: `"encrypt"`,
`"delivery"`, `"upload"` or `"too-large"` (see above). Check it to tell
"couldn't encrypt" apart from a delivery failure. The send path never quietly
falls back to cleartext; the
only way down is an explicit `message resend {plaintext: 1}`, which
rewrites the one row and leaves the chat toggle alone. That rewrite rides
the row's `<Status>` as an `encryption` field, so a displayed message never
keeps a lock it no longer has.

**Message origin** - a decrypted row carries `sender_fp`, the fingerprint of
the peer device that sent it. Join it against `trustList` for that device's id
and trust state. Messages are decrypted and stored whatever the sender's trust;
flag an `untrusted` or `compromised` sender at draw time, so a later trust
change applies to old messages too. A `compromised` device's messages arrive as
an "identity key changed" placeholder rather than their text.

### Group chats

A room can use OMEMO when it is members-only and non-anonymous: only then
does the room tell everyone its members' real JIDs, which is what the keys
are made for. `roomStatus` says whether a room qualifies (`eligible`, and
`reasons` when not: `unknown`, `not_members_only`, `anonymous`), whether it
is on, and who a message to it is keyed for. `offered` is whether there is
a switch to show: the room qualifies, or it is on and can be turned off.

- **Off by default.** A room is encrypted only after `setEnabled` turns it
  on, which a room that doesn't qualify refuses. A room that stops
  qualifying while on stays on: its sends fail (`fail_reason: "encrypt"`)
  rather than going out in the clear.
- **Every member or nobody.** A message is keyed for every device of every
  member - everyone the room gives an owner, admin or member affiliation,
  in the room or not - and for your own other devices. A member none of
  whose devices can be used (no OMEMO, every device untrusted) fails the
  send, and `<MembersUnreachable>` names them with a `reason`
  (`no_devices`, `no_usable_device`); the last such list stays in
  `roomStatus` as `unreachable` until a send goes through. Show who, and
  offer to review their keys or turn encryption off. A member whose keys
  are still being fetched holds the send until they arrive.
- **Who wrote it.** A room message is decrypted as the member the room
  says sent it: by their presence, or in the archive by their occupant-id,
  which tacky keeps so history from someone who has left still opens. A
  message the room gives no sender for, and that none of the sessions
  tacky holds opens, is stored as a placeholder and told as
  `<DecryptFailed>` with `room`.
- **Keys.** `trustList` with the room lists every member's devices, each
  row naming its member in `jid`; `<TrustList>` for the room follows them.
  Blind trust works as in 1:1 chats.
- **Who needs attention.** `members` gives each member's keys counted by
  trust, devices no longer in their list left out, with `attention` when
  they stop or would hold up a send or a key of theirs changed: they
  stopped the last one (`reason`), none of their devices would be keyed
  for (none known, all distrusted, or new ones blind trust does not
  cover), or one is compromised. Those come first; `attention` counts
  them. `<RoomStatus>` follows trust changes and blind trust, and the same
  keys ride on each member in [`muc people`](#muc).

A room's private messages (`room@service/nick`) are not encrypted.

**UI.** For the encryption switch, read `isEnabled` for the peer before you
draw it, subscribe to `omemo <Enabled>` to follow it after that, and call
`setEnabled` when it's toggled. Read rather than assume: the default is on,
so a switch drawn before the answer arrives can show a padlock over a chat
that is going out in the clear. For the key panel, subscribe
to `omemo <TrustList>`, draw the rows, and call `trust` with a row's
`device` when it's clicked (and, in a room's panel, the row's `jid`). For a failed message, `fail_reason: "encrypt"`
leads with "resend as plaintext" (`message resend {plaintext: 1}`), while
"keys arrived, retry" is a plain `message resend`. `fail_reason:
"delivery"` offers only the plain `message resend` - the encryption was
never the problem - and `fail_reason: "upload"` offers `message retryUpload`. `<FingerprintChanged>`
(a peer's identity key rotated, so trust auto-drops to compromised) is
per-peer, and a single handler subscribed by `acc` covers every chat at
once.

## Voice and video calls

Audio over Jingle (XEP-0166/0167/0176), set up through Jingle Message
Initiation (XEP-0353). Video rides the same PeerConnection as a second
track, offered by naming `video: true` on `start`, or answered symmetrically
when the peer offered it.

There are two ways to run the media half of a call. Signaling is tacky's in
both: Jingle, JMI, call state and the SDP translation stay here, so `calls`
reads the same either way.

**Tacky runs the media.** A [media](#media) backend, one for the whole
process and chosen at startup, owns ICE/DTLS/RTP and the mic, speaker and
camera:

- **rtc** - libdatachannel for the transport, rtc-ma (miniaudio) for the
  audio devices and Opus, rtc-mv for the camera and VP8. Linked into every
  native build, so there it is the backend that cannot go missing. Opus and VP8 are all
  it speaks, and it has no camera on Windows:
  there it receives video but sends none.
- **webrtc** - libwebrtc, whole, in `libtacky_webrtc.so` (`.dll` on
  Windows), loaded at startup and only present in builds that ship that
  library. Brings libwebrtc's codecs, echo cancellation and ICE.

How one is picked is in [media](#media). Both produce the same events and the
same frame streams; a frontend needs no per-backend code beyond `capabilities`.

**The frontend runs the media.** The `host` backend, for platforms whose
WebRTC stack belongs to the host and cannot be linked in - a browser's
`RTCPeerConnection`, `WebRTC.xcframework`, Android's `org.webrtc`. Tacky
creates no peer connection of its own. Every step it would have taken leaves
as a `media <HostCommand>` event, and the frontend answers with
`media hostEvent` as its own stack produces a description, a candidate, a
state or a track. Tacky turns those into Jingle and back exactly as it does
for its own backends, so call state and every `calls` event are unchanged.
There the devices and the rendering are the frontend's: enumeration comes
back empty, and video arrives as its own track id rather than a frame stream.
The two message shapes are in [The host backend](#the-host-backend).

Two things are the host stack's to get right. When answering it gets no
`addTrack` and sends on the offer's m-lines, so make them sendrecv (a browser
leaves them recvonly) before the answering `setLocalDescription`; then put the
mic or camera on the m-line the following `attachAudio` or `attachVideoSender`
names, and treat that track as yours for `setVideoEnabled` and mute. And share
one camera between every sender and a group call's `openPreview` self-view, a
track clone per sender, so a pc closing stops only its own clone and the
preview never freezes.

The signalling below is tacky's own and does not change with the backend.
What a backend can vary is whether it enumerates devices at all - see
`media capabilities` - and, on `host`, how video reaches the screen: the
frame streams described further down are the other backends'; on `host`
video is the frontend's own track.

Caller: `calls start` sends a JMI `propose` to the bare JID and emits
`<Outgoing>`. A peer device answering `ringing` gives you `<Ringing>`.
Their `proceed` kicks off fetching ICE servers, building the offer, sending
`session-initiate`, and trickling candidates; the peer's `session-accept`
applies the answer, media connects, and you get `<Active>`.

Callee: an incoming `propose` gives you `<Incoming>` (with `video: true` if
the caller offered it) and auto-replies `ringing`. A `propose` from the
occupant of a room you are in or have bookmarked is dropped unanswered:
anyone in a public room could otherwise ring you to learn you are online. `calls accept` sends
`proceed`, then media setup waits for `session-initiate`, which applies the
offer and sends `session-accept`. An unanswered ring ends in `<Ended>` too:
retracted, taken by another of your devices, or rejected with `timeout` after
a minute. An outgoing call is retracted after the same minute.

A `propose` arriving while the account has any other call, group sessions
included, is rejected `busy` without ringing and comes out as `<Missed>`.

Calls are verified the way Conversations does it: each side sends its DTLS
fingerprint OMEMO-encrypted, so a server can't swap in its own certificate.
`<Verified>` gives the result before `<Active>` and again whenever it changes;
show the call as secure only while it says `verified`. A fingerprint that
should have come encrypted and didn't, or that comes from an untrusted key,
fails the call rather than downgrading it.

Either side ends the call with `calls hangup`. Until the callee has answered,
the caller retracts over JMI instead of terminating; after that it's a Jingle
`session-terminate`. Both land as `<Ended>`. To turn down a ringing call use
`calls reject` (`<Ended>` reason `declined`); `hangup` there ends it as
`hangup`. `calls reject` on a call you placed yourself retracts it as
`hangup` would. Video, if either side had it up,
ends with the call - there's no partial teardown of just the video half.

Audio is decoded and played by the backend directly; the frontend never
sees an audio sample. Video is decoded by the backend too, but frames are
handed to the frontend rather than rendered by the backend itself: each of
`<VideoTrack>` (remote) and `<VideoPreview>` (local camera) names a stream
the frontend connects to - a Unix socket path, or a named pipe
(`\\.\pipe\tv-...`) on Windows, that only the user running tacky can open. It
works the same whether the frontend is in-process or a separate one talking
over `--backend process`.

A stream serves one reader. A new connection replaces the current one, and
first receives the last frame sent, so a frontend that reopens a view shows
video straight away. The backend never waits for the reader: one that falls
behind skips to the newest frame. The stream ends with the video, and the
socket file goes with it.

Each frame is a 40-byte little-endian header followed by the pixels:

| offset | type | field |
|---|---|---|
| 0 | u32 | magic, `TVF1` |
| 4 | u16 | version, 1 |
| 6 | u16 | header length; skip anything past the 40 bytes listed here |
| 8 | u32 | format, `I420` as a FourCC |
| 12 | u32 | flags; bit 0 = keyframe |
| 16 | u32 | width |
| 20 | u32 | height |
| 24 | u32 | payload length |
| 28 | u32 | reserved, 0 |
| 32 | i64 | presentation time, ns |

The payload is the Y plane (`width` x `height`), then U, then V (each
`(width+1)/2` x `(height+1)/2`), tightly packed. Frames can change size at
any time. There is no resync point, so a header that doesn't parse means
the connection is unusable: close it and reconnect.

Reconnecting without stream resumption ends every live call with `<Ended>`,
because the peer cannot route anything back to a sid from the dead session.
A resumed stream keeps its calls, and so does a plain disconnection: the
media path is peer to peer and can outlive the outage.

Call state lives only in the backend, and only as events, so a client that
restarted has none of it. `calls list` per account rebuilds it: ask on
`conn <State>` reaching `connected`, which a client sees both when a stream
comes up and when it reattaches to a backend that stayed up. On a fresh stream
every sid has already been ended and forgotten before the backend reads the
request, so the answer is authoritative: a call it does not name is over.

## Group calls

tacky does mesh group calls, as Dino does: a Jingle session between every
pair, so a handful of people is the practical limit.

A hosted call lives in a hidden MUC made for it: not bookmarked, archived or
listed, its messages dropped; `muc isHidden` tells it apart. Calls held in a
group chat itself, as Movim's are, can be joined too.

Using the API:

1. `groupcall start` from a chat, or `groupcall join` an invite
   (`<Invited>` is when to ring).
2. Draw it from `groupcall <State>`; `groupcall get` on startup.
3. `groupcall leave`; the `ended` state says you are out.

Dino joins any call room under a random nick, so inviting a Dino user to a
call held in a group chat renames them there.
