# videotile - one participant of a call: avatar or live video, a name, a
# status line. groupcallwindow grids these.
#
# Usage:
#   videotile $w -name $nick -status "Connecting..."
#   $w configure -stream $name     ;# the frame stream a <VideoTrack> named
#   $w configure -stream ""        ;# back to the avatar
#   $w configure -avatar $photo
#
# A host-rendered track has no stream name and keeps the avatar.

package require rtcmv_tk

snit::widget videotile {
    hulltype ttk::frame

    option -name   -default "" -configuremethod SetName
    option -status -default "" -configuremethod SetStatus
    option -avatar -default "" -configuremethod SetAvatar
    option -stream -default "" -configuremethod SetStream

    variable view  ""
    variable photo ""

    constructor args {
        $hull configure -padding 4 -relief groove -borderwidth 1
        ttk::label $win.image -anchor center \
            -image avatarcache::defaultAvatar
        ttk::label $win.name -anchor center -font {-weight bold}
        ttk::label $win.status -anchor center -foreground gray40
        pack $win.image -expand yes -fill both
        pack $win.name -fill x
        pack $win.status -fill x
        $self configurelist $args
    }

    destructor {
        $self StopVideo
    }

    method SetName {opt value} {
        set options($opt) $value
        $win.name configure -text $value
    }

    method SetStatus {opt value} {
        set options($opt) $value
        $win.status configure -text $value
    }

    method SetAvatar {opt value} {
        set options($opt) $value
        if {$view eq ""} { $self ShowAvatar }
    }

    method SetStream {opt value} {
        set options($opt) $value
        $self StopVideo
        if {$value eq ""} {
            $self ShowAvatar
            return
        }
        set p [image create photo]
        if {[catch {::rtcmv::view::open $value $p} v]} {
            image delete $p
            $self ShowAvatar
            return
        }
        set view $v
        set photo $p
        $win.image configure -image $photo
    }

    method ShowAvatar {} {
        set img $options(-avatar)
        if {$img eq ""} { set img avatarcache::defaultAvatar }
        $win.image configure -image $img
    }

    method StopVideo {} {
        if {$view ne ""} {
            catch {::rtcmv::view::close $view}
            set view ""
        }
        if {$photo ne ""} {
            catch {image delete $photo}
            set photo ""
        }
    }
}
