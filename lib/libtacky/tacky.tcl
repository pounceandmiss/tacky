package provide libtacky 0.1
package require jid

# Split the --debug-* flags (jlog configureDebug's options) out of an args list
# into {debugFlags restArgs}; the rest go to taco_type, which rejects unknown
# options.
proc tacky_split_debug {arglist} {
    set flags {
        -debug-level -debug-file
        -libdatachannel-debug-level -rtcma-debug-level
    }
    set debug {}
    set rest {}
    foreach {k v} $arglist {
        if {$k in $flags} {
            lappend debug $k $v
        } else {
            lappend rest $k $v
        }
    }
    return [list $debug $rest]
}

# tacky — event router bridging the GUI and the taco XMPP backend.
#
# Class hierarchy:
#
#   tacky_base              Pub/sub event bus + callback token plumbing.
#       |                   Subclasses only need to provide _send and
#       |                   a constructor.
#       |
#       +-- tacky_type              In-process backend.
#       +-- tacky_threaded_type     Thread backend (thread::send).
#       +-- tacky_process_type      Child-process backend (lenpipe).
#
# Event flow (all backends):
#   Backend fires:  tacky emit $module $event ...
#   GUI side:       emit → dispatch → matching _listeners entries
#
# Callback flow:
#   GUI calls:      tacky $module $method -command $cmd -tag $tag
#   unknown:        stores $cmd in Callbacks(token), replaces -command with
#                     {tacky emit callback <Result> -token $token -result}
#   _send:          delivers rewritten command to backend
#   Backend:        executes method, on success calls the rewritten -command
#                     → tacky emit callback <Result> -token N -result $data
#   Transport:      proxy (thread) or pipe routes emit back to GUI
#   GUI emit:       sees module "callback", calls _callback
#   _callback:      looks up token in Callbacks, removes entry, invokes
#                   the original command with the result.  One-shot: no
#                   dead listener accumulation.
#
# Cancellation:
#   tacky unlisten $tag  →  removes _listeners entries,
#                            then purges Callbacks entries tagged $tag.

oo::class create tacky_base {
    variable _listeners ;# dict: {module event} → list of {tag filters command}
    variable TagCounter
    variable TokenCounter 0
    variable Callbacks ;# dict: token → {tag command}

    constructor {} {
        set _listeners [dict create]
        set TagCounter 0
        set Callbacks [dict create]
    }

    # listen ?-tag $tag? module event ?-field $value ...? $command
    method listen args {
        set eventIdx [lsearch -glob $args <*>]
        set event [lindex $args $eventIdx]
        set module [lindex $args [expr {$eventIdx - 1}]]
        set command [lindex $args end]
        set filters [lrange $args [expr {$eventIdx + 1}] end-1]
        set tagIdx [lsearch -exact $args -tag]
        if {$tagIdx >= 0} {
            set tag [lindex $args [expr {$tagIdx + 1}]]
        } else {
            set tag [incr TagCounter]
        }
        set key [list $module $event]
        dict lappend _listeners $key [list $tag $filters $command]
        return $tag
    }

    # observe ?-tag $tag? module event ?-field $value ...? $command
    #
    # State-bearing companion to listen: registers the listener, then calls
    # the module's `pull` method as `pull -event <Event> ?-field $v ...?`,
    # which re-emits the event with the current value. The synthesized
    # "initial" event flows through dispatch like any subsequent change,
    # so callers get one uniform callback for both. Modules with multiple
    # pullable events dispatch on the -event arg.
    method observe args {
        set tag [my listen {*}$args]
        set eventIdx [lsearch -glob $args <*>]
        set module [lindex $args [expr {$eventIdx - 1}]]
        set event [lindex $args $eventIdx]
        set filters [lrange $args [expr {$eventIdx + 1}] end-1]
        my $module pull -event $event {*}$filters
        return $tag
    }

    # Remove persistent listeners and pending callbacks for $tag.
    method unlisten {tag} {
        dict for {key entries} $_listeners {
            set filtered {}
            foreach entry $entries {
                if {[lindex $entry 0] ne $tag} {
                    lappend filtered $entry
                }
            }
            if {[llength $filtered] == 0} {
                dict unset _listeners $key
            } else {
                dict set _listeners $key $filtered
            }
        }
        dict for {token entry} $Callbacks {
            if {[lindex $entry 0] eq $tag} {
                dict unset Callbacks $token
            }
        }
    }

    # Are we listening check for $tag callbacks or events
    method listening {tag} {
        dict for {_key entries} $_listeners {
            foreach entry $entries {
                if {[lindex $entry 0] eq $tag} { return 1 }
            }
        }
        dict for {_token entry} $Callbacks {
            if {[lindex $entry 0] eq $tag} { return 1 }
        }
        return 0
    }

    method dispatch {module event argsL} {
        set key [list $module $event]
        if {![dict exists $_listeners $key]} return
        foreach entry [dict get $_listeners $key] {
            lassign $entry _tag filters cmd
            set match 1
            foreach {field value} $filters {
                set idx [lsearch -exact $argsL $field]
                if {$idx < 0 || [lindex $argsL [expr {$idx + 1}]] ne $value} {
                    set match 0
                    break
                }
            }
            if {$match} {
                {*}$cmd $argsL
            }
        }
    }

    # Route incoming messages: "callback" module → one-shot _callback,
    # everything else → normal listener dispatch.
    method emit {module event args} {
        if {$module eq "callback"} {
            my _callback {*}$args
        } else {
            my dispatch $module $event $args
        }
    }

    # Look up token, remove entry (one-shot), invoke original command.
    # Silently ignores unknown tokens (callback was cancelled).
    method _callback {args} {
        set token [dict get $args -token]
        if {![dict exists $Callbacks $token]} return
        set entry [dict get $Callbacks $token]
        dict unset Callbacks $token
        lassign $entry _tag cmd
        {*}$cmd [dict get $args -result]
    }

    # Forward jlog calls to the backend thread where the jlog singleton lives.
    # Auto-captures -obj and -acc from the caller's snit scope via uplevel.
    method jlog {level text args} {
        array set opts $args
        if {![info exists opts(-obj)]} {
            catch {set opts(-obj) gui.[uplevel 1 {set self}]}
        }
        if {![info exists opts(-acc)]} {
            catch {set opts(-acc) [uplevel 1 {set options(-acc)}]}
        }
        my _send jlog $level $text {*}[array get opts]
    }

    # Subclass must override: deliver command to backend.
    method _send {module method args} {
        error "abstract: subclass must override _send"
    }

    # Intercept outgoing calls: store -command/-onerror in Callbacks and
    # replace them with {tacky emit callback <Result|Error> -token N -result}
    # so the backend round-trips through emit on completion.
    method unknown {module method args} {
        if {[dict exists $args -command] || [dict exists $args -onerror]} {
            if {[dict exists $args -tag]} {
                set tag [dict get $args -tag]
            } else {
                set tag ""
            }
            foreach opt {-command -onerror} {
                if {![dict exists $args $opt]} continue
                set orig [dict get $args $opt]
                set token [incr TokenCounter]
                set event [dict get {-command <Result> -onerror <Error>} $opt]
                dict set Callbacks $token [list $tag $orig]
                dict set args $opt \
                    [list tacky emit callback $event -token $token -result]
            }
        }
        my _send $module $method {*}$args
    }
}

# In-process backend: taco lives in the same thread.
# Callbacks go through the token system like the async backends,
# but the entire round-trip is synchronous (same stack, same thread).
oo::class create tacky_type {
    superclass tacky_base

    constructor {args} {
        next
        package require taco
        lassign [tacky_split_debug $args] debug rest
        taco_type taco {*}$rest
        jlog configureDebug {*}$debug
    }

    destructor {
        catch {taco destroy}
    }

    method _send {module method args} {
        taco $module $method {*}$args
    }
}

# Thread-based backend: taco runs in a dedicated thread.
# A tacky_proxy snit type lives in the backend thread; when taco calls
# tacky emit, the proxy bounces it to the GUI thread via thread::send -async,
# landing in our emit method (which routes callbacks and events).
oo::class create tacky_threaded_type {
    superclass tacky_base
    variable TacoTid  ;# backend thread id
    variable TackyTid ;# GUI thread id (for the proxy to target)

    constructor {args} {
        next
        set TackyTid [thread::id]
        set TacoTid [thread::create]
        thread::send $TacoTid [list set auto_path $::auto_path]
        thread::send $TacoTid {package require taco}
        lassign [tacky_split_debug $args] debug rest
        set args $rest
        # Route backend-thread background errors through jlog, falling back to
        # raw stderr if no sink is set.
        thread::send $TacoTid {
            proc bgerror {message} {
                if {![catch {jlog cget -logproc} _lp] && $_lp ne ""} {
                    catch {jlog error $::errorInfo -obj bgerror}
                } else {
                    puts stderr $::errorInfo
                }
            }
        }
        thread::send $TacoTid [list jlog configureDebug {*}$debug]
        # Define the proxy in the backend thread: it forwards every emit
        # back to the GUI thread asynchronously.
        thread::send $TacoTid {
            snit::type tacky_proxy {
                option -tid -readonly yes
                option -target -readonly yes
                method emit {module event args} {
                    # The GUI thread can vanish while the backend is still
                    # draining queued stanzas during teardown. A dead target
                    # makes thread::send throw; -async never surfaces
                    # target-side errors here, so catch only swallows that
                    # race and the late event is harmlessly dropped.
                    catch {
                        thread::send -async $options(-tid) \
                            [list $options(-target) emit $module $event {*}$args]
                    }
                }
            }
        }
        # Create proxy as "tacky" in backend so taco's emit calls reach us.
        thread::send $TacoTid [list tacky_proxy tacky -tid $TackyTid -target [self]]
        thread::send $TacoTid [list taco_type create taco {*}$args]
    }

    destructor {
        # Replace proxy with no-op so events during teardown are discarded.
        thread::send $TacoTid {tacky destroy; proc ::tacky {args} {}}
        thread::send $TacoTid {taco destroy}
        thread::release $TacoTid
    }

    method _send {module method args} {
        thread::send -async $TacoTid [list taco $module $method {*}$args]
    }
}

set _tacky_backend_script [file join [file dirname [info script]] .. .. bin tackyd.tcl]

# Process-based backend: taco runs in a child process (bin/tackyd.tcl),
# communicating over stdin/stdout with length-prefixed messages (lenpipe).
#
# Wire shape mirrors tackyd-json.tcl, just with Tcl lists/dicts on the
# wire instead of JSON:
#
#   out: [module method args]          fire-and-forget
#        [module method args token]    request/response
#   in:  [event module <Event> args]   broadcast
#        [result token data]           success reply
#        [error  token message]        error reply
#
# Unlike tacky_type / tacky_threaded_type — which round-trip the
# original callback by replacing -command with a magic string that
# bounces back through `tacky emit callback` — we override `unknown`
# to allocate a wire-level token and let the child wire its own
# internal callbacks against it.  Keeps the callback string off the
# wire.
oo::class create tacky_process_type {
    superclass tacky_base
    variable Pipe
    variable Callbacks
    variable TokenCounter

    constructor {args} {
        next
        package require lenpipe
        set Callbacks [dict create]
        set TokenCounter 0
        # -tackyd is a launcher concern (which daemon to spawn), not a taco
        # option, so pull it out before forwarding the rest to the daemon.
        set explicit ""
        if {[dict exists $args -tackyd]} {
            set explicit [dict get $args -tackyd]
            dict unset args -tackyd
        }
        set cmd [my BackendCommand $explicit]
        set fd [open |[list {*}$cmd {*}$args] r+]
        set Pipe [lenpipe new $fd \
            -onmessage [namespace code {my _onMessage}] \
            -oneof [namespace code {my _onEof}]]
    }

    # Resolve the daemon command to spawn. An explicit path wins; otherwise
    # prefer a tclsh-based tackyd binary shipped next to the GUI executable
    # (no Tk, so no stray window). Fall back to running the daemon script
    # under the current interpreter for the dev/source layout.
    method BackendCommand {explicit} {
        if {$explicit ne ""} {
            if {![file executable $explicit]} {
                error "tackyd not executable: $explicit"
            }
            return [list $explicit]
        }
        set daemon [file join [file dirname [info nameofexecutable]] tackyd]
        if {$::tcl_platform(platform) eq "windows"} {
            append daemon .exe
        }
        if {[file executable $daemon]} {
            return [list $daemon]
        }
        return [list [info nameofexecutable] $::_tacky_backend_script]
    }

    destructor { catch {$Pipe destroy} }

    method unknown {module method args} {
        if {[dict exists $args -command] || [dict exists $args -onerror]} {
            set tag [expr {[dict exists $args -tag] ? [dict get $args -tag] : ""}]
            set cmd [expr {[dict exists $args -command] ? [dict get $args -command] : ""}]
            set err [expr {[dict exists $args -onerror] ? [dict get $args -onerror] : ""}]
            set token [incr TokenCounter]
            dict set Callbacks $token [list $tag $cmd $err]
            dict unset args -command
            dict unset args -onerror
            $Pipe send [list $module $method $args $token]
        } else {
            $Pipe send [list $module $method $args]
        }
    }

    method _send {module method args} {
        $Pipe send [list $module $method $args]
    }

    method _onMessage {msg} {
        switch -- [lindex $msg 0] {
            event {
                lassign $msg _ module event eargs
                my dispatch $module $event $eargs
            }
            result {
                lassign $msg _ token data
                if {[dict exists $Callbacks $token]} {
                    set entry [dict get $Callbacks $token]
                    dict unset Callbacks $token
                    set cmd [lindex $entry 1]
                    if {$cmd ne ""} { {*}$cmd $data }
                }
            }
            error {
                lassign $msg _ token errmsg
                if {[dict exists $Callbacks $token]} {
                    set entry [dict get $Callbacks $token]
                    dict unset Callbacks $token
                    set err [lindex $entry 2]
                    if {$err ne ""} { {*}$err $errmsg }
                }
            }
        }
    }

    method _onEof {} { my dispatch error <ProcessExit> {} }
}

if 0 {
    avatarcache_base - shared avatar image cache with refcounting.

    Frontend-agnostic base class: handles refcounting, tag management,
    visibility tracking, master-image fetching, update listening, and
    notification fanout.  It fetches the master avatar bytes (avatar
    metadata -> avatar data) and hands them to the subclass to scale;
    the backend does no resizing.  Subclasses override three methods to
    provide image primitives:

        CreateImage $data $size - decode master bytes, crop/scale to a
                                  $size square, return an image handle
        DeleteImage $img        - destroy image handle
        CreateDefault           - create a default/placeholder image handle

    tk_avatarcache (gui/avatarcache.tcl) provides the Tk implementation.

    API:
        avatarcache track -acc $acc -jid $jid -tag $tag ?-size 32? -command $cmd
            Returns an image handle (default initially).
            Calls {*}$cmd $img whenever the image changes.
            -size is the target square edge in px (default 32); the same
            jid can be tracked at several sizes independently.
            -tag identifies this registration for untrack.

        avatarcache untrack -tag $tag
            Unregisters the callback and decrements refcount.
            At zero the image is deleted and avatar invisible is called.

        avatarcache default
            Returns the shared default image handle.
}

oo::class create avatarcache_base {
    variable Images
    variable Refcounts
    variable Tags
    variable DefaultImage

    constructor {} {
        set Images [dict create]
        set Refcounts [dict create]
        set Tags [dict create]
        set DefaultImage [my CreateDefault]
        ::tacky listen -tag [self] avatar <Update> \
            [namespace code {my OnUpdate}]
    }

    destructor {
        catch {::tacky unlisten [self]}
        dict for {key img} $Images {
            catch {my DeleteImage $img}
        }
        catch {my DeleteImage $DefaultImage}
    }

    method CreateImage {data size} { error "abstract: subclass must override" }
    method DeleteImage {img}       { error "abstract: subclass must override" }
    method CreateDefault {}        { error "abstract: subclass must override" }

    method default {} {
        return $DefaultImage
    }

    method track {args} {
        array set opts {-size 32}
        array set opts $args
        set acc [jid norm $opts(-acc)]
        # Accept chat JIDs: a group chat's ?join suffix is not part of
        # the JID the avatar lives under (resource kept for occupants)
        set jid [jid norm [regsub {\?join$} $opts(-jid) {}]]
        set tag $opts(-tag)
        set command $opts(-command)
        set size $opts(-size)
        set key "$acc\n$jid\n$size"

        dict set Tags $tag [list $acc $jid $size $command]

        if {[dict exists $Images $key]} {
            dict set Refcounts $key [expr {[dict get $Refcounts $key] + 1}]
            return [dict get $Images $key]
        }

        set img [my CreateDefault]

        dict set Images $key $img
        dict set Refcounts $key 1

        ::tacky avatar visible -acc $acc -jid $jid
        my Fetch $acc $jid $size

        # Return current image — may have been replaced by a
        # synchronous fetch callback during the Fetch above.
        return [dict get $Images $key]
    }

    method untrack {args} {
        array set opts $args
        set tag $opts(-tag)
        if {![dict exists $Tags $tag]} return

        lassign [dict get $Tags $tag] acc jid size _command
        dict unset Tags $tag
        set key "$acc\n$jid\n$size"

        if {![dict exists $Refcounts $key]} return

        set count [dict get $Refcounts $key]
        if {$count <= 1} {
            ::tacky avatar invisible -acc $acc -jid $jid
            catch {my DeleteImage [dict get $Images $key]}
            dict unset Images $key
            dict unset Refcounts $key
        } else {
            dict set Refcounts $key [expr {$count - 1}]
        }
    }

    # Fetch the master avatar for a (jid, size): resolve the current hash
    # via metadata, then pull the master bytes by hash. Both are backend
    # calls; in the same-thread transport they resolve synchronously.
    method Fetch {acc jid size} {
        ::tacky avatar metadata -acc $acc -jid $jid \
            -command [namespace code [list my OnMeta $acc $jid $size]]
    }

    method OnMeta {acc jid size meta} {
        if {![dict exists $meta hash] || [dict get $meta hash] eq ""} return
        set hash [dict get $meta hash]
        ::tacky avatar data -acc $acc -hash $hash \
            -command [namespace code [list my OnData $acc $jid $size]]
    }

    method OnData {acc jid size data} {
        if {$data eq ""} return
        set key "$acc\n$jid\n$size"
        if {![dict exists $Images $key]} return
        set oldImg [dict get $Images $key]
        set newImg [my CreateImage $data $size]
        dict set Images $key $newImg
        catch {my DeleteImage $oldImg}
        my Notify $key $newImg
    }

    method OnUpdate {ev} {
        set acc [jid norm [dict get $ev -acc]]
        set jid [jid norm [dict get $ev -jid]]
        set sizes [my SizesFor $acc $jid]
        if {[llength $sizes] == 0} return

        if {[dict exists $ev -action] && [dict get $ev -action] eq "disabled"} {
            foreach size $sizes {
                set key "$acc\n$jid\n$size"
                set oldImg [dict get $Images $key]
                set newImg [my CreateDefault]
                dict set Images $key $newImg
                catch {my DeleteImage $oldImg}
                my Notify $key $newImg
            }
            return
        }

        foreach size $sizes {
            my Fetch $acc $jid $size
        }
    }

    # Sizes currently tracked for a (acc, jid), across all slots.
    method SizesFor {acc jid} {
        set out {}
        dict for {key _} $Images {
            lassign [split $key \n] a j s
            if {$a eq $acc && $j eq $jid} { lappend out $s }
        }
        return $out
    }

    method Notify {key img} {
        dict for {tag info} $Tags {
            lassign $info acc jid size command
            if {"$acc\n$jid\n$size" eq $key} {
                {*}$command $img
            }
        }
    }
}

proc tacky_init_threaded {args} {
    package require Thread
    tacky_threaded_type create tacky {*}$args
    if {[info commands tk_avatarcache] ne ""} {
        tk_avatarcache create avatarcache
    }
}

proc tacky_init {args} {
    tacky_type create tacky {*}$args
    if {[info commands tk_avatarcache] ne ""} {
        tk_avatarcache create avatarcache
    }
}

proc tacky_init_process {args} {
    tacky_process_type create tacky {*}$args
    if {[info commands tk_avatarcache] ne ""} {
        tk_avatarcache create avatarcache
    }
}

