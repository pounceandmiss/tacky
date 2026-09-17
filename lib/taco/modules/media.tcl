# Which media backend the process runs on. Process-global, like `audio` and
# `video`: one backend serves every account, and it is chosen once at startup
# before any client exists.
#
# tacky media backend      ?-command $cb?  ;# active backend's name
# tacky media list         ?-command $cb?  ;# backends this build offers
# tacky media capabilities ?-command $cb?  ;# flag -> bool, see lib/media/media.tcl
#
# tacky listen media <Warning> $cmd  ;# -name $requested -reason $text
#
# Selected by taco_type's -media-backend (auto, or a name from `list`) and
# -webrtc-lib (where to load libtacky_webrtc.so from). A requested backend
# that is not in this build, or will not start, falls back to rtc with a
# <Warning>; calls still work, on the other backend.

package require tacky::media
package require tacky::media::rtc

snit::type taco_media {
    option -taco       -default ""
    option -backend    -default auto
    option -webrtc-lib -default ""

    # What `auto` tries, in order. Only rtc for now: the webrtc backend is
    # opt-in until Phase 5 has it at parity, so asking for it is deliberate.
    typevariable AUTO_ORDER {rtc}

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

    # rtc goes last whatever was asked for: it is linked into every build,
    # so it is the one fallback that cannot go missing.
    method Select {} {
        set requested $options(-backend)
        set order [expr {$requested eq "auto" ? $AUTO_ORDER : [list $requested]}]
        if {"rtc" ni $order} { lappend order rtc }
        foreach name $order {
            if {[$self TryOpen $name]} return
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
        jlog warn "media backend $name unavailable ($reason); using rtc"
        if {$options(-taco) eq ""} return
        catch {$options(-taco) emit media <Warning> -name $name -reason $reason}
    }

    # A backend that is not registered yet may still be loadable: webrtc
    # lives in libtacky_webrtc.so next to the executable and registers
    # itself on load.
    method TryOpen {name} {
        if {$name ni [::tacky::media available]} {
            if {[catch {$self LoadBackend $name} err]} {
                $self Warn $name $err
                return 0
            }
        }
        set openArgs {}
        if {$name eq "webrtc" && $options(-webrtc-lib) ne ""} {
            lappend openArgs -lib $options(-webrtc-lib)
        }
        if {[catch {::tacky::media open $name {*}$openArgs} err]} {
            $self Warn $name $err
            return 0
        }
        return 1
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
