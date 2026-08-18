package require control
package require snit

# attachmentxfer - the file transfers behind one chat's attachments.
#
# Knows which message and which slot within it a transfer belongs to, and turns
# the account-wide `file <Update>` stream into per-attachment updates. It draws
# nothing: the host is told what changed and decides what that looks like.
#
# It also runs the actions an attachment offers: open, save, show in folder,
# drop from cache, retry. Each is a download first, then the action.
snit::type attachmentxfer {
    option -acc    -readonly yes
    option -chat   -readonly yes
    option -tag    -readonly yes
    # Widget the error dialogs hang off; its toplevel is used, so it need not
    # be one itself.
    option -parent -readonly yes

    # Fires for every transfer update that concerns a drawn attachment, as
    # {*}$cmd $key $idx $direction $state $loaded $total $thumbpath.
    option -update-command -default control::no-op

    # source -> list of "key,idx" awaiting a thumbnail. One download can serve
    # several messages quoting the same URL, so each update fans out.
    variable Pending

    # source -> 1 for a download the user cancelled, so its failure isn't
    # reported as one.
    variable Cancelled

    constructor args {
        $self configurelist $args
        set Pending [dict create]
        set Cancelled [dict create]
        ::tacky listen -tag $options(-tag) file <Update> \
            -acc $options(-acc) [mymethod OnTransfer]
    }

    destructor {
        catch {::tacky unlisten $options(-tag)}
    }

    # An attachment names a wire url, a local file of our own, or both; the
    # backend decides which it serves. Updates come back keyed by the url, or
    # by the path when there is no url yet.
    method Key {url path} { expr {$url ne "" ? $url : $path} }

    # Kick off the inline-thumbnail fetch for each image attachment of a
    # message. The file module downloads (remote) or reads in place (local),
    # derives the thumbnail, and reports back through `file <Update>`.
    # -auto subjects the fetch to the autofetch policy and size cap. Our own
    # sends are exempt: theirs is the file on disk, or the URL it was uploaded
    # to.
    method fetch {msg} {
        if {![dict exists $msg attachments]} return
        set key [dict get $msg key]
        set auto [expr {![dict get $msg is_outgoing]}]
        set idx 0
        foreach att [dict get $msg attachments] {
            if {[dict get $att type] eq "image"} {
                $self Download [dict get $att url] [dict get $att path] \
                    $key $idx -auto $auto -from [dict get $msg from_jid]
            }
            incr idx
        }
    }

    # Click-to-reload after "Delete from cache" or a held-back autofetch: the
    # same path as the initial fetch, minus the gating.
    method load {url path key idx} { $self Download $url $path $key $idx }

    method Download {url path key idx args} {
        set src [$self Key $url $path]
        set slot "$key,$idx"
        set waiting [dict getdef $Pending $src {}]
        if {$slot ni $waiting} {
            dict set Pending $src [lappend waiting $slot]
        }
        dict unset Cancelled $src
        ::tacky file download -acc $options(-acc) \
            -url $url -path $path {*}$args
    }

    # Uploads are cancelled by message id, downloads by source - which stops
    # the fetch for every message waiting on it.
    method cancel {direction url path key} {
        if {$direction eq "upload"} {
            ::tacky file cancel -acc $options(-acc) -id $key
            return
        }
        dict set Cancelled [$self Key $url $path] 1
        ::tacky file cancel -acc $options(-acc) -url $url -path $path
    }

    # Upload events key on -id (the message id); download events key on -url,
    # the source, which may have several attachments waiting on it.
    method OnTransfer {ev} {
        set direction [dict get $ev -direction]
        if {$direction eq "upload"} {
            $self Report [dict get $ev -id] 0 $ev
            return
        }
        set url [dict get $ev -url]
        if {![dict exists $Pending $url]} return
        foreach slot [dict get $Pending $url] {
            lassign [split $slot ,] key idx
            $self Report $key $idx $ev
        }
        if {[dict get $ev -state] ne "active"} { dict unset Pending $url }
    }

    method Report {key idx ev} {
        set state [dict get $ev -state]
        set direction [dict get $ev -direction]
        # A download that ends idle (held back, capped or cancelled) drops its
        # row and leaves the plain click-to-load caption. An upload can only
        # get there by being cancelled, which leaves the message dead: it shows
        # failed, which is what its message row now says.
        if {$state eq "idle" && $direction eq "upload"} { set state failed }
        {*}$options(-update-command) $key $idx $direction \
            $state [dict get $ev -loaded] [dict get $ev -total] \
            [dict get $ev -thumbpath]
    }

    method retry {key} {
        {*}$options(-update-command) $key 0 upload active 0 0 ""
        ::tacky message retryUpload -acc $options(-acc) \
            -chat $options(-chat) -timestamp $key
    }

    # Every action runs on a local copy: our own file where it lies, or the
    # download (from cache when it is there).
    method open {url path} { $self WithLocalCopy $url $path attachment_os_open }

    method openfolder {url path} {
        $self WithLocalCopy $url $path showinfm::show
    }

    method uncache {url path} {
        ::tacky file uncache -acc $options(-acc) -url $url -path $path
    }

    method save {url path name} {
        set dest [tk_getSaveFile -initialfile $name -parent [$self Parent]]
        if {$dest eq ""} return
        $self WithLocalCopy $url $path [mymethod CopyTo $dest]
    }

    method WithLocalCopy {url path action} {
        set src [$self Key $url $path]
        dict unset Cancelled $src
        ::tacky file download -acc $options(-acc) -url $url -path $path \
            -command [mymethod OnLocalCopy $action $src]
    }

    # An open/save can ride along on a thumbnail fetch already in flight; a
    # cancel that stops it is not an error to report.
    method OnLocalCopy {action src path} {
        set cancelled [dict exists $Cancelled $src]
        dict unset Cancelled $src
        if {$path eq ""} {
            if {!$cancelled} {
                $self Complain "Download Failed" \
                    "Could not download the attachment."
            }
            return
        }
        {*}$action $path
    }

    method CopyTo {dest path} {
        if {[catch {file copy -force -- $path $dest} err]} {
            $self Complain "Save Failed" $err
        }
    }

    method Complain {title message} {
        tk_messageBox -icon error -title $title -parent [$self Parent] \
            -message $message
    }

    method Parent {} { winfo toplevel $options(-parent) }
}
