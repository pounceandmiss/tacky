# Avatars

The backend fetches and caches avatars (XEP-0084 PEP and XEP-0153 vCard)
and serves the master bytes as-is; it does no resizing. The frontend tells
it which JIDs are on screen, reads the master, scales/crops for its own
slots, and reacts to change events. JIDs may be bare, `room@muc/nick` for
MUC participants, or a `room@muc?join` chat JID (the `?join` suffix is
accepted and ignored).

## Reading

The master image is content-addressed by hash; fetch it in two steps -
`metadata` maps a JID to its current hash, `data` returns the bytes.

    tacky avatar metadata -acc $acc -jid $jid
        Dict: hash type bytes width height. Empty if none.
    tacky avatar data -acc $acc -hash $hash
        Master bytes for a hash, as published - the peer's original format,
        often JPEG via vCard, not necessarily PNG. "" if not cached yet.

Scale to your slot on the frontend. There is no server-side thumbnail:
`data` is the same master whether a 32px list row or a full-resolution
view asks for it, so decode it and resize (and, for a square slot,
center-crop) to the size you need.

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

On a hash update, re-request `metadata`/`data` and swap it in. On
`disabled`, drop to your placeholder.

## Publishing

    tacky avatar publish -acc $acc -data $bytes ?-type $mime? ?-width $w? ?-height $h? ?-tag $tag? ?-command $cb?
    tacky avatar disable -acc $acc ?-tag $tag? ?-command $cb?
    tacky avatar cancel  -acc $acc -tag $tag

`publish` stores and sends `-data` verbatim - prepare it on the frontend
(crop, scale, encode) before calling. `-type`/`-width`/`-height` describe
those bytes and are advertised in the XEP-0084 `<info>`. The published
blob is the exact bytes every subscriber downloads (PEP has no server-side
regeneration), so keep it modest - a ~128px PNG is a safe size against
server stanza caps. `disable` removes the avatar. `-command` is invoked as
`{*}$cb [list ok ""]` or `{*}$cb [list error $msg]`; `cancel` drops a
still-pending callback by its `-tag`.

## Refresh

    tacky avatar refresh -acc $acc -jid $jid

Re-fetches a JID's avatar, bypassing the hash cache. Backs an explicit
"reload" affordance; normal updates arrive on their own.

## Caching (optional)

When one avatar shows in many slots, refcount it by `(acc, jid, size)`:
call `visible` and fetch the master on the first slot of a size,
`invisible` on the last, reusing one scaled image between. See
`avatarcache_base` (`lib/libtacky/tacky.tcl`) for a worked example.
