## Trust model

Four per-device states in `omemo_trust.trust`:

- `undecided` — default for new devices. With blind trust on, treated as
  trusted for sending; with blind trust off, sending is refused until the user
  flips to `trusted`.
- `trusted` / `untrusted` — set by the user via `tacky omemo trust`.
  Free movement between {undecided, trusted, untrusted}.
- `compromised` — system-set when a peer device's identity key rotates
  (potential MITM). Sticky: the `trust` API refuses to move out of it.
  Recovery path (explicit "accept new key") is not yet implemented.

Blind trust setting is account-wide: `omemo blindTrust` / `setBlindTrust`.

## Per-chat toggle

Each 1:1 chat has a genuine on/off OMEMO toggle — the user's choice,
defaulting to ON (chats are encrypted by default). `setEnabled -jid X
-value 0|1`, observable via `<Enabled>`, stored per peer under setting
key `omemo.enabled.<jid>`.

The toggle does not consult peer capability. If the toggle is on but
the peer can't do OMEMO (no published devicelist), the send fails
(see below) rather than the toggle silently flipping — the failed
message is where the user learns and resends in clear.

## Send-time gate

`message send` for a 1:1 chat stamps an intended `encryption` on the
row (`'omemo'` if the toggle is on, else `''`) and builds the stanza
accordingly. On `TACO_OMEMO_NOT_READY` the row is persisted
`server_status='pending'` (not on the wire) and retried when the
internal bus fires `omemo:<SessionReady>` (a session got built) or
`omemo:<DevicelistResolved>` (the devicelist arrived). On
`TACO_OMEMO_TERMINAL` it's marked `failed` with `fail_reason='encrypt'`.
The send path never falls back to cleartext.

A peer who publishes no devicelist resolves to an empty cached list, so
the retry's encrypt hits `TERMINAL` and the message lands `failed` —
deterministic, not hung.

Each message row carries two distinct fields:

- `encryption` — *intent*: `'omemo'` or `''`. What we tried to do.
- `fail_reason` — *outcome*: why a `failed` row failed, `''` otherwise.
  Currently only `'encrypt'` (OMEMO couldn't produce ciphertext).
  Reserved for a future delivery-failure path: `'send'`.

Use `fail_reason` — not `encryption` — to tell "couldn't encrypt" from
a delivery failure; `encryption='omemo'` says the message was *meant*
to be encrypted, not why it failed. A `fail_reason='encrypt'` row is
the GUI's cue to offer "resend as plaintext".

Automatic retries (reconnect, `<SessionReady>`) honor the stamped
`encryption` — a later toggle-off can't silently downgrade a pending
encrypted message. The only path that may downgrade is an explicit
user resend:

    tacky message resend -acc $jid -chat_jid X -timestamp T ?-plaintext 0|1?

Default honors the row's stamp ("try again, same way"). `-plaintext 1`
rewrites that one row's stamp to `''` and sends cleartext — for when
the user learns the peer can't do OMEMO. It does NOT touch the chat
toggle, so downgrading one message leaves future messages encrypted. A
message to a peer who never publishes keys stays pending until the user
resends it with `-plaintext 1` (or disables the chat toggle for new
messages).

## Tacky API

### Getters

| Method                          | Returns                                              |
|---------------------------------|------------------------------------------------------|
| `device_id`                     | our device id (int)                                  |
| `account_jid`                   | our bare jid                                         |
| `own_fingerprint`               | hex string for our identity key                      |
| `devicelist -jid X`             | list of device ids (raw PEP cache)                   |
| `trustList -jid X`              | list of `{device trust active fingerprint}` dicts    |
| `blindTrust`                    | `0`/`1` — current blind trust setting                |

Peer fingerprints come from `trustList` rows, not a standalone getter.
The `device` field on each row is an opaque handle: the GUI renders the
row, and on a trust-toggle click passes that `device` back to `trust`.
It's never shown to or typed by the user.

### Mutations

| Method                                                          | Effect                                          |
|-----------------------------------------------------------------|-------------------------------------------------|
| `trust -jid X -device D -state {undecided\|trusted\|untrusted}` | set trust (validates transitions)               |
| `setBlindTrust -value 0\|1`                                     | persist blind trust; emits `<BlindTrust>`       |
| `setEnabled -jid X -value 0\|1`                                 | per-chat OMEMO toggle; emits `<Enabled>`        |

### Async control

| Method                              | Effect                            |
|-------------------------------------|-----------------------------------|
| `prepareChat -jid X ?-command cb?`  | warm peer's devicelist + bundles  |

Optional — without it the backend does the same lazily on first send.

## Events

Subscribe via `tacky listen omemo <Ev> -acc $jid …` or, for pullable
events, `tacky observe omemo <Ev> -acc $jid …` (delivers current state
plus subsequent changes through one callback).

### Pullable (state-noun)

| Event           | Payload                  | Fires when                                                                      |
|-----------------|--------------------------|---------------------------------------------------------------------------------|
| `<TrustList>`   | `-jid X -trustList L`    | any per-peer trust state change; carries the full rebuilt list                  |
| `<BlindTrust>`  | `-value V`               | blind trust setting toggled                                                     |
| `<Enabled>`     | `-jid X -value 0\|1`     | per-chat OMEMO toggle changed (default on; pull gives current)                  |

### Granular (change-verb, not pullable)

| Event                   | Payload                              | Fires when                                                       |
|-------------------------|--------------------------------------|------------------------------------------------------------------|
| `<TrustChanged>`        | `-jid X -device D -state S`          | one device's trust transitioned                                  |
| `<FingerprintChanged>`  | `-jid X -device D -fingerprint H`    | peer device's IK rotated; trust auto-flips to compromised        |
| `<DecryptFailed>`       | `-jid X -device D -reason R`         | live decrypt error                                               |


## GUI bindings

Lock icon / encryption switch:

```tcl
::tacky observe -tag $win omemo <Enabled> -acc $acc -jid $peer $cmd
tacky omemo setEnabled -acc $acc -jid $peer -value $on
```

Conversations-style key panel:

```tcl
::tacky observe -tag $win omemo <TrustList> -acc $acc -jid $peer \
    [list RenderKeyPanel $win]
# row click -> flip trust
tacky omemo trust -acc $acc -jid $peer -device $dev -state trusted
```

Failed message. A `failed` row carries a resend affordance; branch on
`fail_reason`. `fail_reason='encrypt'` (peer can't do OMEMO) → lead with
"resend as plaintext" and convey "this contact may not support
encryption" — no separate capability banner needed. The row's
`server_status`/`fail_reason` arrive live via `message <Patch>` and on
history load via the row dict.

```tcl
# retry encrypted (peer came back / keys arrived):
tacky message resend -acc $acc -chat_jid $peer -timestamp $ts
# give up on encryption for this one message:
tacky message resend -acc $acc -chat_jid $peer -timestamp $ts -plaintext 1
```

"Device key rotated" alert. The event is per-peer (`-jid -device
-fingerprint`); subscribing with `-acc` only (no `-jid` filter) catches
rotations for every peer on the account, so one account-level handler
covers all chats. The callback reads `-jid` to say whose key changed.

```tcl
::tacky listen -tag keyalert omemo <FingerprintChanged> -acc $acc \
    [list ShowKeyRotationToast]
# proc ShowKeyRotationToast {ev} {
#     toast "[dict get $ev -jid] device [dict get $ev -device]\
#            has a new key — verify before trusting"
# }
```
