# Process-global audio device selection.
#
# Mics and speakers belong to the machine, not to an XMPP account, so
# enumeration and the preferred device + volume prefs live here on
# taco_type instead of on per-account taco_calls. `tacky calls setDevices`
# is a per-call device override that still lives on the calls module;
# volume has no per-call override — there's one gain per kind, period.
#
# tacky audio enumerateDevices    ?-command $cb?
#   ;# $cb receives {capture {...} playback {...}}, each value a list of
#   ;# {name <str> id <str> default 0|1}.
# tacky audio getPreferredDevice  -kind capture|playback ?-command $cb?
# tacky audio setPreferredDevice  -kind capture|playback -id $id
#   ;# persists, hot-swaps every live call on every account, emits
#   ;# <PreferredDevice>.
# tacky audio getVolume           -kind capture|playback ?-command $cb?
#   ;# returns linear gain in [0.0, 1.0]; "1.0" if unset.
# tacky audio setVolume           -kind capture|playback -volume $v
#   ;# persists, hot-swaps every live call on every account, emits
#   ;# <Volume>.
#
# tacky listen audio <PreferredDevice> $cmd  ;# -kind capture|playback -id $id
# tacky listen audio <Volume>          $cmd  ;# -kind capture|playback -volume $v
#
# Preferences are stored in the shared `setting` table under the keys
# `audio_input_device` / `audio_output_device` ("" means system default)
# and `audio_input_volume` / `audio_output_volume` (linear gain, default
# "1.0" when unset).

package require rtcma

snit::type taco_audio {
    option -db   -default ""
    option -taco -default ""

    constructor args {
        $self configurelist $args
    }

    tackymethod enumerateDevices {args} {
        return [::rtcma::enumerate-devices]
    }

    tackymethod getPreferredDevice {args} {
        array set opts {-kind ""}
        array set opts $args
        set key [$self DeviceSettingKey $opts(-kind)]
        return [$options(-taco) setting get -key $key]
    }

    # Persist the preference, hot-swap every live call on every account
    # (skipping dormant clients), and emit <PreferredDevice> so sibling
    # pickers stay in sync.
    tackymethod setPreferredDevice {args} {
        array set opts {-kind "" -id ""}
        array set opts $args
        set key [$self DeviceSettingKey $opts(-kind)]
        $options(-taco) setting set -key $key -value $opts(-id)
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set client $options(-taco).client($jid)
            if {[info commands $client] eq ""} continue
            $client calls applyPreferredDevice \
                -kind $opts(-kind) -id $opts(-id)
        }
        $options(-taco) emit audio <PreferredDevice> \
            -kind $opts(-kind) -id $opts(-id)
        return
    }

    # Default 1.0 (unity) when never set — matches rtcma's own default so
    # AttachMedia can apply unconditionally without first checking.
    tackymethod getVolume {args} {
        array set opts {-kind ""}
        array set opts $args
        set key [$self VolumeSettingKey $opts(-kind)]
        set v [$options(-taco) setting get -key $key]
        if {$v eq ""} { return 1.0 }
        return $v
    }

    # Same broadcast/hot-swap pattern as setPreferredDevice. Range
    # validation lives in rtcma; bad values surface as <Warning> from
    # taco_calls.applyVolume rather than blocking the preference write.
    tackymethod setVolume {args} {
        array set opts {-kind "" -volume ""}
        array set opts $args
        set key [$self VolumeSettingKey $opts(-kind)]
        $options(-taco) setting set -key $key -value $opts(-volume)
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set client $options(-taco).client($jid)
            if {[info commands $client] eq ""} continue
            $client calls applyVolume \
                -kind $opts(-kind) -volume $opts(-volume)
        }
        $options(-taco) emit audio <Volume> \
            -kind $opts(-kind) -volume $opts(-volume)
        return
    }

    method DeviceSettingKey {kind} {
        switch -- $kind {
            capture  { return audio_input_device }
            playback { return audio_output_device }
            default {
                error "device kind must be capture or playback, got: $kind"
            }
        }
    }

    method VolumeSettingKey {kind} {
        switch -- $kind {
            capture  { return audio_input_volume }
            playback { return audio_output_volume }
            default {
                error "volume kind must be capture or playback, got: $kind"
            }
        }
    }
}
