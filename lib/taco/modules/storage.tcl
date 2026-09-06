# Off by default: a fresh accounts.db is plain sqlite, no PRAGMA key ever
# issued. Once a user opts in (storage encrypt), every later launch needs
# `storage unlock` before taco_type finishes its own setup - see taco.tcl's
# constructor and CompleteUnlock.
#
# Only OMEMO/XEP-0454 attachments are ever encrypted at rest, using their
# own transit key rather than a separate master key - see file.tcl's
# attachment_key table. A plain (non-OMEMO) attachment is never touched,
# in either mode.
#
# encrypt/decrypt is a staged migration: every changed file (each db via
# sqlcipher_export, each OMEMO attachment via ::omemo::media_encrypt/decrypt)
# is written to $configDir/.storage-migrate first, and only renamed over its
# live counterpart once everything staged - see Migrate and
# taco_storage_resume in taco.tcl. Nothing live is touched before that, so a
# failed or interrupted migration is always safe to retry from scratch.
#
# encrypt/decrypt only ever run at the pre-boot gate, never mid-session:
# requestEncrypt/requestDecrypt just record intent in a $configDir/
# .storage-pending marker (direction only, never the passphrase - that's
# entered fresh at the gate on the next launch, same principle as never
# putting a passphrase on process argv). taco_type's constructor gate (see
# taco.tcl) checks that marker before ever calling CompleteUnlock, so the
# actual migration always runs before any account has ever connected in that
# process - DisconnectAllAccounts below should therefore always be a no-op,
# kept as cheap defense-in-depth rather than something load-bearing.
snit::type taco_storage {
    option -db -default ""
    option -taco -default ""
    option -config-dir -default ""
    option -data-dir -default ""
    option -cache-dir -default ""

    # plaintext | locked | unlocked - never a pending-* value; those are
    # computed on the fly by the status method from this plus the marker
    # file, not stored here.
    variable State "plaintext"
    variable Passphrase ""

    constructor args {
        $self configurelist $args
        if {[$self Readable]} {
            set State plaintext
        } else {
            set State locked
        }
        $self CleanStaleMarker
    }

    # An "encrypt" marker only ever makes sense on a plaintext db (that's
    # what pending-encrypt means); a "decrypt" marker only on a still-locked
    # one (awaiting unlock to actually run). Either marker found alongside
    # the *other* State here means a migration already completed for real
    # (the file swap succeeded) but the process crashed before the marker
    # itself got deleted - stale, self-heal by deleting it now rather than
    # leaving it to block a future request forever. State is never anything
    # but plaintext/locked at construction (unlock hasn't run yet), so
    # that's the full set of combinations to check.
    method CleanStaleMarker {} {
        set marker [$self MarkerRead]
        if {$marker eq "encrypt" && $State ne "plaintext"} { $self MarkerDelete }
        if {$marker eq "decrypt" && $State ne "locked"} { $self MarkerDelete }
    }

    # True if the db can be read without issuing PRAGMA key first - either
    # genuinely plaintext, or already unlocked with the right key set.
    method Readable {} {
        expr {![catch {$options(-db) eval {SELECT count(*) FROM sqlite_master}}]}
    }

    # The verified passphrase, once unlocked - "" in plaintext/locked state.
    # For client.tcl to key each per-account db with the same passphrase.
    method passphrase {} {
        return $Passphrase
    }

    # The raw plaintext|locked|unlocked state, ignoring any pending-request
    # marker - unlike status, this never lies about whether the db is
    # actually keyed right now. file.tcl's at-rest attachment encryption
    # gate needs exactly this: during a pending-decrypt window the db is
    # still genuinely encrypted, even though status reports pending-decrypt.
    method state {} {
        return $State
    }

    method MarkerFile {} {
        return [file join $options(-config-dir) .storage-pending]
    }

    method MarkerRead {} {
        set f [$self MarkerFile]
        if {$options(-config-dir) eq "" || ![file isfile $f]} { return "" }
        set fh [open $f r]
        try { return [string trim [read $fh]] } finally { close $fh }
    }

    method MarkerWrite {direction} {
        set fh [open [$self MarkerFile] w]
        try { puts -nonewline $fh $direction } finally { close $fh }
    }

    method MarkerDelete {} {
        catch {file delete -- [$self MarkerFile]}
    }

    # A marker can only ever be genuinely pending here, not stale:
    # CleanStaleMarker already ran at construction, and unlock/encrypt/
    # decrypt all delete it themselves the moment it stops being pending.
    tackymethod status {args} {
        switch -- $State {
            plaintext { return [expr {[$self MarkerRead] eq "encrypt" ? "pending-encrypt" : "plaintext"}] }
            unlocked  { return [expr {[$self MarkerRead] eq "decrypt" ? "pending-decrypt" : "unlocked"}] }
            default   { return $State }
        }
    }

    tackymethod unlock {args} {
        if {$State ne "locked"} {
            error "storage is not locked"
        }
        set passphrase [dict get $args -passphrase]
        taco_pragma_key $options(-db) $passphrase
        if {![$self Readable]} {
            error "incorrect passphrase"
        }
        set Passphrase $passphrase
        set State unlocked
        # A pending decrypt means the gate isn't done yet - the caller has
        # to run it before normal boot proceeds, same as pending-encrypt
        # defers CompleteUnlock at construction time.
        if {[$self status] ne "pending-decrypt"} {
            $options(-taco) CompleteUnlock
        }
        $options(-taco) emit storage <Unlocked>
        return
    }

    method RequestMigration {direction requiredState} {
        if {$options(-config-dir) eq ""} {
            error "local storage encryption requires persistent storage"
        }
        if {$State ne $requiredState} {
            error "storage is not $requiredState"
        }
        if {[$self MarkerRead] ne ""} {
            error "a storage migration is already pending"
        }
        $self MarkerWrite $direction
    }

    tackymethod requestEncrypt {args} {
        $self RequestMigration encrypt plaintext
        return
    }

    tackymethod requestDecrypt {args} {
        $self RequestMigration decrypt unlocked
        return
    }

    # A resolved gate is a normal boot: run the CompleteUnlock the constructor
    # or unlock deferred. Not while locked - unlock completes the boot itself.
    tackymethod cancelPending {args} {
        if {[$self MarkerRead] eq ""} {
            error "nothing is pending"
        }
        $self MarkerDelete
        if {$State ne "locked"} {
            $options(-taco) CompleteUnlock
        }
        return
    }

    # The live accounts.db connection (installed once, at taco_type
    # construction) still points at the pre-migration file - a rename over
    # its path doesn't affect an already-open handle, it just orphans the
    # old inode. Since the whole point of the gate is to reach normal boot
    # in this same process (no restart), the connection has to actually be
    # closed and reopened against the freshly swapped-in file before
    # CompleteUnlock can safely run against it.
    method ReopenDb {passphrase} {
        $options(-db) close
        sqlite3 $options(-db) [file join $options(-config-dir) accounts.db]
        if {$passphrase ne ""} {
            taco_pragma_key $options(-db) $passphrase
        }
        if {![$self Readable]} {
            error "storage migration left accounts.db unreadable"
        }
    }

    # Runs the migration and lands storage in its new resting state, in
    # this same process: reopens accounts.db against the freshly-swapped
    # file, updates State/Passphrase, clears the pending marker, and runs
    # CompleteUnlock - no restart needed.
    method FinishMigration {direction passphrase newState} {
        $options(-taco) DisconnectAllAccounts
        $self Migrate $direction $passphrase
        $self ReopenDb $passphrase
        set Passphrase $passphrase
        set State $newState
        $self MarkerDelete
        $options(-taco) CompleteUnlock
    }

    tackymethod encrypt {args} {
        if {$State ne "plaintext"} {
            error "storage is not plaintext"
        }
        $self FinishMigration encrypt [dict get $args -passphrase] unlocked
        $options(-taco) emit storage <Unlocked>
        return
    }

    tackymethod decrypt {args} {
        if {$State ne "unlocked"} {
            error "storage is not unlocked"
        }
        $self FinishMigration decrypt "" plaintext
        return
    }

    # Every sqlite db this install has: accounts.db plus one per account.
    method MigrateDbFiles {} {
        set files [list [file join $options(-config-dir) accounts.db]]
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            lappend files [file join $options(-data-dir) $jid.db]
        }
        return $files
    }

    # Every aesgcm:// url referenced anywhere in any account's message
    # history, per account jid, keyed by the hash its downloaded file is
    # named with. Read straight off the live per-account dbs, which are
    # still plaintext at this point (nothing staged yet) - only meaningful
    # while encrypting.
    method OmemoAttachUrlsByAccount {} {
        set byAccount [dict create]
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set jidDbFile [file join $options(-data-dir) $jid.db]
            if {![file isfile $jidDbFile]} continue
            sqlite3 migrateattachscan $jidDbFile
            set urls [dict create]
            migrateattachscan eval \
                {SELECT attachments FROM chat_message WHERE attachments != ''} row {
                foreach att $row(attachments) {
                    set url [dict get $att url]
                    if {[is_aesgcm_url $url]} {
                        dict set urls [attachment_url_hash $url] $url
                    }
                }
            }
            migrateattachscan close
            dict set byAccount $jid $urls
        }
        return $byAccount
    }

    # hash -> {iv key} for every attachment_key row recorded by any
    # account, read with the passphrase that unlocked this session - only
    # meaningful while decrypting.
    method OmemoAttachKeys {} {
        set keys [dict create]
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set jidDbFile [file join $options(-data-dir) $jid.db]
            if {![file isfile $jidDbFile]} continue
            sqlite3 migrateattachscan $jidDbFile
            taco_pragma_key migrateattachscan $Passphrase
            migrateattachscan eval {SELECT hash, iv, key FROM attachment_key} row {
                dict set keys $row(hash) [list $row(iv) $row(key)]
            }
            migrateattachscan close
        }
        return $keys
    }

    # The on-disk attachment files whose hash is a key in $omemoHashes -
    # the set of OMEMO-sourced hashes this migration is touching (a url map
    # from OmemoAttachUrlsByAccount on encrypt, a key map from
    # OmemoAttachKeys on decrypt). A plain (non-OMEMO) attachment's hash is
    # in neither, so it's never selected, in either direction.
    method MigrateAttachFiles {omemoHashes} {
        set dir [file join $options(-data-dir) attachments]
        if {![file isdirectory $dir]} { return {} }
        set result {}
        foreach f [glob -nocomplain -directory $dir -type f *] {
            if {[dict exists $omemoHashes [file rootname [file tail $f]]]} {
                lappend result $f
            }
        }
        return $result
    }

    # SQLCipher's documented plaintext<->encrypted conversion: attach the
    # staged copy with the target key (empty, for decrypt) and export the
    # schema+data into it. Own connection, even for accounts.db, which is
    # also open as $options(-db) - sqlite allows multiple connections.
    method ExportDb {liveFile stagedFile direction passphrase} {
        sqlite3 migratesrc $liveFile
        if {$direction eq "decrypt"} {
            taco_pragma_key migratesrc [$self passphrase]
        }
        set keyClause [expr {$direction eq "encrypt"
            ? "KEY '[taco_sql_quote $passphrase]'"
            : "KEY ''"}]
        migratesrc eval "ATTACH DATABASE '[taco_sql_quote $stagedFile]' AS migrated $keyClause"
        migratesrc eval {SELECT sqlcipher_export('migrated')}
        migratesrc eval {DETACH DATABASE migrated}
        migratesrc close
    }

    # For encrypt: fresh-encrypts $liveFile and returns the {iv key} used
    # (the original transit key isn't recoverable once already decrypted to
    # plaintext on disk, so a new one is generated). For decrypt: decrypts
    # using $keys' entry for this file's hash and returns "".
    method CryptAttachFile {liveFile stagedFile direction keys} {
        set fh [open $liveFile rb]
        try { set data [read $fh] } finally { close $fh }
        if {$direction eq "encrypt"} {
            set enc [::omemo::media_encrypt $data]
            set out [dict get $enc ct]
            set result [list [dict get $enc iv] [dict get $enc key]]
        } else {
            set hash [file rootname [file tail $liveFile]]
            lassign [dict get $keys $hash] iv key
            set out [::omemo::media_decrypt $key $iv $data]
            set result {}
        }
        set fh2 [open $stagedFile wb]
        try { puts -nonewline $fh2 $out } finally { close $fh2 }
        return $result
    }

    method Migrate {direction passphrase} {
        set stageDir [file join $options(-config-dir) .storage-migrate]
        file delete -force -- $stageDir
        file mkdir $stageDir

        # Every OMEMO-attachment hash this install currently knows about,
        # scanned once and reused below for both file selection and the
        # crypt pass: a url map (still-plaintext files to encrypt) on
        # encrypt, a key map (already-ciphertext files to decrypt, and
        # exactly what CryptAttachFile needs) on decrypt.
        if {$direction eq "encrypt"} {
            set byAccount [$self OmemoAttachUrlsByAccount]
            set omemoHashes [dict create]
            dict for {jid urls} $byAccount {
                dict for {hash url} $urls { dict set omemoHashes $hash $url }
            }
        } else {
            set omemoHashes [$self OmemoAttachKeys]
        }

        set dbFiles [$self MigrateDbFiles]
        set attachFiles [$self MigrateAttachFiles $omemoHashes]
        set total [expr {[llength $dbFiles] + [llength $attachFiles]}]
        set done 0
        set manifest {}

        foreach live $dbFiles {
            set staged [file join $stageDir [file tail $live]]
            $self ExportDb $live $staged $direction $passphrase
            lappend manifest $staged $live
            incr done
            $options(-taco) emit storage <MigrateProgress> -done $done -total $total
        }

        # New at-rest keys generated while encrypting, landed into each
        # relevant account's staged db below; unused on decrypt, where every
        # staged db instead gets its attachment_key table cleared outright.
        set newKeys [dict create]
        if {[llength $attachFiles]} {
            set stageAttachDir [file join $stageDir attachments]
            file mkdir $stageAttachDir
            foreach live $attachFiles {
                set staged [file join $stageAttachDir [file tail $live]]
                set r [$self CryptAttachFile $live $staged $direction $omemoHashes]
                if {$direction eq "encrypt"} {
                    dict set newKeys [file rootname [file tail $live]] $r
                }
                lappend manifest $staged $live
                incr done
                $options(-taco) emit storage <MigrateProgress> -done $done -total $total
            }
        }

        # Regenerable cache, dropped rather than migrated (see
        # MigrateAttachFiles) - safe once every real attachment is staged.
        file delete -force -- [file join $options(-cache-dir) attachments]

        # Land the per-account attachment_key changes into each STAGED
        # <jid>.db, not the live one - only takes effect once the manifest
        # swap below commits it along with everything else.
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set stagedJidDb [file join $stageDir $jid.db]
            if {![file isfile $stagedJidDb]} continue
            sqlite3 migratekeydb $stagedJidDb
            if {$direction eq "encrypt"} {
                taco_pragma_key migratekeydb $passphrase
            }
            migratekeydb eval {
                CREATE TABLE IF NOT EXISTS attachment_key(
                    hash TEXT PRIMARY KEY, iv BLOB NOT NULL, key BLOB NOT NULL)
            }
            if {$direction eq "encrypt"} {
                if {[dict exists $byAccount $jid]} {
                    foreach hash [dict keys [dict get $byAccount $jid]] {
                        if {[dict exists $newKeys $hash]} {
                            lassign [dict get $newKeys $hash] iv key
                            migratekeydb eval {
                                INSERT OR REPLACE INTO attachment_key(hash, iv, key)
                                VALUES ($hash, $iv, $key)
                            }
                        }
                    }
                }
            } else {
                migratekeydb eval {DELETE FROM attachment_key}
            }
            migratekeydb close
        }

        set manifestFile [file join $stageDir manifest]
        set fh [open $manifestFile w]
        puts $fh $manifest
        close $fh

        # Every file staged - normal completion and crash-recovery share
        # this same swap step (see taco_storage_resume in taco.tcl).
        taco_storage_resume $options(-config-dir)

        $options(-taco) emit storage <MigrationComplete> -direction $direction
    }
}
