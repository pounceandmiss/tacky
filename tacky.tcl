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

set _tacky_taco_script [file join [file dirname [info script]] taco taco.tcl]

# In-process backend: taco lives in the same thread.
# Callbacks go through the token system like the async backends,
# but the entire round-trip is synchronous (same stack, same thread).
oo::class create tacky_type {
    superclass tacky_base

    constructor {args} {
        next
        if {[info commands taco_type] eq ""} {
            uplevel #0 source $::_tacky_taco_script
        }
        taco_type taco {*}$args
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
        thread::send $TacoTid [list source $::_tacky_taco_script]
        # Define the proxy in the backend thread: it forwards every emit
        # back to the GUI thread asynchronously.
        thread::send $TacoTid {
            snit::type tacky_proxy {
                option -tid -readonly yes
                option -target -readonly yes
                method emit {module event args} {
                    thread::send -async $options(-tid) \
                        [list $options(-target) emit $module $event {*}$args]
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

set _tacky_lenpipe_script [file join [file dirname [info script]] taco lenpipe.tcl]
set _tacky_backend_script [file join [file dirname [info script]] taco_process_backend.tcl]

# Process-based backend: taco runs in a child process
# (taco_process_backend.tcl), communicating over stdin/stdout with
# length-prefixed messages (lenpipe).  The child's tacky object sends
# {event $module $event $args} messages back, which _onMessage routes
# through emit.
oo::class create tacky_process_type {
    superclass tacky_base
    variable Pipe

    constructor {args} {
        next
        source $::_tacky_lenpipe_script
        set fd [open |[list [info nameofexecutable] $::_tacky_backend_script {*}$args] r+]
        set Pipe [lenpipe new $fd \
            -onmessage [namespace code {my _onMessage}] \
            -oneof [namespace code {my _onEof}]]
    }

    destructor { catch {$Pipe destroy} }

    method _send {module method args} {
        $Pipe send [list $module $method {*}$args]
    }

    # Dispatch incoming messages from the child process.
    # Format: {event $module $event $args}
    method _onMessage {msg} {
        lassign $msg type module event args
        my emit $module $event {*}$args
    }

    method _onEof {} { my dispatch error <ProcessExit> {} }
}

if 0 {
    avatarcache_base - shared avatar image cache with refcounting.

    Frontend-agnostic base class: handles refcounting, tag management,
    visibility tracking, thumb fetching, update listening, and
    notification fanout.  Subclasses override three methods to provide
    image primitives:

        CreateImage $data   - create image from PNG bytes, return handle
        DeleteImage $img    - destroy image handle
        CreateDefault       - create a default/placeholder image, return handle

    tk_avatarcache (gui/avatarcache.tcl) provides the Tk implementation.

    API:
        avatarcache track -acc $acc -jid $jid -tag $tag -command $cmd
            Returns an image handle (default initially).
            Calls {*}$cmd $img whenever the image changes.
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

    method CreateImage {data} { error "abstract: subclass must override" }
    method DeleteImage {img}  { error "abstract: subclass must override" }
    method CreateDefault {}   { error "abstract: subclass must override" }

    method default {} {
        return $DefaultImage
    }

    method track {args} {
        array set opts $args
        set acc [jid norm $opts(-acc)]
        set jid [jid norm $opts(-jid)]
        set tag $opts(-tag)
        set command $opts(-command)
        set key "$acc\n$jid"

        dict set Tags $tag [list $acc $jid $command]

        if {[dict exists $Images $key]} {
            dict set Refcounts $key [expr {[dict get $Refcounts $key] + 1}]
            return [dict get $Images $key]
        }

        set img [my CreateDefault]

        dict set Images $key $img
        dict set Refcounts $key 1

        ::tacky avatar visible -acc $acc -jid $jid
        ::tacky avatar thumb -acc $acc -jid $jid \
            -command [namespace code [list my OnThumb $key]]

        # Return current image — may have been replaced by a
        # synchronous OnThumb callback during the thumb call above.
        return [dict get $Images $key]
    }

    method untrack {args} {
        array set opts $args
        set tag $opts(-tag)
        if {![dict exists $Tags $tag]} return

        lassign [dict get $Tags $tag] acc jid _command
        dict unset Tags $tag
        set key "$acc\n$jid"

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

    method OnThumb {key data} {
        if {$data eq "" || ![dict exists $Images $key]} return
        set oldImg [dict get $Images $key]
        set newImg [my CreateImage $data]
        dict set Images $key $newImg
        catch {my DeleteImage $oldImg}
        my Notify $key $newImg
    }

    method OnUpdate {ev} {
        set acc [jid norm [dict get $ev -acc]]
        set jid [jid norm [dict get $ev -jid]]
        set key "$acc\n$jid"
        if {![dict exists $Images $key]} return

        if {[dict exists $ev -action] && [dict get $ev -action] eq "disabled"} {
            set oldImg [dict get $Images $key]
            set newImg [my CreateDefault]
            dict set Images $key $newImg
            catch {my DeleteImage $oldImg}
            my Notify $key $newImg
            return
        }

        ::tacky avatar thumb -acc $acc -jid $jid \
            -command [namespace code [list my OnThumb $key]]
    }

    method Notify {key img} {
        dict for {tag info} $Tags {
            lassign $info acc jid command
            if {"$acc\n$jid" eq $key} {
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

