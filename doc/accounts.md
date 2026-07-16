# Accounts and setup

## Startup

The backend connects every enabled account on its own at init - there
is no "connect" call to make. The frontend's startup decision is only
what to show:

    tacky account list -enabled 1 -command $cb

Non-empty: open the main UI.
Empty: show the setup flow.

The same check runs in reverse when the last account window closes:
no accounts at all (the last one was removed) means setup again,
otherwise quit.

## Account store

    tacky account list ?-enabled 0|1? -command $cb - account JIDs
    tacky account exists -acc $jid - 0|1
    tacky account get -acc $jid ?-field $f? - field dict, or one field
    tacky account add -acc $jid ?-password $p? ?-username $u? ?-domain $d?
    tacky account set -acc $jid -$field $value ...
    tacky account remove -acc $jid
    tacky account enable -acc $jid
    tacky account disable -acc $jid
    tacky account changePassword -acc $jid -password $new -command $cb

Fields are `username`, `domain`, `password`, `resource`, `enabled`. `add`
creates or updates; on create, username and domain default to the JID's
parts. `enable` persists the flag and connects; `disable` disconnects
and persists. `remove` disconnects and deletes the account row and
its per-account cache database. `changePassword` changes the password
server-side (XEP-0077) and, on success, updates the stored one; the
callback gets `ok ""` or `error $message`.

Store changes arrive as events:

    tacky listen account <Added|Removed|Enabled|Disabled> $command
        -acc $jid

`<Added>`, `<Removed>`, and `<Enabled>` fire once per real transition
(enabling an already-enabled account is a no-op and emits nothing).
`<Disabled>` fires on every `disable` call, including one that was
already disabled - treat it as idempotent, not as an edge signal.

## Connection state

Per-account connection lifecycle, all carrying `-acc`:

    tacky listen conn <State> -acc $a $cmd
        -state disconnected|connecting|authenticating|binding|connected|waiting

    tacky listen conn <Ready> -acc $a $cmd        fully online (-resumed 0|1)
    tacky listen conn <ConnError> -acc $a $cmd    transport failure (-message)
    tacky listen conn <AuthError> -acc $a $cmd    credentials rejected (-message)

`<State>` fires on every transition and drives a status indicator.
Transport failures are retried forever with backoff: `<ConnError>`
reports the reason, `-state waiting` is the pause between attempts,
and `connected` clears the error. `<AuthError>` is terminal - auth
errors are not transient, so the backend stops until the account is
re-enabled (e.g. after fixing the password).

`<State>` and `<ConnError>` are pullable: subscribe with `tacky
observe` instead of `listen` to also receive the current value
immediately.

## Sign-in

There is no separate "verify credentials" call - signing in is
creating the account and watching the connection:

    tacky listen conn <Ready> -acc $jid ...        success
    tacky listen conn <AuthError> -acc $jid ...    bad credentials
    tacky listen conn <ConnError> -acc $jid ...    network/server failure
    tacky account add -acc $jid -password $pw
    tacky account enable -acc $jid

On `<Ready>`, keep the account and proceed to the main UI. On a
failure (show `-message`), or if the user cancels, `tacky account
remove -acc $jid` - the account was stored before validation, so an
aborted sign-in must clean it up. Note that `<ConnError>` is not
terminal (the backend keeps retrying).

## Sign-up (in-band registration)

XEP-0077 registration runs on its own throwaway connection, separate
from the account store. A session is identified by `-token` (any
unique string; the reference uses the widget path), so concurrent
attempts don't clash.

    tacky register connect -host $server ?-port $p? -token $t
    tacky register form -token $t -command $cb
    tacky register media -token $t -var $v -command $cb
    tacky register submit -token $t -values {var value ...}
    tacky register cancel -token $t

    tacky listen register <Form> -token $t $cmd        form ready to fetch
    tacky listen register <MediaReady> -token $t $cmd  CAPTCHA image (-var)
    tacky listen register <Success> -token $t $cmd
    tacky listen register <Error> -token $t $cmd       failed (-message)

The flow: `connect`, wait for `<Form>`, fetch the field list with
`form` and render it (`username` and `password` are typical fields,
but the set is server-defined; `<MediaReady>` supplies CAPTCHA bytes
for a field via `media`), then `submit` the filled values. `<Error>`
can fire at either step; the form may need re-fetching after a failed
submit (e.g. an expired CAPTCHA).

On `<Success>` the server-side account exists, but the local store
knows nothing yet - finish exactly like sign-in:

    tacky account add -acc $username@$server -password $pw
    tacky account enable -acc $username@$server

`cancel` (or destroying the widget) tears the session down at any
point.
