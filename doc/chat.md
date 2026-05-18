# Chat view

This file describes how the chat GUI<->backend interaction goes.  Reference implementation: `gui/chat.tcl`.

## 1. Overview

A chat view shows a sliding window over the conversation, fetched on
demand. The window is bounded (memory pressure forces culling); the
conversation is not. A frontend must ensure:

- **Order** - "A B C", not "A C B"
- **Contiguity** - messages in the window form an unbroken run of the
  conversation. Only "A B C", no "A B F".
- **No stale displays** - a result whose cursor was invalidated
  (because the user culled or jumped) is never applied to the window.

## 2. Data model

`timestamp` doubles down as id as it's unique (under the hood backend bumps it by a millisecond when necessary). The window is sorted by `timestamp`.

The backend stores messages in one ordered timeline per chat and
returns contiguous batches in response to pagination queries.
Pending outgoing messages (not yet confirmed by the server) interleave
into the window by timestamp like everything else.

## 3. What the frontend holds

Beyond the displayed messages, the chat-view tracks a single flag:
whether the window contains the conversation tail. Live-event
acceptance gates on this flag (see section 6); the empty window is
vacuously at tail.

In-flight backend requests are identified by a tag passed when the
request is issued. Cancelling a request is `tacky message cancel -tag
$tag`; results arriving on a cancelled tag are suppressed before the
callback fires. The chat-view uses one tag per cancel scope - one for
live events, plus one each for older-page, newer-page, and goto
requests. Tag-based cancellation is the only mechanism protecting
contiguity from racing results.

Pagination cursors are the first and last timestamps in the window -
used as `-before` and `-after` arguments for the older and newer
directions. The frontend passes the cursor and gets back a contiguous
batch.

## 4. Insertion rule

For each message in any incoming batch (initial, paginated, goto,
live), insert it at its timestamp-sorted position. The same rule
applies regardless of source - there is no separate "backfill" or
"live insert" path. `<Patch>` events take a different path entirely
(see section 7).

## 5. tacky API surface

- `tacky message history -acc $a -chat $j -limit $n -tag $t -command $cb` -
  initial page (no `-before` / `-after` returns the newest).
- `tacky message history -before $ts ...` - older page.
- `tacky message history -after $ts ...` - newer page.
- `tacky message goto -acc $a -chat $j -date $ts -source local|remote ...` -
  jump to anchor. Result: `{messages $list anchor $nearestTs}`. `-source
  remote` fetches from MAM first.
- `tacky message cancel -acc $a -tag $t` - mark in-flight callbacks for `$t`
  inactive.
- `tacky chats maxTimestamp -acc $a -chat $j` - newest known timestamp for
  the chat. Used to decide whether the window has reached the tail.
- `tacky listen -tag $t message <Received|Sent|Patch|CatchupDone> ... $cb` -
  subscribe to live events.
- `tacky unlisten $t` - remove all listeners under `$t`.

## 6. Event handling

The chat-view reacts to events from two sources: its own UI (the user
scrolls, jumps, or culls) and the backend (a result arrives, a live
event arrives). Each event has an effect on the held message list and
the at-tail flag.

When (and how often) to request more pages or cull is up to the
frontend - the reference uses pixel thresholds, but a CLI might use
line counts. Any firing schedule works as long as the responses below
are respected.

### Pagination

A page extends the window by an unbroken run; a stale result is never
applied.

When the user scrolls toward an edge, issue `tacky message history`
with `-before` (older) or `-after` (newer) of the corresponding edge
timestamp, tagged for that direction. If a request on that tag is
already in flight, drop the new one.

When the window culls messages from an end, cancel any in-flight
request on that end's tag - its cursor has moved, and a result still
in flight would extend the window across the resulting gap. Culling
the newer end additionally clears the at-tail flag, since the window
may no longer reach the tail.

When a page result arrives, apply each message via the insertion rule.
For a newer-page result, additionally check whether the window's
newest timestamp equals `tacky chats maxTimestamp`; if so, the window
is back at the tail and the flag is set.

### Initial load, goto, catchup

After any fresh load, the window is a fresh slice and the at-tail flag
reflects whether that slice contains the tail.

On chat-view open, issue `tacky message history` with no
`-before`/`-after`. The newest page comes back; the flag is vacuously
true going in (empty window) and stays true on completion (the newest
page contains the tail by definition, even when empty).

A "scroll to bottom" affordance cancels in-flight requests, clears the
window, sets the flag false, and re-runs the initial load. The flag
flips back when that completes.

A jump to a specific timestamp cancels in-flight requests, sets the
flag false, and issues `tacky message goto -date $ts`. The result
carries `messages` and `anchor`. If the anchor is already in the
window, just scroll to it - the user is already looking at the right
slice. Otherwise clear the window, apply `messages`, and scroll to the
anchor. The flag stays false either way; even if the returned slice
happens to reach the tail, it does not flip back. The user rejoins the
live tail either by clicking "scroll to bottom" or by paging forward
until the at-tail check flips.

MAM catchup messages arrive as live `<Received>` events under the
AtTail gate - no reload required. `<CatchupDone>` is a UI-settling
signal only (e.g. hide spinners); it does not drive any reload.

### Live messages

When a `<Received>` or `<Sent>` event arrives, apply the message via
the insertion rule if the at-tail flag is set; otherwise drop. The
gate is required because inserting a live message when the window
does not reach the tail would advance the newer-direction cursor past
an unfetched range, and the next page request would skip that range
- a permanent gap. `<Patch>` events take a different path (see
section 7).

## 7. Patch handling

Two shapes arrive on the `<Patch>` channel:

- **Field update** - carries `timestamp` identifying the target, plus
  the changing fields (e.g. `server_status`). If the target is in the
  window, patch its fields in place; if not, drop.
- **Timestamp move** - carries `timestamp $oldTs`, `newtimestamp
  $newTs`, plus updated `server_status`. The message moved (e.g. MUC
  echo assigned a different server time). If displayed: update its
  timestamp / status and reposition it to its sorted slot. If not
  displayed: drop.

The two shapes are distinguished by the presence of `newtimestamp`:
field updates omit it, timestamp moves include it. `<Patch>` is
dispatched on its own path that pre-filters by "is the target
displayed?" - it does not flow through the insertion rule (see
section 4).

## 8. Outgoing messages

Outgoing messages appear immediately on `<Sent>` (optimistic) at their
pending timestamp. On confirmation (MUC echo or own message via MAM)
the message may receive a timestamp-move `<Patch>` along with an
updated `server_status`.

`server_status` evolves through `<Patch>` field updates:

- `""` - incoming (no indicator).
- `"pending"` - sent locally, awaiting confirmation.
- `"received"` - server confirmed.
- `"read"` - recipient acknowledged.

A timestamp-move `<Patch>` (e.g. MUC echo with a different server time)
relocates the message.

## 9. Search

`tacky message search -acc $a -chat $j -query $q -limit $n -command $cb`

Server-side MAM full-text search. Result:
`{messages $list complete $bool last $serverId}`. Paginate with
`-before $serverId`.

Search results are not chat-view content; display them in a separate
list. To navigate to a result, jump the chat view to its timestamp
using `tacky message goto -date $ts -source remote`.
