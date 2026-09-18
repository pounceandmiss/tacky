# Backend selection: taco_type's -media-backend / -webrtc-lib, and the
# fallback to rtc when what was asked for is not there.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tacky::media

set media_backend_env [tacky_env -capture-emit 1]

# `list` is not compared exactly: a test file loaded earlier in the same
# interpreter may have registered a mock backend alongside the real one.
# This build has no webrtc library, so auto lands on rtc.
test media-backend-default-is-rtc {auto falls through to the backend always linked in} \
    {*}$media_backend_env -body {
        list [tacky media backend] [expr {"rtc" in [tacky media list]}]
    } -result {rtc 1}

# Auto reaches for webrtc first, and most builds do not carry it. That is the
# ordinary case, so it stays in the log rather than becoming an event every
# frontend has to learn to ignore.
test media-backend-auto-fallback-is-quiet {reaching for webrtc and missing says nothing} \
    {*}[tacky_env -capture-emit 1 -extra-setup {
        taco_type create ::taco_mb -transient 1
    } -extra-cleanup {::taco_mb destroy}] -body {
        set out {}
        foreach e $::_emitted {
            if {[lindex $e 0] eq "media"} { lappend out $e }
        }
        list [::taco_mb media backend] $out
    } -result {rtc {}}

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


# The choice is tacky's to keep, the way the audio and camera preferences are:
# a frontend stores nothing of its own. These need a real config dir, since a
# preference is only worth anything across two starts.
proc media_pref_env {} {
    return [tacky_env -stub-emit 1 -extra-setup {
        set ::media_pref_dir [makeDirectory media-pref]
        set ::media_pref_was [::tacky::media backend]
    } -extra-cleanup {
        removeDirectory media-pref
        ::tacky::media close
        ::tacky::media open $::media_pref_was
    }]
}

proc media_pref_start {args} {
    taco_type create ::taco_mb -transient 1 -config-dir $::media_pref_dir {*}$args
}

test media-backend-setting-is-remembered {the stored preference picks the backend next start} \
    {*}[media_pref_env] -body {
        media_pref_start
        ::taco_mb setting set -key media_backend -value host
        ::taco_mb destroy
        media_pref_start
        set got [::taco_mb media backend]
        ::taco_mb destroy
        set got
    } -result host

test media-backend-flag-overrides-the-setting \
    {-media-backend is this run's answer and leaves the preference alone} \
    {*}[media_pref_env] -body {
        media_pref_start
        ::taco_mb setting set -key media_backend -value host
        ::taco_mb destroy
        media_pref_start -media-backend rtc
        set got [list [::taco_mb media backend] \
            [::taco_mb setting get -key media_backend]]
        ::taco_mb destroy
        set got
    } -result {rtc host}

# A preference this build cannot open is still the user's answer: the run
# falls back, the setting stays.
test media-backend-unopenable-setting-falls-back \
    {a stored backend that will not open leaves rtc running and the setting set} \
    {*}[media_pref_env] -body {
        media_pref_start
        ::taco_mb setting set -key media_backend -value nosuchbackend
        ::taco_mb destroy
        media_pref_start
        set got [list [::taco_mb media backend] \
            [::taco_mb setting get -key media_backend]]
        ::taco_mb destroy
        set got
    } -result {rtc nosuchbackend}
