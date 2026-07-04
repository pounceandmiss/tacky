The tacky command acts as a bridge between the GUI and the backend. All method calls go through it — internally it usually dispatches them by -acc to appropriate internal client objects. Internals can in turn emit tacky events which will reach the frontend. Having a single bridge allows to transparently have the backend run in the same or different thread or process, with no special handling on the frontend.

## events

Backend → gui. The gui registers listeners, tacky dispatches to matching ones.

### listen / unlisten

    tacky listen ?-tag $tag? $module $event ?-field $value ...? $command

Returns a tag id (auto-assigned unless specified). Several listeners can share the same tag. field filters (e.g. `-acc`, `-jid`) narrow which events fire the callback.

    tacky unlisten $tag

Removes all listeners for that tag.

## Calling tacky

general form:

    tacky $module $method  ?...args? ?-tag $tag? ?-command $cb? ?-onerror $errcb?

All args are keyword args. Some args are special and intercepted by tacky, including -command, -tag, -onerror. -command and -onerror are command prefixes that will be called on result or error. 

### cancellation
-tag when supplied to a command can be used in two ways:
Passively stop listening for result from frontend:
    tacky unlisten $tag
Notify backend that we're no longer interested in a result - module-specific.
    tacky $module cancel -acc $acc -tag $tag

E.g. if a widget called a method and asks for a result, but the destructor is called before the result is received, it *must* call tacky unlisten $tag to make sure tacky doesn't try to call it. It *should* also call the module-specific cancel to maybe save some work.

### Event examples

**account**

    account <Added>       -acc $jid
    account <Enabled>     -acc $jid
    account <Disabled>    -acc $jid
    account <Removed>     -acc $jid

**message**

    message <Received>    -acc $acc -jid $chatJid -message $msgDict
    message <Sent>        -acc $acc -jid $chatJid -message $msgDict
    message <Patch>       -jid $chatJid -messages $patchList
    message <CatchupDone> -acc $acc -count $n

**chatlist** (see chatlist.md)

    chatlist <Item>       -jid $jid -item $entry
    chatlist <Remove>     -jid $jid
    chatlist <Changed>

**bookmarks** (see chatlist.md)

    bookmarks <Changed>   -action clear|add|update|remove ?-jid $jid?
    bookmarks <RoomState> -jid $jid -state $state -reason $reason

**setting**

    setting <Changed>     -key $key -value $value

## Method examples

### account

    tacky account list ?-enabled 1? ?-command $cb?
    tacky account exists -acc $jid ?-command $cb?
    tacky account get -acc $jid ?-field username|password|domain|enabled? ?-command $cb?
    tacky account add -acc $jid ?-password $pw? ?-domain $d? ?-username $u?
    tacky account set -acc $jid ?-password $pw? ?-domain $d? ?-username $u? ?-enabled 1?
    tacky account remove -acc $jid
    tacky account enable -acc $jid
    tacky account disable -acc $jid
    tacky account changePassword -acc $jid -password $new ?-command $cb?

### message

    tacky message send -acc $acc -chat $jid -body $text ?-command $cb?
    tacky message history -acc $acc -chat $jid -limit 50 ?-before $ts? ?-after $ts? ?-tag $tag? ?-command $cb?
    tacky message goto -acc $acc -chat $jid -date $timestamp -source local|remote -limit 50 ?-tag $tag? ?-command $cb?
    tacky message cancel -acc $acc -tag $tag
    tacky message rawxml -acc $acc -chat $jid -timestamp $id ?-command $cb?

### chat lists

`tacky chatlist get` returns the whole chat list as one flat list;
see chatlist.md.

### omemo

OMEMO 0.3 (XEP-0384) encryption is automatic for any 1:1 chat whose peer has
published a devicelist. `tacky message send` routes through OMEMO without any
explicit toggle; the methods here exist for the verification UI (showing and
comparing identity-key fingerprints, marking devices trusted / untrusted).

    tacky omemo own_fingerprint -acc $acc ?-command $cb?
    tacky omemo fingerprint     -acc $acc -jid $peerJid -device $deviceId ?-command $cb?
    tacky omemo devicelist      -acc $acc -jid $peerJid ?-command $cb?
    tacky omemo trust           -acc $acc -jid $peerJid -device $deviceId -state $state ?-command $cb?

`own_fingerprint` returns the hex SHA-256 fingerprint of this device's
identity key, or `{}` before the account has finished OMEMO setup
(pre-`<Ready>`). `fingerprint` returns the equivalent for a peer device, or
`{}` if we have no record (no bundle ever fetched, no message decrypted).
Fingerprints are 64-hex-character strings; the GUI typically chunks them
into 8 groups of 8 for display.

`devicelist` returns the cached list of integer device ids for `$peerJid`
as last seen via PEP. An empty list means either the peer doesn't publish
OMEMO devices or our cache hasn't been populated yet (a PEP `+notify`
delivers updates incrementally; `tacky message send` to that peer also
populates it).

`trust` sets the trust state for a single peer device. Valid `-state`
values are `undecided`, `trusted`, `untrusted`. The state machine:

- Free movement among `undecided`, `trusted`, `untrusted`.
- `* -> compromised` is **system-only**: the backend sets it when a bundle
  fetch reveals the peer's identity key has changed. The GUI cannot move a
  device to `compromised`; attempting it throws `OMEMO TRUST_TRANSITION`.
- `compromised -> *` is currently forbidden. Throws `OMEMO TRUST_TRANSITION`.
  A future accept-new-identity-key flow will lift this.

`trust` throws `OMEMO TRUST_NO_DEVICE` if no row exists for the
(`-jid`, `-device`) pair — call `devicelist` first or wait until at least
one message round-trip has populated the row.

#### Setting: `omemo_blindly_trust`

Mirrors Conversations' "Blindly trust before verification" toggle.
Read/write via `tacky setting get/set -key omemo_blindly_trust`. Values
are interpreted with Tcl's `string is true`; default is **on**.

- **`1` / true (default):** new peer devices land in the trust table as
  `undecided` and are still included as encryption recipients — the user
  is opted into the BTBV / TOFU experience. Equivalent to most clients'
  default behavior.
- **`0` / false:** `undecided` devices are excluded from the recipient
  set on send. The user must explicitly mark each new device `trusted`
  via `tacky omemo trust` before it receives any outgoing messages. Use
  this when matching fingerprints out-of-band is part of the workflow.

The setting only affects outbound encryption. Inbound decryption from
`undecided` devices is unaffected — messages from new devices still
arrive, regardless of the setting, since silently dropping them would
lose data with no UI surface to flag it.
