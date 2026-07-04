package provide taco 0.1

package require sqlite3
package require mtls
package require base64
package require snit
package require control
package require jid

# Declare a set of modules as public components.
# Usage:  taco_modules roster bookmarks muc ...
# Effect: each module gets `component $mod -public $mod` and an instance
#         variable $_modules holding the list for iteration.
snit::macro taco_modules {args} {
    variable _modules [list {*}$args]
    foreach mod $args {
        component $mod -public $mod
    }
}

snit::macro tackymethod {name arglist body} {
    method $name $arglist [string map [list %BODY% $body %NAME% $name] {
        set _code [catch {%BODY%} _result _opts]
        if {$_code == 1} {
            if {[dict exists $args -command]} {
                if {[dict exists $args -onerror]} {
                    {*}[dict get $args -onerror] $_result
                } else {
                    tacky emit error <MethodError> \
                        -module [regsub {^taco_} $type {}] \
                        -method %NAME% \
                        -message $_result \
                        -errorinfo [dict get $_opts -errorinfo]
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

    option -transient -default 1 -readonly yes
    option -config-dir -readonly yes -default ""
    option -cache-dir -readonly yes -default ""

    constructor args {
        $self configurelist $args
        if {!$options(-transient)} {
            if {$options(-config-dir) eq ""} {
                set options(-config-dir) [appdirs config]
            }
            if {$options(-cache-dir) eq ""} {
                set options(-cache-dir) [appdirs cache]
            }
        }
        set db $self.db
        if {$options(-config-dir) ne ""} {
            file mkdir $options(-config-dir)
            sqlite3 $self.db [file join $options(-config-dir) accounts.db]
        } else {
            sqlite3 $self.db :memory:
        }
        install account using taco_account ${selfns}::account \
            -db $db -taco $self -cache-dir $options(-cache-dir)
        install setting using taco_setting ${selfns}::setting -db $db -taco $self
        install audio using taco_audio ${selfns}::audio -db $db -taco $self
        install register using taco_register ${selfns}::register -taco $self
        install debugtap using taco_debugtap ${selfns}::debugtap -taco $self
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
    }

    method emit {module event args} {
        tacky emit $module $event {*}$args
    }

    method jlog {args} {
        jlog {*}$args
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
            set extra {}
            if {$options(-cache-dir) ne ""} {
                file mkdir $options(-cache-dir)
                lappend extra -db-path [file join $options(-cache-dir) $jid.db]
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
