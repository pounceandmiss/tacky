package require http
package require sha1
package require tclwuffs

# File transfers (XEP-0363 upload + cache-backed download). Every transfer has
# an id and reports progress/completion through one event, both directions:
#
#   file <Update> -id ID -direction up|down -state active|done|failed \
#       -loaded L -total T -url U -localpath P -thumbpath TP -error MSG
#
# Upload id is the caller's (the message own_id), known before the GET URL
# exists. Download is keyed and coalesced by URL; a local path passed as -url is
# used in place (outgoing, pre-upload); for images a PNG thumbnail is derived
# (wuffs) and surfaced as -thumbpath.
#
# XEP-0454 (OMEMO media): `upload -encrypt 1` AES-256-GCMs the file, PUTs the
# ciphertext, and returns an aesgcm:// URL carrying the key/iv in its fragment;
# `download` recognises that scheme, fetches the https:// form, and decrypts.
# The key only ever travels inside the OMEMO-encrypted body.
#
# Public API:
#   $client file download -url U  [-command {cb $localPath}]   ;# "" on failure
#   $client file upload   -id ID -path P [-encrypt 0|1] \
#       -command {cb $getUrl}                                  ;# "" on failure
#   $client file cancel   -id ID | -url U
#   $client file uncache  -url U

snit::type taco_file {
    option -client -readonly yes

    typevariable NS         urn:xmpp:http:upload:0
    typevariable DISCO_ITEMS http://jabber.org/protocol/disco#items
    typevariable DISCO_INFO  http://jabber.org/protocol/disco#info
    typevariable TIMEOUT_MS 60000
    typevariable THUMB_MAX  320
    typevariable HttpRegistered 0

    variable client
    variable ServiceJid  ""   ;# discovered upload component ("" = none/unknown)
    variable MaxFileSize 0    ;# bytes; 0 = unknown / no advertised limit
    variable Discovered  0    ;# whether discovery has been attempted this session
    variable Transfers        ;# array: id -> transfer dict
    variable DownloadByUrl    ;# array: url -> id (active downloads, for coalescing)
    variable Counter 0

    constructor args {
        $self configurelist $args
        set client $options(-client)
        array set Transfers {}
        array set DownloadByUrl {}
        $client bus subscribe $self <Disconnect> [mymethod OnDisconnect]
    }

    destructor {
        catch {$client bus unsubscribe $self}
        foreach id [array names Transfers] {
            catch {after cancel [dict get $Transfers($id) timer]}
            catch {::http::reset [dict get $Transfers($id) httptoken]}
        }
    }

    # A reconnect may land on a different server, so forget the discovered
    # service and re-probe lazily on the next upload.
    method OnDisconnect {args} {
        set ServiceJid ""
        set MaxFileSize 0
        set Discovered 0
    }

    # Register the https transport once per interp. mtls::socket mirrors the
    # core `socket` signature, so the tcllib http client can drive TLS through
    # it directly.
    method EnsureHttps {} {
        if {$HttpRegistered} return
        catch {http::register https 443 ::mtls::socket}
        set HttpRegistered 1
    }

    # --- Transfer registry ----------------------------------------------

    method NewTransfer {direction url {id ""}} {
        if {$id eq ""} { set id [incr Counter] }
        set Transfers($id) [dict create \
            direction $direction state active loaded 0 total 0 \
            url $url localpath "" thumbpath "" error "" \
            cmds {} done 0 lastfrac -1 timer "" fh "" httptoken "" \
            mediakey "" mediaiv "" tmpfile ""]
        return $id
    }

    method EmitUpdate {id} {
        set t $Transfers($id)
        $client emit file <Update> -id $id \
            -direction [dict get $t direction] -state [dict get $t state] \
            -loaded [dict get $t loaded] -total [dict get $t total] \
            -url [dict get $t url] -localpath [dict get $t localpath] \
            -thumbpath [dict get $t thumbpath] -error [dict get $t error]
    }

    # Throttled to whole-percent steps so large transfers don't flood the bus.
    method ProgressCb {id token total current} {
        if {![info exists Transfers($id)]} return
        dict set Transfers($id) loaded $current
        dict set Transfers($id) total $total
        set frac [expr {$total > 0 ? double($current) / $total : 0.0}]
        if {$frac - [dict get $Transfers($id) lastfrac] < 0.01 && $frac < 1.0} {
            return
        }
        dict set Transfers($id) lastfrac $frac
        $self EmitUpdate $id
    }

    # Single terminal point for both directions: set state, emit, invoke the
    # per-transfer commands with the result (getUrl for upload, localpath for
    # download; "" on failure), then drop the registry entry.
    method Terminal {id state {error ""}} {
        if {![info exists Transfers($id)]} return
        if {[dict get $Transfers($id) done]} return
        dict set Transfers($id) done 1
        dict set Transfers($id) state $state
        dict set Transfers($id) error $error
        set t $Transfers($id)
        catch {after cancel [dict get $t timer]}
        if {[dict get $t tmpfile] ne ""} {
            catch {file delete -- [dict get $t tmpfile]}
        }
        if {$state eq "failed" && $error ne ""} {
            jlog inform "file transfer failed: $error"
        }
        $self EmitUpdate $id
        if {$state eq "done"} {
            set res [expr {[dict get $t direction] eq "upload"
                ? [dict get $t url] : [dict get $t localpath]}]
        } else {
            set res ""
        }
        foreach c [dict get $t cmds] { {*}$c $res }
        if {[dict get $t direction] eq "download"} {
            catch {unset DownloadByUrl([dict get $t url])}
        }
        unset Transfers($id)
    }

    method cancel {args} {
        array set opts {-id "" -url ""}
        array set opts $args
        set id $opts(-id)
        if {$id eq "" && $opts(-url) ne "" \
                && [info exists DownloadByUrl($opts(-url))]} {
            set id $DownloadByUrl($opts(-url))
        }
        if {$id eq "" || ![info exists Transfers($id)]} return
        catch {::http::reset [dict get $Transfers($id) httptoken]}
        catch {close [dict get $Transfers($id) fh]}
        $self Terminal $id failed cancelled
    }

    # --- Download (cache-backed; derives image thumbnails) --------------

    method download {args} {
        array set opts {-url "" -command ""}
        array set opts $args
        set url $opts(-url)
        set cmd $opts(-command)

        # Join an in-flight download of the same url.
        if {[info exists DownloadByUrl($url)]} {
            if {$cmd ne ""} {
                dict lappend Transfers($DownloadByUrl($url)) cmds $cmd
            }
            return
        }

        # A local source file (outgoing attachment, pre-upload) is used in
        # place; a cache hit is served from disk. Both resolve immediately.
        foreach src [list $url [$self CachePath $url]] {
            if {[file isfile $src]} {
                set id [$self NewTransfer download $url]
                if {$cmd ne ""} { dict set Transfers($id) cmds [list $cmd] }
                dict set Transfers($id) localpath $src
                dict set Transfers($id) thumbpath [$self SafeThumb $url $src]
                $self Terminal $id done
                return
            }
        }

        # Fresh remote download. An aesgcm:// URL fetches its https:// form;
        # the ciphertext lands in .part and is decrypted in OnDownloaded.
        set full [$self CachePath $url]
        set id [$self NewTransfer download $url]
        if {$cmd ne ""} { dict set Transfers($id) cmds [list $cmd] }
        set DownloadByUrl($url) $id
        set fetchUrl $url
        set parsed [aesgcm_parse $url]
        if {$parsed ne ""} {
            lassign $parsed fetchUrl iv key
            dict set Transfers($id) mediakey $key
            dict set Transfers($id) mediaiv  $iv
        }
        $self EnsureHttps
        file mkdir [file dirname $full]
        if {[catch {open $full.part wb} fh]} {
            $self Terminal $id failed "open: $fh"
            return
        }
        dict set Transfers($id) fh $fh
        $self EmitUpdate $id
        if {[catch {
            set tok [http::geturl $fetchUrl -channel $fh -binary 1 \
                -timeout $TIMEOUT_MS -blocksize 65536 \
                -progress [mymethod ProgressCb $id] \
                -command [mymethod OnDownloaded $id $fh $full]]
            dict set Transfers($id) httptoken $tok
        } err]} {
            catch {close $fh}
            catch {file delete -- $full.part}
            $self Terminal $id failed "download: $err"
        }
    }

    method OnDownloaded {id fh full token} {
        catch {close $fh}
        set ok 0
        if {[http::status $token] eq "ok"} {
            set nc [http::ncode $token]
            if {$nc >= 200 && $nc < 300} { set ok 1 }
        }
        catch {http::cleanup $token}
        if {!$ok} {
            catch {file delete -- $full.part}
            $self Terminal $id failed "http error"
            return
        }
        if {[info exists Transfers($id)] \
                && [dict get $Transfers($id) mediakey] ne ""} {
            if {[catch {$self DecryptPart $id $full} err]} {
                catch {file delete -- $full.part}
                $self Terminal $id failed "decrypt: $err"
                return
            }
        } else {
            catch {file rename -force -- $full.part $full}
        }
        if {![info exists Transfers($id)]} return
        set url [dict get $Transfers($id) url]
        dict set Transfers($id) localpath $full
        dict set Transfers($id) thumbpath [$self SafeThumb $url $full]
        $self Terminal $id done
    }

    # Decrypt the downloaded ciphertext (.part) to $full. Reads the whole
    # file in: GCM verifies the tag over the complete buffer.
    method DecryptPart {id full} {
        set inh [open $full.part rb]
        try { set ct [read $inh] } finally { close $inh }
        set plain [::omemo::media_decrypt \
            [dict get $Transfers($id) mediakey] \
            [dict get $Transfers($id) mediaiv] $ct]
        set outh [open $full.dec wb]
        try { puts -nonewline $outh $plain } finally { close $outh }
        file rename -force -- $full.dec $full
        file delete -- $full.part
    }

    method CachePath {url} {
        set ext [file extension [attachment_basename $url]]
        set hash [sha1::sha1 [encoding convertto utf-8 $url]]
        return [file join [appdirs cache] attachments $hash$ext]
    }

    # --- Upload (XEP-0363) ----------------------------------------------

    method upload {args} {
        array set opts {-id "" -path "" -command "" -encrypt 0}
        array set opts $args
        set id $opts(-id)
        set path $opts(-path)
        set cmd $opts(-command)

        $self NewTransfer upload "" $id
        if {$cmd ne ""} { dict set Transfers($id) cmds [list $cmd] }

        if {![file isfile $path] || ![file readable $path]} {
            $self Terminal $id failed "file not readable"
            return
        }
        # URL keeps the original filename (extension drives kind detection);
        # an encrypted share PUTs the ciphertext as application/octet-stream.
        set name [file tail $path]
        set putPath $path
        set mime [attachment_mime $name]
        if {$opts(-encrypt)} {
            if {[catch {$self EncryptToTemp $path} enc]} {
                $self Terminal $id failed "encrypt: $enc"
                return
            }
            lassign $enc putPath key iv
            dict set Transfers($id) tmpfile $putPath
            dict set Transfers($id) mediakey $key
            dict set Transfers($id) mediaiv  $iv
            set mime application/octet-stream
        }
        set size [file size $putPath]
        dict set Transfers($id) total $size
        dict set Transfers($id) localpath $path
        dict set Transfers($id) timer \
            [after $TIMEOUT_MS [mymethod Terminal $id failed timeout]]
        $self EmitUpdate $id
        $self DiscoverService \
            [mymethod OnServiceForUpload $id $putPath $size $name $mime]
    }

    # Encrypt $path to a temp ciphertext file under the cache dir. Returns
    # {ciphertextPath key iv}; Terminal cleans up the temp.
    method EncryptToTemp {path} {
        set fh [open $path rb]
        try { set plain [read $fh] } finally { close $fh }
        set enc [::omemo::media_encrypt $plain]
        set tmp [file join [appdirs cache] attachments upload \
            "[clock microseconds].enc"]
        file mkdir [file dirname $tmp]
        set out [open $tmp wb]
        try {
            puts -nonewline $out [dict get $enc ct]
        } finally {
            close $out
        }
        return [list $tmp [dict get $enc key] [dict get $enc iv]]
    }

    method OnServiceForUpload {id path size name mime serviceJid} {
        if {![info exists Transfers($id)]} return
        if {$serviceJid eq ""} {
            $self Terminal $id failed "no upload service advertised by server"
            return
        }
        if {$MaxFileSize > 0 && $size > $MaxFileSize} {
            $self Terminal $id failed "file exceeds server limit ($size > $MaxFileSize)"
            return
        }
        $self RequestSlot $serviceJid $name $size $mime \
            [mymethod OnSlotForUpload $id $path $mime]
    }

    method OnSlotForUpload {id path mime slot} {
        if {![info exists Transfers($id)]} return
        lassign $slot putUrl getUrl headers
        if {$putUrl eq "" || $getUrl eq ""} {
            $self Terminal $id failed "server returned no slot"
            return
        }
        $self EnsureHttps
        if {[catch {open $path rb} fh]} {
            $self Terminal $id failed "open: $fh"
            return
        }
        dict set Transfers($id) fh $fh
        if {[catch {
            set tok [http::geturl $putUrl -method PUT -querychannel $fh \
                -type $mime -headers $headers -timeout $TIMEOUT_MS \
                -queryblocksize 65536 \
                -queryprogress [mymethod ProgressCb $id] \
                -command [mymethod OnPutDone $id $fh $getUrl]]
            dict set Transfers($id) httptoken $tok
        } err]} {
            catch {close $fh}
            $self Terminal $id failed "PUT: $err"
        }
    }

    method OnPutDone {id fh getUrl token} {
        catch {close $fh}
        set st [http::status $token]
        set nc [http::ncode $token]
        catch {http::cleanup $token}
        if {![info exists Transfers($id)]} return
        if {$st eq "ok" && $nc >= 200 && $nc < 300} {
            set key [dict get $Transfers($id) mediakey]
            if {$key ne ""} {
                set getUrl [aesgcm_url $getUrl \
                    [dict get $Transfers($id) mediaiv] $key]
            }
            dict set Transfers($id) url $getUrl
            $self Terminal $id done
        } else {
            $self Terminal $id failed "PUT status=$st code=$nc"
        }
    }

    # --- Slot request (XEP-0363) ----------------------------------------

    method RequestSlot {serviceJid filename size mime cmd} {
        $client iq request -type get -to $serviceJid \
            -payload [j request -ns $NS \
                -filename $filename -size $size -content-type $mime] \
            -command [mymethod OnSlotResult $cmd]
    }

    method OnSlotResult {cmd stanza} {
        if {[xsearch $stanza -get @type] ne "result"} {
            {*}$cmd ""
            return
        }
        set putUrl [xsearch $stanza slot put -get @url]
        set getUrl [xsearch $stanza slot get -get @url]
        set headers {}
        xsearch $stanza slot put header -script h {
            set n [xsearch $h -get @name]
            set v [xsearch $h -get body]
            if {$n ne ""} { lappend headers $n $v }
        }
        {*}$cmd [list $putUrl $getUrl $headers]
    }

    # --- Service discovery ----------------------------------------------

    method DiscoverService {cmd} {
        if {$Discovered} {
            {*}$cmd $ServiceJid
            return
        }
        set domain [jid domain [$client cget -jid]]
        $client iq request -type get -to $domain \
            -payload [j query -ns $DISCO_ITEMS] \
            -command [mymethod OnDiscoItems $cmd]
    }

    method OnDiscoItems {cmd stanza} {
        set items {}
        xsearch $stanza query item -script it {
            set ij [xsearch $it -get @jid]
            if {$ij ne ""} { lappend items $ij }
        }
        $self ProbeNext $cmd $items
    }

    # Probe candidate components one at a time; first to advertise the upload
    # feature wins. Caches the result for the rest of the session.
    method ProbeNext {cmd items} {
        if {[llength $items] == 0} {
            set Discovered 1
            {*}$cmd ""
            return
        }
        set items [lassign $items first]
        $client iq request -type get -to $first \
            -payload [j query -ns $DISCO_INFO] \
            -command [mymethod OnDiscoInfo $cmd $first $items]
    }

    method OnDiscoInfo {cmd jidProbed rest stanza} {
        set feat [xsearch $stanza query feature @var $NS]
        if {[llength $feat] > 0} {
            set ServiceJid $jidProbed
            set MaxFileSize [$self ReadMaxFileSize $stanza]
            set Discovered 1
            {*}$cmd $ServiceJid
            return
        }
        $self ProbeNext $cmd $rest
    }

    method ReadMaxFileSize {stanza} {
        set size 0
        xsearch $stanza query x field -script f {
            if {[xsearch $f -get @var] eq "max-file-size"} {
                set v [xsearch $f value -get body]
                if {[string is integer -strict $v]} { set size $v }
            }
        }
        return $size
    }

    # --- Thumbnails -----------------------------------------------------

    # Thumbnail path for an image, or "" for a non-image / undecodable file.
    method SafeThumb {url full} {
        if {[attachment_kind $url] ne "image"} { return "" }
        set thumb [$self ThumbPath $url $THUMB_MAX]
        if {[file exists $thumb]} { return $thumb }
        if {[catch {$self RenderThumb $full $thumb $THUMB_MAX} err]} {
            jlog inform "thumbnail failed: $err"
            return ""
        }
        return $thumb
    }

    # Decode the source, downscale to fit $max, re-encode (wuffs resize always
    # emits PNG, so the result is renderable by core Tk regardless of source
    # format). Throws on a non-image / undecodable file.
    method RenderThumb {src thumb max} {
        set fh [open $src rb]
        try { set raw [read $fh] } finally { close $fh }
        set d [::tclwuffs::decode $raw]
        lassign [fit_within [dict get $d width] [dict get $d height] $max] tw th
        set png [::tclwuffs::resize_bytes $raw $tw $th]
        file mkdir [file dirname $thumb]
        set out [open $thumb.part wb]
        try { puts -nonewline $out $png } finally { close $out }
        file rename -force -- $thumb.part $thumb
    }

    method ThumbPath {url max} {
        set hash [sha1::sha1 [encoding convertto utf-8 $url]]
        return [file join [appdirs cache] attachments thumb ${hash}_${max}.png]
    }

    # Drop the cached download and every thumbnail size for a URL. Only ever
    # touches files under the cache dir (paths are derived from a hash), so a
    # local source file passed as -url is never at risk.
    method uncache {args} {
        array set opts {-url ""}
        array set opts $args
        set url $opts(-url)
        catch {file delete -- [$self CachePath $url]}
        set hash [sha1::sha1 [encoding convertto utf-8 $url]]
        foreach t [glob -nocomplain \
                [file join [appdirs cache] attachments thumb ${hash}_*.png]] {
            catch {file delete -- $t}
        }
    }
}

# --- Shared attachment helpers (also used by message.tcl) ---------------

# XEP-0454 aesgcm:// URL helpers. The fragment is hex(iv) || hex(key): the
# key is always the last 32 bytes (64 hex chars); the iv is whatever precedes
# it (12 bytes is what we and modern clients emit, but 16 is accepted on the
# way in).
proc is_aesgcm_url {url} {
    return [string match -nocase "aesgcm://*" $url]
}

# Build an aesgcm:// URL from the https:// GET URL plus raw iv/key bytes.
proc aesgcm_url {httpsUrl iv key} {
    regsub {^[a-zA-Z][a-zA-Z0-9+.-]*://} $httpsUrl {aesgcm://} out
    return "$out#[binary encode hex $iv][binary encode hex $key]"
}

# Parse an aesgcm:// URL into {httpsUrl iv key} (raw bytes), or "" if it isn't
# one or the fragment is malformed.
proc aesgcm_parse {url} {
    if {![is_aesgcm_url $url]} { return "" }
    set hash [string first "#" $url]
    if {$hash < 0} { return "" }
    set base [string range $url 0 [expr {$hash - 1}]]
    set frag [string range $url [expr {$hash + 1}] end]
    if {[string length $frag] < 64 || [string length $frag] % 2 != 0} {
        return ""
    }
    regsub {^aesgcm://} $base {https://} httpsUrl
    set split [expr {[string length $frag] - 64}]
    set ivHex  [string range $frag 0 [expr {$split - 1}]]
    set keyHex [string range $frag $split end]
    return [list $httpsUrl [binary decode hex $ivHex] [binary decode hex $keyHex]]
}

# Filename component of a URL, with query/fragment stripped.
proc attachment_basename {url} {
    set bare [lindex [split $url "?#"] 0]
    return [file tail $bare]
}

# image (renderable inline) vs file (chip with open/save).
proc attachment_kind {nameOrUrl} {
    set ext [string tolower [file extension [attachment_basename $nameOrUrl]]]
    if {$ext in {.png .jpg .jpeg .gif .webp .bmp}} { return image }
    return file
}

proc attachment_mime {name} {
    switch -- [string tolower [file extension $name]] {
        .png        { return image/png }
        .jpg - .jpeg { return image/jpeg }
        .gif        { return image/gif }
        .webp       { return image/webp }
        .bmp        { return image/bmp }
        .pdf        { return application/pdf }
        .txt        { return text/plain }
        .mp4        { return video/mp4 }
        .webm       { return video/webm }
        .mp3        { return audio/mpeg }
        .ogg        { return audio/ogg }
        default     { return application/octet-stream }
    }
}
