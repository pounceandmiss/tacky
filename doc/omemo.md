# OMEMO

## Concepts

**Trust** — four per-device states: `undecided` (default for new
devices), `trusted`/`untrusted` (user-set, freely interchangeable), and
`compromised` (system-set on identity-key rotation; sticky, the API
refuses to move out of it). `blindTrust` (account-wide) decides whether
`undecided` devices are usable for sending.

**Per-chat toggle** — each 1:1 chat has an on/off OMEMO switch, the
user's choice, default on. It does not consult peer capability; sending
to a peer that can't do OMEMO fails rather than silently downgrading.

**Intent vs outcome** — each message row carries `encryption` (intent:
`'omemo'` or `''`) and `fail_reason` (outcome on a `failed` row,
currently only `'encrypt'`). Branch on `fail_reason` to tell "couldn't
encrypt" from a delivery failure. The send path never falls back to
cleartext on its own; the only downgrade is an explicit
`message resend -plaintext 1`.

## Tacky API

### Getters

| Method                  | Returns                                            |
|-------------------------|----------------------------------------------------|
| `device_id`             | our device id (int)                                |
| `account_jid`           | our bare jid                                        |
| `own_fingerprint`       | hex string for our identity key                    |
| `devicelist -jid X`     | list of device ids (raw PEP cache)                 |
| `trustList -jid X`      | list of `{device trust active fingerprint}` dicts  |
| `blindTrust`            | `0`/`1` — current blind trust setting              |

Peer fingerprints come from `trustList` rows, not a standalone getter.
The `device` field is an opaque handle: render the row, pass `device`
back to `trust` on a toggle click. Never shown to or typed by the user.

### Mutations

| Method                                                          | Effect                                    |
|-----------------------------------------------------------------|-------------------------------------------|
| `trust -jid X -device D -state {undecided\|trusted\|untrusted}` | set trust (validates transitions)         |
| `setBlindTrust -value 0\|1`                                     | persist blind trust; emits `<BlindTrust>` |
| `setEnabled -jid X -value 0\|1`                                 | per-chat OMEMO toggle; emits `<Enabled>`  |

### Async control

| Method                             | Effect                           |
|------------------------------------|----------------------------------|
| `prepareChat -jid X ?-command cb?` | warm peer's devicelist + bundles |

Optional — the backend does the same lazily on first send.

### Message resend

    tacky message resend -acc $jid -chat X -timestamp T ?-plaintext 0|1?

Default honors the row's stamped `encryption`. `-plaintext 1` rewrites
that one row to send cleartext (for a peer that can't do OMEMO); it does
not touch the chat toggle.

## Events

Subscribe via `tacky listen omemo <Ev> -acc $jid …`, or `tacky observe`
for pullable events (delivers current state plus subsequent changes).

### Pullable (state-noun)

| Event          | Payload               | Fires when                                  |
|----------------|-----------------------|---------------------------------------------|
| `<TrustList>`  | `-jid X -trustList L` | any per-peer trust change; full rebuilt list|
| `<BlindTrust>` | `-value V`            | blind trust setting toggled                 |
| `<Enabled>`    | `-jid X -value 0\|1`  | per-chat OMEMO toggle changed               |

### Granular (change-verb, not pullable)

| Event                  | Payload                           | Fires when                                       |
|------------------------|-----------------------------------|--------------------------------------------------|
| `<TrustChanged>`       | `-jid X -device D -state S`       | one device's trust transitioned                  |
| `<FingerprintChanged>` | `-jid X -device D -fingerprint H` | peer device's IK rotated; trust auto-compromised |
| `<DecryptFailed>`      | `-jid X -device D -reason R`      | live decrypt error                               |

`<FingerprintChanged>` is per-peer; subscribe with `-acc` only (no
`-jid`) for one account-level handler covering every chat.

## GUI bindings

Encryption switch:

```tcl
::tacky observe -tag $win omemo <Enabled> -acc $acc -jid $peer $cmd
tacky omemo setEnabled -acc $acc -jid $peer -value $on
```

Key panel:

```tcl
::tacky observe -tag $win omemo <TrustList> -acc $acc -jid $peer \
    [list RenderKeyPanel $win]
tacky omemo trust -acc $acc -jid $peer -device $dev -state trusted
```

Failed message — branch on `fail_reason`. `'encrypt'` (peer can't do
OMEMO) leads with "resend as plaintext". The row's `server_status` /
`fail_reason` arrive live via `message <Patch>` and on history load via
the row dict.

```tcl
# retry encrypted (keys arrived):
tacky message resend -acc $acc -chat $peer -timestamp $ts
# give up on encryption for this one message:
tacky message resend -acc $acc -chat $peer -timestamp $ts -plaintext 1
```
