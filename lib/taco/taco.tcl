package provide taco 0.1

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

    option -transient -default 1 -readonly yes
    option -config-dir -readonly yes -default ""
    option -data-dir -readonly yes -default ""
    option -cache-dir -readonly yes -default ""

    variable TransientRoot ""

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
        set db $self.db
        if {$options(-config-dir) ne ""} {
            sqlite3 $self.db [file join $options(-config-dir) accounts.db]
        } else {
            sqlite3 $self.db :memory:
        }
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
                lappend extra -db-path [file join $options(-data-dir) $jid.db]
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
