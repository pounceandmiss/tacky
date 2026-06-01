snit::type app_type {
    option -transient -default 0 -readonly yes
    option -backend -default direct -readonly yes
    option -debug-dir -default "" -readonly yes

    variable windows {}
    variable winCounter 0
    variable setupWin ""

    constructor args {
        $self configurelist $args
        wm withdraw .
        wm title . "Tacky"
        switch $options(-backend) {
            process {
                tacky_init_process -transient $options(-transient) \
                    -debug-dir $options(-debug-dir)
            }
            thread {
                package require Thread
                tacky_init_threaded -transient $options(-transient) \
                    -debug-dir $options(-debug-dir)
            }
            default {
                tacky_init -transient $options(-transient)
            }
        }
        if {$options(-debug-dir) ne ""} {
            file mkdir $options(-debug-dir)
            jlog configure -logproc [list jlog_file_writer $options(-debug-dir)] \
                -defaultlevel debug
        }
        ::tacky listen -tag $self calls <Incoming> [mymethod OnIncomingCall]
        ::tacky listen -tag $self calls <Outgoing> [mymethod OnOutgoingCall]

        ::tacky account list -enabled 1 -command [mymethod OnAccountList]
    }

    destructor {
        catch {::tacky unlisten $self}
        foreach w $windows {
            catch {destroy $w}
        }
        catch {::tacky destroy}
    }

    method OnAccountList {result} {
        if {[llength $result] > 0} {
            $self SpawnWindow [lindex $result 0]
        } else {
            $self ShowSetup
        }
    }

    # --- Account windows ---

    # One window per account: raise the existing one if it's already open.
    method SpawnWindow {jid} {
        set existing [$self WindowForAccount $jid]
        if {$existing ne ""} {
            $self RaiseWindow $existing
            return $existing
        }
        set safe [string map {@ _ . _ / _} $jid]
        set w .acctwin_${safe}_[incr winCounter]
        accountwindow $w -account $jid -controller $self
        lappend windows $w
        return $w
    }

    method WindowForAccount {jid} {
        foreach w $windows {
            if {[winfo exists $w] && [$w CurrentAccount] eq $jid} {
                return $w
            }
        }
        return ""
    }

    method RaiseWindow {w} {
        if {![winfo exists $w]} return
        wm deiconify $w
        raise $w
        focus $w
    }

    method OnWindowClosed {w} {
        set idx [lsearch -exact $windows $w]
        if {$idx >= 0} {
            set windows [lreplace $windows $idx $idx]
        }
        catch {destroy $w}
        if {[llength $windows] == 0} {
            $self EnsureSomethingVisible
        }
    }

    method AnyVisibleWindow {} {
        return [lindex $windows 0]
    }

    method EnsureSomethingVisible {} {
        if {[tk windowingsystem] eq "aqua"} {
            # macOS keeps the process alive with no open windows; the Dock
            # icon would reopen a window via tk::mac::ReopenApplication.
            # Hook left for later - not wired yet.
            return
        }
        ::tacky account list -command [mymethod OnLastWindowClosed]
    }

    # With no windows left: drop back to setup if there are no accounts at
    # all (e.g. the last one was removed), otherwise quit.
    method OnLastWindowClosed {result} {
        if {[llength $windows] > 0} return
        if {[llength $result] == 0} {
            $self ShowSetup
        } else {
            $self Quit
        }
    }

    method Quit {} {
        catch {::tacky unlisten $self}
        foreach w $windows {
            catch {destroy $w}
        }
        set windows {}
        catch {::tacky destroy}
        destroy .
    }

    # --- Setup / add account ---

    method ShowSetup {} {
        if {$setupWin ne "" && [winfo exists $setupWin]} {
            raise $setupWin
            return
        }
        set setupWin .setup
        toplevel $setupWin
        wm title $setupWin "Welcome to Tacky"
        wm protocol $setupWin WM_DELETE_WINDOW [mymethod OnSetupClosed]
        initialsetup $setupWin.content -onsuccess [mymethod OnSetupDone]
        pack $setupWin.content -expand yes -fill both
    }

    method OnSetupClosed {} {
        catch {destroy $setupWin}
        set setupWin ""
        if {[llength $windows] == 0} {
            $self Quit
        }
    }

    method OnSetupDone {jid} {
        ::tacky account enable -acc $jid
        catch {destroy $setupWin}
        set setupWin ""
        $self SpawnWindow $jid
    }

    method OpenAddAccount {} {
        if {[winfo exists .addaccount]} {
            raise .addaccount
            return
        }
        toplevel .addaccount
        wm title .addaccount "Add Account"
        set parent [$self AnyVisibleWindow]
        if {$parent ne "" && [winfo exists $parent]} {
            wm transient .addaccount $parent
        }
        initialsetup .addaccount.setup \
            -onsuccess [mymethod OnAddAccountDone]
        pack .addaccount.setup -expand yes -fill both
    }

    method OnAddAccountDone {jid} {
        ::tacky account enable -acc $jid
        catch {destroy .addaccount}
        if {[llength $windows] == 0} {
            $self SpawnWindow $jid
        }
    }

    # --- Calls ---

    method OnIncomingCall {ev} {
        incomingcalldialog open \
            -acc [dict get $ev -acc] \
            -sid [dict get $ev -sid] \
            -from [dict get $ev -from]
    }

    method OnOutgoingCall {ev} {
        callwindow show \
            -acc [dict get $ev -acc] \
            -sid [dict get $ev -sid] \
            -peer [dict get $ev -to] \
            -direction outgoing
    }
}
