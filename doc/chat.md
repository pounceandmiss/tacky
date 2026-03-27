# Chat view guide

## 1. Lifecycle

### Open

1. Subscribe to four events filtered by JID (use a single tag for
   teardown):
   - `message <Received>` — incoming live message
   - `message <Sent>` — own outgoing message (optimistic)
   - `message <Patch>` — partial update to a displayed message
   - `message <CatchupDone>` — MAM sync finished (1:1 chats only)

2. Request the initial page:
   `tacky message history -acc $acc -chat $jid -limit 50 -tag $tag -command $cb`
   No `-before` or `-after` — returns the newest page. Display and
   scroll to bottom.

### Close

1. `tacky unlisten $tag` — removes all event listeners.
2. `tacky message cancel -acc $acc -tag $tag` — marks in-flight
   callbacks inactive. Optional optimization.

---

## 2. The prev rule

Every message carries `prev`: the timestamp of the message
immediately before it. The `timestamp + prev` chain is the source of
truth for ordering.

The view uses one algorithm for every batch — history responses, live
events, goto results — with no direction-awareness or special cases.

### Algorithm

Maintain an ordered list of displayed message IDs and a bidirectional
map (id <-> prev) for O(1) forward and reverse lookup.

For each message in a batch:

1. **Already displayed?** Patch fields (`prev`, `server_status`).
2. **Hollow and not displayed?** Skip (field update for off-screen
   message).
3. **Some displayed message's prev == this ID?** Insert *before* it.
4. **This message's prev is displayed?** Insert *after* prev.
5. **Display empty?** Insert (bootstrap).
6. **None of the above?** Skip (can't connect — stale response).

This handles forward/backward pagination, live messages, prev-patches,
dedup, and staleness in one loop.

### Notes

- The view can process messages sequentially in returned order.
- **Backward pages** are reversed before applying so the hollow is
  processed first (updating the edge message's prev), then the rest
  chain via rule 3.
- **Forward pages** are applied in order; each message's prev points
  to the previous one, chaining via rule 4.
- **Live messages** connect via rule 4 or are skipped if the user
  scrolled away (show a "new message" indicator).
- **Stale responses** silently fail: if the cursor was culled while
  the request was in flight, nothing connects and the batch is
  discarded.

### Displaced-prev rule

When inserting C with prev=B (rule 4), if another displayed message E
already claims B as its prev, update E.prev=C before inserting. This
keeps the chain intact when messages interleave — incoming between
displayed, incoming before pending outgoing, delayed delivery, MUC
echo reorders.

```
Before:    [A, B, E]          E.prev=B
C arrives: insert C after B, displace E.prev -> C
After:     [A, B, C, E]       E.prev=C
```

---

## 3. Pagination

The view holds a sliding window, not the full history. When the user
scrolls near an edge, request more:

`tacky message history -before $oldest -region $region ...`

or `-after $newest` to scroll down.

**Region selection**: use the region of the furthest *non-outgoing*
message in the direction of scrolling, but the *timestamp* of the
furthest displayed message (outgoing or not). Never use an outgoing
message's region — outgoing doesn't participate in contiguity and
would mask gaps.

Guard against duplicate in-flight requests with a boolean per
direction. Set on fire, clear on callback.

### Backward pagination and hollows

The backend appends a **hollow message** to backward pages:
`{timestamp $edgeTs prev $newPrev hollow 1}`. This updates the edge
message's prev to connect the new page to the existing display.

A hollow carries no body and must never be inserted. In the algorithm,
it needs no special treatment beyond rule 2 (skip if not displayed)
and rule 1 (patch if displayed).

Reverse backward pages before applying so the hollow is processed
first.

### Forward pagination

Applied in chronological order (no reversal). Each message's prev
points to the one before it, chaining via rule 4.

---

## 4. Live events

### `<Received>` and `<Sent>`

Both carry `-message` (a single message dict). Feed through the prev
rule.

### `<Patch>`

Carries `-messages`: a list of update dicts, each with a `timestamp`
identifying the target.

**Simple patch** (in-place): `{timestamp $ts server_status received}`
Updates the receipt indicator.

**Timestamp-change patch**:
`{timestamp $oldTs newtimestamp $newTs server_status received prev $newPrev}`
The message moved to a new timestamp (server assigned a different
time on MUC echo). Delete by `$oldTs`, re-insert with new timestamp,
status, and prev. The displaced-prev rule handles any affected
followers automatically during re-insertion.

### `<CatchupDone>`

Fired after reconnect MAM sync. Only handle for 1:1 chats (MUCs
don't do eager catchup yet).

Response: clear the display and re-run the initial load (`goto end`).
Cancel any in-flight pagination tags.

---

## 5. Outgoing messages

Outgoing messages are stored with `region = -1`. They don't
participate in the contiguity model in the DB, but the view gets them
linked by prev like incoming messages.

### Display

On `<Sent>`, the message appears immediately (optimistic), after all
real-region messages. Its prev links it to the chain.

### Receipt indicators

- `server_status = ""` — incoming, no indicator
- `server_status = "pending"` — sent, awaiting confirmation
- `server_status = "received"` — server confirmed delivery

Update in place when `<Patch>` changes `server_status`.

### Confirmation

A `<Patch>` may change timestamp, prev, region, and status. The
message moves from the pending area to its chronological position.

For MUC messages, the server may assign a different timestamp
(timestamp-change patch). SM-acked messages stay at region -1 — they
move to a real region only on MUC echo or MAM dedup.

---

## 6. Live message region bridging

Live messages are stored in `liveRegion`, which starts empty and is
created on the first incoming message. Since MAM history lives in a
different region, the first live message bridges `liveRegion` into
the predecessor's region so they share a single contiguous region.

On disconnect, a fresh `liveRegion` is pre-allocated (rather than
reset to empty) so the bridge does not fire again — post-disconnect
messages correctly land in a separate region. On reconnect,
`OnCatchup` sets `liveRegion` to the catchup region.

---

## 7. Goto and search

### Goto

`tacky message goto -acc $acc -chat $jid -date $ts -source local -limit 50 ...`

Callback returns `{messages $list anchor $nearestTs}`.

- If `anchor` is already displayed: scroll to it.
- Otherwise: clear the display, show returned messages, scroll to
  anchor.

`-source remote` fetches from the server (MAM) first, then returns
local results.

### Search

`tacky message search -acc $acc -chat $jid -query "text" -limit 20 ...`

Server-side (MAM) full-text search. Returns
`{messages $list complete $bool last $serverId}`. Paginate with
`-before $serverId`.

To navigate to a result, use `goto $timestamp -source remote`.

Search results should be displayed separately (e.g. a search window),
not as real history. The messages come from different points in
history but are artificially prev-linked so the view can use the same
logic.
