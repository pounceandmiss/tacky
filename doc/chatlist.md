# Chat List API

## Search

`tacky chatlist search -acc $jid ?-query $text? ?-sort name|jid? -command $cb`

Callback receives a dict with three keys:

### recent

Ordered by last message time, capped at 20.
`jid $jid name $resolvedName source roster|bookmark|both|none`
Items with source `bookmark` or `both` also include `autojoin 0|1`.

### roster

Sorted by `-sort` (default: name, fallback to JID when unnamed).
`jid $jid name $name subscription $sub ask $ask approved $bool groups {g1 g2}`

### bookmarks

Same sort order as roster. Name resolved (roster name wins).
`jid $jid name $resolvedName autojoin $bool nick $nick password $pw`

## Events

### `<Changed>` — full rebuild

`tacky listen chatlist <Changed> -acc $acc $command`

Fires when roster or bookmarks change. Call `search` again to refresh.

### `<RecentTop>` — incremental insert/move

`tacky listen chatlist <RecentTop> -acc $acc $command`

Fires when a new message arrives. Callback receives:
`-jid $jid -name $resolvedName -source roster|bookmark|both|none`
Items with source `bookmark` or `both` also include `-autojoin 0|1`.
The JID should be inserted or moved to position 0 in the recent section.

### `<RecentDrop>` — incremental removal

`tacky listen chatlist <RecentDrop> -acc $acc $command`

Fires when a JID falls off the 20-item recent list. Callback receives `-jid $jid`.
