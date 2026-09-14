# Process-global camera selection. Mirrors audio.tcl: cameras belong to
# the machine, not an XMPP account, so enumeration and the preferred
# camera live here on taco_type.
#
# tacky video enumerateCameras   ?-command $cb?
#   ;# $cb receives a list of {name <str> id <str> facing <int>}.
# tacky video getPreferredCamera ?-command $cb?
#   ;# "" means "let rtc-mv pick" (first V4L2 device / the test source).
# tacky video setPreferredCamera -id $id
#   ;# persists, hot-swaps the camera on every live video call, emits
#   ;# <PreferredCamera>.
#
# tacky listen video <PreferredCamera> $cmd  ;# -id $id
#
# Preference is stored in the shared `setting` table under `video_camera`.

package require rtcmv

snit::type taco_video {
    option -db   -default ""
    option -taco -default ""

    constructor args {
        $self configurelist $args
    }

    tackymethod enumerateCameras {args} {
        return [::rtcmv::enumerate-cameras]
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
