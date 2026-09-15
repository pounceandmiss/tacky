# Backend selection: taco_type's -media-backend / -webrtc-lib, and the
# fallback to rtc when what was asked for is not there.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::media

set media_backend_env [tacky_env -capture-emit 1]

# `list` is not compared exactly: a test file loaded earlier in the same
# interpreter may have registered a mock backend alongside the real one.
test media-backend-default-is-rtc {auto picks rtc, the one backend always linked in} \
    {*}$media_backend_env -body {
        list [tacky media backend] [expr {"rtc" in [tacky media list]}]
    } -result {rtc 1}

test media-backend-capabilities {rtc reports what it can do} \
    {*}$media_backend_env -body {
        dict get [tacky media capabilities] audioDevices
    } -result 1

# tacky_env always builds the default taco_type, so these construct their own.
test media-backend-explicit-rtc {naming rtc selects it} -body {
    taco_type create ::taco_mb -transient 1 -media-backend rtc
    set got [::taco_mb media backend]
    ::taco_mb destroy
    set got
} -result rtc

test media-backend-unknown-falls-back {an unknown backend falls back to rtc} -body {
    taco_type create ::taco_mb -transient 1 -media-backend nosuchbackend
    set got [::taco_mb media backend]
    ::taco_mb destroy
    set got
} -result rtc

test media-backend-missing-webrtc-falls-back \
    {webrtc with no library falls back to rtc rather than failing to start} -body {
    taco_type create ::taco_mb -transient 1 \
        -media-backend webrtc -webrtc-lib /nonexistent/libtacky_webrtc.so
    set got [::taco_mb media backend]
    ::taco_mb destroy
    set got
} -result rtc

# The fallback is the one thing worth telling a frontend about: it asked for
# something and got something else.
test media-backend-fallback-warns {falling back emits media <Warning>} \
    {*}[tacky_env -capture-emit 1 -extra-setup {
        taco_type create ::taco_mb -transient 1 -media-backend nosuchbackend
    } -extra-cleanup {::taco_mb destroy}] -body {
        set out {}
        foreach e $::_emitted {
            if {[lindex $e 0] eq "media"} {
                lappend out [list [lindex $e 1] {*}[lrange $e 2 end]]
            }
        }
        set out
    } -result {{<Warning> -name nosuchbackend -reason {not built in}}}

test media-backend-selection-is-before-clients \
    {a backend is open by the time a call could start} \
    {*}$media_backend_env -body {
        expr {[::tacky::media backend] ne ""}
    } -result 1

