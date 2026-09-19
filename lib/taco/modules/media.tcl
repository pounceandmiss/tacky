# Which media backend the process runs on. Process-global, like `audio` and
# `video`: one backend serves every account, and it is chosen once at startup
# before any client exists.
#
# tacky media backend      ?-command $cb?  ;# active backend's name
# tacky media list         ?-command $cb?  ;# backends this build offers
# tacky media capabilities ?-command $cb?  ;# flag -> bool, see lib/media/media.tcl
# tacky media hostEvent    -pc $pc -type $t ...  ;# host backend only
#
# tacky listen media <Warning>     $cmd  ;# -name $requested -reason $text
# tacky listen media <HostCommand> $cmd  ;# -op $verb -pc $pc ...
#
# Which one runs is the `media_backend` setting, read here at startup; unset
# means webrtc where the build carries its library and rtc everywhere else.
# taco_type's -media-backend (auto, or a name from `list`) overrides it for the
# run without storing anything, and -webrtc-lib says where to load
# libtacky_webrtc.so from. A named backend that is not in this build, or will
# not start, falls back to rtc with a <Warning>; calls still work, on the other
# backend.
#
# On the `host` backend the media half is the frontend's: every command
# leaves as a <HostCommand> event and every answer comes back through
# `hostEvent`. See lib/media/media_host.tcl.

package require tacky::media
# rtc is the libdatachannel backend, and only a build that carries the
# extension has one to register. Without it (the browser, where the page owns
# WebRTC through the host backend) rtc is simply not among `available`, and
# TryOpen already answers "not built in" for a backend that is not.
if {![catch {package require rtc}]} {
    package require tacky::media::rtc
}
package require tacky::media::host

snit::type taco_media {
    option -taco       -default ""
    option -backend    -default auto
    option -webrtc-lib -default ""

    # What an unset preference tries, in order: the webrtc library when the
    # build carries one, rtc otherwise. Not finding it is the ordinary case,
    # not a fault, so that fallback is quiet.
    typevariable AUTO_ORDER {webrtc rtc}
    typevariable SETTING_KEY media_backend

    constructor args {
        $self configurelist $args
        $self Select
    }

    tackymethod backend {args} {
        return [::tacky::media backend]
    }

    tackymethod list {args} {
        return [::tacky::media available]
    }

    tackymethod capabilities {args} {
        return [::tacky::media capabilities]
    }

    # The frontend's half of the host backend. On any other backend this is
    # a mistake worth an error: nothing asked the frontend for it.
    tackymethod hostEvent {args} {
        if {[::tacky::media backend] ne "host"} {
            error "media hostEvent: the host backend is not open"
        }
        set ev {}
        foreach {key value} $args {
            dict set ev [string trimleft $key -] $value
        }
        ::tacky::media::host::event $ev
        return
    }

    # rtc goes last whatever was asked for: it is linked into every build,
    # so it is the one fallback that cannot go missing.
    method Select {} {
        set requested $options(-backend)
        if {$requested eq "auto"} { set requested [$self Stored] }
        set asked [expr {$requested ni {auto ""}}]
        set order [expr {$asked ? [list $requested] : $AUTO_ORDER}]
        if {"rtc" ni $order} { lappend order rtc }
        # host last, and never a failure: it is pure Tcl, always registered,
        # and asks nothing of the build. A build that carries no media stack
        # at all - a browser's, where WebRTC belongs to the page - would
        # otherwise not construct taco, and everything that is not a call
        # would be lost along with calls. A frontend that drives the host
        # protocol gets calls too; one that ignores it gets what it would
        # have got from a backend that could not open.
        if {"host" ni $order} { lappend order host }
        foreach name $order {
            if {[$self TryOpen $name $asked]} return
        }
        error "no media backend could be opened"
    }

    # Only the fallback is announced, and only because the user asked for
    # something they did not get; a successful selection is silent so a
    # frontend's first read is still the answer to its first request.
    # `media backend` reports it whenever anyone asks.
    #
    # Selection runs inside taco_type's constructor, early enough that an
    # entry point may not have defined `tacky` yet, so the emit is
    # best-effort - the log line records it either way.
    method Warn {name reason} {
        jlog warn "media backend $name unavailable ($reason); falling back"
        if {$options(-taco) eq ""} return
        catch {$options(-taco) emit media <Warning> -name $name -reason $reason}
    }

    # Read, not passed in: media is installed right after setting, on the same
    # db. A preference naming a backend that will not open is left as it is -
    # the fallback below is this run's answer, not a new preference.
    method Stored {} {
        if {$options(-taco) eq ""} { return "" }
        set name ""
        catch {set name [$options(-taco) setting get -key $SETTING_KEY]}
        return $name
    }

    # A backend that is not registered yet may still be loadable: webrtc
    # lives in libtacky_webrtc.so next to the executable and registers
    # itself on load.
    # $asked is whether a name was given rather than reached for: a build
    # without the webrtc library is the ordinary case and says so in the log,
    # while a backend someone named and did not get is a <Warning>.
    method TryOpen {name asked} {
        if {$name ni [::tacky::media available]} {
            if {[catch {$self LoadBackend $name} err]} {
                $self Missed $name $err $asked
                return 0
            }
        }
        set openArgs {}
        if {$name eq "webrtc" && $options(-webrtc-lib) ne ""} {
            lappend openArgs -lib $options(-webrtc-lib)
        }
        # host is a conversation with the frontend: with no taco to emit
        # through there is nobody on the other end, so rtc is the answer.
        if {$name eq "host"} {
            if {$options(-taco) eq ""} {
                $self Missed $name "no event channel" $asked
                return 0
            }
            lappend openArgs -emit \
                [list $options(-taco) emit media <HostCommand>]
        }
        if {[catch {::tacky::media open $name {*}$openArgs} err]} {
            $self Missed $name $err $asked
            return 0
        }
        return 1
    }

    method Missed {name reason asked} {
        if {!$asked} {
            jlog inform "media backend $name unavailable ($reason); trying the next"
            return
        }
        $self Warn $name $reason
    }

    method LoadBackend {name} {
        if {$name ne "webrtc"} {
            error "not built in"
        }
        set path $options(-webrtc-lib)
        if {$path eq ""} { set path [$self DefaultWebrtcLib] }
        # A bare name is the dynamic linker's to find, as on Android.
        if {[file tail $path] ne $path && ![file exists $path]} {
            error "no library at $path"
        }
        load $path Tackywebrtc
        if {$name ni [::tacky::media available]} {
            error "$path registered no backend"
        }
        # -webrtc-debug-level was applied before the library existed.
        catch {jlog applynative -source webrtc}
        return
    }

    # Next to the running executable, which is where the AppImage puts it.
    method DefaultWebrtcLib {} {
        return [file join [file dirname [info nameofexecutable]] \
            libtacky_webrtc[info sharedlibextension]]
    }
}
