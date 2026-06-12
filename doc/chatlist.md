# Chat List API

One method builds every chat list the GUI shows:

    tacky chatlist search -acc $acc ?-query $text? ?-sort name|jid? -command $cb

It merges recent chats, the roster, and bookmarks, and filters.
`-query` matches case-insensitive substrings against each entry's
`jid` and `name`. `-sort` orders the roster and bookmarks sections
(default name; unnamed items sort by their JID).

The callback receives a dict with three keys:

## recent

Chats ordered by last message time, newest first, capped at 20 items.

    jid $chatJid name $resolvedName source roster|bookmark|both|none

`jid` is the chat JID, passed through verbatim, and its form tells the
kind of chat:

    contact@host        1:1 chat
    room@muc?join       group chat
    room@muc/nick       private message with a room occupant

The `?join` suffix is the way to tell a group chat from a 1:1 - use
it for routing, and pass the jid back unchanged when opening the
chat. `source` says where the counterpart (the suffix-stripped JID)
is known from; `none` is a conversation with no roster or bookmark
entry.

Beyond the three fields above, a recent entry is the union of its
counterpart's entries from the other sections.

## roster

Roster items (RFC 6121), filtered and sorted:

    jid $jid name $name subscription $sub ask $ask approved $approved groups {g1 g2}

`name` is the user-assigned roster name and may be empty.
`subscription` is none|to|from|both, `ask` is "subscribe" or empty,
`approved` is 0|1, `groups` is a possibly-empty list of group names.

## bookmarks

Bookmarked rooms (XEP-0402), filtered and sorted:

    jid $roomJid?join name $name autojoin 0|1 nick $nick password $pw
    room-state $state room-reason $reason

`jid` is the room's chat JID - the bare room JID plus the `?join`
suffix - ready to open verbatim. `name` is the bookmark's own name
and may be empty. `room-state` is the live join state:

    joined        we are in the room
    joining       join request sent, no answer yet
    error         join failed; room-reason holds the error condition
    disconnected  we dropped out of a room we are still a member of
                  (autojoin on)
    idle          not joined and not trying: never attempted, or left
                  deliberately

`room-reason` is empty except in the error state.

## Events

A list view keeps itself current with one resync signal and a set of
incremental patches. Patches carry full entries in the section shapes
above, with `-jid` in that section's form (so `?join` for the
bookmarks section), and are idempotent (re-applying one is a no-op).
They are not filtered or sorted: a consumer maintaining a filtered or
sorted view applies its own query match and ordering, and an `<Item>`
may arrive for a JID its current filter previously excluded (e.g.
after a rename).

    tacky listen chatlist <Changed> -acc $acc $command

A source was wholly replaced (initial fetch or reconnect). Call
`search` again. Single-item changes never fire this; they arrive as
`<Item>`/`<Remove>`.

    tacky listen chatlist <Item> -acc $acc $command
        -section recent|roster|bookmarks -jid $jid -item $entry

An entry was added to or changed in a section. A change also patches
the counterpart's recent entry when its chat is in the recent list.
Replace (or insert) the section's entry for that JID with `-item`.

    tacky listen chatlist <Remove> -acc $acc $command
        -section recent|roster|bookmarks -jid $jid

The entry left that section (roster item or bookmark deleted).

    tacky listen chatlist <RecentTop> -acc $acc $command
        -jid $jid -name $resolvedName -source roster|bookmark|both|none ?-autojoin 0|1?

A chat got a new message. `-jid` is the chat JID (verbatim, forms as
in the recent section). Insert it at position 0 of the recent section,
or move it there if already present. Room state is not included: take
it from the bookmarks section of your last search result (keyed by
the same `?join` chat JID) and keep it current via `<RoomState>`.

    tacky listen chatlist <RecentDrop> -acc $acc $command
        -jid $jid

A chat JID fell off the 20-item recent list. Remove it.

    tacky listen bookmarks <RoomState> -acc $acc $command
        -jid $jid -state $state -reason $reason

A room's join state changed (states as above). Patch the item in
place; `<Changed>` does not fire for join-state transitions, so this
is the only signal for them.

## Notes

- Every `jid` in a search result is a chat JID: pass it back verbatim
  to open the chat. Roster entries are bare (a 1:1's chat JID is its
  bare JID); bookmark entries and group-chat recents carry `?join`.
  Strip `?join` only where the real room JID is needed: sharing it,
  or matching `bookmarks <RoomState>`, whose `-jid` is the bare room
  JID.
- Methods taking a room `-jid` (e.g. `bookmarks item/leave/autojoin`)
  accept the `?join` chat-JID form and canonicalize it.
- Presence (online/away indicators) is not provided by this API yet.
