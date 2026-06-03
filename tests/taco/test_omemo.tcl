# taco_omemo unit tests - exercises the bits of the module that don't
# require a live server: schema, trust-transition validator, skipped-key
# cap, devicelist active/inactive reconciliation, reflected-message
# guard, and decryptForwarded/SynthesisePlain MAM invariants.
#
# JIDs follow the XEP convention: juliet@capulet.lit is "us" (the local
# account under test), romeo@montague.lit is the peer / sender.

package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

namespace eval ::test::omemo_unit {
    variable JULIET      "juliet@capulet.lit/balcony"
    variable JULIET_BARE "juliet@capulet.lit"
    variable ROMEO       "romeo@montague.lit"

    proc stubTacoBtbv {value args} {
        if {[lrange $args 0 1] eq {setting get}} { return $value }
        return ""
    }

    # Settings stub that backs `setting get`/`setting set` with an
    # in-memory array. ::test::omemo_unit::stubStore is keyed by `-key`.
    variable stubStore
    array set stubStore {}
    proc stubTacoSetting {args} {
        variable stubStore
        if {[lindex $args 0] ne "setting"} { return "" }
        set verb [lindex $args 1]
        array set opts [lrange $args 2 end]
        switch -- $verb {
            get { return [expr {[info exists stubStore($opts(-key))]
                                ? $stubStore($opts(-key)) : ""}] }
            set { set stubStore($opts(-key)) $opts(-value); return $opts(-value) }
        }
    }
}

# taco_client's constructor derives -jid from -username + -host and
# clobbers any constructor-provided -jid (client.tcl line 42), so we
# always set -jid via `c configure` in -extra-setup after construction.
set jid_common [tacky_env -taco-client {-db-path :memory:} -extra-setup {
    c configure -jid $::test::omemo_unit::JULIET
    c omemo OnReady
}]

test omemo-unit-schema-created {migrate creates the four tables} \
    {*}$jid_common -body {
        set tables [list]
        c db eval {
            SELECT name FROM sqlite_master WHERE type='table'
              AND name LIKE 'omemo_%' ORDER BY name
        } row {
            lappend tables $row(name)
        }
        set tables
    } -result {omemo_sessions omemo_skipped omemo_store omemo_trust}

test omemo-unit-device-id-nonzero {EnsureStore generates non-zero 31-bit id} \
    {*}$jid_common -body {
        set d [c omemo device_id]
        list nonzero [expr {$d > 0}] width [expr {$d < (1 << 31)}]
    } -result {nonzero 1 width 1}

# Persist test needs two taco_client instances backed by the same
# sqlite handle - outside what tacky_env's single-client layer models,
# so it manages tacky + db + clients itself.
test omemo-unit-device-id-persists {device_id and store persist across reload} -setup {
    tacky_type create ::tacky
    sqlite3 omemodb1 :memory:
    taco_client c1 -db omemodb1
    c1 configure -jid $::test::omemo_unit::JULIET
    c1 omemo OnReady
    set d1 [c1 omemo device_id]
    set fp1 [c1 omemo own_fingerprint]
    c1 destroy
    taco_client c2 -db omemodb1
    c2 configure -jid $::test::omemo_unit::JULIET
} -body {
    c2 omemo OnReady
    set d2 [c2 omemo device_id]
    set fp2 [c2 omemo own_fingerprint]
    list dev_match [expr {$d1 == $d2}] fp_match [expr {$fp1 eq $fp2}]
} -cleanup {
    c2 destroy
    omemodb1 close
    tacky destroy
} -result {dev_match 1 fp_match 1}

test omemo-unit-trust-undecided-to-trusted-ok {free transition} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,x'00','undecided',
                1, 1)
        }
    }] -body {
        c omemo trust -jid romeo@montague.lit -device 1 -state trusted
        c db onecolumn {
            SELECT trust FROM omemo_trust WHERE peer_jid='romeo@montague.lit'
        }
    } -result {trusted}

test omemo-unit-trust-refuse-compromised {* -> compromised is system-only} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,x'00','trusted',1,1)
        }
    }] -body {
        set code [catch {c omemo trust -jid romeo@montague.lit -device 1 -state compromised} _ opts]
        list code $code ecode [dict get $opts -errorcode]
    } -result {code 1 ecode {OMEMO TRUST_TRANSITION}}

test omemo-unit-trust-compromised-sticky {compromised -> trusted refused} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,x'00','compromised',
                1, 1)
        }
    }] -body {
        set code [catch {c omemo trust -jid romeo@montague.lit -device 1 -state trusted} _ opts]
        list code $code ecode [dict get $opts -errorcode]
    } -result {code 1 ecode {OMEMO TRUST_TRANSITION}}

test omemo-unit-trust-untrusted-flips-freely {user can flip untrusted both ways} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,x'00','trusted',1,1)
        }
    }] -body {
        c omemo trust -jid romeo@montague.lit -device 1 -state untrusted
        set s1 [c db onecolumn {SELECT trust FROM omemo_trust}]
        c omemo trust -jid romeo@montague.lit -device 1 -state trusted
        set s2 [c db onecolumn {SELECT trust FROM omemo_trust}]
        list $s1 $s2
    } -result {untrusted trusted}

test omemo-unit-devicelist-deactivates-dropped {dropped devices go active=0} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,x'00','trusted',1,1);
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',2,x'00','trusted',1,1)
        }
        c omemo UpdatePeerDevicelist romeo@montague.lit {1 2}
    }] -body {
        c omemo UpdatePeerDevicelist romeo@montague.lit {1}
        set a1 [c db onecolumn {SELECT active FROM omemo_trust WHERE peer_device=1}]
        set a2 [c db onecolumn {SELECT active FROM omemo_trust WHERE peer_device=2}]
        set t2 [c db onecolumn {SELECT trust FROM omemo_trust WHERE peer_device=2}]
        list active1 $a1 active2 $a2 trust2 $t2
    } -result {active1 1 active2 0 trust2 trusted}

test omemo-unit-skipped-cap-enforced {OnStoreSkipped errors at the 2000th entry} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db transaction {
            for {set i 0} {$i < $::taco::omemo::SKIPPED_CAP} {incr i} {
                c db eval {
                    INSERT INTO omemo_skipped(account_jid, peer_jid,
                        peer_device, dh, nr, mk)
                    VALUES('juliet@capulet.lit','romeo@montague.lit',1,
                        x'00', $i, x'00')
                }
            }
        }
    }] -body {
        set code [catch {
            c omemo OnStoreSkipped romeo@montague.lit 1 [binary decode hex 00] \
                9999 [binary decode hex 00] 1
        } err]
        list code $code msg $err
    } -result {code 1 msg {skipped key cap reached for romeo@montague.lit/1}}

test omemo-unit-reflected-guard-drops-own-echo {server echo of our send is dropped} \
    {*}$jid_common -body {
        set dev [c omemo device_id]
        set msg [j message -from $::test::omemo_unit::JULIET_BARE -type chat {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid $dev {
                    j key -rid $dev .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        c omemo OnMessage $msg
    } -result {1}

test omemo-unit-reflected-guard-allows-cross-device-carbon \
    {carbon from another of our devices passes the guard} \
    {*}$jid_common -body {
        set ourDev [c omemo device_id]
        set otherDev [expr {$ourDev + 1}]
        set msg [j message \
                -from $::test::omemo_unit::JULIET_BARE \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id stanza-1 {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid $otherDev {
                    j key -rid $ourDev .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        c omemo OnMessage $msg
    } -result {1}

test omemo-unit-no-key-for-us-surfaces-error \
    {message with no <key rid=ourdev> returns decrypt_error from DoDecrypt} \
    {*}$jid_common -body {
        set ourDev [c omemo device_id]
        set otherRid [expr {$ourDev + 7}]
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id stanza-1 {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid 42 {
                    j key -rid $otherRid .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        set encNode [lindex [xsearch $msg encrypted \
            -ns eu.siacs.conversations.axolotl] 0]
        c omemo DoDecrypt $encNode $::test::omemo_unit::ROMEO 42 0
    } -result {decrypt_error {[OMEMO] Message not encrypted for this device}}

# MAM-replay invariants (regression coverage for "ghost messages on
# chat reopen"). All four cases used to leak the cleartext EME fallback
# body ("I sent you an OMEMO encrypted message but your client...")
# into the user-visible body column on every MAM backfill.

test omemo-unit-mam-preserves-stanza-id \
    {SynthesisePlain keeps <stanza-id> so messagestore can dedup MAM replays} \
    {*}$jid_common -body {
        set sid "ABCDEF-server-archive-id"
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-1 {
            j {stanza-id} -ns urn:xmpp:sid:0 -id $sid -by $::test::omemo_unit::JULIET_BARE
            j body .body "OMEMO encrypted message fallback"
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid 42 {
                    j key -rid 99 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        set plain [c omemo SynthesisePlain $msg "hello"]
        set sidAttr [xsearch $plain {stanza-id} -ns urn:xmpp:sid:0 -get @id]
        set bodyText [xsearch $plain body -get body]
        set leakedEme [string match "*your client doesn't support OMEMO*" $bodyText]
        list sid $sidAttr body $bodyText leaked $leakedEme
    } -result {sid ABCDEF-server-archive-id body hello leaked 0}

test omemo-unit-mam-self-sent-blanks-body \
    {decryptForwarded on our own outgoing MAM replay emits empty body, not EME fallback} \
    {*}$jid_common -body {
        set ourDev [c omemo device_id]
        set msg [j message \
                -from $::test::omemo_unit::JULIET_BARE \
                -to   $::test::omemo_unit::ROMEO \
                -type chat -id wire-2 {
            j body .body "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid $ourDev {
                    j key -rid 7 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        set out [c omemo decryptForwarded $msg]
        xsearch $out body -get body
    } -result {}

test omemo-unit-mam-untrusted-blanks-body \
    {decryptForwarded with peer device untrusted emits empty body (matches live drop)} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',77,x'00',
                'untrusted',1,1)
        }
    }] -body {
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-3 {
            j body .body "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid 77 {
                    j key -rid 1 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        set out [c omemo decryptForwarded $msg]
        xsearch $out body -get body
    } -result {}

test omemo-unit-mam-no-header-blanks-body \
    {decryptForwarded on malformed encrypted (no <header>) emits empty body} \
    {*}$jid_common -body {
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-4 {
            j body .body "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            j encrypted -ns eu.siacs.conversations.axolotl {
                j payload .body Zm9v
            }
        }]
        set out [c omemo decryptForwarded $msg]
        xsearch $out body -get body
    } -result {}

# Malformed-header robustness: a peer (or hostile server) can send a
# <header sid="abc"> or omit <header> entirely. Both used to throw out
# of the dispatch chain (Tcl's `==` errors on non-numeric operands; the
# old guard read sid before null-checking headerNode).

test omemo-unit-onmessage-nonnumeric-sid-drops \
    {OnMessage with non-numeric @sid drops cleanly without throwing} \
    {*}$jid_common -body {
        set msg [j message \
                -from $::test::omemo_unit::JULIET_BARE \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-nan1 {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid "abc" {
                    j key -rid 1 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        c omemo OnMessage $msg
    } -result {1}

test omemo-unit-onmessage-no-header-drops \
    {OnMessage on <encrypted> with no <header> drops without xsearching empty node} \
    {*}$jid_common -body {
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-nh1 {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j payload .body Zm9v
            }
        }]
        c omemo OnMessage $msg
    } -result {1}

test omemo-unit-mam-nonnumeric-sid-blanks-body \
    {decryptForwarded with non-numeric @sid emits empty body, not EME fallback} \
    {*}$jid_common -body {
        set msg [j message \
                -from $::test::omemo_unit::JULIET_BARE \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-nan2 {
            j body .body "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid "abc" {
                    j key -rid 1 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        set out [c omemo decryptForwarded $msg]
        xsearch $out body -get body
    } -result {}

# BTBV gating: a transient setting-fetch error used to silently
# re-enable blind trust (fail open). With `-taco ""`, `$taco setting get`
# errors and the catch branch must return 0.

test omemo-unit-blindtrust-setting-error-fails-closed \
    {blindTrust returns 0 when setting fetch errors (fail closed)} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET -taco ""
        c omemo OnReady
    }] -body {
        c omemo blindTrust
    } -result {0}

# IsDeviceBlocked with no trust row: was a blanket allow (return 0).
# Now defers to BTBV - on -> allow (parity with `undecided` rows),
# off -> block (no IK pinned, refuse to send).

test omemo-unit-isdeviceblocked-no-row-btbv-on-allows \
    {IsDeviceBlocked with no trust row allows when BTBV is on} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        interp alias {} ::test_taco_btbv_on {} ::test::omemo_unit::stubTacoBtbv true
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_btbv_on
        c omemo OnReady
    } -extra-cleanup {
        interp alias {} ::test_taco_btbv_on {}
    }] -body {
        c omemo IsDeviceBlocked $::test::omemo_unit::ROMEO 42
    } -result {0}

test omemo-unit-isdeviceblocked-no-row-btbv-off-blocks \
    {IsDeviceBlocked with no trust row blocks when BTBV is off (fail closed)} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        interp alias {} ::test_taco_btbv_off {} ::test::omemo_unit::stubTacoBtbv false
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_btbv_off
        c omemo OnReady
    } -extra-cleanup {
        interp alias {} ::test_taco_btbv_off {}
    }] -body {
        c omemo IsDeviceBlocked $::test::omemo_unit::ROMEO 42
    } -result {1}

# Events: every public mutation emits a typed event for the UI to bind to.

# Helper: filter ::_emitted down to omemo events with a specific tag.
proc ::test::omemo_unit::emittedOmemo {tag} {
    set out [list]
    foreach e $::_emitted {
        if {[lindex $e 0] eq "omemo" && [lindex $e 1] eq $tag} {
            lappend out [lrange $e 2 end]
        }
    }
    return $out
}

test omemo-unit-event-devicelist-internal \
    {<Devicelist> stays on the internal bus, not the tacky bridge} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_busDevs 0
        c bus subscribe ::dummy omemo:<Devicelist> \
            [list apply {args { incr ::_busDevs }}]
        set ::_emitted {}
    } -extra-cleanup {
        unset -nocomplain ::_busDevs
    }] -body {
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 2}
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 3}
        list \
            tacky [::test::omemo_unit::emittedOmemo <Devicelist>] \
            bus $::_busDevs
    } -result {tacky {} bus 2}

test omemo-unit-devicelist-resolved-wakes-sender \
    {UpdatePeerDevicelist publishes omemo:<DevicelistResolved> even empty->empty} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_resolved 0
        c bus subscribe ::dummy omemo:<DevicelistResolved> \
            [list apply {args { incr ::_resolved }}]
    } -extra-cleanup {
        unset -nocomplain ::_resolved
    }] -body {
        # Never-seen peer resolving to empty is a no-change (empty->empty)
        # but must still fire, so a blocked send can TERMINAL-fail.
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {}
        set onEmpty $::_resolved
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 2}
        list empty_fired [expr {$onEmpty == 1}] total $::_resolved
    } -result {empty_fired 1 total 2}

test omemo-unit-devicelist-error-caches-empty \
    {a PEP error (peer has no OMEMO node) caches empty + fires resolved} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_resolved 0
        c bus subscribe ::dummy omemo:<DevicelistResolved> \
            [list apply {args { incr ::_resolved }}]
    } -extra-cleanup {
        unset -nocomplain ::_resolved
    }] -body {
        # item-not-found from PEP: peer never published a devicelist.
        set errStanza [j iq -type error -from $::test::omemo_unit::ROMEO {
            j error -type cancel {
                j {item-not-found} -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        c omemo OnFetchedDevicelist $::test::omemo_unit::ROMEO \
            [list apply {args {}}] $errStanza
        # Empty list now cached (so the next encrypt TERMINAL-fails) and
        # the blocked sender is woken.
        list cached [c omemo devicelist -jid $::test::omemo_unit::ROMEO] \
            resolved $::_resolved
    } -result {cached {} resolved 1}

# Eager bundle fetch: on learning a devicelist we fetch a bundle for
# every announced device we haven't keyed yet (own + peer), so the trust
# UI shows them without a message exchange. Skips already-keyed devices
# and our own current device. Uses a mock conn to capture the fetch IQs.
test omemo-unit-eager-bundle-fetch-peer \
    {EnsureBundlesForDevicelist fetches unkeyed peer devices, skips keyed} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        # Pre-key romeo device 2 so it's skipped.
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',2,x'00','trusted',1,1)
        }
    }] -body {
        set before [llength [c conn get_written]]
        c omemo EnsureBundlesForDevicelist $::test::omemo_unit::ROMEO {1 2 3}
        set fetched {}
        foreach s [lrange [c conn get_written] $before end] {
            set node [xsearch $s pubsub items -get @node]
            if {[string match {*axolotl.bundles:*} $node]} {
                lappend fetched [lindex [split $node :] end]
            }
        }
        lsort -integer $fetched
    } -result {1 3}

test omemo-unit-eager-bundle-fetch-skips-own-device \
    {EnsureBundlesForDevicelist skips our own current device} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set ourDev [c omemo device_id]
        set otherDev [expr {$ourDev + 1}]
        set before [llength [c conn get_written]]
        c omemo EnsureBundlesForDevicelist $::test::omemo_unit::JULIET_BARE \
            [list $ourDev $otherDev]
        set fetched {}
        foreach s [lrange [c conn get_written] $before end] {
            set node [xsearch $s pubsub items -get @node]
            if {[string match {*axolotl.bundles:*} $node]} {
                lappend fetched [lindex [split $node :] end]
            }
        }
        # Only the other device is fetched; our own current device skipped.
        list count [llength $fetched] \
            is_other [expr {$fetched eq [list $otherDev]}] \
            own_skipped [expr {$ourDev ni $fetched}]
    } -result {count 1 is_other 1 own_skipped 1}

# =====================================================================
# Session recovery ("heal"): never delete on failure, one
# rate-limited re-key + KeyTransport per peer-device. Most tests observe
# the bundle-fetch IQ; the last drives the real re-key with a minted bundle.

# Count axolotl bundle-fetch IQs for $dev in a list of written stanzas.
proc ::test::omemo_unit::bundleFetches {written dev} {
    set n 0
    foreach s $written {
        set node [xsearch $s pubsub items -get @node]
        if {$node eq "eu.siacs.conversations.axolotl.bundles:$dev"} { incr n }
    }
    return $n
}

# ESTATE (no session) used to be dropped and never recovered.
test omemo-unit-recover-no-session-heals \
    {ESTATE (no session) triggers a bundle-fetch heal} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ESTATE} "no session" {{0 keydata}} 0
        ::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571
    } -result 1

# A broken session must recover without the old DropSession (which left a
# no-session gap and re-keyed every reconnect): row survives, fetch fires.
test omemo-unit-recover-broken-preserves-session \
    {ECORRUPT heals but does not delete the existing session} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_sessions(account_jid, peer_jid, peer_device, blob)
            VALUES('juliet@capulet.lit', 'romeo@montague.lit', 648103571, x'00')
        }
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 0
        list \
            session_rows [c db onecolumn {
                SELECT count(*) FROM omemo_sessions
                WHERE peer_jid='romeo@montague.lit' AND peer_device=648103571
            }] \
            fetches [::test::omemo_unit::bundleFetches \
                [lrange [c conn get_written] $before end] 648103571]
    } -result {session_rows 1 fetches 1}

# Repeated failures for one device heal at most once per window.
test omemo-unit-recover-rate-limited-per-device \
    {two failures for one device produce a single heal} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 0
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 0
        ::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571
    } -result 1

# The old per-connection cap was cleared in OnDisconnect, so reconnects
# defeated it. A failure in-window after a reconnect must not heal.
test omemo-unit-recover-rate-limit-survives-reconnect \
    {heal rate-limit is not reset by OnDisconnect} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 0
        c omemo OnDisconnect
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 0
        ::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571
    } -result 1

# MAM-origin failures postpone; healing mid-catchup would storm on
# replayed history.
test omemo-unit-recover-skips-during-mam \
    {an isMam failure does not heal mid-catchup} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 1
        ::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571
    } -result 0

# A prekey-path failure (malformed/replayed prekey) isn't a broken session; drop it.
test omemo-unit-recover-skips-prekey-failure \
    {a prekey-path failure does not heal} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{1 keydata}} 0
        ::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571
    } -result 0

# Execution half: a real peer bundle (minted from a second store, no
# server) so the re-key and KeyTransport actually run, not just the fetch.
test omemo-unit-heal-rekeys-and-sends-keytransport \
    {AfterHeal builds a session from a real bundle and sends a prekey KeyTransport} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        # A real, validly-signed peer bundle from an independent store.
        omemo::store create peerstore -device 648103571
        peerstore setup
        set bundle [peerstore bundle]
        peerstore destroy

        set before [llength [c conn get_written]]
        c omemo AfterHeal $::test::omemo_unit::ROMEO 648103571 $bundle ""

        set kt 0
        set prekey 0
        foreach s [lrange [c conn get_written] $before end] {
            set enc [lindex [xsearch $s encrypted \
                -ns eu.siacs.conversations.axolotl] 0]
            if {$enc eq ""} continue
            if {[llength [xsearch $enc payload]] != 0} continue
            xsearch $enc header key -script kn {
                if {[xsearch $kn -get @rid] eq "648103571"} {
                    incr kt
                    if {[xsearch $kn -get @prekey] in {true 1}} { set prekey 1 }
                }
            }
        }
        list session_rows [c db onecolumn {
            SELECT count(*) FROM omemo_sessions
            WHERE peer_jid='romeo@montague.lit' AND peer_device=648103571
        }] keytransports $kt prekey $prekey
    } -result {session_rows 1 keytransports 1 prekey 1}

# Companion to skips-during-mam: the deferred heal fires at mam:<QueryEnd>.
test omemo-unit-recover-mam-heal-flushes-at-queryend \
    {a postponed MAM heal fires at mam:<QueryEnd>} \
    {*}[tacky_env -mock conn -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    }] -body {
        set before [llength [c conn get_written]]
        # MAM-origin failure: deferred, no heal yet.
        c omemo HandleDecryptError $::test::omemo_unit::ROMEO 648103571 \
            {OMEMO ECORRUPT} "bad mac" {{0 keydata}} 1
        set deferred [::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571]
        # Query end flushes the postponed heal -> exactly one heal.
        c omemo OnMamQueryEnd
        set flushed [::test::omemo_unit::bundleFetches \
            [lrange [c conn get_written] $before end] 648103571]
        list deferred $deferred flushed $flushed
    } -result {deferred 0 flushed 1}

# Self-chat (chatJid == our own jid): encrypt must never include our own
# current device, and must not double-list other own devices. With only
# our current device announced, there are no recipients -> TERMINAL
# (proves we don't try to encrypt to ourselves, which used to build a
# junk self-session and duplicate keys).
test omemo-unit-self-chat-excludes-own-current-device \
    {encrypt to self with only our own device yields no recipients} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        # Inject an own devicelist containing ONLY our current device.
        set dev [c omemo device_id]
        c omemo OnDevicelist [j message -from $::test::omemo_unit::JULIET_BARE {
            j event -ns http://jabber.org/protocol/pubsub#event {
                j items -node eu.siacs.conversations.axolotl.devicelist {
                    j item {
                        j list -ns eu.siacs.conversations.axolotl {
                            j device -id $dev
                        }
                    }
                }
            }
        }]
    }] -body {
        set code [catch {
            c omemo encrypt $::test::omemo_unit::JULIET_BARE "note to self"
        } _ opts]
        list code $code ecode [dict get $opts -errorcode]
    } -result {code 1 ecode TACO_OMEMO_TERMINAL}

test omemo-unit-devicelist-transient-error-leaves-pending \
    {a transient PEP error does not cache empty or wake (message stays pending)} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_resolved 0
        c bus subscribe ::dummy omemo:<DevicelistResolved> \
            [list apply {args { incr ::_resolved }}]
    } -extra-cleanup {
        unset -nocomplain ::_resolved
    }] -body {
        # service-unavailable (not item-not-found): transient. Must NOT
        # cache empty or fire resolved, so the peer can still turn out
        # OMEMO-capable later. resolved==0 proves UpdatePeerDevicelist
        # (the only thing that fires it) was not called -> cache absent.
        set errStanza [j iq -type error -from $::test::omemo_unit::ROMEO {
            j error -type wait {
                j {service-unavailable} -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
        c omemo OnFetchedDevicelist $::test::omemo_unit::ROMEO \
            [list apply {args {}}] $errStanza
        set ::_resolved
    } -result {0}

test omemo-unit-event-trust-changed \
    {trust tackymethod emits <TrustChanged> on successful state change} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',7,x'00',
                'undecided',1,1)
        }
        set ::_emitted {}
    }] -body {
        c omemo trust -jid romeo@montague.lit -device 7 -state trusted
        ::test::omemo_unit::emittedOmemo <TrustChanged>
    } -result {{-acc juliet@capulet.lit -jid romeo@montague.lit -device 7 -state trusted}}

test omemo-unit-event-trust-no-emit-on-noop \
    {trust to current state is a no-op and emits nothing} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',7,x'00',
                'trusted',1,1)
        }
        set ::_emitted {}
    }] -body {
        c omemo trust -jid romeo@montague.lit -device 7 -state trusted
        ::test::omemo_unit::emittedOmemo <TrustChanged>
    } -result {}

test omemo-unit-event-fingerprint-changed \
    {EnsureTrustRow on IK mismatch emits <FingerprintChanged> + compromised <TrustChanged>} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::oldIk [binary decode hex \
            "1111111111111111111111111111111111111111111111111111111111111111"]
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',9,$::oldIk,
                'trusted',1,1)
        }
        set ::_emitted {}
        set ::newIk [binary decode hex \
            "2222222222222222222222222222222222222222222222222222222222222222"]
    }] -body {
        c omemo EnsureTrustRow romeo@montague.lit 9 $::newIk
        list \
            fp [::test::omemo_unit::emittedOmemo <FingerprintChanged>] \
            tc [::test::omemo_unit::emittedOmemo <TrustChanged>]
    } -result [list \
        fp [list "-acc juliet@capulet.lit -jid romeo@montague.lit -device 9 -fingerprint {[omemo::fingerprint [binary decode hex 2222222222222222222222222222222222222222222222222222222222222222]]}"] \
        tc {{-acc juliet@capulet.lit -jid romeo@montague.lit -device 9 -state compromised}}]

test omemo-unit-event-decrypt-failed \
    {DispatchDecrypt emits <DecryptFailed> when decrypt yields an error} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_emitted {}
    }] -body {
        # Inbound stanza with no <key rid=ourdev> - DoDecrypt returns
        # decrypt_error; DispatchDecrypt should emit before flowing to
        # the message bubble.
        set ourDev [c omemo device_id]
        set msg [j message \
                -from $::test::omemo_unit::ROMEO \
                -to   $::test::omemo_unit::JULIET_BARE \
                -type chat -id wire-df1 {
            j encrypted -ns eu.siacs.conversations.axolotl {
                j header -sid 42 {
                    j key -rid 99 .body Zm9v
                    j iv .body AAAAAAAAAAAAAAAA
                }
                j payload .body Zm9v
            }
        }]
        c omemo OnMessage $msg
        ::test::omemo_unit::emittedOmemo <DecryptFailed>
    } -result {{-acc juliet@capulet.lit -jid romeo@montague.lit -device 42 -reason {[OMEMO] Message not encrypted for this device}}}

test omemo-unit-event-blindtrust \
    {setBlindTrust persists value and emits <BlindTrust>} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        array unset ::test::omemo_unit::stubStore
        interp alias {} ::test_taco_setting {} ::test::omemo_unit::stubTacoSetting
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_setting
        c omemo OnReady
        set ::_emitted {}
    } -extra-cleanup {
        interp alias {} ::test_taco_setting {}
    }] -body {
        set v1 [c omemo blindTrust]
        c omemo setBlindTrust -value 0
        set v2 [c omemo blindTrust]
        list before $v1 after $v2 \
            emits [::test::omemo_unit::emittedOmemo <BlindTrust>]
    } -result {before 1 after 0 emits {{-acc juliet@capulet.lit -value 0}}}

# pull dispatches by -event so `observe` works for multiple pullable events.

test omemo-unit-pull-trustlist \
    {pull -event <TrustList> re-emits current trustList rows} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',5,x'00','trusted',1,1)
        }
        set ::_emitted {}
    }] -body {
        c omemo pull -event <TrustList> -jid $::test::omemo_unit::ROMEO
        set ev [lindex [::test::omemo_unit::emittedOmemo <TrustList>] 0]
        set payload [dict get $ev -trustList]
        set first [lindex $payload 0]
        list jid [dict get $ev -jid] \
            device [dict get $first device] \
            trust [dict get $first trust]
    } -result {jid romeo@montague.lit device 5 trust trusted}

# <TrustList> fires from every per-peer mutation site so observers can
# re-render uniformly.

test omemo-unit-trustlist-event-fires-on-trust-toggle \
    {trust tackymethod re-emits <TrustList> alongside <TrustChanged>} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',5,x'00',
                'undecided',1,1)
        }
        set ::_emitted {}
    }] -body {
        c omemo trust -jid romeo@montague.lit -device 5 -state trusted
        llength [::test::omemo_unit::emittedOmemo <TrustList>]
    } -result {1}

test omemo-unit-trustlist-event-fires-on-devicelist-change \
    {UpdatePeerDevicelist re-emits <TrustList> when set changes} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_emitted {}
    }] -body {
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 2}
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 2}
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1 3}
        llength [::test::omemo_unit::emittedOmemo <TrustList>]
    } -result {2}

test omemo-unit-trustlist-event-fires-on-new-device \
    {EnsureTrustRow INSERT path re-emits <TrustList>} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_emitted {}
    }] -body {
        set ik [binary decode hex \
            "3333333333333333333333333333333333333333333333333333333333333333"]
        c omemo EnsureTrustRow $::test::omemo_unit::ROMEO 11 $ik
        set ev [lindex [::test::omemo_unit::emittedOmemo <TrustList>] 0]
        set first [lindex [dict get $ev -trustList] 0]
        list device [dict get $first device] trust [dict get $first trust]
    } -result {device 11 trust undecided}

test omemo-unit-pull-blindtrust \
    {pull -event <BlindTrust> re-emits current BTBV} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        array unset ::test::omemo_unit::stubStore
        interp alias {} ::test_taco_setting {} ::test::omemo_unit::stubTacoSetting
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_setting
        c omemo OnReady
        c omemo setBlindTrust -value 0
        set ::_emitted {}
    } -extra-cleanup {
        interp alias {} ::test_taco_setting {}
    }] -body {
        c omemo pull -event <BlindTrust>
        ::test::omemo_unit::emittedOmemo <BlindTrust>
    } -result {{-acc juliet@capulet.lit -value 0}}

test omemo-unit-pull-rejects-non-pullable \
    {pull on a change-verb event errors} \
    {*}$jid_common -body {
        catch {c omemo pull -event <TrustChanged> -jid romeo@montague.lit -device 1} err
        set err
    } -result {omemo pull: event <TrustChanged> is not pullable}

# Per-chat OMEMO toggle. Explicit setting wins; unset defaults to peer
# OMEMO-capability (cached non-empty devicelist).

test omemo-unit-enabled-default-on \
    {IsEnabled defaults to on (encrypted) when unset, regardless of capability} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        array unset ::test::omemo_unit::stubStore
        interp alias {} ::test_taco_setting {} ::test::omemo_unit::stubTacoSetting
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_setting
        c omemo OnReady
    } -extra-cleanup {
        interp alias {} ::test_taco_setting {}
    }] -body {
        # On by default with no cached devicelist, and still on once one
        # is cached - capability does not drive the toggle.
        set noCache [c omemo IsEnabled $::test::omemo_unit::ROMEO]
        c omemo UpdatePeerDevicelist $::test::omemo_unit::ROMEO {1}
        set withCache [c omemo IsEnabled $::test::omemo_unit::ROMEO]
        list unset_nocache $noCache unset_cached $withCache
    } -result {unset_nocache 1 unset_cached 1}

test omemo-unit-enabled-explicit-overrides \
    {explicit setEnabled wins over the default-on} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        array unset ::test::omemo_unit::stubStore
        interp alias {} ::test_taco_setting {} ::test::omemo_unit::stubTacoSetting
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_setting
        c omemo OnReady
    } -extra-cleanup {
        interp alias {} ::test_taco_setting {}
    }] -body {
        c omemo setEnabled -jid $::test::omemo_unit::ROMEO -value 0
        set off [c omemo IsEnabled $::test::omemo_unit::ROMEO]
        c omemo setEnabled -jid $::test::omemo_unit::ROMEO -value 1
        set on [c omemo IsEnabled $::test::omemo_unit::ROMEO]
        list off $off on $on
    } -result {off 0 on 1}

test omemo-unit-event-enabled \
    {setEnabled emits <Enabled>; pull re-emits current effective value} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        array unset ::test::omemo_unit::stubStore
        interp alias {} ::test_taco_setting {} ::test::omemo_unit::stubTacoSetting
        c configure -jid $::test::omemo_unit::JULIET -taco ::test_taco_setting
        c omemo OnReady
        set ::_emitted {}
    } -extra-cleanup {
        interp alias {} ::test_taco_setting {}
    }] -body {
        c omemo setEnabled -jid $::test::omemo_unit::ROMEO -value 0
        set onSet [::test::omemo_unit::emittedOmemo <Enabled>]
        set ::_emitted {}
        c omemo pull -event <Enabled> -jid $::test::omemo_unit::ROMEO
        set onPull [::test::omemo_unit::emittedOmemo <Enabled>]
        list set $onSet pull $onPull
    } -result {set {{-acc juliet@capulet.lit -jid romeo@montague.lit -value 0}} pull {{-acc juliet@capulet.lit -jid romeo@montague.lit -value 0}}}

# Internal event: <SessionReady> no longer crosses the tacky bridge.

test omemo-unit-session-ready-internal-only \
    {NotifySessionReady publishes on the internal bus, not via tacky emit} \
    {*}[tacky_env -capture-emit 1 -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_busHits 0
        c bus subscribe ::dummy omemo:<SessionReady> \
            [list apply {args { incr ::_busHits }}]
        set ::_emitted {}
    } -extra-cleanup {
        unset -nocomplain ::_busHits
    }] -body {
        c omemo NotifySessionReady $::test::omemo_unit::ROMEO
        list \
            tacky [::test::omemo_unit::emittedOmemo <SessionReady>] \
            bus $::_busHits
    } -result {tacky {} bus 1}

test omemo-unit-selfready-published \
    {AfterOwnDevicelistFetch publishes omemo:<SelfReady> on the internal bus} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::_selfReady 0
        c bus subscribe ::dummy omemo:<SelfReady> \
            [list apply {args { incr ::_selfReady }}]
    } -extra-cleanup {
        unset -nocomplain ::_selfReady
    }] -body {
        # Pass our own device in the list so the early branch is taken
        # (no DoPublishDevicelist IQ); the wake must still fire.
        set dev [c omemo device_id]
        c omemo AfterOwnDevicelistFetch $::test::omemo_unit::JULIET_BARE [list $dev]
        set ::_selfReady
    } -result {1}

# Aggregate query: trustList returns one dict per known device.

test omemo-unit-trustlist \
    {trustList -jid X returns one row per device with full state} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
        set ::ik1 [binary decode hex \
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        set ::ik2 [binary decode hex \
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
        c db eval {
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',1,$::ik1,'trusted',1,1);
            INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                identity_pk, trust, active, last_activation)
            VALUES('juliet@capulet.lit','romeo@montague.lit',2,$::ik2,'untrusted',0,1)
        }
    }] -body {
        set rows [c omemo trustList -jid romeo@montague.lit]
        list \
            count [llength $rows] \
            r0 [dict get [lindex $rows 0] device] \
                [dict get [lindex $rows 0] trust] \
                [dict get [lindex $rows 0] active] \
                fp_len [string length [dict get [lindex $rows 0] fingerprint]] \
            r1 [dict get [lindex $rows 1] device] \
                [dict get [lindex $rows 1] trust] \
                [dict get [lindex $rows 1] active]
    } -result {count 2 r0 1 trusted 1 fp_len 71 r1 2 untrusted 0}

# Sanity: zero-arg tackymethods accept -command callback delivery so
# the threaded/process tacky bridge can dispatch them.

test omemo-unit-tackymethod-command-callback \
    {device_id with -command delivers the value to the callback} \
    {*}[tacky_env -taco-client {-db-path :memory:} -extra-setup {
        c configure -jid $::test::omemo_unit::JULIET
        c omemo OnReady
    } -extra-cleanup {
        unset -nocomplain ::cbResult
    }] -body {
        set wanted [c omemo device_id]
        set ::cbResult ""
        c omemo device_id -command [list apply {{r} {set ::cbResult $r}}]
        expr {$wanted eq $::cbResult && $wanted ne ""}
    } -result {1}

