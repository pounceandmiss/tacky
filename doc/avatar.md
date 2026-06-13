# Avatars

The backend fetches, caches, and re-encodes avatars (XEP-0084 PEP and
XEP-0153 vCard). The frontend tells it which JIDs are on screen, reads
the cached bytes, and reacts to change events. JIDs may be bare,
`room@muc/nick` for MUC participants, or a `room@muc?join` chat JID
(the `?join` suffix is accepted and ignored).

## Reading

    tacky avatar thumb -acc $acc -jid $jid -command $cb
        32x32 PNG bytes, or "" if none. For lists and small slots.
    tacky avatar data -acc $acc -hash $hash
        Full-size PNG bytes for a hash. For a full-resolution view.
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

    tacky avatar publish -acc $acc -data $rawBytes \
        ?-type image/png? ?-tag $tag? ?-command $cb?
    tacky avatar disable -acc $acc ?-tag $tag? ?-command $cb?
    tacky avatar cancel  -acc $acc -tag $tag

`publish` takes raw bytes in any common format. `disable` removes the
avatar. `-command` is invoked as `{*}$cb [list ok ""]` or
`{*}$cb [list error $msg]`; `cancel` drops a still-pending callback by
its `-tag`.

## Refresh

    tacky avatar refresh -acc $acc -jid $jid

Re-fetches a JID's avatar, bypassing the hash cache. Backs an explicit
"reload" affordance; normal updates arrive on their own.

## Recommended frontend cache

The same avatar appears in many slots at once, so cache decoded image
objects keyed by `(acc, jid)` rather than decoding per slot. The
reference Tk client does this in `avatarcache_base`
(`lib/libtacky/tacky.tcl`).

- **track(acc, jid, cb) -> image**: first reference stores a
  placeholder, calls `avatar visible`, and requests `avatar thumb`;
  later references bump a refcount. Deliver the real image via `cb`.
- **untrack(token)**: decrement; at zero, free the image and call
  `avatar invisible`.
- Listen for `<Update>` once. On a change, re-request `thumb`, replace
  the cached image, and fire every registered `cb` for that key. On
  `disabled`, swap in the placeholder.

Visibility, lazy fetch, and multi-slot repaint all fall out of the
refcount.
