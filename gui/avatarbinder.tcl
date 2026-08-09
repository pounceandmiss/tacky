package require control
package require snit

# avatarbinder - which avatar image belongs to which JID, for as long as that
# JID is on screen.
#
# A host says which JIDs it is drawing and which it has stopped drawing, and is
# told when an image changes.
snit::type avatarbinder {
    option -acc -readonly yes
    # Prefix for the avatarcache tags, one per tracked JID.
    option -tag -readonly yes

    # Fires when a JID's image changed, as {*}$cmd $jid $image. A host repaints
    # whatever it already drew for that JID.
    option -repaint-command -default control::no-op

    variable Images
    variable Tracked

    constructor args {
        $self configurelist $args
        set Images [dict create]
        set Tracked [list]
    }

    destructor { $self releaseAll }

    # The image to draw for a JID, or "" when there is none yet. Callers pick
    # their own placeholder: this only reports what it knows.
    method image {jid} { dict getdef $Images $jid "" }

    # Start following a JID's avatar. Idempotent, since every message drawn by
    # that author calls it. avatarcache handles visibility, fetching and image
    # lifetime; it answers immediately with whatever it already has.
    method track {jid} {
        if {$jid in $Tracked} return
        lappend Tracked $jid
        $self Update $jid [avatarcache track \
            -acc $options(-acc) -jid $jid -tag $options(-tag)/$jid \
            -command [mymethod Update $jid]]
    }

    # The host has stopped drawing this JID anywhere.
    method release {jid} {
        if {$jid ni $Tracked} return
        catch {avatarcache untrack -tag $options(-tag)/$jid}
        set idx [lsearch -exact $Tracked $jid]
        set Tracked [lreplace $Tracked $idx $idx]
        dict unset Images $jid
    }

    method releaseAll {} {
        foreach jid $Tracked {
            catch {avatarcache untrack -tag $options(-tag)/$jid}
        }
        set Tracked [list]
        set Images [dict create]
    }

    method Update {jid image} {
        dict set Images $jid $image
        {*}$options(-repaint-command) $jid $image
    }
}
