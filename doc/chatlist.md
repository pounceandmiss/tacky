# Chat List API

## Search

```tcl
tacky chatlist search -acc $jid ?-query $text? ?-sort name|jid? -command $cb
```

Callback receives a dict with three keys:

### recent

Ordered by last message time, capped at 20.

```tcl
-jid $jid -name $resolvedName -source roster|bookmark|both|none
```

Items with source `bookmark` or `both` also include `-autojoin 0|1`.

### roster

Sorted by `-sort` (default: name, fallback to JID when unnamed).

```tcl
-jid $jid -name $name -subscription $sub -ask $ask -approved $bool -groups {g1 g2}
```

### bookmarks

Same sort order as roster. Name resolved (roster name wins).

```tcl
-jid $jid -name $resolvedName -autojoin $bool -nick $nick -password $pw
```

## Events

```tcl
tacky listen chatlist <Changed> -acc $acc $command
```

Fires when roster, bookmarks, or chats change. Call `search` again to refresh.
