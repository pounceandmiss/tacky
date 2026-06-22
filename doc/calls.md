# Voice calls

Audio calls over Jingle (XEP-0166/0167/0176), rung through Jingle
Message Initiation (XEP-0353). 

## API

    tacky calls start  -acc $jid -to $barejid -command $cb   ;# returns sid
    tacky calls accept -acc $jid -sid $sid
    tacky calls reject -acc $jid -sid $sid ?-reason decline?
    tacky calls hangup -acc $jid -sid $sid ?-reason success?
    tacky calls setDevices -acc $jid -sid $sid ?-input $id? ?-output $id?

`start` returns the session id used to address the call. `setDevices`
overrides mic/speaker for this one call; empty id means system
default.  

## Events

    tacky listen calls <Outgoing> $cmd   ;# -sid -to     we are calling out
    tacky listen calls <Incoming> $cmd   ;# -sid -from   someone is calling us
    tacky listen calls <Ringing>  $cmd   ;# -sid         peer device is alerting
    tacky listen calls <Active>   $cmd   ;# -sid         RTP is flowing
    tacky listen calls <Ended>    $cmd   ;# -sid         normal teardown
    tacky listen calls <Failed>   $cmd   ;# -sid -reason unrecoverable
    tacky listen calls <Warning>  $cmd   ;# -sid -reason non-fatal, call continues

A call ends on exactly one of `<Ended>` or `<Failed>`. `<Warning>` is
informational (e.g. a device went away mid-call) and does not end the
call.

## Flow

Caller:

- `start` sends a JMI `propose` to the bare JID, emits `<Outgoing>`
- peer device replies `ringing` -> `<Ringing>`
- peer device replies `proceed` -> fetch ICE servers, build the
  offer, send `session-initiate`, trickle candidates
- peer `session-accept` applies the answer; media connects ->
  `<Active>`

Callee:

- inbound `propose` -> `<Incoming>`, auto-replies `ringing`
- `accept` sends `proceed`; media setup waits for `session-initiate`
- `session-initiate` applies the offer and sends `session-accept`

Either side hangs up with `hangup`. Before media is up the caller
`retract`s instead of terminating; after that it is a Jingle
`session-terminate`. Both produce `<Ended>`.


