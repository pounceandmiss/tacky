# Tacky backend API

The tacky backend is a headless XMPP client. You drive it with requests
and get back replies and events.

## Contents

- [Using the backend](#using-the-backend)
  - [Ways to run it](#ways-to-run-it)
  - [Requests, replies, events](#requests-replies-events)
- [Reference](#reference)
  - [account](#account)
  - [register](#register)
  - [conn](#conn)
  - [setting](#setting)
  - [chatlist](#chatlist)
  - [presence](#presence)
  - [message](#message)
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

**JSON subprocess.** `tclsh9.0 bin/tackyd-json.tcl` reads JSON from stdin
and writes JSON to stdout, each message length-prefixed:

    <byte_count>\n<payload>

The payload is UTF-8. Read: `len = readline()`, `data = read(len)`, decode
UTF-8; repeat. Write: `body = payload.encode("utf-8")`, then
`write(str(len(body)) + "\n" + body)`; flush.

    msg='["account", "list", {}, 1]'
    printf '%d\n%s' ${#msg} "$msg" | tclsh9.0 bin/tackyd-json.tcl; echo

**C library.** `make lib` builds `dist/libtacky.a` (`make win-lib` cross-
compiles the MinGW `dist/libtacky-win.a`). The ABI is `embed/tacky.h`:

    tacky *tacky_create(const char *const *taco_args, tacky_emit_fn emit, void *ud);
    void tacky_send(tacky *t, const char *json, size_t len);
    void tacky_destroy(tacky *t);

`tacky_create` starts the backend on its own thread and returns right
away. `taco_args` is a NULL-terminated array of taco_type constructor args
(e.g. `"-transient", "0"`), or NULL. Each `tacky_send` carries one complete JSON
request; each emit callback delivers one complete JSON reply or event.
If the backend fails to start up it emits
`["event","backend","<Dead>",{"error":"..."}]` and goes dead: no replies
arrive, and you still have to destroy the handle. You can call `tacky_send`
from any thread; the emit callback fires on the backend thread, so copy
the bytes out before you return (they're invalid afterward), hand them to
your own loop, and don't block. `tests/lib_driver.c` is a minimal host
(`make test-lib`).

**In-process Tcl.** The `tacky` command runs the backend in the same or a
separate thread/process transparently. A Tcl frontend calls it through the
same requests:

    tacky module method ?...args? ?-tag $tag? ?-command $cb? ?-onerror $ecb?

Keyword args only. `-command` and `-onerror` are command prefixes run on
the result and on an error; `-tag` groups calls so you can cancel them
together. The two transports line up directly:

    JSON                                Tcl
    ["mod","method",{"k":"v"}]          tacky mod method -k v
    ...with a token for a reply         ...-command $cb ?-onerror $ecb?
    ["result", token, data]             $cb data
    ["error", token, message]           $ecb message
    ["event","mod","<E>",{...}]         a fired listen/observe callback

Keys pick up a `-`; the argument and result values are the same either
way. Errors route three ways: with both `-command` and `-onerror`, a
failure goes to `-onerror`; with just `-command`, it comes back as an
`error <MethodError>` event (`-module -method -message -errorinfo`); with
neither, it's re-thrown right there.

The Tcl binding adds frontend-side subscription sugar on top of the raw
firehose, which could be used as inspiration for any frontend, including
json:

    tacky listen ?-tag $tag? $module $event ?-field $value ...? $command
    tacky unlisten $tag
    tacky observe ?-tag $tag? $module $event ?-field $value ...? $command

`listen` registers a filtered callback and hands back a tag (auto-assigned
unless you pass one); field filters like `-acc` and `-jid` narrow down
which events fire it. `unlisten` drops every listener under a tag.
`observe` is `listen` plus one immediate delivery of the current value - a
getter and a subscribe in a single call - for pullable events.

Cancelling: `tacky unlisten $tag` keeps the frontend from firing a pending
callback; `tacky $module cancel -acc $acc -tag $tag` is an optimization
that tells the backend to drop the work itself. E.g. a widget torn down
mid-request *must* `unlisten` its tag, and *should* also call the module's
`cancel`.

## Requests, replies, events

A request is a JSON array: a module, a method, an object of keyword
arguments, and an optional token.

    ["module", "method", {"arg1": "val1", ...}]
    ["module", "method", {"arg1": "val1", ...}, token]

The token (any integer) asks for a reply tagged with that same token.
Leave it off and the request is fire-and-forget: no reply, and any error
is dropped. Argument values go through untouched - the backend is untyped,
so `5` and `"5"` mean the same thing on the way in.

    ["account", "add", {"acc": "user@example.com", "password": "secret"}]
    ["account", "list", {}, 1]

A request with a token gets at most one reply: a result if it worked, an
error if it didn't, or nothing at all if it never finishes (you cancelled
it, or the server went quiet). Not every method replies - `message send`
does its work through the event stream and never answers the token.

    ["result", token, data]
    ["error", token, message]

    ["result", 1, ["alice@example.com", "bob@example.com"]]
    ["error", 1, "Account doesn't exist: nobody@example.com"]

Events get pushed whenever something happens; they aren't tied to a
request.

    ["event", "module", "<EventName>", {payload}]
    ["event", "message", "<New>",
      {"acc": "me@host", "jid": "peer@host",
       "message": {"timestamp": 1700000000, "is_outgoing": false,
                   "content": {"type": "text", "body": "hi"}}}]

Event subscription and filtering is up to the frontend. Per-account events
carry an `acc` - you'll almost always want to filter based on that. When
you want the current state instead of waiting for the next change, call a
getter or the module's `pull` method - `pull` re-fires the relevant event
with the value as it stands now.

# Reference

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
and its per-account cache database. `changePassword` changes the password
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
                  groupchat: bool, autojoin: bool, last_activity: int}

`jid` is the chat JID, used verbatim when you open it: `contact@host` for
1:1, `room@muc?join` for a group, `room@muc/nick` for a MUC private
message. `groupchat` is `true` when the jid has `?join`. `source` is
`roster` (a roster contact, bare JID), `bookmarks` (a bookmarked room), or
`free` (came from chat history, with no roster or bookmark entry). `name`
can be `""` (always is for `free`). `last_activity` is the last message
time in microseconds, or `0`.

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

`<Item>` upserts (an add, rename, new message, source change, or
room_state change). `<Remove>` deletes - except a removed roster contact
that still has history, which comes back as an `<Item>` with
`source: "free"`. `<Changed>` means a whole source was swapped out (first
fetch, reconnect); refetch with `get`. The module funnels the roster,
bookmarks, chats, and room_state signals into just these three events, so
you only need to subscribe to `chatlist`. The raw `bookmarks <Changed>`
and `bookmarks <RoomState>` signals are still there, but a frontend
normally sticks with the funneled ones.

## presence

    presence get {jid: string}         -> presence      best resource
    presence resources {jid: string}   -> {*: presence}  per-resource
    presence isOnline {jid: string}    -> bool

    presence = {show: string, status: string, priority: int}

Event:

    presence <Changed> {acc: string, jid: string}

`jid` is a bare JID.

## message

    message send {chat: string, body: string}
    message sendFile {chat: string, path: string}
    message history {chat: string, limit?: int, before?: int, after?: int, tag?: string}  -> [message]
    message goto {chat: string, date: int, source: string, limit?: int, tag?: string}     -> goto_result
    message gotoReply {chat: string, reply_id: string, reply_to?: string, tag?: string}   -> goto_result
    message search {chat: string, query: string, limit?: int, before?: string}            -> search_result
    message resend {chat: string, timestamp: int, plaintext?: bool}
    message retryUpload {chat: string, timestamp: int}
    message cancel {tag: string}
    message rawxml {chat: string, timestamp: int} -> string  raw stanza (debug)
    message markDisplayed {chat: string, timestamp: int}

    message = {timestamp: int, newtimestamp: int, is_outgoing: bool,
               server_status: string, encryption: string, fail_reason: string,
               edited: bool, edited_ts: int, retracted: bool,
               content: content,
               reactions: {*: {reactors: [string], mine: bool}}}

    content = {type: "text",  body: string, formatting?: formatting}
            | {type: "media", attachments: [attachment], caption: string, formatting?: formatting}

    formatting = [{type: span_type, offset: int, length: int}]
    span_type  = "bold" | "italic" | "overstrike" | "monospace"
               | "preformatted" | "quote"
    attachment = {url: string, type: "image" | "file", name: string, size: int, mime: string}

    goto_result   = {messages: [message], anchor: int, bounded_before: bool, bounded_after: bool}
    search_result = {messages: [message], complete: bool, last: string}

`timestamp` doubles as the row id - it's unique, and the backend bumps it
by a microsecond if two would collide. `before`/`after` on `history` are
exclusive cursors; `source` on `goto` is `local` or `remote`.
`server_status` is `""` (the server has it), `pending`, `uploading`, or
`failed`. `encryption` is `"omemo"` or `""`. `content` is the typed payload:
`type: "text"` carries a `body`, `type: "media"` carries an `attachments` list
plus a `caption` (grouped attachments are just more than one entry). Each
`attachment` has a `type` of `"image"` (render inline) or `"file"` (a download
chip). `formatting` (XEP-0393 styling spans) indexes into whichever of
`body`/`caption` the variant carries, with the styling characters already
removed from that string. A span's `type` is `bold`, `italic`, `overstrike`,
`monospace`, `preformatted`, or `quote`.
A **retracted** message carries no `content` (the tombstone has no payload, and
its former body/attachments are never shipped); the `retracted` flag is the
signal. Deletion is a message-level state, not a content type (matching TDLib);
future kinds like `call` or `system` events extend the `content` union. See
[The chat window](#the-chat-window), [Attachments](#attachments),
[OMEMO](#omemo-1).

Events:

    message <New>         {jid: string, message: message}
    message <Status>      {jid: string, timestamp: int, server_status?: string, remote_status?: string, fail_reason?: string}
    message <Confirmed>   {jid: string, timestamp: int, newtimestamp: int, server_status: string}
    message <Reactions>   {jid: string, timestamp: int, reactions: {*: {reactors: [string], mine: bool}}}
    message <Edited>      {jid: string, message: message}
    message <Retracted>   {jid: string, timestamp: int}
    message <CatchupDone> {count: int}
    message <Tail>        {jid: string, timestamp: int}

These events each carry one kind of change to a message already on screen,
found by `timestamp`. If the target isn't displayed, drop it. `<Status>`
updates send/receipt state in place (`server_status`
`pending`/`uploading`/`failed`, `remote_status` delivery/read,
`fail_reason`). `<Confirmed>` is a pending send the server acknowledged: it
always carries `newtimestamp` (equal to `timestamp` when the stamp held, the
relocated server stamp when it moved) and clears `server_status` to `""` -
update in place when equal, rekey and re-sort when it moved. It's the only
event that clears to `""`, and the only one that shifts a message's slot.
`<Reactions>` replaces the aggregated reaction map. `<Edited>` re-sends the
whole `message` row for a content edit, redraw it in place. `<Retracted>`
flips the displayed message to a tombstone - unlike
TDLib `updateDeleteMessages`, it does not remove the message: the row is kept
(the `retracted` envelope flag is set, `content` is dropped) so pagination
anchors, reply resolution, and slot/attribution keep working, and the client
redraws the placeholder in place from the header it already holds. That is why
it carries only `timestamp`, not a row.

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

    avatar_meta = {hash: string, type: string, bytes: int, width: int, height: int}

The full-size image is content-addressed by hash: `metadata` maps a JID to
its current hash, and `data` gives you the bytes as they were published
(often JPEG, not always PNG). The backend never resizes - scale on your
end. It only fetches bytes for JIDs you've marked `visible`, and that's
refcounted, so balance each `visible` with an `invisible`. `publish` sends
`data` as-is; a ~128px PNG is a safe size. See `avatarcache_base` in
`lib/libtacky/tacky.tcl` for a caching example.

Events:

    avatar <Update>   {jid: string, hash: string}      changed, arrived, or removed (hash "")
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

    file download {acc: string, url: string}   -> string   cached path ("" on failure)
    file cancel {acc: string, id: int}
    file cancel {acc: string, url: string}
    file uncache {acc: string, url: string}

`download` pulls a file into the cache. A cache hit or an already-local
path comes back immediately, and two downloads of the same URL collapse
into one. It handles the `aesgcm://` scheme (XEP-0454) for you. `cancel`
aborts a transfer in either direction - it ends `failed` with the error
`"cancelled"`. `uncache` deletes the cached copy and its thumbnail. See
[Attachments](#attachments).

Event:

    file <Update> {id: int, direction: string, state: string,
                   loaded: int, total: int, url: string,
                   localpath: string, thumbpath: string, error: string}

`direction` is `upload` or `download`; `state` is `active`, `done`, or
`failed`. For an upload, `id` is the message timestamp; for a download,
match on `url`.

## calls

    calls start {to: string}                                       -> string   sid
    calls accept {sid: string}
    calls reject {sid: string, reason?: string}                    reason default: decline
    calls hangup {sid: string, reason?: string}                    reason default: success
    calls setDevices {sid: string, input?: string, output?: string}

`start` rings the peer and returns the session id. That id also shows up on
`<Outgoing>`, which is the reliable source no matter the transport.
`setDevices` overrides the mic and speaker for a single call; an empty id
means the system default. See [Voice calls](#voice-calls).

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

The stateful protocols you'll actually implement. The Reference above has
the signatures; these walk through the flows.

## Accounts and sign-in

**Startup.** The backend connects every enabled account by itself at
init - there's no "connect" call. Your only startup decision is what to show:
run `account list {enabled: 1}`, and if it's non-empty open the main UI,
otherwise show setup. Do the same check in reverse when the last account
window closes - no accounts left means back to setup, otherwise quit.

**Sign-in.** There's no separate "verify credentials" call - signing in
*is* creating the account and watching what the connection does. Subscribe
to `conn <Ready>`, `<AuthError>`, and `<ConnError>` for the account, then
`account add` followed by `account enable`. On `<Ready>`, keep the account
and move on. On failure (show the `message`), or if the user backs out,
call `account remove` - the account got stored before it was ever
validated, so an abandoned sign-in has to clean itself up. `<ConnError>`
isn't terminal (the backend keeps retrying); `<AuthError>` is.

**Sign-up.** XEP-0077 registration runs over its own throwaway connection
(the `register` module), keyed by a `token`. The flow: `register connect`,
wait for `<Form>`, pull the field list with `register form` and render it
(`username` and `password` are the usual fields, but the server decides
the set; `<MediaReady>` hands you CAPTCHA bytes for a field via
`register media`), then `register submit` with the filled-in values.
`<Error>` can fire at either step, and you may have to re-fetch the form
after a failed submit - an expired CAPTCHA, say. On `<Success>` the account
exists on the server but your local store has never heard of it, so finish
it off exactly like sign-in (`account add` then `enable`). `register cancel`,
or just dropping the session, tears it down at any point.

## The chat window

A chat view is a sliding window over the conversation, fetched on demand
and culled under memory pressure. The conversation behind it is not bounded.
Three things have to stay true:

- **Order** - "A B C", never "A C B".
- **Contiguity** - the window is an unbroken run of the conversation:
  "A B C", never "A B F".
- **No stale displays** - never apply a result whose cursor has been
  invalidated (the user culled or jumped away).

**Data model.** `timestamp` is both the sort key and the unique id. The
backend keeps one ordered timeline per chat and hands back contiguous
batches for pagination queries. Pending outgoing messages sort in by
timestamp like everything else.

**What the frontend holds.** Beyond the messages on screen, one flag:
whether the window reaches the conversation tail. Accepting live events
hinges on that flag, and an empty window counts as at-tail. You identify
in-flight requests by a token. The reference chat view keeps one cancel
scope per direction - live, older-page, newer-page, and goto. Cancelling by
that token is what stops racing results from breaking contiguity. The
pagination cursors are just the first and last timestamps in the window,
passed as `before` and `after`.

**Paging.** `message history` with no cursor gives you the newest page.
`before` (exclusive) pages older, `after` (exclusive) pages newer, always
oldest-first, capped at `limit` (default 50). It's local-first: it returns
local rows right away and only reaches for the server (MAM) when a cursor
anchors a fill *and* the local read came up short of `limit`. A cursorless
initial load shows only the contiguous local tail and won't auto-fetch
older history - scrolling up (a `before` page) pulls the next page
from MAM. When the user scrolls toward an edge, fire a tagged `history` for
that direction, unless one is already in flight there. When the window
culls an end, cancel any in-flight request on that end, since its cursor
just moved and the result would be stale. Culling the newer end also clears
the at-tail flag. Subscribe to `message <Tail>`, which pushes the chat's
newest real-message timestamp whenever it changes. On a newer-page result,
if the window's newest timestamp matches the last `<Tail>`, you're back at
the tail, so set the flag.

**Initial load, goto, catchup.** When the chat opens, call
`message history` with no cursor. The newest page comes back (local if it's
stored, otherwise fetched from MAM). That empty-local fetch is the one time
a cursorless load hits the server, and it has no timeout - so treat the
per-request callback as best-effort and lean on live `<New>` events to fill
an empty window once you're connected. "Scroll to bottom" cancels in-flight
requests, clears the window, sets the flag false, and re-runs the initial
load. A jump calls `message goto`: if the returned `anchor` is already in
the window, just scroll to it, otherwise clear and apply `messages`. The
flag stays false after a goto until the user gets back to the tail -
scroll-to-bottom, or paging forward until the at-tail check flips.
`goto`'s `bounded_before` and `bounded_after` flag a side that was cut off
at a hole: there's more history that way, and paging fills it in.
`gotoReply` (XEP-0461) jumps to a reply's target and returns the same
shape. MAM catchup comes in as live `<New>` events under the at-tail gate.
`<CatchupDone>` is only there to let the UI settle.

**Live messages.** On `<New>`, insert it at its timestamp-sorted spot if
the at-tail flag is set, otherwise drop it.

**Updates to a shown message.** Five events change a message already on
screen rather than adding one. Switch on the event, never sniff which field
is present. All find their target by `timestamp` and drop silently if it
isn't displayed. `<Status>` updates the send/receipt state where the row
sits. `<Reactions>` swaps the reaction map. `<Edited>` carries a full
`message` row to redraw in place for a content edit. `<Retracted>` flips the
row to a tombstone in place - it carries only `timestamp`, so redraw the
placeholder from the header you already hold. `<Confirmed>` acknowledges a
pending send: update its checkmark in place when `newtimestamp == timestamp`,
or rekey to `newtimestamp` and re-sort when the server relocated it - the
only one that shifts a message's slot.

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

**Search.** `message search` is server-side MAM full-text search. Page
through it with `before: last`. The results aren't chat-view content - show
them somewhere separate, and jump to one with
`message goto {date: ts, source: remote}`.

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
read state in `remote_status`. Switch on `content.type` rather than sniffing
which fields are present.

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

**Downloading.** `file download` pulls the file into the cache and, for an
image, makes a PNG thumbnail (max 320px) alongside it. Progress and the
final state come on `file <Update>`: the last event carries `localpath`
(plus `thumbpath` for an image) on `done`, or an `error` on `failed` - no
upload service, file too big, network died, or cancelled.

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
or `""`), and on a `failed` row, `fail_reason` (currently just
`"encrypt"`). Check `fail_reason` to tell "couldn't encrypt" apart from a
delivery failure. The send path never quietly falls back to cleartext; the
only way down is an explicit `message resend {plaintext: 1}`, which
rewrites the one row and leaves the chat toggle alone.

**UI.** For the encryption switch, subscribe to `omemo <Enabled>` for the
peer and call `setEnabled` when it's toggled. For the key panel, subscribe
to `omemo <TrustList>`, draw the rows, and call `trust` with a row's
`device` when it's clicked. For a failed message, `fail_reason: "encrypt"`
leads with "resend as plaintext" (`message resend {plaintext: 1}`), while
"keys arrived, retry" is a plain `message resend`. `<FingerprintChanged>`
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
`session-terminate`. Both land as `<Ended>`.
