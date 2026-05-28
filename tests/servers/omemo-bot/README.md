# OMEMO test peer

A Dockerized OMEMO echo bot peer plus a standalone Python smoke test. 

## How to run
To verify it works
```
tests/servers/with_prosody.sh \
  tests/servers/omemo-bot/with_bot.sh \
    tests/servers/omemo-bot/run-smoke.sh
```
Or then 
```
tests/servers/with_prosody.sh \
  tests/servers/omemo-bot/with_bot.sh \
    tclsh tests/taco_integration/test_omemo.tcl ??? something like this
```

## Accounts

- `bot@example.local` / `botpass` — registered on the prosody container at
  test time by `run-smoke.sh`.
- `test@example.local` / `testpass` — already created by `_lib.sh`'s
  `USERS` list when prosody starts.

## OMEMO version

`slixmpp-omemo==1.0.0` only wires the oldmemo backend into its internal
SessionManager (see `xep_0384.py:482-486` in the upstream wheel — twomemo
is commented out pending SCE). So the bot publishes a devicelist under
`eu.siacs.conversations.axolotl` and never under `urn:xmpp:omemo:2`.
