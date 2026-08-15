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
  - [setting](#setting)
  - [chatlist](#chatlist)
  - [bookmarks](#bookmarks)
  - [roster](#roster)
  - [presence](#presence)
  - [caps](#caps)
  - [message](#message)
  - [notify](#notify)
  - [mam](#mam)
  - [omemo](#omemo)
  - [avatar](#avatar)
  - [nick](#nick)
  - [file](#file)
  - [calls](#calls)
  - [audio](#audio)
- [Guides](#guides)
  - [Accounts and sign-in](#accounts-and-sign-in)
  - [The chat window](#the-chat-window)
  - [Attachments](#attachments)
  - [OMEMO](#omemo-1)
  - [Voice calls](#voice-calls)

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
  (e.g. `"-transient", "0"`), or NULL; pass `-config-dir`, `-data-dir` and
  `-cache-dir` to override the defaults in [Storage layout](#storage-layout).
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

Three roots, set with `-config-dir`, `-data-dir` and `-cache-dir`; each falls
back to a platform default. All three are created mode 0700 on platforms with
file modes. The XDG variables below fall back to `~/.config`, `~/.local/share`
and `~/.cache`.

|        | Linux                    | macOS                                 | Windows                      |
| ------ | ------------------------ | ------------------------------------- | ---------------------------- |
| config | `$XDG_CONFIG_HOME/tacky` | `~/Library/Application Support/tacky` | `%APPDATA%\tacky`            |
| data   | `$XDG_DATA_HOME/tacky`   | `~/Library/Application Support/tacky` | `%LOCALAPPDATA%\tacky\data`  |
| cache  | `$XDG_CACHE_HOME/tacky`  | `~/Library/Caches/tacky`              | `%LOCALAPPDATA%\tacky\cache` |

config holds `accounts.db`. data holds one `<jid>.db` per account - its state
and message history with downloaded attachments. cache holds only what can
be regenerated: thumbnails and upload staging.

`-transient yes` keeps every database in RAM and puts attachments in a
temporary directory that is removed on shutdown.

## Requests, replies, events

A request is a JSON array: a module, a method, an object of keyword
arguments, and an optional token.

    ["module", "method", {"arg1": "val1", ...}]
    ["module", "method", {"arg1": "val1", ...}, token]

The token (any integer) asks for a reply tagged with that same token.
Leave it off and the request is fire-and-forget: no reply, and any error
is dropped. Argument values go through untouched - the backend is untyped,
so `5` and `"5"` mean the same thing on the way in. The exception is an
argument typed `base64`: it is decoded to bytes before dispatch, and a bad
encoding comes back as an error reply.

    ["account", "add", {"acc": "user@example.com", "password": "secret"}]
    ["account", "list", {}, 1]

A request with a token gets at most one reply: a result if it worked, an
error if it didn't, or nothing at all if you cancelled it. Not every
method replies - `message send` does its work through the event stream and
never answers the token.

A request that needs the server waits for one minute of connected time
before giving up with an error. The clock stops while the account is
offline, so a request left pending across a disconnect still completes on
reconnect.

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

## account

    account list {enabled?: bool}                   -> [string]   account bare JIDs
    account exists {acc: string}                    -> bool
    account get {acc: string, field?: string}       -> account_fields  (or one field's value)
    account add {acc: string, password?: string, username?: string, domain?: string}
    account set {acc: string, password?: string, username?: string, domain?: string, enabled?: bool}
    account remove {acc: string}
    account enable {acc: string}
    account disable {acc: string}
    account changePassword {acc: string, password: string}   -> ""

    account_fields = {username: string, domain: string, password: string,
                      resource: string, enabled: bool}

`add` creates or updates. On create, `username` and `domain` default to
the pieces of the JID. `enable` saves the flag and connects; `disable`
disconnects and saves. `remove` disconnects, then deletes the account row
and its per-account database. Downloaded attachments are shared across
accounts and are left alone. `changePassword` changes the password
on the server (XEP-0077) and, if that works, updates the stored one - the
reply is `""` on success or an `["error", ...]`. See
[Accounts and sign-in](#accounts-and-sign-in).

Events:

    account <Added>    {acc: string}
    account <Enabled>  {acc: string}
    account <Disabled> {acc: string}
    account <Removed>  {acc: string}

`<Added>`, `<Removed>`, and `<Enabled>` fire once per actual change -
enabling an account that's already enabled does nothing and emits nothing.
`<Disabled>` fires on every `disable` call, so treat it as idempotent.

## register

In-band registration (XEP-0077) over a throwaway connection, kept separate
from the account store. Each session is identified by a `token` (any unique
string).

    register connect {host: string, port?: int, token: string}
    register form {token: string}                 -> form
    register media {token: string, var: string}   -> base64
    register submit {token: string, values: {*: string}}
    register cancel {token: string}

    form       = {fields: [form_field]}
    form_field = {var: string, type: string, label: string, required: bool,
                  value: [string], options: [{label: string, value: string}],
                  media: {cid: string, type: string}}

Events:

    register <Form>       {token: string}           form ready to fetch
    register <MediaReady> {token: string, var: string}   CAPTCHA image bytes for a field
    register <Success>    {token: string}
    register <Error>      {token: string, message: string}

See [Accounts and sign-in](#accounts-and-sign-in) for the flow.

## conn

The per-account connection lifecycle. Events only, no methods. `<State>`
and `<ConnError>` are pullable (use Tcl `observe`, or just track the last
event you saw).

    conn <State>     {acc: string, state: string}     every transition
    conn <Ready>     {acc: string, resumed: bool}      fully online
    conn <ConnError> {acc: string, message: string}    transport failure
    conn <AuthError> {acc: string, message: string}    credentials rejected

`state` is one of `disconnected`/`connecting`/`authenticating`/`binding`/
`connected`/`waiting`. A transport failure retries forever with backoff:
`<ConnError>` gives the reason, `state: "waiting"` is the gap between
tries, and `connected` clears it. `<AuthError>` is the end of the road -
the backend stops until you re-enable the account.

## setting

A global key/value store - not tied to any account.

    setting get {key: string}                  -> string   stored value ("" if unset)
    setting set {key: string, value: string}
    setting list {}                            -> [string]  known keys

Event:

    setting <Changed> {key: string, value: string}

## chatlist

    chatlist get {}   -> [chat_entry]

The entire chat list as one flat, unordered array: the roster, bookmarked
rooms, and any chat that has message history, all merged. No querying or
sorting.

    chat_entry = {jid: string, name: string, source: string,
                  groupchat: bool, autojoin: bool, last_activity: int,
                  unread: int, unread_mentions: int}

`jid` is the chat JID, used verbatim when you open it: `contact@host` for
1:1, `room@muc?join` for a group, `room@muc/nick` for a MUC private
message. `groupchat` is `true` when the jid has `?join`. `source` is
`roster` (a roster contact, bare JID), `bookmarks` (a bookmarked room), or
`free` (came from chat history, with no roster or bookmark entry). `name`
can be `""` (always is for `free`). `last_activity` is the last message
time in microseconds, or `0`. `unread` counts the other side's messages past
your read watermark (see [Read state](#read-state)); your own messages and
retracted tombstones never count. `unread_mentions` is how many of those
named you (see [notify](#notify)), and is always `0` outside group chats.

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
change, or room_state change). `<Remove>` deletes - except a removed roster contact
that still has history, which comes back as an `<Item>` with
`source: "free"`. `<Changed>` means a whole source was swapped out (first
fetch, reconnect); refetch with `get`. The module funnels the roster,
bookmarks, chats, and room_state signals into just these three events, so
you only need to subscribe to `chatlist`. The raw `bookmarks <Changed>`
and `bookmarks <RoomState>` signals are still there, but a frontend
normally sticks with the funneled ones.

## bookmarks

    bookmarks item {jid: string, name?: string, autojoin?: bool,
                    nick?: string, password?: string}
    bookmarks leave {jid: string}
    bookmarks remove {jid: string}
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
retracts it from the server. `forceJoin` re-sends the join with the stored nick
and password without touching autojoin, for a room dropped underneath you (an
IRC gateway going down). `nick` renames you in one room and stores it;
`defaultNick` is the account-wide fallback for new bookmarks, itself falling
back to the JID's localpart. `autojoin` reads one room's flag, for a menu that
has to show its state before it opens.

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
`groups` keeps the stored groups, passing `[]` clears them. `add` is `item`
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
advertises no caps.

Event:

    presence <Changed> {acc: string, jid?: string, action?: string}

`jid` names the contact whose presence moved. On disconnect it is
`action: "clear"` with no `jid`: all presence is dropped, and re-received on the
next connect.

## caps

    caps softwareVersion {to: string} -> {name: string, version: string,
                                          os: string, error: bool,
                                          error_text: string}

XEP-0092: what software an entity runs, self-reported as a free-text name and
version. `to` is a full JID - a bare one answers for the account itself,
omitting it asks your own server. An entity that will not answer comes back as
`error: true` with a reason in `error_text`, not as an `["error", ...]` reply.

One round trip per resource, so it is a request rather than something the
backend collects. What a resource supports needs no call: `presence resources`
carries it in `client`.

## message

    message send {chat: string, body: string, reply_to_ts?: int}
    message sendFile {chat: string, path: string}
    message history {chat: string, limit?: int, before?: int, after?: int, tag?: string}           -> [message]
    message goto {chat: string, date: int, source: "local" | "remote", limit?: int, tag?: string}  -> goto_result
    message gotoReply {chat: string, reply_id: string, reply_to?: string, tag?: string}            -> goto_result
    message search {chat?: string, query: string, source?: "local" | "remote" | "both", limit?: int, before?: string} -> search_result
    message edit {chat: string, timestamp: int, body: string}
    message retract {chat: string, timestamp: int}
    message moderate {chat: string, timestamp: int, reason?: string}
    message react {chat: string, timestamp: int, emoji: string}
    message reactClear {chat: string, timestamp: int}
    message resend {chat: string, timestamp: int, plaintext?: bool}
    message retryUpload {chat: string, timestamp: int}
    message cancel {tag: string}
    message rawxml {chat: string, timestamp: int} -> string  raw stanza (debug)
    message markDisplayed {chat: string, timestamp: int}
    message markOwnRead {chat: string, timestamp: int}
    message ownRead {chat: string} -> {timestamp: int, unread: int}

    message = {timestamp: int, chat_jid: string, from_jid: string,
               is_outgoing: bool,
               server_status: string, remote_status: string,
               encryption: string, sender_fp: string, fail_reason: string,
               edited: bool, edited_ts: int, retracted: bool,
               content?: content,
               reply_id?: string, reply_to?: string,
               reply_author_jid?: string, reply_body?: string,
               reactions?: {*: {reactors: [string], mine: bool}}}

    content = {type: "text",  body: string, formatting?: formatting, matches?: matches}
            | {type: "media", attachments: [attachment], caption: string, formatting?: formatting, matches?: matches}

    formatting = [{type: span_type, offset: int, length: int}]
    span_type  = "bold" | "italic" | "overstrike" | "monospace"
               | "preformatted" | "quote"
    matches    = [{offset: int, length: int}]
    attachment = {url: string, type: "image" | "file", name: string, size: int, mime: string}

    goto_result   = {messages: [message], anchor: int, bounded_before: bool, bounded_after: bool}
    search_result = {messages: [message], complete: bool, last: string}

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
  `history` are exclusive cursors.
- `server_status` tracks the hop to your own server: `""` (it has the
  message), `pending`, `uploading`, or `failed`.
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
  `"image"` (render inline) or `"file"` (a download chip). Deletion is a
  message-level state rather than a content type, so future kinds like `call`
  or `system` extend this union - switch on `type` and tolerate unknown ones.
- `formatting` (XEP-0393 styling spans) indexes into whichever of
  `body`/`caption` the variant carries, with the styling characters already
  removed from that string. Spans may overlap: two styles over the same run
  are two separate single-type entries, combined by the renderer.
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
    message <Tail>        {jid: string, timestamp: int}

`<Status>`, `<Confirmed>`, `<Reactions>`, `<Edited>` and `<Retracted>` each
change a message already on screen, found by `timestamp` - drop one whose
target isn't displayed. `<Status>` carries only the fields that changed, plus
`encryption` when a resend rewrote the row to cleartext. `<Confirmed>` always
carries `newtimestamp` and is the only event that clears `server_status` to
`""`, and the only one that can move a message's slot. What to do with each is
in [The chat window](#the-chat-window).

### Read state

Two independent directions. `remote_status` on a message is the peer's read
state of something you sent. The read watermark is the reverse: how far you have
read a chat. It is one timestamp per chat, not a per-message flag, so backfilled
history landing behind it does not become unread.

`markOwnRead` sets it, forward-only - an older-or-equal stamp is ignored, so it
is safe to call on every focus and scroll. It is local state and applies to
group chats; `markDisplayed` is the separate wire half (a XEP-0333 `<displayed>`,
1:1 only). Call both when the user reads a 1:1 chat. The watermark also advances
on its own when you send a message from any of your devices, and when another
device's `<displayed>` marker reaches this one.

`<OwnRead>` fires on every move, from any of those sources. `ownRead` gives one
chat's watermark and unread count; each `chatlist` entry carries its own
`unread`, so a chat list needs no extra call. Which of those are worth
interrupting the user over is [notify](#notify)'s job.

## notify

    notify get {chat: string} -> {muted: bool, mentions: bool}
    notify set {chat: string, muted?: bool, mentions?: bool}

Events:

    notify <Notify>   {jid: string, timestamp: int, nick: string, body: string,
                       unread: int, mention: bool}
    notify <Settings> {jid: string, muted: bool, mentions: bool}

`<Notify>` means this message is worth telling the user about even if they are
not looking at the app; how to tell them is the frontend's job.

- `nick` is who sent it, resolved the way `author get` does.
- `body` is the full message text - trimming it for display is the frontend's
  job. For an attachment it is the caption, empty when there was none.
- `unread` is the chat's total at that moment, so a burst can collapse into a
  single "Name (12)" alert.
- `mention` marks a group-chat message that named you.

The gate is the read watermark, not a "user is looking at this chat" call:
a message alerts only while it sits past the watermark, and the alert is held
for `notify_delay_ms` (default `500`) first, so a chat the user is reading
marks itself read via `markOwnRead` and never alerts. Dismiss a shown alert
when `message <OwnRead>` moves past it - that covers reads on your other
devices too.

Messages that arrived while you were offline alert once catch-up settles,
capped at 10 per chat per catch-up, with `unread` still reporting the true
total. `notify_floor` is stamped at the account's first connection, so nothing
older ever alerts and the opening archive fetch is silent. Both are `setting`
keys.

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
- `metadata` - the oldest and newest entries; every value `""` for an empty
  archive, plus an `error: true` key on an IQ error.
- `formfields` - the filter fields the archive advertises, empty on error. A
  fulltext field among them is what `fulltextSupported` checks for.

## omemo

    omemo device_id {}                -> int
    omemo account_jid {}              -> string
    omemo own_fingerprint {}          -> string    hex identity-key fingerprint
    omemo devicelist {jid: string}    -> [int]      raw PEP devicelist cache
    omemo trustList {jid: string}     -> [omemo_trust]
    omemo blindTrust {}               -> bool
    omemo trust {jid: string, device: int, state: string}      validates the transition
    omemo setBlindTrust {value: bool}            -> bool   emits <BlindTrust>
    omemo setEnabled {jid: string, value: bool}  -> bool   emits <Enabled>
    omemo prepareChat {jid: string}   -> ""    warm devicelist + bundles (replies on completion)

    omemo_trust = {device: int, trust: string, active: bool, fingerprint: string}

`trust` moves freely between `undecided`, `trusted`, and `untrusted`. Only
the system can move a device to `compromised`, and nothing moves it back. A
bad transition errors with `OMEMO TRUST_TRANSITION`; a `(jid, device)` pair
that doesn't exist errors with `OMEMO TRUST_NO_DEVICE`. `device` is an
opaque row handle from `trustList` - don't show it to the user. See
[OMEMO](#omemo-1).

Events:

    omemo <TrustList>          {jid: string, trustList: [omemo_trust]}   pullable
    omemo <BlindTrust>         {value: bool}                             pullable
    omemo <Enabled>            {jid: string, value: bool}                pullable
    omemo <TrustChanged>       {jid: string, device: int, state: string}
    omemo <FingerprintChanged> {jid: string, device: int, fingerprint: string}
    omemo <DecryptFailed>      {jid: string, device: int, reason: string}

## avatar

    avatar metadata {jid: string}   -> avatar_meta   ({} if none)
    avatar data {hash: string}      -> base64        ("" if not cached)
    avatar visible {jid: string}
    avatar invisible {jid: string}
    avatar publish {data: base64, type?: string, width?: int, height?: int}  -> ""
    avatar disable {}   -> ""
    avatar cancel {tag: string}
    avatar refresh {jid: string}
    avatar inject {jid: string, data: base64, type?: string, width?: int, height?: int}  -> string

    avatar_meta = {hash: string, type: string, bytes: int, width: int, height: int}

The full-size image is content-addressed by hash: `metadata` maps a JID to its
current hash, and `data` gives you the bytes as they were published. The
backend fetches bytes for JIDs you've marked `visible`. The marks are a set,
not counted references: a repeat `visible` does nothing, one `invisible` clears
the mark, and the set outlives a dropped connection. `visible` also re-emits
`<Update>` for an already-cached avatar, so listening is enough. `refresh`
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

    avatar <Update>   {jid: string, hash: string}      changed, arrived, removed (hash ""), or first `visible`
    avatar <Progress> {acc: string, message: string}   during your own publish

## nick

    nick get {jid: string}                  -> string   cached nick ("" if none)
    nick set {nick: string}                 -> ""       publish + vcard + bookmarks
    nick publish {nick: string}             -> ""       PEP only
    nick fetch {jid: string}                            refresh from the server

XEP-0172 user nicknames over PEP. `get` is a local cache read; `fetch`
pulls a JID's published nick and caches it, and `set` publishes your own
(PEP node, vcard-temp, and every bookmark's nick unless you pass
`bookmarks: skip`, in which case only the default nick is updated).
`publish` is the PEP-only slice of `set`.

Event:

    nick <Changed> {jid: string}   a JID's cached nick changed; re-read with `nick get`

## file

    file download {acc: string, url: string, auto?: bool, from?: string,
                   thumbmax?: int}              -> string  local path ("" on failure)
    file cancel {acc: string, id: int}
    file cancel {acc: string, url: string}
    file uncache {acc: string, url: string}

`download` pulls a file into the data dir. An already-downloaded file or an
already-local path comes back immediately, and two downloads of the same URL
collapse into one. It handles the `aesgcm://` scheme (XEP-0454) for you.
`cancel` aborts a transfer in either direction - it ends `idle`. Cancel an
upload by `id`, a download by `url` - which stops the coalesced fetch for every
caller waiting on it. `uncache` deletes the downloaded file and its thumbnail.
See [Attachments](#attachments).

Set `auto` for a fetch you start yourself, such as rendering an inline image,
and pass the message's sender as `from`. Those two subject it to the autofetch
policy and size cap; without them a download always proceeds. A fetch the
sender policy declines never opens a socket; one over the size cap is dropped
as the bytes arrive. Either ends `idle`.

Event:

    file <Update> {id: int, direction: string, state: string,
                   loaded: int, total: int, url: string,
                   localpath: string, thumbpath: string, error: string}

`direction` is `upload` or `download`; `state` is `active`, `done`, `failed`
or `idle`. `idle` is the neutral end - nothing transferring, nothing on disk,
a fetch will start it - and covers a declined autofetch, a size-capped abort
and a cancel. `error` is only ever set on `failed`. For an upload, `id` is the
message timestamp; for a download, match on `url`.

## calls

    calls start {to: string}                                       -> string   sid
    calls accept {sid: string}
    calls reject {sid: string, reason?: string}                    reason default: decline
    calls hangup {sid: string, reason?: string}                    reason default: success
    calls setDevices {sid: string, input?: string, output?: string}

`start` rings the peer. Take the session id from `<Outgoing>`.
`setDevices` overrides the mic and speaker for a single call; an empty id means the system default. See
[Voice calls](#voice-calls).

Events:

    calls <Outgoing> {sid: string, to: string}
    calls <Incoming> {sid: string, from: string}
    calls <Ringing>  {sid: string}
    calls <Active>   {sid: string}
    calls <Ended>    {sid: string}
    calls <Failed>   {sid: string, reason: string}
    calls <Warning>  {sid: string, reason: string}

A call ends on exactly one of `<Ended>` or `<Failed>`. `<Warning>` is just
informational and doesn't end anything.

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

Events:

    audio <PreferredDevice> {kind: string, id: string}       preferred device changed
    audio <Volume>          {kind: string, volume: double}   gain changed

# Guides

## Accounts and sign-in

**Startup.** The backend connects every enabled account at init; there is no
connect call. Run `account list {enabled: 1}` and open the main UI if it
returns anything, setup if it doesn't.

**Sign-in.** Creating the account is the credential check. Subscribe to
`conn <Ready>`, `<AuthError>` and `<ConnError>` for the account, then call
`account add` and `account enable`. Keep the account on `<Ready>`. On failure,
show the `message` and call `account remove`: `account add` stores the account
before anything validates it, so an abandoned sign-in leaves a row behind.
`<ConnError>` is retried by the backend; `<AuthError>` is terminal.

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

Requests carry a `tag`, and cancelling by tag is what keeps a result that
outlived its cursor from being applied. The pagination cursors are just the
first and last timestamps in the window, passed as `before` and `after`.

**Paging.** `message history` with no cursor gives you the newest page.
`before` (exclusive) pages older, `after` (exclusive) pages newer, always
oldest-first, capped at `limit` (default 50). It's local-first: it returns
local rows right away and reaches for the server (MAM) only when both hold: a
cursor anchors the fill, and the local read came up short of `limit`. A cursorless
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
A `reply_to_ts` naming a row that isn't stored sends as an ordinary message
rather than failing.

A message that is a reply carries four fields. `reply_id` is the wire id it
answers and `reply_to` the JID it was addressed to, both as they appeared on
the wire. `reply_author_jid` is that author normalized the way `from_jid` is -
an occupant JID in a room, a bare JID in a 1:1 - so it resolves through
`author get` like any other author. `reply_body` is a shortened preview of the
target, for rendering the quote inline; it is absent when the target isn't in
the store. Jump to it by passing `reply_id` and `reply_to` to `gotoReply`,
which resolves the id locally and then behaves like `goto`. An uncached target comes back with no
`messages` and an empty `anchor` - there is no fetch-by-stanza-id, so a target
beyond a hole is not reachable this way.

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
`message` row to redraw in place for a content edit. `<Retracted>` flips the
row to a tombstone in place - it carries only `timestamp`, so redraw the
placeholder from the header you already hold. `<Confirmed>` acknowledges a
pending send: update its checkmark in place when `newtimestamp == timestamp`,
or rekey to `newtimestamp` and re-sort when the server relocated it - the
only one that shifts a message's slot.

**Causing those updates.** Five calls, all naming their target by `timestamp`
and all silently doing nothing when it isn't stored. `edit` (XEP-0308) sends a
correction of one of your own messages and swaps the stored body immediately,
so `<Edited>` arrives without waiting for the echo. `react` (XEP-0444) toggles
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
is normal - pass `onerror` to hear about it, since success is silent.

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
stored; a row still pending afterwards is re-sent if it falls inside the
span catchup covered (the server demonstrably never got it), and marked
`failed` with `fail_reason: "delivery"` if it predates that span, where
the archive can no longer say either way.

**Search.** `message search` takes a `source`, mirroring `goto`. `source:
local` (the default) runs over the bodies already stored for one chat, with
`before` as an exclusive timestamp cursor. Each query word matches a body word
from its start and every word must match, in any order: `нужн` finds `нужный`,
`needle haystack` finds a body carrying both, and `eedle` finds nothing -
mid-word text isn't findable. Case and diacritics are ignored.
Retracted messages never match.

`source: remote` is server-side MAM full-text (XEP-0431): page through it with
`before: last`, which on this path is an RSM cursor rather than a timestamp.
Few servers implement the field, so check first with `mam fulltextSupported
{chat: string} -> bool`; a search against an archive that advertises none comes
back empty with `error: true` and `unsupported: true` rather than silently
matching everything. `field` selects the full-text form field explicitly.

`source: both` runs the remote leg for its cache-filling effect - hits are
stored on the way through - and then answers from the store, so one matching
rule covers the whole result. It falls back to the store alone when the archive
can't run the search, and pages locally: passing `before` means walking a result
set already fetched, so it skips the remote leg and fetches one server page per
search.

Omitting `chat` searches every chat in the account. MAM queries one archive, so
that is local-only: a remote `source` without a `chat` is an error.
Its `last` cursor is a `{timestamp, chat_jid}` pair, and each
result carries the `chat_jid` it came from.

`last` is a continuation token rather than a value to read: pass it back as
`before` to a call with the same `source` and the same scoping. The three
paths encode it differently, and crossing them fails quietly - a remote cursor
handed to a local search matches every row, so paging stops advancing instead
of erroring.

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
`author get {chat: string} -> {from_jid: name, ...}` resolves the names for
one chat: in a MUC that's the participant nick, in a 1:1 it's the roster
name, then the PEP nick, then the bare JID. Fetch it once when the chat
opens, key rows off `from_jid`, and subscribe to
`author <Changed> {chat: string, from: string, name: string}` to re-resolve
a single sender in place (a roster edit, a nick change, a new occupant)
without refetching the whole map.

**Rendering a message.** Draw a row in this order. If `retracted` is set, the
row is a tombstone - show the deleted-message placeholder from the header
(sender and timestamp) and stop, there is no `content`. Otherwise switch on
`content.type`. A `text` message draws `body`, applying each `formatting` span
over its offset range. A `media` message draws every entry in `attachments` by
its `type` - an `image` inline, a `file` as a download chip - then the
`caption` beneath, styled from its own `formatting` the same way (see
[Attachments](#attachments)). Around the content go the parts covered
elsewhere in this section: the sender name, the reaction row from `reactions`,
and for your own messages the send state in `server_status` and delivery or
read state in `remote_status`.

## Attachments

A message with attachments has `content.type: "media"`, carrying an
`attachments` list and a `caption` (see the `message` type). Render each
attachment `type: "image"` inline and `type: "file"` as a chip; more than one
entry is a grouped/album message under a single `caption`. `caption` is the
text to show: senders copy the share URL into the body for clients that don't
understand OOB, so `caption` is `""` when the body was nothing but that URL, and
the body verbatim otherwise. `size` and `mime` are only set on outgoing
attachments; on received ones they're `0` and `""`.

**Sending.** `message sendFile` is optimistic: the message shows up right
away via `<New>` with `server_status: "uploading"` and the local path
standing in as the attachment `url`. The backend uploads the file, sends
the real message with the public URL, and confirmation carries on like any
other send. A failed upload marks the row `failed`, and
`message retryUpload` runs it again from the local path it recorded. Each
upload transition rides `message <Status>` as a `server_status` change:
`uploading -> pending` on success, `uploading -> failed` on error, and
`failed -> uploading` on retry. Byte-level progress and terminal state come
on `file <Update>` (keyed by the message `timestamp`), which is also where
the attachment's public URL lands - the message row keeps the local path it
was drawn with, and the stored row carries the public URL for reload. In an
OMEMO chat the file is AES-256-GCM
encrypted before the PUT and the `url` is an `aesgcm://` URL (XEP-0454);
`file download` grabs the `https://` version and decrypts it for you.

**Downloading.** `file download` pulls the file into the data dir and, for an
image, makes a PNG thumbnail under the cache dir. Progress and the
final state come on `file <Update>`: the last event carries `localpath`
(plus `thumbpath` for an image) on `done`, or an `error` on `failed` - no
upload service, server refused, network died. A transfer the user cancelled
or the autofetch settings held back ends `idle` instead.

`thumbmax` is the thumbnail's long side in pixels - pick what your display
needs. It defaults to 320, is capped at 2048, and a smaller image is never
upscaled to it. Each size is cached separately, so asking for two sizes of one
URL costs two thumbnails; a download that joins one already in flight gets the
size that fetch asked for, and its own size on the next call.

**Autofetch.** Two settings bound what gets pulled without the user asking.
`attachment_autofetch` is `everyone` (the default), `contacts` (a roster
subscription of `to`, `from` or `both`), or `never`; a room JID is not a
roster entry, so under `contacts` group chats don't autofetch.
`attachment_autofetch_max` is a byte cap, default `5242880`, `0` for
unlimited, checked against `Content-Length` and again against the bytes
actually arriving. Both apply only to `download` calls made with `auto`, so a
held-back image still loads on click - it ends `idle`, not `failed`, since
nothing went wrong. Leave `auto` off when redrawing the user's own sends:
upload swaps the local path for the public URL, making a reload from history a
real fetch.

## OMEMO

OMEMO 0.3 (XEP-0384) for 1:1 chats. Three concepts:

**Trust** - each device has one of four states: `undecided` (where new
devices start), `trusted` and `untrusted` (set by the user, and freely
swappable), and `compromised` (set by the system when an identity key
rotates; it sticks). The account-wide `blindTrust` decides whether
`undecided` devices can be sent to: on (the default), new devices are
included as recipients (TOFU/BTBV); off, they're left out until you've
`trusted` them yourself.

**Per-chat toggle** - every 1:1 chat has an OMEMO on/off switch, on by
default. It doesn't check whether the peer can actually do OMEMO; sending
to one who can't fails outright instead of quietly downgrading.

**Intent vs outcome** - a row carries `encryption` (the intent: `"omemo"`
or `""`), and on a `failed` row, `fail_reason`: `"encrypt"` or
`"delivery"`. Check it to tell "couldn't encrypt" apart from a delivery
failure. The send path never quietly falls back to cleartext; the
only way down is an explicit `message resend {plaintext: 1}`, which
rewrites the one row and leaves the chat toggle alone. That rewrite rides
the row's `<Status>` as an `encryption` field, so a displayed message never
keeps a lock it no longer has.

**Message origin** - a decrypted row carries `sender_fp`, the fingerprint of
the peer device that sent it. Join it against `trustList` for that device's id
and trust state.

**UI.** For the encryption switch, subscribe to `omemo <Enabled>` for the
peer and call `setEnabled` when it's toggled. For the key panel, subscribe
to `omemo <TrustList>`, draw the rows, and call `trust` with a row's
`device` when it's clicked. For a failed message, `fail_reason: "encrypt"`
leads with "resend as plaintext" (`message resend {plaintext: 1}`), while
"keys arrived, retry" is a plain `message resend`. `fail_reason:
"delivery"` offers only the plain `message resend` - the encryption was
never the problem. `<FingerprintChanged>`
(a peer's identity key rotated, so trust auto-drops to compromised) is
per-peer, and a single handler subscribed by `acc` covers every chat at
once.

## Voice calls

Audio over Jingle (XEP-0166/0167/0176), set up through Jingle Message
Initiation (XEP-0353).

Caller: `calls start` sends a JMI `propose` to the bare JID and emits
`<Outgoing>`. A peer device answering `ringing` gives you `<Ringing>`.
Their `proceed` kicks off fetching ICE servers, building the offer, sending
`session-initiate`, and trickling candidates; the peer's `session-accept`
applies the answer, media connects, and you get `<Active>`.

Callee: an incoming `propose` gives you `<Incoming>` and auto-replies
`ringing`. `calls accept` sends `proceed`, then media setup waits for
`session-initiate`, which applies the offer and sends `session-accept`.

Either side ends the call with `calls hangup`. Before media is up the
caller retracts over JMI instead of terminating; after that it's a Jingle
`session-terminate`. Both land as `<Ended>`. `calls reject` on a call you
placed yourself retracts it the same way.

Reconnecting without stream resumption ends every live call with `<Ended>`,
because the peer cannot route anything back to a sid from the dead session.
A resumed stream keeps its calls, and so does a plain disconnection: the
media path is peer to peer and can outlive the outage.
