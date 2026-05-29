# OMEMO 0.3 integration tests. Run via:
#   tests/servers/with_prosody.sh tests/servers/omemo-bot/with_bot.sh \
#     tclsh ./test_all.tcl -match omemo-int-*
#
# Wires a `test@example.local` account against the dockerized omemo-bot
# (`bot@example.local`, decrypt+echo) running alongside Prosody. The
# bot is started by with_bot.sh - it publishes its devicelist and bundle
# to PEP via slixmpp-omemo before signalling ready, so prepareChat()
# from our side resolves on the first round-trip.

package require tcltest
package require tacky::testhelpers
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::omemo_int {

    variable HOST "example.local"
    variable TIMEOUT 10000

    variable TESTER "test@example.local"
    variable BOT    "bot@example.local"

    variable _awaitCounter 0

    proc awaitEvent {args} {
        variable TIMEOUT
        set script [lindex $args end]
        set listenerArgs [lrange $args 0 end-1]
        set var [namespace current]::_await_[incr [namespace current]::_awaitCounter]
        set $var ""
        set tag [tacky listen {*}$listenerArgs [list apply {{var argsL} {
            set $var $argsL
        }} $var]]
        uplevel 1 $script
        try {
            ::test::helpers::waitVar $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }
        tacky unlisten $tag
        return [set $var]
    }

    # Register the account and wait for stream <Ready> + initial MAM
    # catchup. Stops short of warming OMEMO, so the bot's devicelist is
    # NOT cached (the bot isn't in our roster, so no PEP +notify warms
    # it either). The cold-send test relies on this.
    proc coldSetup {} {
        variable HOST
        variable TESTER
        tacky account add -acc $TESTER -password testpass \
            -domain $HOST -username test
        tacky account enable -acc $TESTER
        ::test::helpers::waitEvents {
            {conn <Ready> -acc test@example.local}
        }
        ::test::helpers::waitEvents {
            {message <CatchupDone> -acc test@example.local}
        }
    }

    # Post-tacky setup shared by most tests: coldSetup, then warm OMEMO
    # state against the bot (devicelist + bundles cached) so the first
    # encrypt is a hot path. Re-invoked from the persistence test, which
    # tears down and re-creates tacky mid-body.
    proc extraSetup {} {
        variable BOT
        variable TESTER
        coldSetup
        # prepareChat is async since the vwait-removal refactor -
        # wait for it explicitly at the test top level (vwait here is
        # fine; the rule is no vwait inside the business path).
        set client [tacky client $TESTER]
        set ::test::omemo_int::_prepDone 0
        $client omemo prepareChat -jid $BOT -command [list apply {args {
            set ::test::omemo_int::_prepDone 1
        }}]
        if {!$::test::omemo_int::_prepDone} {
            vwait ::test::omemo_int::_prepDone
        }
    }

    proc sendOmemo {body} {
        variable BOT
        variable TESTER
        set ev [awaitEvent message <Received> -acc $TESTER -jid $BOT {
            tacky message send -acc $TESTER -chat_jid $BOT -body $body
        }]
        return $ev
    }

    # Poll until a session row for (bot, dev) exists. Used to await an
    # async Heal: omemo:<SessionReady> is internal-bus only (not exposed
    # to `tacky listen`), so the DB row reappearing is our readiness signal.
    proc waitSessionRow {client tester bot dev} {
        variable TIMEOUT
        set deadline [expr {[clock milliseconds] + $TIMEOUT}]
        while {[clock milliseconds] < $deadline} {
            if {[$client db onecolumn {
                SELECT count(*) FROM omemo_sessions
                WHERE account_jid=$tester AND peer_jid=$bot AND peer_device=$dev
            }] > 0} { return 1 }
            set ::test::omemo_int::_tick 0
            after 100 [list set ::test::omemo_int::_tick 1]
            vwait ::test::omemo_int::_tick
        }
        return 0
    }

    set common [concat {-constraints withServer} \
        [tacky_env -extra-setup { ::test::omemo_int::extraSetup }]]

    set coldCommon [concat {-constraints withServer} \
        [tacky_env -extra-setup { ::test::omemo_int::coldSetup }]]

    # 1. Basic roundtrip.
    test omemo-int-roundtrip {encrypt-send + decrypt-receive against bot} \
        {*}$common -body {
            set ev [sendOmemo "hello bot"]
            set msg [dict get $ev -message]
            string trimright [dict get $msg body]
        } -result {hello bot}

    # 1b. Cold-cache optimistic send: no prepareChat warming. The first
    # send finds no cached devicelist, so encrypt throws NOT_READY and
    # the row is persisted pending (not on the wire). Warming runs in the
    # background; <SessionReady> drives the retry; the bot decrypts and
    # echoes back. Proves the outbox queue->auto-deliver path end to end.
    test omemo-int-cold-send-pends-then-delivers \
        {unwarmed send pends, warms in background, then delivers} \
        {*}$coldCommon -body {
            set client [tacky client $::test::omemo_int::TESTER]
            set bot $::test::omemo_int::BOT
            set ev [awaitEvent message <Received> -acc $::test::omemo_int::TESTER \
                    -jid $bot {
                tacky message send -acc $::test::omemo_int::TESTER \
                    -chat_jid $bot -body "cold hello"
                # Synchronous post-send: encrypt threw NOT_READY, so the
                # row is pending and has no wire stanza yet.
                set ::test::omemo_int::_coldStatus [$client db onecolumn {
                    SELECT server_status FROM chat_message
                    WHERE chat_jid=$bot AND body='cold hello'
                }]
                set ::test::omemo_int::_coldRaw [$client db onecolumn {
                    SELECT on_wire=0 FROM chat_message
                    WHERE chat_jid=$bot AND body='cold hello'
                }]
            }]
            set recv [string trimright [dict get [dict get $ev -message] body]]
            list pending $::test::omemo_int::_coldStatus \
                no_wire $::test::omemo_int::_coldRaw \
                delivered $recv
        } -result {pending pending no_wire 1 delivered {cold hello}}

    # 2. Multiple messages, same session - exercises non-prekey ratchet.
    test omemo-int-multi {ten messages, ten echoes} {*}$common -body {
        set bodies [list]
        for {set i 0} {$i < 10} {incr i} {
            set ev [sendOmemo "msg $i"]
            lappend bodies [string trimright \
                [dict get [dict get $ev -message] body]]
        }
        set bodies
    } -result {{msg 0} {msg 1} {msg 2} {msg 3} {msg 4} {msg 5} {msg 6} {msg 7} {msg 8} {msg 9}}

    # 2b. Non-ASCII body. The picomemo payload codec wants UTF-8 bytes;
    # passing a Tcl string with non-ASCII codepoints throws EPARAM, so
    # encrypt convertto-utf-8's and decrypt convertfrom-utf-8's. CJK
    # exercises 3-byte sequences, the \U-escaped emoji a 4-byte one.
    test omemo-int-unicode-roundtrip {non-ASCII body survives encrypt + decrypt} \
        {*}$common -body {
            set msg "你好 \U0001F44B"
            set ev [sendOmemo $msg]
            expr {[string trimright [dict get [dict get $ev -message] body]] eq $msg}
        } -result 1

    # 4. Heal convergence against a real peer. The echo bot only replies
    # to our sends and can't be driven to desync, so we can't provoke a
    # natural inbound decrypt failure - instead we drop our session and
    # invoke Heal directly. This checks the two things the unit tests
    # can't: (a) BuildSessionFromBundle re-keys from a REAL fetched bundle,
    # and (b) the peer adopts our prekey KeyTransport so traffic resumes
    # on the healed session. sendOmemo is wrapped so a convergence failure
    # reports `converged timeout` rather than erroring the whole test.
    test omemo-int-heal-converges \
        {dropped session: Heal rebuilds from a real bundle + peer re-syncs} \
        {*}$common -body {
            set client [tacky client $::test::omemo_int::TESTER]
            set bot $::test::omemo_int::BOT
            set tester [jid bare $::test::omemo_int::TESTER]
            sendOmemo "warmup"
            set dev [$client db onecolumn {
                SELECT peer_device FROM omemo_sessions
                WHERE account_jid=$tester AND peer_jid=$bot LIMIT 1
            }]
            $client db eval {
                DELETE FROM omemo_sessions
                WHERE account_jid=$tester AND peer_jid=$bot AND peer_device=$dev
            }
            $client omemo Heal $bot $dev
            set rebuilt [::test::omemo_int::waitSessionRow $client $tester $bot $dev]
            set converged timeout
            if {![catch {sendOmemo "after heal"} ev]} {
                set converged [string trimright [dict get [dict get $ev -message] body]]
            }
            list rebuilt $rebuilt converged $converged
        } -result {rebuilt 1 converged {after heal}}

    # 5. Persistence: destroy + recreate, ensure the saved session
    # carries forward. No new prekey establishment required.
    test omemo-int-persistence \
        {session blob from DB drives the next send/recv} \
        {*}$common -body {
            sendOmemo "first"
            catch {tacky destroy}
            tacky_init
            ::test::omemo_int::extraSetup
            set ev [sendOmemo "second"]
            string trimright [dict get [dict get $ev -message] body]
        } -result {second}

    # 5b. Live OMEMO ingress preserves <stanza-id>. The synthesised
    # plaintext stanza used to drop everything except <body>+<encryption>,
    # leaving messagestore with server_id="" for OMEMO rows. That broke
    # MAM dedup on chat reopen and produced ghost messages (see DB
    # forensics in chat with `kurisumakise@draugr.de`). Symptom: the
    # decrypted echo from the bot gets stored with no server_id, so any
    # later MAM backfill of the same stanza inserts a fresh row instead
    # of matching the live one.
    test omemo-int-mam-live-row-has-server-id \
        {decrypted live OMEMO row keeps the server stanza-id for MAM dedup} \
        {*}$common -body {
            sendOmemo "dedup-check"
            set client [tacky client $TESTER]
            # Echo from bot is the inbound row with body 'dedup-check'.
            $client db onecolumn {
                SELECT server_id != '' FROM chat_message
                WHERE chat_jid=$::test::omemo_int::BOT AND kind='message'
                  AND from_jid=$::test::omemo_int::BOT
                  AND body='dedup-check'
                ORDER BY timestamp DESC LIMIT 1
            }
        } -result {1}

    # 6. Reflected message guard: a stanza whose @from is our own bare
    # JID and whose <header sid> is our own device id must be dropped
    # without raising or re-injecting.
    test omemo-int-reflected-guard \
        {self-from + self-sid drops without side effects} \
        {*}$common -body {
            set client [tacky client $::test::omemo_int::TESTER]
            set dev [$client omemo device_id]
            set msg [j message -from $::test::omemo_int::TESTER \
                -type chat {
                    j encrypted -ns eu.siacs.conversations.axolotl {
                        j header -sid $dev {
                            j key -rid $dev .body Zm9v
                            j iv .body AAAAAAAAAAAAAAAA
                        }
                        j payload .body Zm9v
                    }
                }]
            $client omemo OnMessage $msg
        } -result {1}

    # 8. Compromised key: rewrite identity_pk to a bogus value, then
    # confirm both directions refuse.
    test omemo-int-compromised-drops {compromised devices refuse send + receive} \
        {*}$common -body {
            set client [tacky client $::test::omemo_int::TESTER]
            # Force a baseline send so omemo_trust has the bot's row.
            sendOmemo "warmup"
            set bot $::test::omemo_int::BOT
            set tester [jid bare $::test::omemo_int::TESTER]
            set bogus [binary decode hex \
                "ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00"]
            $client db eval {
                UPDATE omemo_trust SET trust='compromised', identity_pk=$bogus
                WHERE account_jid=$tester AND peer_jid=$bot
            }
            set caught 0
            if {[catch {sendOmemo "should fail"} _ opts]} {
                set caught 1
            }
            set caught
        } -result {1}

    # 9. Manual distrust round-trip + sticky compromised assertions.
    test omemo-int-manual-distrust {user distrust + flip back; compromised sticky} \
        {*}$common -body {
            set client [tacky client $::test::omemo_int::TESTER]
            set bot $::test::omemo_int::BOT
            set tester [jid bare $::test::omemo_int::TESTER]
            sendOmemo "warmup"

            # Use one specific bot device id for the sticky checks at
            # the end, but mark EVERY bot device untrusted up front so
            # the encrypt below has zero usable recipients regardless
            # of how many devices the bot publishes.
            set botDevs [$client db eval {
                SELECT peer_device FROM omemo_trust
                WHERE account_jid=$tester AND peer_jid=$bot
            }]
            set botDev [lindex $botDevs 0]
            foreach d $botDevs {
                $client omemo trust -jid $bot -device $d -state untrusted
            }
            puts stderr "DBG botDevs=$botDevs"
            puts stderr "DBG trust rows: [$client db eval {SELECT peer_device, trust FROM omemo_trust WHERE peer_jid=$bot}]"
            puts stderr "DBG cached devicelist: [$client omemo devicelist -jid $bot]"
            # Send no longer throws on encrypt failure - the outbox
            # absorbs the failure and persists the row with
            # server_status='failed' so the GUI can surface a tap-to-
            # retry indicator. Verify by reading back the row.
            tacky message send -acc $::test::omemo_int::TESTER \
                -chat_jid $bot -body "while untrusted"
            set sendFailed [$client db onecolumn {
                SELECT server_status='failed' AND fail_reason='encrypt'
                FROM chat_message
                WHERE chat_jid=$bot AND body='while untrusted'
            }]
            puts stderr "DBG sendFailed=$sendFailed"
            # Flip back to trusted; send works again.
            foreach d $botDevs {
                $client omemo trust -jid $bot -device $d -state trusted
            }
            set ev [sendOmemo "after re-trust"]
            set recv [string trimright [dict get [dict get $ev -message] body]]
            # trust -> compromised refused via API.
            set comprRefused 0
            if {[catch {$client omemo trust -jid $bot -device $botDev -state compromised} \
                    _ opts]} {
                set ecode [dict get $opts -errorcode]
                if {$ecode eq {OMEMO TRUST_TRANSITION}} {
                    set comprRefused 1
                }
            }
            # Force compromised in DB; compromised -> trusted refused.
            $client db eval {
                UPDATE omemo_trust SET trust='compromised'
                WHERE account_jid=$tester AND peer_jid=$bot
            }
            set stickyRefused 0
            if {[catch {$client omemo trust -jid $bot -device $botDev -state trusted} \
                    _ opts]} {
                set ecode [dict get $opts -errorcode]
                if {$ecode eq {OMEMO TRUST_TRANSITION}} {
                    set stickyRefused 1
                }
            }
            list send_failed_when_untrusted $sendFailed \
                roundtrip_after_retrust $recv \
                api_refuses_compromised $comprRefused \
                compromised_sticky $stickyRefused
        } -result {send_failed_when_untrusted 1 roundtrip_after_retrust {after re-trust} api_refuses_compromised 1 compromised_sticky 1}
}
