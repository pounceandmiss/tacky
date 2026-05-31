# taco_omemo - OMEMO 0.3 (XEP-0384) on top of picomemo.
#
# Sits in client.tcl's message dispatch chain between calls and message.
# Returns 1 from OnMessage if the stanza was OMEMO (claimed); the decrypt
# path synthesises a plaintext <message> and hands it back to the chain.
#
# Public API (UI-facing tackymethods; all accept -command/-onerror):
#   tacky omemo device_id       -acc $jid                    -> int
#   tacky omemo account_jid     -acc $jid                    -> bare jid
#   tacky omemo own_fingerprint -acc $jid                    -> hex or {}
#   tacky omemo devicelist      -acc $jid -jid $j            -> list of dev ids
#   tacky omemo trust           -acc $jid -jid $j -device $d -state $s
#                                                           -> set trust state
#                                                              (validates transitions)
#   tacky omemo trustList       -acc $jid -jid $j            -> list of dicts
#                                                              {device trust active fingerprint}
#   tacky omemo blindTrust      -acc $jid                    -> 0|1 (BTBV setting)
#   tacky omemo setBlindTrust   -acc $jid -value 0|1         -> persists BTBV setting
#   tacky omemo setEnabled      -acc $jid -jid $j -value 0|1 -> per-chat OMEMO toggle
#                                                              (read internally via IsEnabled;
#                                                               GUI observes <Enabled>)
#
# Async (plain method; pass -command):
#   $client omemo prepareChat -jid $j ?-command cb?         -> warms peer cache
#
# Internal (caller is taco_message):
#   $client omemo encrypt $chat_jid $plaintext              -> <encrypted> node
#
# Events (tacky listen / tacky observe - noun-named events are pullable):
#   omemo <TrustList>           -jid $peerJid -trustList L  full trustList rebuilt
#                                                           (fires on any per-peer trust
#                                                           mutation: device add/drop,
#                                                           trust toggle, IK rotation)
#                                                           [pullable]
#   omemo <BlindTrust>          -value 0|1                  BTBV setting [pullable]
#   omemo <Enabled>             -jid $peerJid -value 0|1    per-chat OMEMO toggle [pullable]
#   omemo <TrustChanged>        -jid $peerJid -device D -state S   trust row mutated
#                                                                  (granular companion to
#                                                                  <TrustList>)
#   omemo <FingerprintChanged>  -jid $peerJid -device D -fingerprint H
#                                                           peer device IK rotated - security
#                                                           alert (also auto-flips trust=compromised)
#   omemo <DecryptFailed>       -jid $peerJid -device D -reason R   live decrypt error
#
# Internal-only ($client bus, no external tacky fan-out):
#   omemo:<SessionReady>        -jid $peerJid               per peer-device ratchet built
#                                                           - drives message.tcl retry
#   omemo:<DevicelistResolved>  -jid $peerJid               devicelist fetched/notified
#                                                           (devices or empty) - wakes
#                                                           message.tcl to re-run encrypt
#                                                           (success / warming / TERMINAL)
#   omemo:<SelfReady>           (no args)                   our store + own devicelist
#                                                           ready - retries account-wide
#                                                           pending sends blocked on them
#   omemo:<Devicelist>          -jid $peerJid -devices L    raw PEP devicelist cache delta
#                                                           - backend-only signal
#
# Storage lives in the shared client SQLite (same DB messagestore uses).
# Tables: omemo_store, omemo_sessions, omemo_skipped, omemo_trust.
#
# Trust model: BTBV with four states (undecided, trusted, untrusted,
# compromised). The compromised state is system-set (identity-key
# change detected at bundle fetch) and sticky - only a future GUI
# accept-new-key flow can clear it. See the "Trust model" section of
# the implementation plan.

package require omemo
package require base64
package require sqlite3

namespace eval ::taco::omemo {
    variable NS_AXOLOTL eu.siacs.conversations.axolotl
    variable NS_DEVICELIST eu.siacs.conversations.axolotl.devicelist
    variable NS_BUNDLES eu.siacs.conversations.axolotl.bundles
    variable NS_PUBSUB http://jabber.org/protocol/pubsub
    variable NS_EME urn:xmpp:eme:0
    variable SKIPPED_CAP 2000
    # Curve25519 public-key type tag (= libsignal Curve.DJB_TYPE): the
    # one-byte prefix on the 33-byte wire form of a key.
    variable DJB_TYPE "\x05"
    # Min interval between heals to one peer-device. Survives
    # reconnect (see HealAt) to stop a re-key ping-pong.
    variable HEAL_WINDOW_MS 60000

    # OMEMO 0.3 wire format (matches libsignal / oldmemo) carries
    # Curve25519 public keys as 33 bytes: a 0x05 DJB-type prefix
    # followed by the 32-byte raw key. picomemo's $store bundle yields
    # the raw 32 bytes (and $sess initiate expects raw 32 bytes too).
    # We add the prefix on publish and strip it on parse.
    proc prefixDjb {bytes} { return "${::taco::omemo::DJB_TYPE}${bytes}" }
    proc stripDjb {bytes} {
        if {[string length $bytes] == 33 \
                && [string index $bytes 0] eq $::taco::omemo::DJB_TYPE} {
            return [string range $bytes 1 end]
        }
        return $bytes
    }
}

snit::type taco_omemo {
    option -client -readonly yes

    variable client
    variable db
    variable accountJid ""

    # picomemo store handle. Lazy-created on session_start (after we
    # know our bare JID).
    variable store ""
    variable deviceId ""

    # Per-(peer_jid, peer_device) session command handle. Sessions are
    # explicit-destroy in picomemo; map[$jid|$dev] -> $cmd
    variable Sessions

    # In-memory devicelist cache: jid -> list of int device ids.
    # Populated from devicelist PEP arrivals.
    variable DeviceLists

    # Per-(peer_jid, peer_device) cached bundle dict (latest fetch).
    # Cleared on devicelist change for that peer.
    variable Bundles

    # In-flight bundle fetch promises: key=(jid|dev), val=list of
    # callbacks to fire when fetch resolves.
    variable BundleFetchWaiters

    # MAM postpone state, drained at mam:<QueryEnd> only when mamHadOmemo
    # is set (so a MAM page with no OMEMO traffic skips the flush).
    #   Postponed:           side effects from successful MAM decrypts
    #                        (bundle republish).
    #   PostponedHeartbeats: (peer,device) keys needing a heartbeat.
    #   PostponedHealing:    broken-session (peer,device) keys from failed
    #                        MAM decrypts; one Heal each at query end,
    #                        rate-limited by HealAt.
    # Concurrent MAM on two chats can drain both at the first query end;
    # the second re-drains what accumulated after (cost: a deduped
    # republish, maybe a heartbeat). Live decrypts (isMam=0) heal and run
    # side effects immediately, never postponed.
    variable mamHadOmemo 0
    variable Postponed
    variable PostponedHealing
    variable PostponedHeartbeats

    # Heal rate-limit: "$jid|$dev" -> earliest clock-ms we may heal again.
    # NOT cleared in OnDisconnect, so reconnects can't re-key in a loop.
    variable HealAt

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]
        set Sessions [dict create]
        set DeviceLists [dict create]
        set Bundles [dict create]
        set BundleFetchWaiters [dict create]
        set Postponed [list]
        set PostponedHealing [dict create]
        set PostponedHeartbeats [dict create]
        set HealAt [dict create]

        $self Migrate

        # Storage callbacks: skipped-key delete-on-read + 2000-key cap.
        omemo::set_storage \
            -load  [mymethod OnLoadSkipped] \
            -store [mymethod OnStoreSkipped]

        # PEP devicelist subscription (filtered notify via caps).
        $client pubsub handler $::taco::omemo::NS_DEVICELIST \
            [mymethod OnDevicelist]
        $client caps addFeature ${::taco::omemo::NS_DEVICELIST}+notify

        # Per-query MAM signal: mam.tcl emits mam:<QueryEnd> at OnFin.
        # We use it to flush Postponed for queries that decrypted at
        # least one OMEMO message - see the mamHadOmemo / Postponed
        # commentary in the variable block.
        $client bus subscribe $self <Ready>         [mymethod OnReady]
        $client bus subscribe $self <Disconnect>    [mymethod OnDisconnect]
        $client bus subscribe $self mam:<QueryEnd>  [mymethod OnMamQueryEnd]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        catch {$client pubsub unhandler $::taco::omemo::NS_DEVICELIST}
        dict for {key sess} $Sessions {
            catch {$sess destroy}
        }
        if {$store ne ""} { catch {$store destroy} }
    }

    method Migrate {} {
        $db eval {
            CREATE TABLE IF NOT EXISTS omemo_store(
                account_jid TEXT PRIMARY KEY,
                device_id   INTEGER NOT NULL,
                blob        BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS omemo_sessions(
                account_jid TEXT NOT NULL,
                peer_jid    TEXT NOT NULL,
                peer_device INTEGER NOT NULL,
                blob        BLOB NOT NULL,
                PRIMARY KEY (account_jid, peer_jid, peer_device)
            );
            CREATE TABLE IF NOT EXISTS omemo_skipped(
                account_jid TEXT NOT NULL,
                peer_jid    TEXT NOT NULL,
                peer_device INTEGER NOT NULL,
                dh          BLOB NOT NULL,
                nr          INTEGER NOT NULL,
                mk          BLOB NOT NULL,
                PRIMARY KEY (account_jid, peer_jid, peer_device, dh, nr)
            );
            CREATE TABLE IF NOT EXISTS omemo_trust(
                account_jid     TEXT NOT NULL,
                peer_jid        TEXT NOT NULL,
                peer_device     INTEGER NOT NULL,
                identity_pk     BLOB NOT NULL,
                trust           TEXT NOT NULL
                                CHECK (trust IN
                                    ('undecided','trusted','untrusted','compromised')),
                active          INTEGER NOT NULL DEFAULT 1,
                last_activation INTEGER NOT NULL,
                PRIMARY KEY (account_jid, peer_jid, peer_device)
            );
        }
    }

    # =====================================================================
    # Lifecycle
    # =====================================================================

    method OnReady {args} {
        set accountJid [jid bare [$client cget -jid]]
        $self EnsureStore
        # Republish our devicelist (no-op if already on-list) and our
        # bundle. Both go through pubsub with publish-options.
        $self PublishDevicelist
        $self PublishBundle
    }

    method OnDisconnect {args} {
        # Drop in-memory caches so the next connection is unconditioned.
        # HealAt is kept on purpose - it must outlive reconnects.
        set DeviceLists [dict create]
        set Bundles [dict create]
        set BundleFetchWaiters [dict create]
        set Postponed [list]
        set PostponedHealing [dict create]
        set PostponedHeartbeats [dict create]
        set mamHadOmemo 0
    }

    method OnMamQueryEnd {args} {
        # Guard: only flush when an OMEMO decrypt actually happened in
        # MAM context since the last flush. Cheap noop otherwise.
        if {!$mamHadOmemo} return
        set mamHadOmemo 0
        $self FlushPostponed
    }

    method FlushPostponed {} {
        set actions $Postponed
        set Postponed [list]
        set didRepublish 0
        foreach a $actions {
            switch -- [lindex $a 0] {
                republish_bundle {
                    if {!$didRepublish} {
                        $self PublishBundle
                        set didRepublish 1
                    }
                }
            }
        }
        set hbs [dict keys $PostponedHeartbeats]
        set PostponedHeartbeats [dict create]
        foreach key $hbs {
            lassign [split $key |] pj pd
            $self SendHeartbeat $pj $pd
        }
        set heals [dict keys $PostponedHealing]
        set PostponedHealing [dict create]
        foreach key $heals {
            lassign [split $key |] pj pd
            $self Heal $pj $pd
        }
    }

    # =====================================================================
    # Store and device-id
    # =====================================================================

    method EnsureStore {} {
        if {$store ne ""} return
        set row [$db eval {
            SELECT device_id, blob FROM omemo_store WHERE account_jid=$accountJid
        }]
        set store ${selfns}::store
        if {[llength $row] == 0} {
            set deviceId [$self GenerateDeviceId]
            omemo::store create $store -device $deviceId
            $store setup
            $self PersistStore
        } else {
            lassign $row deviceId blob
            omemo::store create $store -device $deviceId
            $store deserialize $blob
        }
    }

    method GenerateDeviceId {} {
        # 31-bit non-zero. Loop on the (vanishingly unlikely) zero draw.
        set ch [open /dev/urandom rb]
        try {
            while {1} {
                set raw [read $ch 4]
                binary scan $raw Iu n
                set n [expr {$n & 0x7fffffff}]
                if {$n != 0} { return $n }
            }
        } finally {
            close $ch
        }
    }

    method PersistStore {} {
        set blob [$store serialize]
        $db eval {
            INSERT OR REPLACE INTO omemo_store(account_jid, device_id, blob)
            VALUES($accountJid, $deviceId, $blob)
        }
    }

    method PersistSession {peerJid peerDev sess} {
        set blob [$sess serialize]
        $db eval {
            INSERT OR REPLACE INTO omemo_sessions
                (account_jid, peer_jid, peer_device, blob)
            VALUES($accountJid, $peerJid, $peerDev, $blob)
        }
    }

    # A session for $peerJid became usable for outbound (rehydrated from
    # DB, built from a bundle, or established by inbound decrypt).
    # taco_message retries pending sends that hit TACO_OMEMO_NOT_READY.
    # Internal bus only (per peer-device, not GUI-relevant).
    method NotifySessionReady {peerJid} {
        $client bus publish omemo:<SessionReady> -jid $peerJid
    }

    # =====================================================================
    # Storage callbacks (skipped-key)
    # =====================================================================

    method OnLoadSkipped {peerJid peerDev dh nr} {
        set rows [$db eval {
            SELECT mk FROM omemo_skipped
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid
              AND peer_device=$peerDev
              AND dh=$dh AND nr=$nr
        }]
        if {[llength $rows] == 0} { return {} }
        $db eval {
            DELETE FROM omemo_skipped
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid
              AND peer_device=$peerDev
              AND dh=$dh AND nr=$nr
        }
        return [lindex $rows 0]
    }

    method OnStoreSkipped {peerJid peerDev dh nr mk n} {
        # n is picomemo's hint for the size of the current skip batch;
        # we enforce a per-(peer,device) total cap instead.
        set count [$db onecolumn {
            SELECT COUNT(*) FROM omemo_skipped
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid
              AND peer_device=$peerDev
        }]
        if {$count >= $::taco::omemo::SKIPPED_CAP} {
            error "skipped key cap reached for $peerJid/$peerDev"
        }
        $db eval {
            INSERT OR REPLACE INTO omemo_skipped
                (account_jid, peer_jid, peer_device, dh, nr, mk)
            VALUES($accountJid, $peerJid, $peerDev, $dh, $nr, $mk)
        }
    }

    # =====================================================================
    # Devicelist
    # =====================================================================

    method PublishDevicelist {} {
        # If we already know our own list and we're on it, no-op.
        if {[dict exists $DeviceLists $accountJid]
            && $deviceId in [dict get $DeviceLists $accountJid]} {
            return
        }
        # Otherwise fetch and rebuild. The first fetch + republish loop
        # converges in one round-trip.
        $self FetchDevicelist $accountJid \
            [mymethod AfterOwnDevicelistFetch]
    }

    method AfterOwnDevicelistFetch {jid devices} {
        if {$deviceId in $devices} {
            dict set DeviceLists $accountJid $devices
        } else {
            lappend devices $deviceId
            dict set DeviceLists $accountJid $devices
            $self DoPublishDevicelist $devices
        }
        # Key our own OTHER devices so they appear in the "my keys" UI.
        $self EnsureBundlesForDevicelist $accountJid $devices
        # Account-level prerequisites (store + own devicelist) are now in
        # place. Wake any send that pended on them this connection, since
        # message.tcl's reconnect RetryPending ran before omemo's OnReady.
        $client bus publish omemo:<SelfReady>
    }

    method DoPublishDevicelist {devices} {
        set node $::taco::omemo::NS_DEVICELIST
        set ns $::taco::omemo::NS_PUBSUB
        $client iq request -type set -payload [j pubsub -ns $ns {
            j publish -node $node {
                j item -id current {
                    j list -ns $::taco::omemo::NS_AXOLOTL {
                        foreach d $devices {
                            j device -id $d
                        }
                    }
                }
            }
            j publish-options {
                j x -ns jabber:x:data -type submit {
                    j field -var FORM_TYPE -type hidden {
                        j value .body \
                            "http://jabber.org/protocol/pubsub#publish-options"
                    }
                    j field -var pubsub#persist_items {
                        j value .body true
                    }
                    j field -var pubsub#max_items {
                        j value .body 1
                    }
                    j field -var pubsub#access_model {
                        j value .body open
                    }
                }
            }
        }]
    }

    method FetchDevicelist {peerJid command} {
        set node $::taco::omemo::NS_DEVICELIST
        set ns $::taco::omemo::NS_PUBSUB
        set toArgs [list]
        if {$peerJid ne $accountJid} { set toArgs [list -to $peerJid] }
        $client iq request -type get {*}$toArgs \
            -payload [j pubsub -ns $ns {
                j items -node $node
            }] \
            -command [mymethod OnFetchedDevicelist $peerJid $command]
    }

    method OnFetchedDevicelist {peerJid command stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            jlog debug "devicelist fetch for $peerJid: ERROR ([xsearch $stanza error -get @type])"
            # item-not-found = the peer has no devicelist node: a
            # definitive "no OMEMO". Cache an empty list so encrypt()
            # hits TERMINAL and the pending message fails (the GUI offers
            # resend-as-plaintext) instead of hanging. Any other error is
            # transient (timeout, server hiccup): leave the cache absent
            # so a later +notify or reconnect re-fetch can still
            # establish OMEMO, and let the message stay pending.
            set noNode 0
            set errNodes [xsearch $stanza error]
            if {[llength $errNodes] > 0
                && [llength [xsearch [lindex $errNodes 0] item-not-found]] > 0} {
                set noNode 1
            }
            if {$peerJid ne $accountJid && $noNode} {
                $self UpdatePeerDevicelist $peerJid {}
            }
            {*}$command $peerJid {}
            return
        }
        set devices [$self ParseDevicelist $stanza]
        jlog debug "devicelist fetch for $peerJid: [llength $devices] device(s) = $devices"
        # Populate the DeviceLists cache (and reconcile trust-active
        # rows) for peers, so encrypt() sees the result without depending
        # on a separate PEP +notify push. OWN jid takes its own
        # AfterOwnDevicelistFetch path (which may add our id and
        # republish), so skip the peer update there.
        if {$peerJid ne $accountJid} {
            $self UpdatePeerDevicelist $peerJid $devices
        }
        {*}$command $peerJid $devices
    }

    method ParseDevicelist {stanza} {
        set devices [list]
        set listNodes [xsearch $stanza pubsub items item list \
            -ns $::taco::omemo::NS_AXOLOTL]
        if {[llength $listNodes] == 0} {
            # PEP notification shape: <event><items><item><list>...
            set listNodes [xsearch $stanza event items item list \
                -ns $::taco::omemo::NS_AXOLOTL]
        }
        if {[llength $listNodes] == 0} { return $devices }
        xsearch [lindex $listNodes 0] device -script dn {
            set id [xsearch $dn -get @id]
            if {$id ne ""} { lappend devices $id }
        }
        return $devices
    }

    method OnDevicelist {stanza} {
        set from [xsearch $stanza -get @from]
        set peerJid [expr {$from eq "" ? $accountJid : [jid bare $from]}]
        set devices [$self ParseDevicelist $stanza]
        jlog debug "devicelist +notify from $peerJid: [llength $devices] device(s) = $devices"
        if {$peerJid eq $accountJid} {
            dict set DeviceLists $accountJid $devices
            if {$deviceId ne "" && $deviceId ni $devices} {
                lappend devices $deviceId
                dict set DeviceLists $accountJid $devices
                $self DoPublishDevicelist $devices
            }
            # Key our own other devices (own devicelist via +notify).
            $self EnsureBundlesForDevicelist $accountJid $devices
            return
        }
        $self UpdatePeerDevicelist $peerJid $devices
    }

    # Reconcile a peer's new devicelist with omemo_trust.active state.
    # Old devices not in the new list go inactive; reappearing ones come
    # back. Bundles cache is invalidated since fingerprints may change.
    method UpdatePeerDevicelist {peerJid devices} {
        set oldDevices [list]
        if {[dict exists $DeviceLists $peerJid]} {
            set oldDevices [dict get $DeviceLists $peerJid]
        }
        dict set DeviceLists $peerJid $devices
        set changed [expr {[lsort -integer $oldDevices] ne [lsort -integer $devices]}]

        set now [clock milliseconds]
        # Mark dropped devices inactive (retain trust row).
        foreach dev $oldDevices {
            if {$dev ni $devices} {
                $db eval {
                    UPDATE omemo_trust SET active=0
                    WHERE account_jid=$accountJid
                      AND peer_jid=$peerJid
                      AND peer_device=$dev
                }
            }
        }
        # Reactivate or note new ones.
        foreach dev $devices {
            set exists [$db onecolumn {
                SELECT 1 FROM omemo_trust
                WHERE account_jid=$accountJid
                  AND peer_jid=$peerJid AND peer_device=$dev
            }]
            if {$exists ne ""} {
                $db eval {
                    UPDATE omemo_trust SET active=1, last_activation=$now
                    WHERE account_jid=$accountJid
                      AND peer_jid=$peerJid AND peer_device=$dev
                }
            }
            # If unknown, trust row is created on first bundle fetch.
            dict unset Bundles "$peerJid|$dev"
        }
        if {$changed} {
            # Internal-only: raw PEP cache delta, not the right shape for
            # GUI panels (which want trustList). Kept on the bus so other
            # backend modules can react if needed.
            $client bus publish omemo:<Devicelist> \
                -jid $peerJid -devices $devices
            $self EmitTrustList $peerJid
        }
        # Wake any send blocked on this peer's devicelist: now that it has
        # resolved, taco_message re-runs encrypt, which succeeds, stays
        # pending (warming), or TERMINAL-fails on an empty list. Fires
        # unconditionally - a never-seen peer resolving to empty is a
        # no-change (empty->empty) yet is exactly the case to wake.
        $client bus publish omemo:<DevicelistResolved> -jid $peerJid
        $self EnsureBundlesForDevicelist $peerJid $devices
    }

    # Fetch bundles for announced devices we haven't keyed yet, so the
    # trust UI shows each device's fingerprint before any message exchange
    # (mirrors Dino). Skips our own current device and already-keyed rows.
    method EnsureBundlesForDevicelist {jid devices} {
        foreach dev $devices {
            if {$jid eq $accountJid && $dev == $deviceId} continue
            set have [$db onecolumn {
                SELECT 1 FROM omemo_trust
                WHERE account_jid=$accountJid
                  AND peer_jid=$jid AND peer_device=$dev
            }]
            if {$have ne ""} continue
            jlog debug "eager bundle fetch $jid/$dev (unkeyed announced device)"
            $self FetchBundle $jid $dev [list apply {args {}}]
        }
    }

    # =====================================================================
    # Bundle
    # =====================================================================

    method PublishBundle {} {
        # No MAM gate here: callers (OnReady, ApplyPrekeySideEffects
        # with isMam=0, FlushPostponed's republish action) decide
        # whether the publish is appropriate. The work is split in
        # two: fetch the server's currently-published bundle, then
        # republish only on a field-level mismatch (mirrors
        # Conversations' publishBundlesIfNeeded).
        set node ${::taco::omemo::NS_BUNDLES}:${deviceId}
        set ns $::taco::omemo::NS_PUBSUB
        $client iq request -type get -payload [j pubsub -ns $ns {
            j items -node $node
        }] -command [mymethod AfterFetchOwnBundle]
    }

    method AfterFetchOwnBundle {stanza} {
        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            # item-not-found: node doesn't exist yet, publish to
            # create it. Anything else (auth, server gone): bail and
            # let the next OnReady / prekey-use retry.
            set errNodes [xsearch $stanza error]
            if {[llength $errNodes] > 0
                && [llength [xsearch [lindex $errNodes 0] \
                    item-not-found]] > 0} {
                $self DoPublishBundle
            }
            return
        }
        set server ""
        catch {set server [$self ParseBundle $stanza]}
        if {$server eq ""} {
            # Empty / unparseable response: safest to publish.
            $self DoPublishBundle
            return
        }
        if {[$self LocalBundleMatches $server]} return
        $self DoPublishBundle
    }

    method LocalBundleMatches {server} {
        set local [$store bundle]
        if {[dict get $local ik]     ne [dict get $server ik]}     { return 0 }
        if {[dict get $local spk]    ne [dict get $server spk]}    { return 0 }
        if {[dict get $local spk_id] != [dict get $server spk_id]} { return 0 }
        if {[dict get $local spks]   ne [dict get $server spks]}   { return 0 }
        set localPk [list]
        foreach pk [dict get $local prekeys] {
            lappend localPk [list [dict get $pk id] [dict get $pk pk]]
        }
        set serverPk [list]
        foreach pk [dict get $server prekeys] {
            lappend serverPk [list [dict get $pk id] [dict get $pk pk]]
        }
        set localPk  [lsort -integer -index 0 $localPk]
        set serverPk [lsort -integer -index 0 $serverPk]
        return [expr {$localPk eq $serverPk}]
    }

    method DoPublishBundle {} {
        set b [$store bundle]
        set node ${::taco::omemo::NS_BUNDLES}:${deviceId}
        set ns $::taco::omemo::NS_PUBSUB
        set ik   [::taco::omemo::prefixDjb [dict get $b ik]]
        set spk  [::taco::omemo::prefixDjb [dict get $b spk]]
        set spkId [dict get $b spk_id]
        set spks [dict get $b spks]
        set prekeys [dict get $b prekeys]
        $client iq request -type set -payload [j pubsub -ns $ns {
            j publish -node $node {
                j item -id current {
                    j bundle -ns $::taco::omemo::NS_AXOLOTL {
                        j signedPreKeyPublic -signedPreKeyId $spkId \
                            .body [base64::encode -wrapchar "" $spk]
                        j signedPreKeySignature \
                            .body [base64::encode -wrapchar "" $spks]
                        j identityKey \
                            .body [base64::encode -wrapchar "" $ik]
                        j prekeys {
                            foreach pk $prekeys {
                                set pid [dict get $pk id]
                                set pdata [::taco::omemo::prefixDjb \
                                    [dict get $pk pk]]
                                j preKeyPublic -preKeyId $pid \
                                    .body [base64::encode -wrapchar "" $pdata]
                            }
                        }
                    }
                }
            }
            j publish-options {
                j x -ns jabber:x:data -type submit {
                    j field -var FORM_TYPE -type hidden {
                        j value .body \
                            "http://jabber.org/protocol/pubsub#publish-options"
                    }
                    j field -var pubsub#persist_items {
                        j value .body true
                    }
                    j field -var pubsub#max_items {
                        j value .body 1
                    }
                    j field -var pubsub#access_model {
                        j value .body open
                    }
                }
            }
        }]
    }

    # Bundle fetch with in-flight dedup. command gets called as
    #   {*}$command $peerJid $peerDev $bundleDictOrEmpty $errorOrEmpty
    method FetchBundle {peerJid peerDev command} {
        set key "$peerJid|$peerDev"
        if {[dict exists $Bundles $key]} {
            {*}$command $peerJid $peerDev [dict get $Bundles $key] ""
            return
        }
        if {[dict exists $BundleFetchWaiters $key]} {
            dict lappend BundleFetchWaiters $key $command
            return
        }
        dict set BundleFetchWaiters $key [list $command]
        set node ${::taco::omemo::NS_BUNDLES}:${peerDev}
        set ns $::taco::omemo::NS_PUBSUB
        $client iq request -type get -to $peerJid \
            -payload [j pubsub -ns $ns {
                j items -node $node
            }] \
            -command [mymethod OnFetchedBundle $peerJid $peerDev]
    }

    method OnFetchedBundle {peerJid peerDev stanza} {
        set key "$peerJid|$peerDev"
        set waiters [dict get $BundleFetchWaiters $key]
        dict unset BundleFetchWaiters $key

        set type_ [xsearch $stanza -get @type]
        if {$type_ eq "error"} {
            jlog debug "bundle fetch $peerJid/$peerDev: ERROR"
            foreach cb $waiters {
                {*}$cb $peerJid $peerDev "" "bundle fetch failed"
            }
            return
        }
        if {[catch {$self ParseBundle $stanza} bundle]} {
            jlog debug "bundle fetch $peerJid/$peerDev: parse failed: $bundle"
            foreach cb $waiters {
                {*}$cb $peerJid $peerDev "" "bundle parse failed: $bundle"
            }
            return
        }
        if {$bundle eq ""} {
            jlog debug "bundle fetch $peerJid/$peerDev: empty/unparseable"
            foreach cb $waiters {
                {*}$cb $peerJid $peerDev "" "bundle empty"
            }
            return
        }

        # Identity-key change detection. Critical security gate; see
        # the file header.
        set ik [dict get $bundle ik]
        if {![$self EnsureTrustRow $peerJid $peerDev $ik]} {
            jlog debug "bundle fetch $peerJid/$peerDev: trust compromised (IK changed)"
            foreach cb $waiters {
                {*}$cb $peerJid $peerDev "" "trust compromised"
            }
            return
        }
        jlog debug "bundle fetch $peerJid/$peerDev: OK (trust row ensured)"
        dict set Bundles $key $bundle
        foreach cb $waiters {
            {*}$cb $peerJid $peerDev $bundle ""
        }
    }

    method ParseBundle {stanza} {
        set bundleNodes [xsearch $stanza pubsub items item bundle \
            -ns $::taco::omemo::NS_AXOLOTL]
        if {[llength $bundleNodes] == 0} {
            set bundleNodes [xsearch $stanza event items item bundle \
                -ns $::taco::omemo::NS_AXOLOTL]
        }
        if {[llength $bundleNodes] == 0} { return "" }
        set bn [lindex $bundleNodes 0]
        set ik [::taco::omemo::stripDjb [base64::decode \
            [xsearch $bn identityKey -get body]]]
        set spkNode [lindex [xsearch $bn signedPreKeyPublic] 0]
        if {$spkNode eq ""} { return "" }
        set spkId [xsearch $spkNode -get @signedPreKeyId]
        set spk [::taco::omemo::stripDjb [base64::decode \
            [dict get $spkNode body]]]
        set spks [base64::decode \
            [xsearch $bn signedPreKeySignature -get body]]
        set prekeys [list]
        xsearch $bn prekeys preKeyPublic -script pk {
            set pid [xsearch $pk -get @preKeyId]
            set pdata [::taco::omemo::stripDjb [base64::decode \
                [dict get $pk body]]]
            lappend prekeys [dict create id $pid pk $pdata]
        }
        return [dict create ik $ik spk $spk spk_id $spkId \
            spks $spks prekeys $prekeys]
    }

    # =====================================================================
    # Session ensure
    # =====================================================================

    # EnsureSession: load from DB or initiate from cached/fetched bundle.
    # cb called as {*}$cb $peerJid $peerDev $sessOrEmpty $errorOrEmpty.
    method EnsureSession {peerJid peerDev cb} {
        set key "$peerJid|$peerDev"
        if {[dict exists $Sessions $key]} {
            {*}$cb $peerJid $peerDev [dict get $Sessions $key] ""
            return
        }
        # DB load
        set row [$db eval {
            SELECT blob FROM omemo_sessions
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {[llength $row] > 0} {
            set sess [$self CreateSessionHandle $peerJid $peerDev]
            $sess deserialize [lindex $row 0]
            dict set Sessions $key $sess
            $self NotifySessionReady $peerJid
            {*}$cb $peerJid $peerDev $sess ""
            return
        }
        # Need to initiate from a bundle.
        $self FetchBundle $peerJid $peerDev \
            [mymethod AfterBundleForInitiate $cb]
    }

    method AfterBundleForInitiate {cb peerJid peerDev bundle err} {
        if {$err ne ""} {
            {*}$cb $peerJid $peerDev "" $err
            return
        }
        # Coalesce: FetchBundle dedupes concurrent fetches, but each
        # waiter independently runs AfterBundleForInitiate. If a
        # prior waiter has already built the session for this key,
        # reuse it - running `initiate` twice from the same bundle
        # produces two divergent session states (we'd keep the
        # second, but if the first was used to encrypt anything in
        # between, the peer's reply can't be decrypted by the second).
        set key "$peerJid|$peerDev"
        if {[dict exists $Sessions $key]} {
            {*}$cb $peerJid $peerDev [dict get $Sessions $key] ""
            return
        }
        lassign [$self BuildSessionFromBundle $peerJid $peerDev $bundle] sess berr
        if {$sess eq ""} {
            {*}$cb $peerJid $peerDev "" $berr
            return
        }
        $self NotifySessionReady $peerJid
        {*}$cb $peerJid $peerDev $sess ""
    }

    # Initiate + persist a fresh session from a bundle, replacing any
    # existing one (picomemo is single-state: a re-key, not build-on-top).
    # Returns {session ""} or {"" errmsg}; destroys the old handle.
    method BuildSessionFromBundle {peerJid peerDev bundle} {
        if {[llength [dict get $bundle prekeys]] == 0} {
            return [list "" "no prekeys in bundle"]
        }
        set pk [lindex [dict get $bundle prekeys] 0]
        set sess [$self CreateSessionHandle $peerJid $peerDev]
        # picomemo verifies spks against ik before deriving any state and
        # returns OMEMO_ECORRUPT on mismatch, so forged SPK material is
        # rejected here.
        if {[catch {
            $sess initiate $store \
                -ik     [dict get $bundle ik] \
                -spk    [dict get $bundle spk] \
                -spks   [dict get $bundle spks] \
                -pk     [dict get $pk pk] \
                -spk-id [dict get $bundle spk_id] \
                -pk-id  [dict get $pk id]
        } initErr]} {
            catch {$sess destroy}
            return [list "" "initiate failed: $initErr"]
        }
        set key "$peerJid|$peerDev"
        catch {[dict get $Sessions $key] destroy}
        dict set Sessions $key $sess
        $self PersistSession $peerJid $peerDev $sess
        return [list $sess ""]
    }

    method CreateSessionHandle {peerJid peerDev} {
        set name ${selfns}::sess_[expr {[incr SessionCounter]}]
        omemo::session create $name -jid $peerJid -device $peerDev
        return $name
    }
    variable SessionCounter 0

    # =====================================================================
    # Incoming dispatch (called from client.tcl message chain)
    # =====================================================================

    method OnMessage {stanza} {
        set encNodes [xsearch $stanza encrypted \
            -ns $::taco::omemo::NS_AXOLOTL]
        if {[llength $encNodes] == 0} { return 0 }
        set encNode [lindex $encNodes 0]

        # Reflected-message guard: a server echo of OUR sent stanza
        # (same bare JID AND same device id in the header sid). Carbons
        # from our OTHER devices have a different sid and pass through.
        set fromBare [jid bare [xsearch $stanza -get @from]]
        set headerNode [lindex [xsearch $encNode header] 0]
        if {$headerNode eq ""} {
            jlog warn "OMEMO drop: missing <header>" -stanza $stanza
            return 1
        }
        set sid [xsearch $headerNode -get @sid]
        if {$sid eq "" || ![string is integer -strict $sid]} {
            jlog warn "OMEMO drop: invalid sid '$sid'" -stanza $stanza
            return 1
        }
        if {$fromBare eq $accountJid && $sid == $deviceId} {
            jlog debug "OMEMO drop: reflected own stanza (sid=$sid)"
            return 1
        }

        set peerJid [expr {$fromBare eq "" ? $accountJid : $fromBare}]
        set peerDev $sid

        # Trust guard.
        set trust [$db onecolumn {
            SELECT trust FROM omemo_trust
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {$trust in {compromised untrusted}} {
            jlog warn "OMEMO drop: peer device $peerJid/$peerDev marked $trust"
            return 1
        }

        $self DispatchDecrypt $stanza $encNode $peerJid $peerDev
        return 1
    }

    # Same core decrypt path, also reachable from MAM via
    # decryptForwarded. Performs all side effects (re-inject for live,
    # caller-returned plain stanza for MAM). Live-only entry - passes
    # isMam=0 so side effects fire promptly.
    #
    # DoDecrypt result shapes:
    #   {}                       -> truly silent drop (malformed wire)
    #   {plaintext $text}        -> decrypted payload; render as message
    #   {decrypt_error $reason}  -> user-facing failure; surface as a
    #                               placeholder message with $reason as
    #                               the body so the user sees SOMETHING
    #                               rather than the previous silent loss
    #   {keytransport ""}        -> no body, side effects already done
    #   {duplicate ""}           -> already-consumed/replayed key
    #                               (EKEYGONE/EUSER); drop silently
    method DispatchDecrypt {stanza encNode peerJid peerDev} {
        set result [$self DoDecrypt $encNode $peerJid $peerDev 0]
        if {$result eq ""} {
            jlog warn "OMEMO drop: DoDecrypt returned empty (malformed wire)" \
                -stanza $stanza
            return
        }
        lassign $result kind body
        if {$kind in {keytransport duplicate}} {
            jlog debug "OMEMO $kind from $peerJid/$peerDev"
            return
        }
        if {$kind eq "decrypt_error"} {
            $client emit omemo <DecryptFailed> \
                -jid $peerJid -device $peerDev -reason $body
        }
        # plaintext OR decrypt_error - both flow as a message bubble.
        # We do NOT call back into the full client chain (that would
        # re-enter OMEMO); jump directly to message.
        set plain [$self SynthesisePlain $stanza $body]
        $client message OnMessage $plain
    }

    # Run the full multi-key decrypt + side-effect path for one
    # <encrypted> node. isMam tells us whether the message arrived
    # via a MAM <forwarded> wrapper (1) or is a live stanza (0); it
    # gates whether prekey side effects (bundle republish, heartbeat)
    # fire immediately or queue up for the post-MAM flush.
    # See DispatchDecrypt header for the result-shape contract.
    method DoDecrypt {encNode peerJid peerDev isMam} {
        set headerNode [lindex [xsearch $encNode header] 0]
        if {$headerNode eq ""} { return {} }
        set ivB64 [xsearch $headerNode iv -get body]
        set iv [base64::decode $ivB64]
        set payloadB64 [xsearch $encNode payload -get body]
        set hasPayload [expr {$payloadB64 ne ""}]

        # Candidate keys: every <key rid="$deviceId"> in document order.
        set candidates [list]
        xsearch $headerNode key -script kn {
            set rid [xsearch $kn -get @rid]
            if {$rid eq "" || $rid != $deviceId} continue
            set prekeyAttr [xsearch $kn -get @prekey]
            set isPrekey [expr {$prekeyAttr in {true 1}}]
            set keyData [base64::decode [dict get $kn body]]
            lappend candidates [list $isPrekey $keyData]
        }
        if {[llength $candidates] == 0} {
            # Sender's devicelist for us is stale - they didn't include
            # a key for our deviceId. User-actionable: peer should
            # refresh the devicelist on their end (often resolves by
            # itself once the +notify reaches them).
            return [list decrypt_error \
                "\[OMEMO\] Message not encrypted for this device"]
        }

        # Ensure session: load or open.
        set sess ""
        set key "$peerJid|$peerDev"
        if {[dict exists $Sessions $key]} {
            set sess [dict get $Sessions $key]
        } else {
            set row [$db eval {
                SELECT blob FROM omemo_sessions
                WHERE account_jid=$accountJid
                  AND peer_jid=$peerJid AND peer_device=$peerDev
            }]
            if {[llength $row] > 0} {
                set sess [$self CreateSessionHandle $peerJid $peerDev]
                $sess deserialize [lindex $row 0]
                dict set Sessions $key $sess
            } else {
                # No session yet. Prekey candidate establishes a fresh
                # session via decrypt_key directly. Create empty handle.
                set sess [$self CreateSessionHandle $peerJid $peerDev]
                dict set Sessions $key $sess
            }
        }

        set ok 0
        set decKey ""
        set lastErr ""
        set lastEcode ""
        foreach pair $candidates {
            lassign $pair isPrekey enc
            if {![catch {
                $sess decrypt_key $store $enc -prekey $isPrekey
            } out opts]} {
                set decKey $out
                set ok 1
                break
            }
            set lastErr $out
            set lastEcode [dict get $opts -errorcode]
        }
        if {!$ok} {
            $self HandleDecryptError $peerJid $peerDev $lastEcode $lastErr \
                $candidates $isMam
            # EKEYGONE (key already consumed) and EUSER (replayed prekey)
            # are duplicates/re-deliveries, not a broken session; drop them
            # silently as Conversations and Dino do. Genuine session breaks
            # (ECORRUPT/ESTATE/...) fall through to the placeholder + heal.
            if {[lindex $lastEcode 1] in {EKEYGONE EUSER}} {
                return [list duplicate ""]
            }
            return [list decrypt_error \
                "\[OMEMO\] Could not decrypt message"]
        }

        # IK-change check on inbound: a prekey message carries the
        # sender's IK inside picomemo's session struct. The bundle-fetch
        # path catches changed IKs for outbound; for inbound we have
        # to compare against the stored IK here, or an attacker could
        # swap the sender's identity in a fresh prekey establishment
        # and we'd silently accept.
        set remoteIk [$sess remote_identity]
        if {$remoteIk ne ""} {
            if {![$self EnsureTrustRow $peerJid $peerDev $remoteIk]} {
                # Trust check moved the row to compromised (or it was
                # already compromised). Surface so the user knows their
                # peer's identity has changed and they can take action.
                return [list decrypt_error \
                    "\[OMEMO\] Sender's identity key changed - possible MITM"]
            }
        }

        if {$isMam} { set mamHadOmemo 1 }

        # Side effects: prekey-used + refill + bundle republish. MAM
        # path postpones the republish (we'd otherwise re-publish per
        # historical prekey message); live path republishes promptly.
        $self ApplyPrekeySideEffects $sess $peerJid $peerDev $isMam
        $self PersistSession $peerJid $peerDev $sess
        $self NotifySessionReady $peerJid

        # Heartbeat: same logic. Live decrypts heartbeat now; MAM
        # decrypts queue a single per-session heartbeat for the flush.
        if {!$isMam} {
            $self SendHeartbeat $peerJid $peerDev
        } else {
            dict set PostponedHeartbeats "$peerJid|$peerDev" 1
        }

        if {!$hasPayload} {
            return [list keytransport ""]
        }
        set ct [base64::decode $payloadB64]
        if {[catch {omemo::decrypt_message $decKey $iv $ct} plain]} {
            return [list decrypt_error \
                "\[OMEMO\] Could not decrypt message payload"]
        }
        # The plaintext on the wire is UTF-8 bytes; decode to a Tcl string.
        set plain [encoding convertfrom utf-8 $plain]
        # Strip Conversations-style privacy padding (trailing whitespace).
        set plain [string trimright $plain " \t"]
        return [list plaintext $plain]
    }

    # Ensure a trust row for (peerJid, peerDev) anchored to $ik.
    # Returns 1 if the device is usable after the call, 0 if the row
    # was moved to compromised (IK changed) and the caller should
    # treat this message as dropped.
    method EnsureTrustRow {peerJid peerDev ik} {
        set now [clock milliseconds]
        set row [$db eval {
            SELECT identity_pk, trust FROM omemo_trust
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {[llength $row] == 0} {
            $db eval {
                INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
                    identity_pk, trust, active, last_activation)
                VALUES($accountJid, $peerJid, $peerDev, $ik,
                    'undecided', 1, $now)
            }
            $self EmitTrustList $peerJid
            return 1
        }
        lassign $row storedIk storedTrust
        if {$storedTrust eq "compromised"} { return 0 }
        if {$storedIk ne $ik} {
            $db eval {
                UPDATE omemo_trust
                SET trust='compromised', active=1, last_activation=$now
                WHERE account_jid=$accountJid
                  AND peer_jid=$peerJid AND peer_device=$peerDev
                  AND trust != 'compromised'
            }
            $client emit omemo <FingerprintChanged> \
                -jid $peerJid -device $peerDev \
                -fingerprint [omemo::fingerprint $ik]
            $client emit omemo <TrustChanged> \
                -jid $peerJid -device $peerDev -state compromised
            $self EmitTrustList $peerJid
            return 0
        }
        $db eval {
            UPDATE omemo_trust SET active=1, last_activation=$now
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }
        return 1
    }

    method ApplyPrekeySideEffects {sess peerJid peerDev isMam} {
        set usedPk [$sess used_prekey_id]
        if {$usedPk eq ""} return
        $store mark_prekey_used $usedPk
        $store refill_prekeys
        $self PersistStore
        if {$isMam} {
            lappend Postponed [list republish_bundle]
        } else {
            $self PublishBundle
        }
    }

    method SendHeartbeat {peerJid peerDev} {
        set key "$peerJid|$peerDev"
        if {![dict exists $Sessions $key]} return
        set sess [dict get $Sessions $key]
        set hb ""
        if {[catch {$sess heartbeat $store} hb]} return
        if {$hb eq ""} return
        $self PersistSession $peerJid $peerDev $sess
        # Send as KeyTransport (no <payload>) to the peer.
        set msg [j message -to $peerJid -type chat {
            j encrypted -ns $::taco::omemo::NS_AXOLOTL {
                j header -sid $deviceId {
                    j key -rid $peerDev .body [base64::encode -wrapchar "" $hb]
                    j iv .body [base64::encode -wrapchar "" \
                        [string repeat \x00 12]]
                }
            }
        }]
        $client write $msg
    }

    method HandleDecryptError {peerJid peerDev ecode err candidates isMam} {
        # candidates is the list of (isprekey, encKey) attempted.
        # The last attempt's error is what we route on.
        set tag [lindex $ecode 1]
        # Was the last candidate a prekey path?
        set lastWasPrekey [lindex [lindex $candidates end] 0]
        jlog debug "HandleDecryptError $peerJid/$peerDev: tag=$tag prekey=$lastWasPrekey\
            isMam=$isMam err='$err'"
        switch -- $tag {
            EPROTOBUF -
            ECORRUPT  -
            ECRYPTO   -
            ESTATE {
                # ESTATE = no session for the sender; the rest = an
                # established session broken. Both recover by healing.
                # Skip prekey-path failures (a bad/replayed prekey isn't a
                # broken session). MAM failures defer to the QueryEnd flush
                # (one heal/device, no racing the same page).
                if {!$lastWasPrekey} {
                    if {$isMam} {
                        dict set PostponedHealing "$peerJid|$peerDev" 1
                        set mamHadOmemo 1
                    } else {
                        $self Heal $peerJid $peerDev
                    }
                }
            }
            EKEYGONE -
            EUSER    {
                # Drop and log: a consumed/replayed prekey, or a storage
                # callback error - healing wouldn't help.
            }
            ESTORE   -
            EPARAM   -
            ESTORAGE {
                # Loud log path; bubble up via $client emit if there
                # was a listener. For now silent.
            }
        }
    }

    # Recover a missing/broken session: re-key from the peer's bundle and
    # send a prekey KeyTransport so they adopt a session we share. Never
    # deletes - picomemo restores the session across a failed decrypt, and
    # BuildSessionFromBundle swaps it atomically. Rate-limited (HealAt)
    # to avoid a re-key ping-pong.
    method Heal {peerJid peerDev} {
        set key "$peerJid|$peerDev"
        set now [clock milliseconds]
        if {[dict exists $HealAt $key] && $now < [dict get $HealAt $key]} {
            return
        }
        dict set HealAt $key \
            [expr {$now + $::taco::omemo::HEAL_WINDOW_MS}]
        jlog debug "OMEMO heal $peerJid/$peerDev: fetching bundle to re-key + KeyTransport"
        # Force a fresh fetch (EnsureSession would short-circuit on the
        # existing broken session); the cached bundle may also be stale.
        dict unset Bundles $key
        $self FetchBundle $peerJid $peerDev [mymethod AfterHeal]
    }

    method AfterHeal {peerJid peerDev bundle err} {
        if {$err ne ""} {
            jlog debug "OMEMO heal $peerJid/$peerDev: bundle fetch failed: $err"
            return
        }
        lassign [$self BuildSessionFromBundle $peerJid $peerDev $bundle] sess berr
        if {$sess eq ""} {
            jlog debug "OMEMO heal $peerJid/$peerDev: rebuild failed: $berr"
            return
        }
        jlog debug "OMEMO heal $peerJid/$peerDev: re-keyed, sending KeyTransport"
        $self NotifySessionReady $peerJid
        $self SendKeyTransport $peerJid $peerDev $sess
    }

    # Send an empty (no <payload>) KeyTransport. On a fresh session this is
    # the prekey message that makes the peer adopt our new session - unlike
    # SendHeartbeat, which only fires when the ratchet counter is too high.
    method SendKeyTransport {peerJid peerDev sess} {
        set enc [omemo::encrypt_message ""]
        if {[catch {$sess encrypt_key [dict get $enc key]} wrap]} {
            jlog debug "OMEMO heal $peerJid/$peerDev: encrypt_key failed: $wrap"
            return
        }
        $self PersistSession $peerJid $peerDev $sess
        set p [dict get $wrap p]
        set isPrekey [dict get $wrap isprekey]
        set iv [dict get $enc iv]
        set msg [j message -to $peerJid -type chat {
            j encrypted -ns $::taco::omemo::NS_AXOLOTL {
                j header -sid $deviceId {
                    if {$isPrekey} {
                        j key -rid $peerDev -prekey true \
                            .body [base64::encode -wrapchar "" $p]
                    } else {
                        j key -rid $peerDev \
                            .body [base64::encode -wrapchar "" $p]
                    }
                    j iv .body [base64::encode -wrapchar "" $iv]
                }
            }
        }]
        $client write $msg
    }

    # Build a synthesised plaintext <message> from the original encrypted
    # stanza. Preserves @from, @to, @type, @id; replaces the <encrypted>
    # node and any cleartext fallback <body> with <body>plaintext</body>
    # and an EME marker. All OTHER children are kept verbatim - in
    # particular <stanza-id> (XEP-0359) so the downstream ingest path
    # gets a server_id, which messagestore needs to dedup against the
    # MAM replay of the same stanza. Dropping it caused ghost rows on
    # every chat reopen.
    method SynthesisePlain {origStanza plaintext} {
        set attrs [dict get $origStanza attrs]
        set out [dict create tag message body {} tail {} children {} \
            ns [dict get $origStanza ns] attrs $attrs]
        set bodyChild [dict create tag body body $plaintext tail {} \
            children {} ns {} attrs {}]
        set emeChild [dict create tag encryption body {} tail {} \
            children {} ns $::taco::omemo::NS_EME \
            attrs [dict create namespace $::taco::omemo::NS_AXOLOTL \
                name OMEMO]]
        set kept [list]
        foreach c [dict get $origStanza children] {
            set tag [dict get $c tag]
            if {$tag in {encrypted body encryption}} continue
            lappend kept $c
        }
        dict set out children [concat [list $bodyChild $emeChild] $kept]
        return $out
    }

    # =====================================================================
    # MAM entry point. Returns the inner stanza unchanged if not OMEMO,
    # or a synthesised plaintext stanza if it is. Side effects (session
    # advance, bundle republish, heartbeat) are deferred during MAM
    # catchup and flushed afterwards.
    method decryptForwarded {msgNode} {
        set encNodes [xsearch $msgNode encrypted \
            -ns $::taco::omemo::NS_AXOLOTL]
        if {[llength $encNodes] == 0} { return $msgNode }
        set encNode [lindex $encNodes 0]
        set fromBare [jid bare [xsearch $msgNode -get @from]]
        set headerNode [lindex [xsearch $encNode header] 0]
        # All "skip this MAM result" exits below return a synthesised
        # stanza with an empty body, NOT the original $msgNode. The
        # original carries the cleartext EME fallback ("I sent you an
        # OMEMO encrypted message but your client doesn't support
        # OMEMO"); returning it would let that string land in the
        # user-visible body column as a phantom message on every chat
        # reopen. ParseResultNode's caller filters empty-body messages.
        if {$headerNode eq ""} {
            return [$self SynthesisePlain $msgNode ""]
        }
        set sid [xsearch $headerNode -get @sid]
        # Our own outgoing stanza echoed via MAM: we never encrypted to
        # ourselves, so DoDecrypt would just emit a "no key for us"
        # placeholder. The pending row from `taco_message send` already
        # holds the plaintext; nothing useful to surface here.
        if {$sid eq "" || ![string is integer -strict $sid]} {
            return [$self SynthesisePlain $msgNode ""]
        }
        if {$fromBare eq $accountJid && $sid == $deviceId} {
            return [$self SynthesisePlain $msgNode ""]
        }
        set peerJid [expr {$fromBare eq "" ? $accountJid : $fromBare}]
        set peerDev $sid
        # Match the live path's trust gate (OnMessage drops silently on
        # untrusted/compromised). MAM must not store the EME fallback
        # body either.
        set trust [$db onecolumn {
            SELECT trust FROM omemo_trust
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {$trust in {compromised untrusted}} {
            return [$self SynthesisePlain $msgNode ""]
        }
        set res [$self DoDecrypt $encNode $peerJid $peerDev 1]
        if {$res eq ""} {
            return [$self SynthesisePlain $msgNode ""]
        }
        lassign $res kind body
        if {$kind in {keytransport duplicate}} {
            return [$self SynthesisePlain $msgNode ""]
        }
        # plaintext OR decrypt_error: surface as a real <message> with
        # $body either as the decrypted text or as a user-facing
        # placeholder explaining the failure.
        return [$self SynthesisePlain $msgNode $body]
    }

    # =====================================================================
    # Outgoing encrypt
    # =====================================================================

    # Mirrors Conversations' "Blindly trust before verification"
    # account toggle. Default ON: undecided devices are treated as
    # trusted for the outbound recipient set (the BTBV / TOFU
    # experience). Default OFF: undecided devices are excluded from
    # outbound - the user must explicitly `tacky omemo trust ...
    # -state trusted` each new device first.
    #
    # Inbound (OnMessage / decryptForwarded) ignores this and always
    # decrypts from undecided devices, since dropping silently would
    # lose messages and we have no "from unverified device" badge UI
    # yet.
    method IsDeviceBlocked {peerJid peerDev} {
        set row [$db eval {
            SELECT trust, active FROM omemo_trust
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {[llength $row] == 0} {
            return [expr {[$self blindTrust] ? 0 : 1}]
        }
        lassign $row trust active
        if {$trust in {compromised untrusted}} { return 1 }
        if {$trust eq "undecided" && ![$self blindTrust]} { return 1 }
        if {!$active} { return 1 }
        return 0
    }

    # encrypt: produce an <encrypted> node ready to splice into a
    # <message>. Per security invariant #2, the caller (taco_message)
    # must surface any error as a send failure - never fall back to
    # cleartext.
    #
    # Pure sync: reads in-memory state, does crypto, returns. Async
    # prerequisites (devicelist, bundles) are kicked as side effects
    # when missing, and the call throws TACO_OMEMO_NOT_READY - caller
    # holds the message pending and retries on <SessionReady>.
    # TACO_OMEMO_TERMINAL means no future warming will help.
    # XEP-0454 media keys (AES-256-GCM, fresh per file). Independent of any
    # session/store. encrypt returns {ct key iv}.
    method mediaEncrypt {plaintext} {
        return [::omemo::media_encrypt $plaintext]
    }

    method mediaDecrypt {key iv ct} {
        return [::omemo::media_decrypt $key $iv $ct]
    }

    method encrypt {chatJid plaintext} {
        if {$store eq ""} {
            # Transient: OnReady hasn't initialised the store yet (e.g. a
            # prior-session pending row retried before omemo's <Ready>
            # handler ran this connection). omemo:<SelfReady> re-drives
            # the retry once the store is up.
            return -code error -errorcode TACO_OMEMO_NOT_READY \
                "OMEMO store not initialised yet"
        }

        jlog debug "encrypt -> $chatJid: peerDevlistCached=[dict exists $DeviceLists $chatJid]\
            ownDevlistCached=[dict exists $DeviceLists $accountJid]"

        # Devicelists must be loaded; if not, kick fetch and bail.
        set kicked 0
        if {![dict exists $DeviceLists $chatJid]} {
            jlog debug "encrypt $chatJid: peer devicelist not cached, kicking fetch"
            $self FetchDevicelist $chatJid [list apply {args {}}]
            set kicked 1
        }
        if {![dict exists $DeviceLists $accountJid]} {
            jlog debug "encrypt $chatJid: OWN devicelist not cached, kicking fetch"
            $self FetchDevicelist $accountJid [list apply {args {}}]
            set kicked 1
        }
        if {$kicked} {
            return -code error -errorcode TACO_OMEMO_NOT_READY \
                "devicelist fetch in flight"
        }

        set peerDevs [dict get $DeviceLists $chatJid]
        if {[llength $peerDevs] == 0} {
            jlog debug "encrypt TERMINAL $chatJid: cached devicelist is empty"
            return -code error -errorcode TACO_OMEMO_TERMINAL \
                "no devices on $chatJid devicelist"
        }
        set ownDevs [list]
        if {[dict exists $DeviceLists $accountJid]} {
            foreach d [dict get $DeviceLists $accountJid] {
                if {$d != $deviceId} { lappend ownDevs $d }
            }
        }
        jlog debug "encrypt $chatJid: peerDevs=$peerDevs ownDevs=$ownDevs (ourDev=$deviceId)"
        # Recipient set = peer devices + our own other devices, deduped
        # and never including our own current device. For a self-chat
        # (chatJid == accountJid) peerDevs already IS our devicelist, so
        # without dedup/self-exclusion we'd (a) try to encrypt to our own
        # current device and (b) double-list every other own device -
        # calling encrypt_key twice on one session, desyncing its ratchet.
        set rawCandidates [list]
        set seen [dict create]
        foreach pair [concat \
                [lmap d $peerDevs {list $chatJid $d}] \
                [lmap d $ownDevs  {list $accountJid $d}]] {
            lassign $pair pj pd
            if {$pj eq $accountJid && $pd == $deviceId} continue
            set k "$pj|$pd"
            if {[dict exists $seen $k]} continue
            dict set seen $k 1
            lappend rawCandidates $pair
        }

        # Sync session lookup only. If a candidate is unsessioned,
        # EnsureSessionSync fires a bundle fetch in the background and
        # returns ""; we count it as "warming" rather than "blocked"
        # so we can distinguish NOT_READY from TERMINAL below.
        set sessions [list]
        set peerSessionCount 0
        set peerWarming 0
        foreach cand $rawCandidates {
            lassign $cand pj pd
            if {[$self IsDeviceBlocked $pj $pd]} {
                jlog debug "encrypt $chatJid: $pj/$pd BLOCKED (trust/inactive)"
                continue
            }
            set sess [$self EnsureSessionSync $pj $pd]
            if {$sess eq ""} {
                jlog debug "encrypt $chatJid: $pj/$pd WARMING (no session yet)"
                if {$pj eq $chatJid} { incr peerWarming }
                continue
            }
            lappend sessions [list $pj $pd $sess]
            if {$pj eq $chatJid} { incr peerSessionCount }
        }
        jlog debug "encrypt $chatJid: usableSessions=[llength $sessions]\
            peerSessions=$peerSessionCount peerWarming=$peerWarming"
        # Fail-closed: no point ciphering a payload no peer device can
        # read, even if our own carbon devices could. The peer would
        # silently get an undecryptable stanza (MessageNotForUs).
        if {$peerSessionCount == 0} {
            if {$peerWarming > 0} {
                jlog debug "encrypt NOT_READY $chatJid: peer bundle(s) still warming"
                return -code error -errorcode TACO_OMEMO_NOT_READY \
                    "bundle fetch in flight for $chatJid"
            }
            jlog debug "encrypt TERMINAL $chatJid: no usable peer recipients"
            return -code error -errorcode TACO_OMEMO_TERMINAL \
                "no usable recipients for $chatJid"
        }

        # Generate AES-GCM payload key + ciphertext + iv. The payload
        # is UTF-8 bytes: the picomemo binding wants a byte string, and
        # a Tcl string with non-ASCII codepoints throws EPARAM. Wrap the
        # crypto so an unexpected failure becomes a typed send error
        # rather than escaping to bgerror and killing the stanza loop.
        if {[catch {
            omemo::encrypt_message [encoding convertto utf-8 $plaintext]
        } encDict]} {
            jlog debug "encrypt TERMINAL $chatJid: payload encrypt failed: $encDict"
            return -code error -errorcode TACO_OMEMO_TERMINAL \
                "payload encryption failed: $encDict"
        }
        set ct  [dict get $encDict ct]
        set key [dict get $encDict key]
        set iv  [dict get $encDict iv]

        # Per-session wrap.
        set perRecipient [list]
        foreach s $sessions {
            lassign $s pj pd sess
            if {[catch {$sess encrypt_key $key} wrap]} continue
            $self PersistSession $pj $pd $sess
            lappend perRecipient [list $pd \
                [dict get $wrap isprekey] [dict get $wrap p]]
        }
        if {[llength $perRecipient] == 0} {
            jlog debug "encrypt TERMINAL $chatJid: all per-session encrypts failed"
            return -code error -errorcode TACO_OMEMO_TERMINAL \
                "all per-session encrypts failed"
        }
        jlog debug "encrypt OK $chatJid: wrapped for [llength $perRecipient] device(s)"

        return [j encrypted -ns $::taco::omemo::NS_AXOLOTL {
            j header -sid $deviceId {
                foreach r $perRecipient {
                    lassign $r rid isPrekey p
                    if {$isPrekey} {
                        j key -rid $rid -prekey true \
                            .body [base64::encode -wrapchar "" $p]
                    } else {
                        j key -rid $rid \
                            .body [base64::encode -wrapchar "" $p]
                    }
                }
                j iv .body [base64::encode -wrapchar "" $iv]
            }
            j payload .body [base64::encode -wrapchar "" $ct]
        }]
    }

    # Synchronous session-ensure: load from DB or initiate from cache
    # if we have a fresh bundle. encrypt() is a synchronous API and
    # cannot await a network round-trip; if the bundle isn't cached,
    # we fire-and-forget a fetch and skip this device for now. The
    # next encrypt attempt after the fetch resolves will include it.
    method EnsureSessionSync {peerJid peerDev} {
        set key "$peerJid|$peerDev"
        if {[dict exists $Sessions $key]} {
            return [dict get $Sessions $key]
        }
        set row [$db eval {
            SELECT blob FROM omemo_sessions
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {[llength $row] > 0} {
            jlog debug "EnsureSessionSync $peerJid/$peerDev: loaded session from DB"
            set sess [$self CreateSessionHandle $peerJid $peerDev]
            $sess deserialize [lindex $row 0]
            dict set Sessions $key $sess
            return $sess
        }
        if {[dict exists $Bundles $key]} {
            set bundle [dict get $Bundles $key]
            if {[llength [dict get $bundle prekeys]] == 0} {
                jlog debug "EnsureSessionSync $peerJid/$peerDev: cached bundle has no prekeys"
                return ""
            }
            set pk [lindex [dict get $bundle prekeys] 0]
            set sess [$self CreateSessionHandle $peerJid $peerDev]
            # picomemo verifies spks against ik before deriving any state and
            # returns OMEMO_ECORRUPT on mismatch, so forged SPK material is
            # rejected here.
            if {[catch {
                $sess initiate $store \
                    -ik     [dict get $bundle ik] \
                    -spk    [dict get $bundle spk] \
                    -spks   [dict get $bundle spks] \
                    -pk     [dict get $pk pk] \
                    -spk-id [dict get $bundle spk_id] \
                    -pk-id  [dict get $pk id]
            } err]} {
                jlog debug "EnsureSessionSync $peerJid/$peerDev: initiate failed: $err"
                catch {$sess destroy}
                return ""
            }
            jlog debug "EnsureSessionSync $peerJid/$peerDev: initiated session from cached bundle"
            dict set Sessions $key $sess
            $self PersistSession $peerJid $peerDev $sess
            return $sess
        }
        # No bundle on hand. Kick off async fetch + session build so a
        # subsequent send will succeed; this send won't include this
        # device. EnsureSession emits <SessionReady> when the build
        # completes, which retries any pending outbound to this peer.
        jlog debug "EnsureSessionSync $peerJid/$peerDev: no session or bundle, kicking async fetch"
        $self EnsureSession $peerJid $peerDev [list apply {args {}}]
        return ""
    }

    # =====================================================================
    # Public introspection / control
    # =====================================================================

    # Per-device peer fingerprints are not a standalone method: they ride
    # along on each trustList row (the `fingerprint` field). The device
    # id (peer_device) is an opaque row handle the GUI gets from
    # trustList and passes back to `trust`; it's never user-facing.

    # own_fingerprint -> hex string for this device's identity key, or {}
    # before OnReady has run.
    tackymethod own_fingerprint {args} {
        if {$store eq ""} { return {} }
        return [omemo::fingerprint [$store identity_pub]]
    }

    # devicelist -jid $peerJid -> list of device ids (empty if not cached)
    tackymethod devicelist {args} {
        array set opts $args
        set peerJid $opts(-jid)
        if {[dict exists $DeviceLists $peerJid]} {
            return [dict get $DeviceLists $peerJid]
        }
        return [list]
    }

    tackymethod device_id {args} { return $deviceId }
    tackymethod account_jid {args} { return $accountJid }

    # Prefetch a peer's devicelist (and best-effort their bundles) so
    # a subsequent encrypt() call is a hot-cache hit. Async: -command
    # fires after the devicelist arrives and bundle fetches have been
    # kicked off (not necessarily completed). In production a PEP
    # +notify arrival populates the devicelist cache for roster
    # contacts; this method is mainly for tests that need to warm
    # against the OMEMO bot without sending a real message.
    method prepareChat {args} {
        array set opts {-command {apply {args {}}}}
        array set opts $args
        set peerJid $opts(-jid)
        $self FetchDevicelist $peerJid \
            [mymethod AfterPrepareChat $opts(-command)]
    }

    method AfterPrepareChat {cb peerJid devices} {
        foreach d $devices {
            $self EnsureSessionSync $peerJid $d
        }
        {*}$cb $peerJid $devices
    }

    # trustList -jid $peerJid -> list of dicts
    # {device <id> trust <state> active <0|1> fingerprint <hex>}
    # Returns every known device for that peer (incl. inactive rows).
    tackymethod trustList {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set out [list]
        $db eval {
            SELECT peer_device, trust, active, identity_pk
            FROM omemo_trust
            WHERE account_jid=$accountJid AND peer_jid=$peerJid
            ORDER BY peer_device
        } row {
            if {[catch {omemo::fingerprint $row(identity_pk)} fp]} {
                set fp ""
            }
            lappend out [dict create \
                device $row(peer_device) \
                trust $row(trust) \
                active $row(active) \
                fingerprint $fp]
        }
        return $out
    }

    # Internal: emit <TrustList> with the current rows. Called from every
    # per-peer trust-state mutation site so observers re-render uniformly.
    method EmitTrustList {peerJid} {
        $client emit omemo <TrustList> \
            -jid $peerJid \
            -trustList [$self trustList -jid $peerJid]
    }

    # blindTrust -> 0|1 (current BTBV setting; defaults to 1 if unset,
    # 0 if the settings store is unreachable - fail closed).
    tackymethod blindTrust {args} {
        set taco [$client cget -taco]
        if {[catch {$taco setting get -key omemo_blindly_trust} v]} {
            return 0
        }
        if {$v eq ""} { return 1 }
        return [expr {!![string is true -strict $v]}]
    }

    # setBlindTrust -value 0|1 -> persist BTBV and emit <BlindTrust>.
    tackymethod setBlindTrust {args} {
        array set opts $args
        set v [expr {!![string is true -strict $opts(-value)]}]
        set taco [$client cget -taco]
        $taco setting set -key omemo_blindly_trust -value $v
        $client emit omemo <BlindTrust> -value $v
        return $v
    }

    # Per-chat OMEMO toggle - a genuine boolean, the user's choice.
    # Stored per peer under setting key omemo.enabled.<jid>; defaults to
    # ON (chats are encrypted by default, Dino-style). Peer capability
    # is a separate concern (`ready`); when a peer can't do OMEMO the
    # GUI warns and the message stays pending until the user turns the
    # toggle off and resends. Read at send time by taco_message; the GUI
    # observes <Enabled>, so there's no public getter - IsEnabled is
    # internal.
    method IsEnabled {peerJid} {
        set taco [$client cget -taco]
        set v ""
        catch {set v [$taco setting get -key omemo.enabled.$peerJid]}
        if {$v eq ""} { return 1 }
        return [expr {!![string is true -strict $v]}]
    }

    # setEnabled -jid X -value 0|1 -> persist per-chat toggle, emit
    # <Enabled>. Pure setting write; pending messages are untouched
    # (their stamped `encryption` is honored on automatic retry).
    tackymethod setEnabled {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set v [expr {!![string is true -strict $opts(-value)]}]
        set taco [$client cget -taco]
        $taco setting set -key omemo.enabled.$peerJid -value $v
        $client emit omemo <Enabled> -jid $peerJid -value $v
        return $v
    }

    # pull -event <Ev> ?-jid X? - re-emit pullable events with current state.
    # Used by `tacky observe`. Non-pullable events (TrustChanged,
    # FingerprintChanged, DecryptFailed) error.
    tackymethod pull {args} {
        array set opts $args
        switch -- $opts(-event) {
            <TrustList> {
                $self EmitTrustList $opts(-jid)
            }
            <BlindTrust> {
                $client emit omemo <BlindTrust> -value [$self blindTrust]
            }
            <Enabled> {
                $client emit omemo <Enabled> \
                    -jid $opts(-jid) -value [$self IsEnabled $opts(-jid)]
            }
            default {
                return -code error \
                    "omemo pull: event $opts(-event) is not pullable"
            }
        }
    }

    # trust -jid $peerJid -device $peerDev -state $newState
    # Transition validator. Free movement among
    # {undecided, trusted, untrusted}; * -> compromised is system-only;
    # compromised -> * is forbidden in this task. Throws
    # {OMEMO TRUST_TRANSITION} on disallowed transitions and
    # {OMEMO TRUST_NO_DEVICE} when the (jid, device) row doesn't exist
    # yet (no bundle ever fetched / no message decrypted).
    tackymethod trust {args} {
        array set opts $args
        set peerJid $opts(-jid)
        set peerDev $opts(-device)
        set newState $opts(-state)
        if {$newState ni {undecided trusted untrusted compromised}} {
            return -code error -errorcode {OMEMO TRUST_TRANSITION} \
                "unknown trust state: $newState"
        }
        if {$newState eq "compromised"} {
            return -code error -errorcode {OMEMO TRUST_TRANSITION} \
                "compromised is system-set only"
        }
        set row [$db eval {
            SELECT trust FROM omemo_trust
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }]
        if {[llength $row] == 0} {
            return -code error -errorcode {OMEMO TRUST_NO_DEVICE} \
                "no trust row for $peerJid/$peerDev"
        }
        set current [lindex $row 0]
        if {$current eq $newState} return
        if {$current eq "compromised"} {
            return -code error -errorcode {OMEMO TRUST_TRANSITION} \
                "compromised is sticky"
        }
        $db eval {
            UPDATE omemo_trust SET trust=$newState
            WHERE account_jid=$accountJid
              AND peer_jid=$peerJid AND peer_device=$peerDev
        }
        $client emit omemo <TrustChanged> \
            -jid $peerJid -device $peerDev -state $newState
        $self EmitTrustList $peerJid
    }
}
