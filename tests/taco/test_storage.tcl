package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

# A garbage-content accounts.db is unreadable the same way a real
# SQLCipher-encrypted one is (any query against it throws), so it stands in
# for "locked" without needing a real encrypted db to test against.
proc storagetest_plantgarbage {path} {
    set fh [open $path wb]
    puts -nonewline $fh "not a real sqlite database"
    close $fh
}

proc storagetest_newdirs {} {
    set cfg [file tempdir tacky-storage-test]
    set data [file join $cfg data]
    set cache [file join $cfg cache]
    file mkdir $data $cache
    return [list $cfg $data $cache]
}

# taco_type's own `tacky emit ...` calls need a `tacky` command to exist -
# tacky_type create ::tacky supplies a real one, but these tests construct
# taco_type directly (to reach its private, non-dispatched methods) and so
# need a no-op stand-in instead. Idempotent and self-cleaning: never left
# behind for a later tacky_type create ::tacky test to trip over.
proc storagetest_stub_tacky {} {
    catch {rename ::tacky {}}
    proc ::tacky {args} {}
}
proc storagetest_unstub_tacky {} {
    catch {rename ::tacky {}}
}

# -- taco_sql_quote / taco_pragma_key ---------------------------------------

test storage-sql-quote-plain {no quotes to escape} \
    -body {
        taco_sql_quote "hello"
    } -result {hello}

test storage-sql-quote-embedded {embedded single quotes are doubled} \
    -body {
        taco_sql_quote "it's a ' test"
    } -result {it''s a '' test}

test storage-pragma-key-no-syntax-error {PRAGMA key text is valid SQL, not a bound-param syntax error} \
    -setup {
        sqlite3 ::_pkdb :memory:
    } -cleanup {
        ::_pkdb close
    } -body {
        # Regression: `PRAGMA key = $var` (bound substitution) is a SQL
        # syntax error - PRAGMA only accepts a literal. This must not throw.
        taco_pragma_key ::_pkdb "it's a tricky ' passphrase"
        set ok 1
    } -result {1}

# -- status: plaintext (transient) ------------------------------------------

test storage-status-plaintext-transient {a transient db is plaintext and every module is up} \
    -setup {
        tacky_type create ::tacky
    } -cleanup {
        tacky destroy
    } -body {
        list [tacky storage status] [tacky account list]
    } -result {plaintext {}}

# -- status: locked (non-transient, garbage accounts.db) --------------------

test storage-status-locked {a garbage accounts.db reports locked and defers setup} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        storagetest_plantgarbage [file join $cfg accounts.db]
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        tacky storage status
    } -result {locked}

test storage-locked-account-unavailable {other modules aren't installed while locked} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        storagetest_plantgarbage [file join $cfg accounts.db]
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        expr {[catch {tacky account list}] != 0}
    } -result {1}

test storage-unlock-wrong-passphrase-stays-locked {a passphrase that can't read it stays locked and is retryable} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        storagetest_plantgarbage [file join $cfg accounts.db]
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        set failed1 [expr {[catch {tacky storage unlock -passphrase one}] != 0}]
        set status1 [tacky storage status]
        set failed2 [expr {[catch {tacky storage unlock -passphrase two}] != 0}]
        set status2 [tacky storage status]
        list $failed1 $status1 $failed2 $status2
    } -result {1 locked 1 locked}

# -- unlock/encrypt/decrypt precondition errors -----------------------------

test storage-unlock-when-plaintext-errors {unlock when not locked is rejected} \
    -setup {
        tacky_type create ::tacky
    } -cleanup {
        tacky destroy
    } -body {
        catch {tacky storage unlock -passphrase x} err
        set err
    } -result {storage is not locked}

test storage-encrypt-when-locked-errors {encrypt requires plaintext} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        storagetest_plantgarbage [file join $cfg accounts.db]
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        catch {tacky storage encrypt -passphrase x} err
        set err
    } -result {storage is not plaintext}

test storage-decrypt-when-plaintext-errors {decrypt requires unlocked} \
    -setup {
        tacky_type create ::tacky
    } -cleanup {
        tacky destroy
    } -body {
        catch {tacky storage decrypt} err
        set err
    } -result {storage is not unlocked}

# -- requestEncrypt/requestDecrypt/cancelPending -----------------------------

test storage-request-encrypt-sets-pending-status \
    {requestEncrypt records intent without touching any file; status reflects it immediately} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        set before [tacky storage status]
        tacky storage requestEncrypt
        list $before [tacky storage status] [file exists [file join $cfg .storage-pending]]
    } -result {plaintext pending-encrypt 1}

test storage-request-encrypt-requires-persistent-storage {transient mode has nothing to migrate} \
    -setup {
        tacky_type create ::tacky
    } -cleanup {
        tacky destroy
    } -body {
        catch {tacky storage requestEncrypt} err
        set err
    } -result {local storage encryption requires persistent storage}

test storage-request-encrypt-requires-plaintext {requestEncrypt requires plaintext, like encrypt itself} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        storagetest_plantgarbage [file join $cfg accounts.db]
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        catch {tacky storage requestEncrypt} err
        set err
    } -result {storage is not plaintext}

test storage-request-encrypt-rejects-when-already-pending {a second request is rejected, not silently replaced} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        catch {tacky storage requestEncrypt} err
        set err
    } -result {a storage migration is already pending}

test storage-request-decrypt-requires-unlocked {requestDecrypt requires unlocked, like decrypt itself} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        catch {tacky storage requestDecrypt} err
        set err
    } -result {storage is not unlocked}

test storage-cancel-pending-errors-when-nothing-pending {cancelPending errors rather than silently no-op'ing} \
    -setup {
        tacky_type create ::tacky
    } -cleanup {
        tacky destroy
    } -body {
        catch {tacky storage cancelPending} err
        set err
    } -result {nothing is pending}

test storage-cancel-pending-clears-marker {cancelPending reverts status to the plain (unmigrated) state} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        set before [tacky storage status]
        tacky storage cancelPending
        list $before [tacky storage status]
    } -result {pending-encrypt plaintext}

test storage-cancel-pending-encrypt-completes-boot \
    {cancelling the pre-boot encrypt gate installs the modules the constructor deferred} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
        tacky destroy
    } -cleanup {
        catch {tacky destroy}
        file delete -force $cfg
    } -body {
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        set results {}
        lappend results relaunch=[tacky storage status]
        tacky storage cancelPending
        lappend results settings-usable=[expr {![catch {tacky setting get -key log_to_file}]}]
        lappend results accounts-usable=[expr {![catch {tacky account list}]}]
        set results
    } -result {relaunch=pending-encrypt settings-usable=1 accounts-usable=1}

test storage-cancel-pending-decrypt-completes-boot \
    {cancelling the pre-boot decrypt gate installs the modules unlock deferred} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage encrypt -passphrase cancelpass
        tacky storage requestDecrypt
        tacky destroy
    } -cleanup {
        catch {tacky destroy}
        file delete -force $cfg
    } -body {
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        set results {}
        tacky storage unlock -passphrase cancelpass
        lappend results after-unlock=[tacky storage status]
        tacky storage cancelPending
        lappend results after-cancel=[tacky storage status]
        lappend results settings-usable=[expr {![catch {tacky setting get -key log_to_file}]}]
        set results
    } -result {after-unlock=pending-decrypt after-cancel=unlocked settings-usable=1}

test storage-cancel-pending-decrypt-while-locked-stays-locked \
    {cancelling a decrypt before unlocking leaves storage locked, boot still deferred} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage encrypt -passphrase cancelpass
        tacky storage requestDecrypt
        tacky destroy
    } -cleanup {
        catch {tacky destroy}
        file delete -force $cfg
    } -body {
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        set results {}
        tacky storage cancelPending
        lappend results status=[tacky storage status]
        lappend results settings-installed=[expr {![catch {tacky setting get -key log_to_file}]}]
        tacky storage unlock -passphrase cancelpass
        lappend results after-unlock=[tacky storage status]
        lappend results settings-usable=[expr {![catch {tacky setting get -key log_to_file}]}]
        set results
    } -result {status=locked settings-installed=0 after-unlock=unlocked settings-usable=1}

# -- stale pending markers self-heal at construction -------------------------

test storage-stale-encrypt-marker-cleaned-when-actually-locked \
    {an "encrypt" marker surviving a migration that actually completed (crash before marker cleanup) is discarded, not mistaken for a fresh request} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        # A real completed encrypt: the db is genuinely locked, but the
        # marker never got cleaned up (simulating a crash in that window).
        storagetest_plantgarbage [file join $cfg accounts.db]
        set fh [open [file join $cfg .storage-pending] w]
        puts -nonewline $fh "encrypt"
        close $fh
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        list [tacky storage status] [file exists [file join $cfg .storage-pending]]
    } -result {locked 0}

test storage-stale-decrypt-marker-cleaned-when-actually-plaintext \
    {a "decrypt" marker surviving a migration that actually completed is discarded on a now-plaintext db} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        set fh [open [file join $cfg .storage-pending] w]
        puts -nonewline $fh "decrypt"
        close $fh
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        tacky destroy
        file delete -force $cfg
    } -body {
        list [tacky storage status] [file exists [file join $cfg .storage-pending]]
    } -result {plaintext 0}

# -- encrypt/decrypt disconnect connected accounts rather than erroring -----

test storage-encrypt-disconnects-connected-account \
    {encrypt destroys a live client instead of erroring, then proceeds} \
    -setup {
        storagetest_stub_tacky
        rename conn _real_conn
        rename mock_conn conn
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com
        set client [t client foo@example.com]
        $client conn fire_state connected
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        rename conn mock_conn
        rename _real_conn conn
        file delete -force $cfg
    } -body {
        set failed [expr {[catch {t storage encrypt -passphrase testpass}] != 0}]
        # A destroyed (not merely disconnected) client is what actually
        # closes its db handle - see DisconnectAllAccounts in taco.tcl for
        # why that matters (WAL checkpoint before the file gets swapped).
        set stillExists [expr {[info commands $client] ne ""}]
        # encrypt now reopens accounts.db against the freshly-swapped file
        # and proceeds straight into unlocked, in this same process - no
        # restart needed (that's the whole point of the pre-boot gate
        # redesign), so `status` reporting unlocked here is correct.
        list $failed $stillExists [t storage status]
    } -result {0 0 unlocked}

# Regression: a real per-account db opened the normal way (client.tcl sets
# WAL mode) leaves -wal/-shm sidecar files on disk. Merely disconnecting the
# client (not destroying it) left its db handle open through the whole
# migration; the sidecars were never checkpointed away, so they survived the
# swap still tied to the pre-migration (plaintext) page contents, corrupting
# the very next open with "file is not a database". Only reproduces with a
# real client (this test's whole point) - every other migration test here
# manipulates sqlite files directly and never opens one through client.tcl.
test storage-encrypt-checkpoints-live-wal-connection \
    {a live WAL-mode client survives being encrypted around, decrypted back, and relaunched} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com
        set client [t client foo@example.com]
        $client db eval {
            CREATE TABLE IF NOT EXISTS scratch(x TEXT);
            INSERT INTO scratch(x) VALUES ('hello')
        }
    } -cleanup {
        catch {t destroy}
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        set results {}
        lappend results walBefore=[file exists [file join $data foo@example.com.db-wal]]

        t storage encrypt -passphrase walpass
        t destroy

        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        lappend results relaunchStatus=[t storage status]
        t storage unlock -passphrase walpass
        set openErr [catch {t client foo@example.com} client2]
        lappend results openAfterEncrypt=$openErr
        if {!$openErr} {
            lappend results rowsAfterEncrypt=[$client2 db eval {SELECT x FROM scratch}]
            $client2 db eval {INSERT INTO scratch(x) VALUES ('world')}
        }

        t storage decrypt
        t destroy

        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        set openErr2 [catch {t client foo@example.com} client3]
        lappend results openAfterDecrypt=$openErr2
        if {!$openErr2} {
            lappend results rowsAfterDecrypt=[$client3 db eval {SELECT x FROM scratch}]
        }
        set results
    } -result {walBefore=1 relaunchStatus=locked openAfterEncrypt=0 rowsAfterEncrypt=hello openAfterDecrypt=0 {rowsAfterDecrypt=hello world}}

# -- MigrateDbFiles / MigrateAttachFiles ------------------------------------

test storage-migrate-db-files {accounts.db plus one per account, none missing} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com
        t account add -acc bar@example.com
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        set want [lsort [list [file join $cfg accounts.db] \
            [file join $data foo@example.com.db] \
            [file join $data bar@example.com.db]]]
        expr {[lsort [t storage MigrateDbFiles]] eq $want}
    } -result {1}

test storage-migrate-attach-files-empty {no attachments dir yet is an empty list, not an error} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        t storage MigrateAttachFiles [dict create somehash x]
    } -result {}

test storage-migrate-attach-files-selects-matching-hashes-only \
    {only a file whose hash is a key in the given set is selected; a plain file is left alone} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        file mkdir [file join $data attachments]
        close [open [file join $data attachments omemohash.png] w]
        close [open [file join $data attachments plainhash.jpg] w]
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        lmap p [t storage MigrateAttachFiles [dict create omemohash x]] { file tail $p }
    } -result {omemohash.png}

# -- OmemoAttachUrlsByAccount / OmemoAttachKeys ------------------------------

# A minimal stand-in for a per-account db: just enough (an attachments
# column on chat_message) for OmemoAttachUrlsByAccount's own query.
proc storagetest_plant_chat_message {jidDbFile url} {
    sqlite3 ::_storagetestmsgdb $jidDbFile
    ::_storagetestmsgdb eval {
        CREATE TABLE IF NOT EXISTS chat_message(
            timestamp INTEGER, chat_jid TEXT, attachments TEXT,
            PRIMARY KEY(chat_jid, timestamp))
    }
    set atts [list [dict create url $url type file name f size "" mime ""]]
    ::_storagetestmsgdb eval {
        INSERT INTO chat_message(timestamp, chat_jid, attachments)
        VALUES (1, 'peer@example.com', $atts)
    }
    ::_storagetestmsgdb close
}

set storagetest_aesUrl \
    "aesgcm://example.com/upload/pic.png#[string repeat 00 12][string repeat 11 32]"
set storagetest_omemoHash [attachment_url_hash $storagetest_aesUrl]

test storage-omemo-attach-urls-by-account \
    {only aesgcm urls are picked up, keyed by account jid and url hash} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com
        storagetest_plant_chat_message [file join $data foo@example.com.db] \
            $storagetest_aesUrl
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        dict get [t storage OmemoAttachUrlsByAccount] foo@example.com \
            $storagetest_omemoHash
    } -result $storagetest_aesUrl

# OmemoAttachKeys only ever runs once genuinely unlocked (decrypt requires
# State=unlocked, which is what sets Passphrase) - so this goes through a
# real encrypt+unlock cycle rather than poking Passphrase from outside.
test storage-omemo-attach-keys \
    {attachment_key rows are read back per account, keyed by hash} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com
        t storage encrypt -passphrase testpass
        t destroy
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t storage unlock -passphrase testpass
        sqlite3 ::_storagetestkeydb [file join $data foo@example.com.db]
        taco_pragma_key ::_storagetestkeydb testpass
        ::_storagetestkeydb eval {
            INSERT INTO attachment_key(hash, iv, key)
            VALUES ('keyedhash', 'ivbytes', 'keybytes')
        }
        ::_storagetestkeydb close
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        dict get [t storage OmemoAttachKeys] keyedhash
    } -result {ivbytes keybytes}

# -- CryptAttachFile (the actual attachment crypto) -------------------------

test storage-crypt-attach-file-roundtrip \
    {encrypt produces real ciphertext and a usable key; decrypt with that key recovers the original bytes} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        set live [file join $data plain.bin]
        set fh [open $live wb]; puts -nonewline $fh "some attachment bytes"; close $fh
        set enc [file join $data enc.bin]
        set dec [file join $data dec.bin]
    } -cleanup {
        t destroy
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        set r [t storage CryptAttachFile $live $enc encrypt {}]
        lassign $r iv key
        set fh [open $enc rb]; set ct [read $fh]; close $fh
        set fh [open $live rb]; set pt [read $fh]; close $fh
        t storage CryptAttachFile $enc $dec decrypt [dict create enc [list $iv $key]]
        set fh [open $dec rb]; set back [read $fh]; close $fh
        list [expr {$ct ne $pt}] $back
    } -result {1 {some attachment bytes}}

# -- Full encrypt/relaunch/unlock/decrypt cycle ------------------------------

test storage-full-migration-cycle \
    {a plaintext-mode OMEMO attachment survives encrypt, relaunch+unlock, and decrypt; a plain attachment is never touched} \
    -setup {
        storagetest_stub_tacky
        lassign [storagetest_newdirs] cfg data cache
        taco_type create ::t -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        t account add -acc foo@example.com

        # A plaintext-mode download of an OMEMO attachment, already on disk
        # and recorded against the account's message history - the case
        # `storage encrypt` has to retroactively pick up.
        set aesUrl "aesgcm://example.com/up/pic.png#[string repeat 00 12][string repeat 11 32]"
        set omemoHash [attachment_url_hash $aesUrl]
        file mkdir [file join $data attachments]
        set omemoFull [file join $data attachments $omemoHash.png]
        set fh [open $omemoFull wb]
        puts -nonewline $fh "plaintext attachment bytes"
        close $fh
        storagetest_plant_chat_message [file join $data foo@example.com.db] $aesUrl

        # A plain (non-OMEMO) attachment alongside it - must never be touched.
        set plainFull [file join $data attachments plainhash.jpg]
        set fh [open $plainFull wb]
        puts -nonewline $fh "plain jpg bytes"
        close $fh
    } -cleanup {
        catch {t destroy}
        catch {t2 destroy}
        storagetest_unstub_tacky
        file delete -force $cfg
    } -body {
        set results {}

        t storage encrypt -passphrase "correct horse battery staple"
        set fh [open $omemoFull rb]; set ct [read $fh]; close $fh
        lappend results changed=[expr {$ct ne "plaintext attachment bytes"}]
        set fh [open $plainFull rb]; set plainStillPlain [read $fh]; close $fh
        lappend results plain-untouched=[expr {$plainStillPlain eq "plain jpg bytes"}]

        sqlite3 ::_fullcycledb [file join $data foo@example.com.db]
        taco_pragma_key ::_fullcycledb "correct horse battery staple"
        set gotKey 0
        ::_fullcycledb eval {SELECT iv, key FROM attachment_key WHERE hash=$omemoHash} row {
            set gotKey 1
            set gotIv $row(iv)
            set gotKeyBytes $row(key)
        }
        lappend results keyrow=$gotKey
        lappend results recovers=[expr {
            [::omemo::media_decrypt $gotKeyBytes $gotIv $ct] eq "plaintext attachment bytes"
        }]
        ::_fullcycledb close

        t destroy
        taco_type create ::t2 -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        lappend results relaunch-status=[t2 storage status]
        t2 storage unlock -passphrase "correct horse battery staple"
        lappend results unlocked-status=[t2 storage status]

        t2 storage decrypt
        set fh [open $omemoFull rb]; set restored [read $fh]; close $fh
        lappend results restored=[expr {$restored eq "plaintext attachment bytes"}]

        sqlite3 ::_fullcycledb2 [file join $data foo@example.com.db]
        lappend results keyrows-after-decrypt=[::_fullcycledb2 eval \
            {SELECT count(*) FROM attachment_key}]
        ::_fullcycledb2 close

        set results
    } -result [list changed=1 plain-untouched=1 keyrow=1 recovers=1 \
        relaunch-status=locked unlocked-status=unlocked restored=1 \
        keyrows-after-decrypt=0]

# -- End-to-end pending-encrypt/pending-decrypt via the gate -----------------

test storage-pending-encrypt-end-to-end \
    {requestEncrypt, relaunch, status is pending-encrypt, encrypt resolves it and proceeds straight to unlocked} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage requestEncrypt
        tacky destroy
    } -cleanup {
        catch {tacky destroy}
        file delete -force $cfg
    } -body {
        set results {}
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        lappend results relaunch=[tacky storage status]
        tacky storage encrypt -passphrase pendingpass
        lappend results after=[tacky storage status]
        lappend results marker=[file exists [file join $cfg .storage-pending]]
        set results
    } -result {relaunch=pending-encrypt after=unlocked marker=0}

test storage-pending-decrypt-end-to-end \
    {requestDecrypt while unlocked, relaunch, unlocking reveals pending-decrypt, decrypt resolves it and proceeds straight to plaintext} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        tacky storage encrypt -passphrase pendingpass
        # encrypt itself proceeds straight to unlocked - request a decrypt
        # in this same session, then relaunch to simulate the real
        # request-now/act-next-launch flow.
        tacky storage requestDecrypt
        tacky destroy
    } -cleanup {
        catch {tacky destroy}
        file delete -force $cfg
    } -body {
        set results {}
        tacky_type create ::tacky -transient 0 \
            -config-dir $cfg -data-dir $data -cache-dir $cache
        lappend results relaunch=[tacky storage status]
        tacky storage unlock -passphrase pendingpass
        lappend results after-unlock=[tacky storage status]
        tacky storage decrypt
        lappend results after-decrypt=[tacky storage status]
        lappend results marker=[file exists [file join $cfg .storage-pending]]
        set results
    } -result {relaunch=locked after-unlock=pending-decrypt after-decrypt=plaintext marker=0}

# -- taco_storage_resume (crash-recovery swap) ------------------------------

test storage-resume-no-manifest {no staged migration is a clean no-op} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
    } -cleanup {
        file delete -force $cfg
    } -body {
        taco_storage_resume $cfg
        set ok 1
    } -result {1}

test storage-resume-swaps-staged-files {a leftover manifest gets its renames finished} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        set stageDir [file join $cfg .storage-migrate]
        file mkdir $stageDir
        set liveA [file join $cfg a.db]
        set liveB [file join $cfg b.db]
        set stagedA [file join $stageDir a.db]
        set stagedB [file join $stageDir b.db]
        set fhA [open $stagedA w]; puts -nonewline $fhA "new-a"; close $fhA
        set fhB [open $stagedB w]; puts -nonewline $fhB "new-b"; close $fhB
        set fhLiveA [open $liveA w]; puts -nonewline $fhLiveA "old-a"; close $fhLiveA
        set manifestFile [file join $stageDir manifest]
        set fhM [open $manifestFile w]
        puts $fhM [list $stagedA $liveA $stagedB $liveB]
        close $fhM
    } -cleanup {
        file delete -force $cfg
    } -body {
        taco_storage_resume $cfg
        set fhA [open $liveA r]; set contentA [read $fhA]; close $fhA
        set fhB [open $liveB r]; set contentB [read $fhB]; close $fhB
        list $contentA $contentB \
            [file exists $stageDir] [file exists $stagedA] [file exists $manifestFile]
    } -result {new-a new-b 0 0 0}

test storage-resume-deletes-stale-wal-sidecars \
    {a live path's leftover -wal/-shm files (from a session that didn't get a clean checkpoint) are deleted once the swap lands, so they can't be replayed against the new file's different page contents} \
    -setup {
        lassign [storagetest_newdirs] cfg data cache
        set stageDir [file join $cfg .storage-migrate]
        file mkdir $stageDir
        set live [file join $cfg a.db]
        set staged [file join $stageDir a.db]
        close [open $staged w]
        close [open $live w]
        close [open $live-wal w]
        close [open $live-shm w]
        set manifestFile [file join $stageDir manifest]
        set fhM [open $manifestFile w]
        puts $fhM [list $staged $live]
        close $fhM
    } -cleanup {
        file delete -force $cfg
    } -body {
        taco_storage_resume $cfg
        list [file exists $live] [file exists $live-wal] [file exists $live-shm]
    } -result {1 0 0}
