# Unit tests for app_type's startup sequencing.
package require tcltest
namespace import ::tcltest::*

# Shared by the tests below that need a real, XDG-scoped install app_type's
# own tacky_init will find (appdirs appends a "tacky" leaf to each XDG
# base - seed/point env vars at exactly where it'll look). $suffix keeps
# each test's temp dir distinct.
proc apptest_setup_env {suffix} {
    set ::_apptest_root [file tempdir tacky-apptest$suffix]
    set ::_apptest_cfgbase [file join $::_apptest_root config]
    set ::_apptest_database [file join $::_apptest_root data]
    set ::_apptest_cachebase [file join $::_apptest_root cache]
    set ::_apptest_cfg [file join $::_apptest_cfgbase tacky]
    set ::_apptest_data [file join $::_apptest_database tacky]
    set ::_apptest_cache [file join $::_apptest_cachebase tacky]
    file mkdir $::_apptest_cfg $::_apptest_data $::_apptest_cache

    foreach v {XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME} {
        if {[info exists ::env($v)]} {
            set ::_apptest_saved($v) $::env($v)
        }
    }
    set ::env(XDG_CONFIG_HOME) $::_apptest_cfgbase
    set ::env(XDG_DATA_HOME) $::_apptest_database
    set ::env(XDG_CACHE_HOME) $::_apptest_cachebase
}

proc apptest_teardown_env {} {
    # .setup's signin/signup pages unlisten from tacky on destroy, so this
    # has to close before testapp's own destructor tears tacky down -
    # otherwise their <Destroy> bindings hit a dangling command. ShowSetup's
    # initialsetup widget creates the global avatarcache singleton, which
    # outlives .setup's own destruction - other tests (harness.tcl's
    # mock_backend_up) create the same singleton by name.
    catch {destroy .setup}
    catch {avatarcache destroy}
    catch {testapp destroy}
    catch {tacky destroy}
    foreach v {XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME} {
        if {[info exists ::_apptest_saved($v)]} {
            set ::env($v) $::_apptest_saved($v)
        } else {
            unset -nocomplain ::env($v)
        }
    }
    unset -nocomplain ::_apptest_saved
    wm deiconify .
    wm attributes . -topmost 1
    raise .
    file delete -force $::_apptest_root
}

# Regression: an unrecognized --backend value (a typo, e.g. "threaded"
# instead of "thread") used to silently fall through to the switch's
# `default` case, which was direct mode - meaning a typo silently ran the
# real backend on the GUI's own thread instead of the intended one, with no
# warning at all.
test app-construct-rejects-unknown-backend \
    {an unrecognized --backend value errors instead of silently defaulting to direct mode} \
    -body {
        catch {app_type testapp3 -backend threaded -transient 1} err
        set err
    } -cleanup {
        catch {testapp3 destroy}
        wm deiconify .
        wm attributes . -topmost 1
        raise .
    } -result {Error in constructor: unknown --backend 'threaded': expected direct, thread, or process}

# Regression: app_type's constructor used to `::tacky observe setting <Changed>
# ...` (which immediately pulls the current value) unconditionally, before
# ever checking `storage status`. `setting` isn't installed while storage is
# locked - only `storage status`/`unlock` are - so relaunching an encrypted
# install crashed immediately with "delegates method ... to undefined
# component setting", before the unlock dialog ever showed.
test app-construct-while-locked-defers-setting-observers \
    {app_type doesn't touch `setting` until storage is confirmed unlocked, even when it starts out locked} \
    -setup {
        apptest_setup_env locked
        # Seed a genuinely encrypted, empty install - same public API a real
        # user would go through, no accounts needed to hit this bug.
        tacky_type create tacky -transient 0 \
            -config-dir $::_apptest_cfg -data-dir $::_apptest_data \
            -cache-dir $::_apptest_cache
        tacky storage encrypt -passphrase apptestpass
        tacky destroy

        # Stand in for the real (blocking) unlock modal: same end state - by
        # the time it returns, storage really is unlocked - without needing
        # a live widget interaction.
        rename StorageUnlockDialog _real_StorageUnlockDialog
        proc StorageUnlockDialog {parent} {
            ::tacky storage unlock -passphrase apptestpass
        }
    } -cleanup {
        apptest_teardown_env
        rename StorageUnlockDialog {}
        rename _real_StorageUnlockDialog StorageUnlockDialog
    } -body {
        set errCode [catch {app_type testapp -transient 0} err]
        wait
        list $errCode $err [tacky storage status]
    } -result {0 ::testapp unlocked}

# OnStorageStatus's pending-encrypt/pending-decrypt path: a requested (not
# yet run) migration has to resolve at the gate, same as locked does, before
# normal boot proceeds - and re-checking status afterward is what lets
# unlocking reveal a pending-decrypt in the first place (see storagegatedialog
# tests for that specific transition; this one only needs pending-encrypt,
# reachable straight from a fresh construct with no unlock step first).
test app-construct-with-pending-encrypt-shows-gate-then-proceeds \
    {app_type shows the gate dialog for a pending-encrypt status and proceeds to unlocked once it resolves} \
    -setup {
        apptest_setup_env 2
        # A plaintext install with a pending encrypt request, same public
        # API a real user would go through.
        tacky_type create tacky -transient 0 \
            -config-dir $::_apptest_cfg -data-dir $::_apptest_data \
            -cache-dir $::_apptest_cache
        tacky storage requestEncrypt
        tacky destroy

        # Stand in for the real (blocking) gate dialog: same end state - by
        # the time it returns, the migration really ran - without needing a
        # live widget interaction.
        set ::_apptest_gate_calls {}
        rename StorageGateDialog _real_StorageGateDialog
        proc StorageGateDialog {parent direction} {
            lappend ::_apptest_gate_calls $direction
            ::tacky storage encrypt -passphrase apptestpass
        }
    } -cleanup {
        apptest_teardown_env
        rename StorageGateDialog {}
        rename _real_StorageGateDialog StorageGateDialog
        unset -nocomplain ::_apptest_gate_calls
    } -body {
        set errCode [catch {app_type testapp -transient 0} err]
        wait
        list $errCode $err $::_apptest_gate_calls [tacky storage status]
    } -result {0 ::testapp encrypt unlocked}
