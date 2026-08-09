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

    # url -> list of "key,idx" awaiting a thumbnail. One download can serve
    # several messages quoting the same URL, so each update fans out.
    variable Pending

    constructor args {
        $self configurelist $args
        set Pending [dict create]
        ::tacky listen -tag $options(-tag) file <Update> \
            -acc $options(-acc) [mymethod OnTransfer]
    }

    destructor {
        catch {::tacky unlisten $options(-tag)}
    }

    # Kick off the inline-thumbnail fetch for each image attachment of a
    # message. The file module downloads (remote) or reads in place (local),
    # derives the thumbnail, and reports back through `file <Update>`.
    # -auto subjects the fetch to the autofetch policy and size cap. Our own
    # sends are exempt: from history they refetch the public URL that replaced
    # the local path on upload.
    method fetch {msg} {
        if {![dict exists $msg attachments]} return
        set key [dict get $msg key]
        set auto [expr {![dict get $msg is_outgoing]}]
        set idx 0
        foreach att [dict get $msg attachments] {
            if {[dict get $att type] eq "image"} {
                $self Download [dict get $att url] $key $idx \
                    -auto $auto -from [dict get $msg from_jid]
            }
            incr idx
        }
    }

    # Click-to-reload after "Delete from cache" or a held-back autofetch: the
    # same path as the initial fetch, minus the gating.
    method load {url key idx} { $self Download $url $key $idx }

    method Download {url key idx args} {
        set slot "$key,$idx"
        set waiting [dict getdef $Pending $url {}]
        if {$slot ni $waiting} {
            dict set Pending $url [lappend waiting $slot]
        }
        ::tacky file download -acc $options(-acc) -url $url {*}$args
    }

    # Upload events key on -id (the message id); download events key on -url,
    # which may have several attachments waiting on it.
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
        # An image the policy held back isn't an error: with no state row the
        # attachment keeps its plain click-to-load caption.
        if {$state eq "failed"
            && [string match autofetch-* [dict get $ev -error]]} return
        {*}$options(-update-command) $key $idx [dict get $ev -direction] \
            $state [dict get $ev -loaded] [dict get $ev -total] \
            [dict get $ev -thumbpath]
    }

    method retry {key} {
        {*}$options(-update-command) $key 0 upload active 0 0 ""
        ::tacky message retryUpload -acc $options(-acc) \
            -chat $options(-chat) -timestamp $key
    }

    # A local path is already on disk; anything else is fetched (from cache
    # when it is there) and the action runs on the downloaded copy.
    method open {url} { $self WithLocalCopy $url attachment_os_open }

    method openfolder {url} { $self WithLocalCopy $url showinfm::show }

    method uncache {url} {
        ::tacky file uncache -acc $options(-acc) -url $url
    }

    method save {url name} {
        set dest [tk_getSaveFile -initialfile $name -parent [$self Parent]]
        if {$dest eq ""} return
        $self WithLocalCopy $url [mymethod CopyTo $dest]
    }

    method WithLocalCopy {url action} {
        if {[file exists $url]} { {*}$action $url; return }
        ::tacky file download -acc $options(-acc) -url $url \
            -command [mymethod OnLocalCopy $action]
    }

    method OnLocalCopy {action path} {
        if {$path eq ""} {
            $self Complain "Download Failed" "Could not download the attachment."
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
