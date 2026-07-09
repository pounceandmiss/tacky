# Attachments

## Message shape

A message with attachments carries two extra keys:

    attachments {{url $u type image|file name $n size $s mime $m} ...}
    caption $text

`type image` is meant to render inline. `file` as a chip with open/save. `caption` is the display
text: senders duplicate the share URL into `body` for OOB-unaware
clients, so `caption` is `body` with the redundant URL removed (empty
when the body was only the URL). Render `caption` if present, else
`body`.

## Sending

    tacky message sendFile -acc $a -chat $j -path $localPath

Optimistic: the message appears immediately via `<New>` with
`server_status uploading` and the local path as the attachment `url`.
The backend uploads, then sends the actual message with the public
URL; from there confirmation proceeds like any send (chat.md section
8). A failed upload marks the row `failed`;

    tacky message retryUpload -acc $a -chat $j -timestamp $ts

re-runs it from the local path recorded on the row.

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
