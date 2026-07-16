# Avatars

The backend fetches, caches, and re-encodes avatars (XEP-0084 PEP and
XEP-0153 vCard). The frontend tells it which JIDs are on screen, reads
the cached bytes, and reacts to change events. JIDs may be bare,
`room@muc/nick` for MUC participants, or a `room@muc?join` chat JID
(the `?join` suffix is accepted and ignored).

## Reading

    tacky avatar thumb -acc $acc -jid $jid -command $cb
        PNG bytes scaled to fit within 32x32, aspect preserved (so a
        non-square avatar is smaller than 32 on one side), or "" if none.
        For lists and small slots.
    tacky avatar data -acc $acc -hash $hash
        Full-size bytes for a hash, as published - the peer's original
        format, often JPEG via vCard, not necessarily PNG. Our own avatar
        is always PNG (see Publishing). For a full-resolution view.
    tacky avatar metadata -acc $acc -jid $jid
        Dict: hash type bytes width height. Empty if none.

## Visibility

The backend only fetches bytes for JIDs you mark visible.

    tacky avatar visible   -acc $acc -jid $jid
    tacky avatar invisible -acc $acc -jid $jid

Call `visible` when a JID first appears, `invisible` when the last slot
showing it goes away. Calls refcount, so balanced pairs are fine; don't
leak a `visible` or call `invisible` without one.

## Events

    tacky listen avatar <Update> -acc ... $cb
        -jid <bare-jid> -hash <sha1>      changed or arrived
        -jid <bare-jid> -action disabled  removed
    tacky listen avatar <Progress> -acc ... $cb
        -acc <bare-jid> -message <status>   during your own publish

On a hash update, re-request `thumb`/`data` and swap it in. On
`disabled`, drop to your placeholder.

## Publishing

    tacky avatar publish -acc $acc -data $rawBytes ?-tag $tag? ?-command $cb?
    tacky avatar disable -acc $acc ?-tag $tag? ?-command $cb?
    tacky avatar cancel  -acc $acc -tag $tag

`publish` takes raw bytes in any common format and always re-encodes: the
image is scaled to fit within 128x128 (aspect preserved) and published as
PNG. The format and dimensions are not selectable. `disable` removes the
avatar. `-command` is invoked as `{*}$cb [list ok ""]` or
`{*}$cb [list error $msg]`; `cancel` drops a still-pending callback by
its `-tag`.

## Refresh

    tacky avatar refresh -acc $acc -jid $jid

Re-fetches a JID's avatar, bypassing the hash cache. Backs an explicit
"reload" affordance; normal updates arrive on their own.

## Caching (optional)

When one avatar shows in many slots, refcount it by `(acc, jid)`: call
`visible`/`thumb` on the first slot and `invisible` on the last, reusing
one decoded image between. See `avatarcache_base`
(`lib/libtacky/tacky.tcl`) for a worked example.
