# Process-global camera selection. Mirrors audio.tcl: cameras belong to
# the machine, not an XMPP account, so enumeration and the preferred
# camera live here on taco_type.
#
# tacky video enumerateCameras   ?-command $cb?
#   ;# $cb receives a list of {name <str> id <str> facing <int>}. Empty on a
#   ;# backend that does not declare the `cameras` capability.
# tacky video getPreferredCamera ?-command $cb?
#   ;# "" means "let the backend pick" (rtc-mv takes the first V4L2 device,
#   ;# or the test source).
# tacky video setPreferredCamera -id $id
#   ;# persists, hot-swaps the camera on every live video call, emits
#   ;# <PreferredCamera>.
#
# tacky listen video <PreferredCamera> $cmd  ;# -id $id
#
# Preference is stored in the shared `setting` table under `video_camera`.
# An id the active backend does not recognise falls back to that backend's
# default camera, the same way audio device preferences do.

package require tacky::media

snit::type taco_video {
    option -db   -default ""
    option -taco -default ""

    # Where a synchronous backend's camera list lands, see enumerateCameras.
    variable Enumerated {}

    constructor args {
        $self configurelist $args
    }

    # Plain method, not tackymethod: asynchronous, for the reasons in
    # taco_audio's enumerateDevices.
    method enumerateCameras {args} {
        set cmd ""
        if {[dict exists $args -command]} { set cmd [dict get $args -command] }
        set Enumerated {}
        if {[::tacky::media capability cameras]} {
            if {$cmd ne ""} {
                ::tacky::media enumerateCameras -command $cmd
                return
            }
            ::tacky::media enumerateCameras -command [mymethod Collected]
        }
        if {$cmd ne ""} {
            uplevel #0 [list {*}$cmd $Enumerated]
            return
        }
        return $Enumerated
    }

    method Collected {result} {
        set Enumerated $result
    }

    tackymethod getPreferredCamera {args} {
        return [$options(-taco) setting get -key video_camera]
    }

    tackymethod setPreferredCamera {args} {
        array set opts {-id ""}
        array set opts $args
        $options(-taco) setting set -key video_camera -value $opts(-id)
        foreach jid [$options(-db) eval {SELECT jid FROM account}] {
            set client [$options(-taco) account liveClient -acc $jid]
            if {$client eq ""} continue
            $client calls applyPreferredCamera -id $opts(-id)
        }
        $options(-taco) emit video <PreferredCamera> -id $opts(-id)
        return
    }
}
