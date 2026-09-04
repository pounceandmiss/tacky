package provide taco 0.1

# tcllib's sha1 (and friends) probe for optional C accelerators we don't
# bundle, inside a catch. Tcl's tclPkgUnknown keeps its "already scanned" state
# in proc-local variables, so each miss re-sources every pkgIndex.tcl in
# auto_path - eight full sweeps of ~137 files, for nothing. Record the misses
# once so the probes resolve without searching.
#
# Here rather than in an entry point for two reasons: every entry point reaches
# taco, and `package require taco` has already forced the sweep that registers
# everything, which is what makes an empty `package versions` mean "absent"
# rather than "not looked for yet". Running this any earlier would wrongly
# poison an accelerator that is genuinely installed.
foreach _pkg {tcllibc sha1c md5c cryptkit Trf} {
    if {[package versions $_pkg] eq ""} {
        package ifneeded $_pkg 0 [list error "$_pkg is not bundled"]
    }
}
unset -nocomplain _pkg

package require sqlite3
package require mtls
package require base64
package require snit
package require control
package require jid

# Pull the condition and optional human text out of a response stanza's
# <error> child. Returns {condition <c> text <t>}: condition is "unknown" when
# absent, text is "" when the server sent no <text>. Keeps stanza parsing in
# the backend so callers can hand the GUI a ready message.
proc stanza_error {stanza} {
    set condition [xsearch $stanza error * -get tag]
    if {$condition eq ""} {
        set condition unknown
    }
    return [dict create \
        condition $condition \
        text [xsearch $stanza error text -get body]]
}

# PRAGMA rejects a bound $var (syntax error) - only a literal in the SQL
# text - so quote it by hand: double any embedded single quotes.
proc taco_sql_quote {s} {
    return [string map {' ''} $s]
}

proc taco_pragma_key {db passphrase} {
    $db eval "PRAGMA key = '[taco_sql_quote $passphrase]'"
}

# Finish, or on a fresh launch resume, a storage encrypt/decrypt migration:
# staged files under $configDir/.storage-migrate get renamed over their live
# counterparts (see taco_storage's Migrate). Call before accounts.db is ever
# opened, so a live file mid-swap is never read stale.
proc taco_storage_resume {configDir} {
    set manifestFile [file join $configDir .storage-migrate manifest]
    if {![file exists $manifestFile]} { return }
    set fh [open $manifestFile r]
    set manifest [read $fh]
    close $fh
    foreach {staged live} $manifest {
        file rename -force -- $staged $live
        # A per-account db may have -wal/-shm sidecars left from a session
        # that didn't get a clean checkpoint (crash, force-quit). They're
        # tied to the pre-migration page contents; left in place they'd
        # confuse the next open of the just-swapped-in file. A freshly
        # migrated db starts clean - WAL mode gets re-enabled fresh by
        # client.tcl's next open anyway.
        file delete -force -- $live-wal $live-shm
    }
    file delete -force -- [file dirname $manifestFile]
}

# A background error has no caller to answer: log the trace, then hand the
# frontend the message so it reports it the way it reports its own. Install only
# where taco runs without a frontend in the same interp (the daemon, the backend
# thread); in direct mode the frontend's own bgerror is already the presenter.
namespace eval ::taco_bg {
    variable reporting 0
    variable lastEmit {}

    proc report {message} {
        variable reporting
        # Snapshot before the catches below overwrite ::errorInfo.
        set info $::errorInfo
        if {$reporting} {
            catch {puts stderr $info}
            return
        }
        set reporting 1
        catch {Report $message $info}
        set reporting 0
    }

    proc Report {message info} {
        if {[catch {jlog error $info -obj bgerror}]} {
            puts stderr $info
        }
        if {![Fresh $message]} return
        # tacky is a no-op proc during threaded teardown and the pipe can be
        # gone in process mode; the log above is the record either way.
        catch {tacky emit error <Background> -message $message -errorinfo $info}
    }

    # One event per distinct message per window, so a throwing `after` repeater
    # cannot push one per tick. The log still keeps every occurrence.
    proc Fresh {message} {
        variable lastEmit
        set now [clock milliseconds]
        if {[dict exists $lastEmit $message]
                && $now - [dict get $lastEmit $message] < 5000} {
            return 0
        }
        if {[dict size $lastEmit] > 64} {
            set lastEmit {}
        }
        dict set lastEmit $message $now
        return 1
    }
}

proc taco_install_bgerror {} {
    proc ::bgerror {message} {::taco_bg::report $message}
}

snit::macro tackymethod {name arglist body} {
    method $name $arglist [string map [list %BODY% $body %NAME% $name] {
        set _code [catch {%BODY%} _result _opts]
        if {$_code == 1} {
            if {[dict exists $args -command]} {
                if {[dict exists $args -onerror]} {
                    {*}[dict get $args -onerror] $_result
                } else {
                    set _extra {}
                    if {[dict exists $args -acc]} {
                        lappend _extra -acc [dict get $args -acc]
                    }
                    tacky emit error <MethodError> \
                        -module [regsub {^::taco_} $type {}] \
                        -method %NAME% \
                        -message $_result \
                        -errorinfo [dict get $_opts -errorinfo] \
                        {*}$_extra
                }
                return
            }
            return -options $_opts $_result
        }
        
        if {[dict exists $args -command]} {
            {*}[dict get $args -command] $_result
            return
        }
        return -options $_opts $_result
    }]
}

# Entry point for a transport delivering one request. Routes a synchronous
# error the way tackymethod routes its own, instead of letting it escape into
# a background handler: nothing times out a request, so an escaped error
# leaves the caller with no reply at all.
proc taco_call {taco module method args} {
    set code [catch {$taco $module $method {*}$args} result opts]
    # Not `return -options` on success: -level 0 evaluates in place instead of
    # unwinding, so the error branches below would run too.
    if {$code == 0} {
        return $result
    }
    if {$code != 1} {
        return -options $opts $result
    }
    if {[dict exists $args -onerror]} {
        return [{*}[dict get $args -onerror] $result]
    }
    if {[dict exists $args -command]} {
        set extra {}
        if {[dict exists $args -acc]} {
            lappend extra -acc [dict get $args -acc]
        }
        tacky emit error <MethodError> \
            -module $module -method $method -message $result \
            -errorinfo [dict get $opts -errorinfo] {*}$extra
        return
    }
    return -options $opts $result
}

set _taco_dir [file join [file dirname [info script]] modules]
foreach script [lsort [glob [file join $_taco_dir *.tcl]]] {
    source $script
}
unset _taco_dir

package require xmpprw

snit::type taco_type {
    component db
    component account -public account
    component setting -public setting
    component audio -public audio
    component register -public register
    component debugtap -public debugtap
    component log -public log
    component storage -public storage

    option -transient -default 1 -readonly yes
    option -config-dir -readonly yes -default ""
    option -data-dir -readonly yes -default ""
    option -cache-dir -readonly yes -default ""

    variable TransientRoot ""
    # Guards CompleteUnlock against running twice: the constructor already
    # runs it once for a plaintext/unlocked-at-construction db, but
    # storage encrypt/decrypt also call it (needed when they run from the
    # pre-boot gate, where the constructor deferred it) - re-installing an
    # already-installed component would throw.
    variable CompleteUnlockDone 0

    constructor args {
        $self configurelist $args
        # -transient only decides whether a database touches disk;
        # attachments still need a real directory to land in.
        if {$options(-transient)} {
            if {$options(-data-dir) eq "" || $options(-cache-dir) eq ""} {
                catch {set TransientRoot [file tempdir tacky-transient]}
            }
            if {$options(-data-dir) eq "" && $TransientRoot ne ""} {
                set options(-data-dir) [file join $TransientRoot data]
            }
            if {$options(-cache-dir) eq "" && $TransientRoot ne ""} {
                set options(-cache-dir) [file join $TransientRoot cache]
            }
        } else {
            foreach {opt which} {-config-dir config -data-dir data -cache-dir cache} {
                if {$options($opt) eq ""} {
                    set options($opt) [appdirs $which]
                }
            }
        }
        foreach opt {-config-dir -data-dir -cache-dir} {
            if {$options($opt) ne ""} {
                appdirs_mkprivate $options($opt)
            }
        }
        if {$options(-config-dir) ne ""} {
            taco_storage_resume $options(-config-dir)
        }
        set db $self.db
        if {$options(-config-dir) ne ""} {
            sqlite3 $self.db [file join $options(-config-dir) accounts.db]
        } else {
            sqlite3 $self.db :memory:
        }
        install storage using taco_storage ${selfns}::storage -db $db -taco $self \
            -config-dir $options(-config-dir) -data-dir $options(-data-dir) \
            -cache-dir $options(-cache-dir)
        # An encrypted accounts.db can't run any query until `storage unlock`
        # verifies the passphrase; a pending encrypt request needs a fresh
        # passphrase from the gate before there's anything to unlock. Either
        # way the rest defers to CompleteUnlock, which unlock (or the gate's
        # own storage encrypt call) triggers once resolved.
        if {[$storage status] in {locked pending-encrypt}} {
            return
        }
        $self CompleteUnlock
    }

    # Run immediately for a plaintext db, or from unlock/encrypt/decrypt
    # once verified - idempotent, since more than one of those can apply in
    # a single process (e.g. a test calling storage encrypt directly on an
    # already-booted instance).
    method CompleteUnlock {} {
        if {$CompleteUnlockDone} return
        set CompleteUnlockDone 1
        install account using taco_account ${selfns}::account \
            -db $db -taco $self -data-dir $options(-data-dir)
        install setting using taco_setting ${selfns}::setting -db $db -taco $self
        install audio using taco_audio ${selfns}::audio -db $db -taco $self
        install register using taco_register ${selfns}::register -taco $self
        install debugtap using taco_debugtap ${selfns}::debugtap -taco $self
        install log using taco_log ${selfns}::log \
            -cache-dir $options(-cache-dir)
        foreach jid [$self account list] {
            $self emit account <Added> -acc $jid
        }
        $self connect
    }

    destructor {
        # Detach native log callbacks before teardown so no queued line
        # dispatches onto a dead thread.
        catch {::rtc::set-log-level none}
        catch {::rtcma::set-log-level none}
        catch {
            foreach jid [$db eval {SELECT jid FROM account}] {
                set client $self.client($jid)
                if {[info commands $client] ne ""} {
                    catch {$client disconnect}
                    catch {$client destroy}
                }
            }
        }
        catch {$db close}
        # Last, so nothing is still writing under it.
        if {$TransientRoot ne ""} {
            catch {file delete -force -- $TransientRoot}
        }
    }

    method emit {module event args} {
        tacky emit $module $event {*}$args
    }

    # Called by storage encrypt/decrypt before migrating: a real client is
    # destroyed outright, not just disconnected - its db handle has to
    # actually close so WAL mode fully checkpoints and drops its -wal/-shm
    # sidecar files, or they'd be left on disk still tied to the pre-
    # migration (plaintext) page contents once the main file is swapped for
    # the encrypted one, corrupting the next open. In practice this is
    # always a no-op: migrations only ever run at the pre-boot gate, before
    # any client has connected - kept as cheap insurance regardless.
    method DisconnectAllAccounts {} {
        foreach jid [$db eval {SELECT jid FROM account}] {
            set client $self.client($jid)
            if {[info commands $client] ne ""} {
                catch {$client destroy}
            }
        }
    }

    method connect {} {
        foreach jid [$db eval {SELECT jid FROM account WHERE enabled=1}] {
            [$self client $jid] connect
        }
    }

    method client {jid} {
        if {![$self account exists -acc $jid]} {
            error "Account does not exist: $jid"
        }

        set client $self.client($jid)
        if {[info commands $client] eq ""} {
            lassign [$db eval {SELECT username, password, domain FROM account WHERE jid=$jid}] \
                username password domain
            set resource [$account resource -acc $jid]
            set extra [list -data-dir $options(-data-dir) \
                            -cache-dir $options(-cache-dir)]
            if {!$options(-transient)} {
                lappend extra -db-path [file join $options(-data-dir) $jid.db] \
                    -passphrase [$storage passphrase]
            }
            taco_client $client \
                -username $username \
                -password $password \
                -host $domain \
                -resource $resource \
                -taco $self \
                {*}$extra
        }
        return $client
    }

    delegate method * using {%s _routeToClient %m}

    method _routeToClient {module method args} {
        [$self client [dict get $args -acc]] $module $method {*}$args
    }
}
