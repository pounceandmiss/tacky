# Chat view guide

---

## 1. Lifecycle

### Open

When a chat view opens for a given account + JID:

1. Subscribe to four events filtered by JID:
   - `message <Received>` — incoming live message
   - `message <Sent>` — own outgoing message (optimistic)
   - `message <Patch>` — partial update to a displayed message
   - `message <CatchupDone>` — MAM sync finished (1:1 chats only)

   It's a good idea to for subscriptions to use a single tag (perhaps derived from the view's
   identity) so they can be torn down in one call.

2. Request the initial page of messages:
   ```
   tacky message history -acc $acc -chat $jid -limit 50 -tag tag -command $cb
   ```
   No `-before` or `-after` — this returns the newest page. On
   completion, display the messages and scroll to the bottom. 

### Close

1. `tacky unlisten $tag` — removes all event listeners. Essential.
2. `tacky message cancel -acc $acc -tag $tag` — marks in-flight
   callbacks inactive so the backend can skip stale work. Optional
   optimization. 

---

## 2. The prev rule

Every message carries `prev`: the timestamp of the message immediately
before it in the same chat. The `timestamp + prev` linking is the
ultimate source of truth for message ordering. In practice, the backend
currently returns batches in correct chronological order.

The view uses one algorithm to process every batch of messages —
history responses, live events, goto results — with no
direction-awareness or special cases.

### Algorithm

Maintain an ordered list of displayed message IDs (oldest to newest).
Also need a way to look up, given an ID, both "what is this message's prev?" and "which displayed message claims this ID as its prev?". 

For each message in a batch:

1. **Already displayed?** → Patch fields (update `prev`, `server_status`).
   Do not re-insert.
2. **Hollow and not displayed?** → Skip. (This is a field update
   targeting a message that isn't on screen. Check the `hollow` flag)
3. **Some displayed message's prev == this message's ID?** → Insert
   *before* that message. (Reverse lookup.)
4. **This message's prev is displayed?** → Insert *after* the prev
   message.
5. **Display is empty?** → Insert (bootstrap case).
6. **None of the above?** → Skip. The message can't connect to
   anything on screen, so it is a stale response. No need for generation tokens.

This handles forward pagination, backward pagination, live
messages, prev-patches, dedup, and staleness — all from one loop.

### Practical implementation notes:
- **The view can rely on the order of the returned result** and process messages sequentially in one pass. 
- **Backward pages** are reversed before applying, so the prev-patch
  for the cursor message is processed first (updating its prev to
  point into the new page), and the rest chain via rule 3.
- **Forward pages** are applied in order; each message's prev points
  to the previous one, chaining via rule 4.
- **Live messages** connect via rule 4 (prev points to the last
  displayed message) or are skipped if the user scrolled away.
- **Stale responses** silently and automatically fail: if the cursor message was culled
  while the request was in flight, nothing connects and the batch is
  discarded. No generation tokens needed.


## 3. Pagination

The view holds a sliding window of messages, not the full history.
When the user approaches an edge of loaded content (scrolls near the
top or bottom of what's currently displayed), the view requests more.
There's a caveat: the view needs to figure out the region of the furthest *non-outgoing* message in the direction of scrolling and pass it as region, but use the timestamp of the furthest displayed message (be that outgoing or non outgoing). Never use an outgoing message's region as the cursor for a real-region query — outgoing messages don't participate in contiguity and would
mask gaps. 

Then call:

```
tacky message history -before $oldest -region $region 
```
to scroll up or `-after` to scroll down.

Guard against duplicate in-flight requests: track a boolean per
direction. Set it when a request fires, clear it when the callback
arrives.


### Backward pagination and hollow messages

When the backend returns an older page, it appends a **hollow
message** at the end: `{timestamp $edgeTs prev $newPrev hollow 1}`.
This updates the edge message's `prev` to point to the last message
in the returned page, connecting the new page to the existing display.

A hollow message is not a real message — it carries no body and must
never be inserted into the display. The `hollow` flag marks it as a
pure field update, distinguishing it from real bodyless messages (e.g.
future attachment-only messages). Conceptually a hollow is the same
thing as a `<Patch>` — both update fields on an existing message
without being messages themselves. The hollow is just delivered inline
with the history response rather than as a separate event.

In the apply algorithm, a hollow needs no special treatment beyond
rule 2: if not already displayed, skip it (check `hollow` flag).
If already displayed, rule 1 patches its fields like any other update.

The view must reverse backward pages before applying. This ensures
the hollow is processed first (updating the edge message's prev), and
the remaining messages chain from it via the reverse-lookup rule.

### Forward pagination

Applied in chronological order (no reversal). Each message's prev
points to the one before it.

---

## 4. Live events

### `<Received>` and `<Sent>`

Both carry a single message dict. Feed it through the same timestamp-prev rule. If the user has scrolled away and the message can't connect (rule 6), it's silently skipped — but the gui should display some sort of indication that there is a new message.

### `<Patch>`

Carries `-messages`: a list of one or more update dicts. Each has a
`timestamp` field identifying the target message.

**Simple patch** (in-place update):
```
{timestamp $ts server_status received}
```
Update `server_status` on the displayed message. The receipt indicator
changes from pending to delivered.

**Prev-only patch:**
```
{timestamp $ts prev $newPrev}
```
Update the message's prev in the bidict. This happens when an incoming
message arrives while outgoing messages are pending — the first pending
message's prev is updated to point to the new last real message.

**Timestamp-change patch** (compound):
```
{timestamp $oldTs newtimestamp $newTs server_status received prev $newPrev}
{timestamp $followerTs prev $newPrev}
...
```
The first entry says: the message formerly at `$oldTs` has moved to
`$newTs` (server assigned a different timestamp on confirmation). The
view must assign the at `$oldTs` with the new timestamp, status, and prev and move it accordingly. Apply subsequent entries as prev patches on affected followers.

### `<CatchupDone>`

Fired after reconnect MAM sync completes. **Only handle for 1:1
chats** (currently MUCs don't do eager catchup - they probably should, but that's for later).

Response: clear the display and re-run the initial load (`goto end`). Cancel any in-flight pagination tags.

---

## 5. Outgoing messages

Outgoing messages are stored with `region = -1` (the outgoing
sentinel). They don't participate in the contiguity model in the db, but the view gets them linked by prev-ts just like incoming messages.

### Display

On `<Sent>`, the message appears immediately (optimistic). It is
always shown at the bottom, after all real-region messages. Its prev
links it to the chain: first pending message's prev points to the last
real message; subsequent pending messages chain off each other.

### Receipt indicators

- `server_status = ""` → incoming message, no indicator
- `server_status = "pending"` → sent, awaiting confirmation (empty or
  spinner)
- `server_status = "received"` → server confirmed delivery (perhaps ✓)

Update the indicator in place when a `<Patch>` changes `server_status`.

### Confirmation

When the server confirms an outgoing message (MUC echo or SM ack), a
`<Patch>` arrives that may change the timestamp, prev, region, and
status. The message "jumps" from the pending area to its chronological
position. This jump is the visual confirmation of delivery.

For MUC messages, the server may assign a different timestamp. The
compound patch handles this.

SM-acked messages stay at region -1 (SM doesn't prove contiguity). They move to a real region only on MUC echo or MAM dedup.

### Displaced-prev rule

When `apply` inserts message C with prev=B, and some displayed message
E already claims B as its prev, `apply` updates E.prev=C before
inserting. This keeps the prev chain intact for all interleaving
cases: incoming between displayed messages, incoming before pending
outgoing, delayed messages, and MUC echo reorders.

```
Before:    [A, B, E]          E.prev=B
C arrives: apply inserts C after B, displaces E.prev → C
After:     [A, B, C, E]       E.prev=C
```

### Live message region bridging

Live messages go into `liveRegion`. On the very first live message
(before any disconnect), `message store` bridges `liveRegion` into
the predecessor's region so `AnnotatePrev` finds cross-region
predecessors. After disconnect, `liveRegion` is pre-allocated (not
reset to empty), so the bridge does not fire and regions stay separate.

---

## 7. Goto and search

Jumping to date:
```
tacky message goto -acc $acc -chat $jid -date $ts -source local -limit 50 ...
```

Callback returns `{messages $list anchor $nearestTs}`.

- If `anchor` is already displayed: just scroll to it.
- Otherwise: clear the display, show the returned messages, scroll to
  the anchor.

`-source remote` fetches from the server (MAM) first, then returns
local results. 

### Search

```
tacky message search -acc $acc -chat $jid -query "text" -limit 20 ...
```

Server-side (MAM) full-text search. Returns `{messages $list complete $bool last $serverId}`. Paginate with `-before $serverId`.

To navigate to a search result, use `goto $timestamp -source remote`.

These results should be handled displayed specially - perhaps in a separate window that makes it clear that its's not a real piece of history. The messages returned come from different points in history, disjointed in practice, but they are artificially prev-ts linked so the view can use the same logic.