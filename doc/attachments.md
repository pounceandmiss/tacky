# Attachments

## Message shape

A message with attachments carries two extra keys:

    attachments {{url $u type image|file name $n size $s mime $m} ...}
    caption $text

`type image` is meant to render inline. `file` as a chip with open/save.
`caption` is the display text: senders duplicate the share URL into `body`
for OOB-unaware clients, so `caption` is `""` when `body` was nothing but
that URL, and `body` verbatim otherwise. Render `caption` if present, else
`body`.

Only a body that is exactly the attachment URL is emptied; a URL inside a
larger sentence stays in `caption`.

`size` and `mime` are set only on outgoing attachments, from the local
file. On received attachments both are `""`.

## Sending

    tacky message sendFile -acc $a -chat $j -path $localPath

Optimistic: the message appears immediately via `<New>` with
`server_status uploading` and the local path as the attachment `url`.
The backend uploads, then sends the actual message with the public
URL; from there confirmation proceeds like any send (chat.md section
8). A failed upload marks the row `failed`;

    tacky message retryUpload -acc $a -chat $j -timestamp $ts

re-runs it from the local path recorded on the row.

Every upload `server_status` transition arrives as a `message <Patch>`
(chat.md section 8): `uploading` -> `pending` on success (the `url` also
flips from the local path to the public URL, so redraw the attachment),
`uploading` -> `failed` on error, and `failed` -> `uploading` on
`retryUpload`. Byte-level progress rides `file <Update>` in parallel;
`<Patch>` carries the coarse state, `<Update>` the progress bar.

In an OMEMO chat the file is AES-256-GCM encrypted before the PUT, and the
attachment `url` is an `aesgcm://` URL (XEP-0454) whose fragment holds the
media key. `file download` handles the scheme itself - fetching the
`https://` form and decrypting - so a frontend passes it like any other URL.

## Downloading

    tacky file download -acc $a -url $u ?-command $cb?

Fetches into the cache. A cache hit - or a local path as `-url`, the
not-yet-uploaded outgoing case - resolves immediately without going
to the network; concurrent downloads of the same URL coalesce onto
one transfer. For an image a PNG thumbnail (max 320px) is derived
alongside. The optional `-command` receives the cached file path, ""
on failure.

    tacky file cancel -acc $a -id $id
    tacky file cancel -acc $a -url $u
    tacky file uncache -acc $a -url $u

`cancel` aborts an in-flight transfer in either direction (it
terminates as `failed` with error `cancelled`). `uncache` deletes the
cached copy and its thumbnail; the next `download` refetches.

## Progress

One event covers both directions:

    tacky listen file <Update> -acc $a $cmd
        -id $id -direction upload|download -state active|done|failed
        -loaded $bytes -total $bytes -url $u
        -localpath $path -thumbpath $path -error $msg

For an upload `-id` is the message's timestamp, so progress correlates
with the row shown by `<New>`; for a download, correlate by `-url`.
Progress is throttled to whole-percent steps. The terminal event
carries `-localpath` (and `-thumbpath` for an image) on `done`, or
`-error` on `failed` (no upload service, file too large, network
failure, cancelled).
