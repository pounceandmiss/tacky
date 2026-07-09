# Chat List API

    tacky chatlist get -acc $acc -command $cb

Returns the whole chat list as one flat, unordered list: the union of
the roster, bookmarked rooms, and any chat with message history. No
query or sort options; the backend keeps only the list and its updates.

Each entry:

    jid $chatJid name $name source roster|bookmarks|free
    groupchat 0|1 autojoin 0|1 last_activity $usec

`jid` is the chat JID, opened verbatim:

    contact@host    1:1 chat
    room@muc?join   group chat
    room@muc/nick   MUC private message

`groupchat` is 1 when the jid carries `?join`. `source`:

    roster      a roster contact (bare JID)
    bookmarks   a bookmarked room (room@muc?join)
    free        chat history but no roster or bookmark entry

`name` may be empty (always for `free`). `last_activity` is the last
message time in microseconds, or 0 if never messaged.

Per source, an entry also carries:

    roster      subscription (none|to|from|both), ask (subscribe|""),
                approved (0|1), groups (list)
    bookmarks   nick, password, room_state, room_reason

`room_state` is the live join state:

    joined        in the room
    joining       join sent, no answer yet
    error         join failed; room_reason has the condition
    disconnected  dropped from a room we still belong to (autojoin)
    idle          not joined, not trying

`room_reason` is empty unless `error`.

## Events

    chatlist <Item>   -jid $jid -item $entry
    chatlist <Remove> -jid $jid
    chatlist <Changed>

`<Item>` upserts an entry (add, rename, new message, source change,
room_state change); a new message just updates `last_activity`, so
there is no separate top/drop event. `<Remove>` deletes it, except a
removed roster contact that still has history becomes an `<Item>` with
`source free`. `<Changed>` means a source was replaced wholesale (first
fetch, reconnect): refetch with `get`.

Patches carry the full entry and are idempotent. The module funnels the
roster, bookmarks, chats, and room_state signals into these three
events, so a consumer listens to `chatlist` alone.

## Notes

- Every jid is a chat JID; pass it back verbatim to open the chat.
  Strip `?join` only for the real room JID (sharing, or matching a bare
  room JID).
- Room methods (`bookmarks item/leave/autojoin`) accept the `?join`
  form and canonicalize it.
- Presence is not provided yet.
