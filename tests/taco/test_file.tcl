# Unit tests for taco_file (XEP-0363 transfers) and attachment parsing/storage.
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tclwuffs

set acc user@test.example.com
set file_env [tacky_env -mock conn -account $acc]

# --- pure helpers ---------------------------------------------------------

test file-kind-image {image extensions are detected, others are files} -body {
    list [attachment_kind foo.png] [attachment_kind /a/b/c.JPG] \
         [attachment_kind https://h/x.gif?k=v] [attachment_kind doc.pdf] \
         [attachment_kind noext]
} -result {image image image file file}

test file-mime {mime guessed by extension} -body {
    list [attachment_mime a.png] [attachment_mime a.jpeg] \
         [attachment_mime a.pdf] [attachment_mime a.bin]
} -result {image/png image/jpeg application/pdf application/octet-stream}

test file-basename-strips-query {basename strips query and fragment} -body {
    list [attachment_basename https://h/path/pic.png?a=1&b=2] \
         [attachment_basename https://h/f.pdf#frag]
} -result {pic.png f.pdf}

# --- aesgcm:// URL helpers (XEP-0454) -------------------------------------

test file-aesgcm-url-roundtrip {aesgcm_url builds a fragment that aesgcm_parse recovers} -body {
    set iv  [binary decode hex "000102030405060708090a0b"]      ;# 12 bytes
    set key [binary decode hex [string repeat "ab" 32]]         ;# 32 bytes
    set url [aesgcm_url "https://up.example/abc/pic.png" $iv $key]
    lassign [aesgcm_parse $url] http riv rkey
    list scheme=[is_aesgcm_url $url] \
         frag=[string match {aesgcm://up.example/abc/pic.png#*} $url] \
         http=$http iv=[expr {$riv eq $iv}] key=[expr {$rkey eq $key}]
} -result {scheme=1 frag=1 http=https://up.example/abc/pic.png iv=1 key=1}

test file-aesgcm-parse-rejects-plain {aesgcm_parse yields "" for a non-aesgcm URL} -body {
    list [is_aesgcm_url https://h/x.png] [aesgcm_parse https://h/x.png]
} -result {0 {}}

# The key is always the trailing 32 bytes, so a sender that used a 16-byte IV
# still parses (interop with older clients).
test file-aesgcm-parse-16byte-iv {parse accepts a 16-byte iv} -body {
    set frag "[string repeat 11 16][string repeat 22 32]"
    lassign [aesgcm_parse "aesgcm://h/x.png#$frag"] http iv key
    list [string length $iv] [string length $key]
} -result {16 32}

test file-aesgcm-parse-rejects-short-fragment {a fragment shorter than a key is rejected} -body {
    aesgcm_parse "aesgcm://h/x.png#deadbeef"
} -result {}

# kind/basename ignore the scheme and fragment, so display logic works on the
# aesgcm URL as-is.
test file-aesgcm-kind {attachment kind/basename see through the aesgcm scheme} -body {
    set u "aesgcm://h/path/pic.png#[string repeat aa 44]"
    list [attachment_kind $u] [attachment_basename $u]
} -result {image pic.png}

test file-fitwithin {fit_within shrinks within max, preserves aspect, no upscale} -body {
    list [fit_within 200 100 50] [fit_within 100 200 50] \
         [fit_within 40 30 100] [fit_within 50 50 50]
} -result {{50 25} {25 50} {40 30} {50 50}}

# sha1 needs a byte string, so URLs with non-ASCII characters (like a Cyrillic
# filename) must be UTF-8 encoded before hashing for the cache path.
test file-unicode-url-hashable {non-ASCII URL can be used for cache/thumb paths} \
    {*}[tacky_env -mock conn -account user@test.example.com] -body {
        set url "https://h/изображение.png"
        set full  [$::_client file CachePath $url]
        set thumb [$::_client file ThumbPath $url 320]
        set uncacheRc [catch {$::_client file uncache -url $url}]
        list full=[string match *attachments/*.png $full] \
             thumb=[string match *attachments/thumb/*_320.png $thumb] \
             uncache=$uncacheRc
    } -result {full=1 thumb=1 uncache=0}

# --- ExtractAttachments ---------------------------------------------------

test file-extract-oob {XEP-0066 OOB url becomes an attachment} -body {
    set m [j message {
        j body #body "https://up.example/abc/pic.png"
        j x -ns jabber:x:oob { j url #body "https://up.example/abc/pic.png" }
    }]
    set atts [ExtractAttachments $m [xsearch $m body -get body]]
    list [llength $atts] [dict get [lindex $atts 0] url] \
         [dict get [lindex $atts 0] type] [dict get [lindex $atts 0] name]
} -result {1 https://up.example/abc/pic.png image pic.png}

test file-extract-bare-url-no-oob {a body that is just a URL is a link, not an attachment} -body {
    set m [j message { j body #body "https://up.example/x/doc.pdf" }]
    ExtractAttachments $m [xsearch $m body -get body]
} -result {}

test file-extract-oob-url-bodied {OOB attachment is still recognised when the body is the same URL} -body {
    set m [j message {
        j body #body "https://up.example/x/pic.png"
        j x -ns jabber:x:oob { j url #body "https://up.example/x/pic.png" }
    }]
    set atts [ExtractAttachments $m [xsearch $m body -get body]]
    list [llength $atts] [dict get [lindex $atts 0] type]
} -result {1 image}

test file-extract-plain-text {plain text yields no attachments} -body {
    set m [j message { j body #body "hello there" }]
    ExtractAttachments $m [xsearch $m body -get body]
} -result {}

test file-extract-url-in-sentence {a URL embedded in a sentence is not an attachment} -body {
    set m [j message { j body #body "see https://x/y.png please" }]
    ExtractAttachments $m [xsearch $m body -get body]
} -result {}

# OMEMO media: the decrypted body IS the aesgcm:// URL (no OOB), and must be
# recognised as the attachment.
test file-extract-aesgcm-body {an aesgcm:// body with no OOB is an attachment} -body {
    set u "aesgcm://up.example/x/pic.png#[string repeat aa 44]"
    set m [j message { j body #body $u }]
    set atts [ExtractAttachments $m [xsearch $m body -get body]]
    list [llength $atts] [dict get [lindex $atts 0] type] \
         [dict get [lindex $atts 0] name] [dict get [lindex $atts 0] url]
} -result [list 1 image pic.png "aesgcm://up.example/x/pic.png#[string repeat aa 44]"]

# A plaintext https body is still just a link, even now.
test file-extract-aesgcm-only-for-aesgcm {a plain https body is not promoted by the aesgcm rule} -body {
    set m [j message { j body #body "https://up.example/x/pic.png" }]
    ExtractAttachments $m [xsearch $m body -get body]
} -result {}

# --- attachment_caption ---------------------------------------------------

proc cap_att {url} { list [dict create url $url type image name x size "" mime ""] }

test file-caption-url-only {a body that is just the attachment URL has an empty caption} -body {
    attachment_caption "https://h/p.png" [cap_att https://h/p.png]
} -result {}

test file-caption-url-whitespace {surrounding whitespace still counts as URL-only} -body {
    attachment_caption "  https://h/p.png  " [cap_att https://h/p.png]
} -result {}

test file-caption-real-text {a body with real text alongside the URL is kept} -body {
    attachment_caption "see this https://h/p.png" [cap_att https://h/p.png]
} -result {see this https://h/p.png}

test file-caption-different-url {a body that is a different URL is kept} -body {
    attachment_caption "https://h/other.png" [cap_att https://h/p.png]
} -result {https://h/other.png}

test file-caption-matches-any {an empty caption when the body matches any one attachment} -body {
    attachment_caption "https://h/b.png" \
        [list [dict create url https://h/a.png type image name a size "" mime ""] \
              [dict create url https://h/b.png type image name b size "" mime ""]]
} -result {}

# --- slot request / response ---------------------------------------------

test file-requestslot-stanza {RequestSlot sends a well-formed XEP-0363 request} {*}$file_env -body {
    $::_client file RequestSlot upload.test.example.com "my file.png" 2048 image/png \
        [list apply {{slot} {}}]
    set iq [lindex [$::_client conn get_written] end]
    set req [xsearch $iq request -ns urn:xmpp:http:upload:0 -get node]
    list [xsearch $iq -get @type] [xsearch $iq -get @to] \
         [xsearch $req -get @filename] [xsearch $req -get @size] \
         [xsearch $req -get @content-type]
} -result {get upload.test.example.com {my file.png} 2048 image/png}

test file-slot-parse {slot result yields put/get URLs and headers} {*}$file_env -body {
    set iq [j iq -type result {
        j slot -ns urn:xmpp:http:upload:0 {
            j put -url "https://up.example/PUT/pic.png" {
                j header -name Authorization #body "Bearer xyz"
            }
            j get -url "https://dl.example/GET/pic.png"
        }
    }]
    set ::_slot ""
    $::_client file OnSlotResult [list apply {{s} {set ::_slot $s}}] $iq
    set ::_slot
} -result {https://up.example/PUT/pic.png https://dl.example/GET/pic.png {Authorization {Bearer xyz}}}

test file-slot-error-yields-empty {a non-result slot reply yields ""} {*}$file_env -body {
    set iq [j iq -type error {
        j error -type cancel { j not-acceptable -ns urn:ietf:params:xml:ns:xmpp-stanzas }
    }]
    set ::_slot NONE
    $::_client file OnSlotResult [list apply {{s} {set ::_slot $s}}] $iq
    set ::_slot
} -result {}

# --- service discovery ----------------------------------------------------

test file-maxfilesize {ReadMaxFileSize reads max-file-size from the disco#info form} {*}$file_env -body {
    set iq [j iq -type result {
        j query -ns http://jabber.org/protocol/disco#info {
            j feature -var urn:xmpp:http:upload:0
            j x -ns jabber:x:data -type result {
                j field -var max-file-size { j value #body 5242880 }
            }
        }
    }]
    $::_client file ReadMaxFileSize $iq
} -result 5242880

test file-discoinfo-match {OnDiscoInfo selects a component advertising the upload feature} {*}$file_env -body {
    set iq [j iq -type result -from upload.test.example.com {
        j query -ns http://jabber.org/protocol/disco#info {
            j feature -var urn:xmpp:http:upload:0
        }
    }]
    set ::_svc NONE
    $::_client file OnDiscoInfo [list apply {{s} {set ::_svc $s}}] \
        upload.test.example.com {} $iq
    set ::_svc
} -result upload.test.example.com

test file-discoinfo-no-match {OnDiscoInfo without the feature and no more candidates yields ""} {*}$file_env -body {
    set iq [j iq -type result {
        j query -ns http://jabber.org/protocol/disco#info {
            j feature -var some:other:ns
        }
    }]
    set ::_svc NONE
    $::_client file OnDiscoInfo [list apply {{s} {set ::_svc $s}}] \
        comp.test.example.com {} $iq
    set ::_svc
} -result {}

# --- storage round-trip ---------------------------------------------------

test file-store-roundtrip {messagestore preserves the attachments column} {*}$file_env -body {
    set att [list [dict create \
        url https://h/p.png type image name p.png size 10 mime image/png]]
    set m [dict create timestamp 5000000 chat_jid bob@example.com \
        from_jid bob@example.com body https://h/p.png server_id sid-1 \
        own_id "" raw_xml "" attachments $att]
    $::_client message messagestore store [list $m]
    set got [lindex [dict get \
        [$::_client message messagestore get latest bob@example.com] messages] 0]
    dict get $got attachments
} -result {{url https://h/p.png type image name p.png size 10 mime image/png}}

test file-store-caption-derived {messagestore derives an empty caption for a URL-only body} {*}$file_env -body {
    set att [list [dict create \
        url https://h/p.png type image name p.png size 10 mime image/png]]
    set m [dict create timestamp 5100000 chat_jid bob@example.com \
        from_jid bob@example.com body https://h/p.png server_id sid-2 \
        own_id "" raw_xml "" attachments $att]
    $::_client message messagestore store [list $m]
    set got [lindex [$::_client message messagestore get ids bob@example.com [list 5100000]] 0]
    dict get $got caption
} -result {}

test file-store-caption-keeps-text {messagestore keeps a body with real text as the caption} {*}$file_env -body {
    set att [list [dict create \
        url https://h/p.png type image name p.png size 10 mime image/png]]
    set m [dict create timestamp 5200000 chat_jid bob@example.com \
        from_jid bob@example.com body "look here https://h/p.png" server_id sid-3 \
        own_id "" raw_xml "" attachments $att]
    $::_client message messagestore store [list $m]
    set got [lindex [$::_client message messagestore get ids bob@example.com [list 5200000]] 0]
    dict get $got caption
} -result {look here https://h/p.png}

# --- upload lifecycle / optimistic send -----------------------------------

proc up_ms {args} {
    $::_client message messagestore {*}$args
}
proc up_store_uploading {jid ts} {
    up_ms store [list [dict create timestamp $ts chat_jid $jid \
        from_jid me@x body "" server_id "" own_id $ts raw_xml "" \
        attachments [list [dict create url /tmp/a.png type image \
            name a.png size 4 mime image/png]] \
        server_status uploading]]
}
proc up_status {jid ts} {
    dict get [lindex [up_ms get ids $jid [list $ts]] 0] server_status
}

test file-markuploaded-promotes {markUploaded promotes uploading -> pending with the remote URL} {*}$file_env -body {
    up_store_uploading bob@example.com 7000000
    up_ms markUploaded bob@example.com 7000000 https://h/a.png "<message/>" \
        [list [dict create url https://h/a.png type image name a.png \
            size 4 mime image/png]]
    set m [lindex [up_ms get ids bob@example.com [list 7000000]] 0]
    list [dict get $m server_status] [dict get $m body] \
        [dict get [lindex [dict get $m attachments] 0] url]
} -result {pending https://h/a.png https://h/a.png}

test file-markuploadfailed {markUploadFailed sets the row to failed} {*}$file_env -body {
    up_store_uploading bob@example.com 7100000
    up_ms markUploadFailed bob@example.com 7100000
    up_status bob@example.com 7100000
} -result failed

test file-markuploading-retry {markUploading flips failed back to uploading} {*}$file_env -body {
    up_store_uploading bob@example.com 7150000
    up_ms markUploadFailed bob@example.com 7150000
    up_ms markUploading bob@example.com 7150000
    up_status bob@example.com 7150000
} -result uploading

test file-failstaleuploads {failStaleUploads turns leftover uploading rows into failed} {*}$file_env -body {
    up_store_uploading bob@example.com 7200000
    up_ms failStaleUploads
    up_status bob@example.com 7200000
} -result failed

test file-sendfile-optimistic-row {sendFile stores the message immediately as uploading} {*}$file_env -body {
    set tmp /tmp/uptest_[pid].bin
    set f [open $tmp w]; puts -nonewline $f "data"; close $f
    # Upload stalls at discovery (mock server never replies) -> stays uploading.
    tacky message sendFile -acc $acc -chat_jid bob@example.com -path $tmp
    set msgs [dict get \
        [$::_client message messagestore get latest bob@example.com] messages]
    set m [lindex $msgs 0]
    set res [list [llength $msgs] [dict get $m server_status] \
        [dict get [lindex [dict get $m attachments] 0] url]]
    file delete $tmp
    set res
} -result [list 1 uploading [file join /tmp uptest_[pid].bin]]

# --- transfer events / download / thumbnails -------------------------------
#
# Sandbox the cache so generated files land in /tmp, not the real ~/.cache.
# Restored at the end of the file.

proc up_readb {path} {
    set f [open $path rb]
    try { return [read $f] } finally { close $f }
}

set ::_old_xdg [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : ""}]
set ::_upcache [file join /tmp tacky_upcache_[pid]]
set ::env(XDG_CACHE_HOME) $::_upcache

test file-encrypt-to-temp {EncryptToTemp writes ciphertext that media_decrypt recovers} \
    {*}[tacky_env -mock conn -account $acc] -body {
        set src [file join $::_upcache plain.bin]
        file mkdir [file dirname $src]
        set plain [string repeat "abc123\x00\xff" 64]
        set f [open $src wb]; puts -nonewline $f $plain; close $f
        lassign [$::_client file EncryptToTemp $src] tmp key iv
        set ct [up_readb $tmp]
        set back [::omemo::media_decrypt $key $iv $ct]
        file delete -- $tmp
        list overhead=[expr {[string length $ct] - [string length $plain]}] \
             keylen=[string length $key] ivlen=[string length $iv] \
             ok=[expr {$back eq $plain}]
    } -result {overhead=16 keylen=32 ivlen=12 ok=1}

test file-progress-throttle {ProgressCb emits a <Update> on ~1% steps and at completion} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set id [$::_client file NewTransfer download http://h/x.png]
        $::_client file ProgressCb $id tok 1000 500    ;# 50%   -> emit
        $::_client file ProgressCb $id tok 1000 505    ;# 50.5% -> throttled
        $::_client file ProgressCb $id tok 1000 1000   ;# 100%  -> emit
        set n 0
        foreach e $::_emitted {
            if {[lindex $e 0] eq "file" && [lindex $e 1] eq "<Update>"} { incr n }
        }
        set n
    } -result 2

test file-download-local-thumbnail {download of a local image emits a sized PNG thumbnail} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set src [file join $::_upcache big.png]
        file mkdir [file dirname $src]
        set w 600; set h 360
        set px [string repeat [binary format cccc 10 120 200 255] [expr {$w * $h}]]
        set f [open $src wb]
        puts -nonewline $f [::tclwuffs::encode_png $w $h $px]
        close $f
        set ::_local ""
        $::_client file download -url $src \
            -command [list apply {{p} {set ::_local $p}}]
        set tp ""; set st ""
        foreach e $::_emitted {
            if {[lindex $e 0] ne "file" || [lindex $e 1] ne "<Update>"} continue
            set ev2 [lrange $e 2 end]
            set st [dict get $ev2 -state]; set tp [dict get $ev2 -thumbpath]
        }
        set d [::tclwuffs::decode [up_readb $tp]]
        list local=[expr {$::_local eq $src}] state=$st \
             sniff=[::tclwuffs::sniff [up_readb $tp]] \
             w=[dict get $d width] h=[dict get $d height]
    } -result {local=1 state=done sniff=png w=320 h=192}

test file-download-non-image-no-thumb {a non-image (undecodable) file downloads with no thumbnail} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set src [file join $::_upcache notimg.png]
        set f [open $src wb]
        puts -nonewline $f "not an image"
        close $f
        set ::_local ""
        $::_client file download -url $src \
            -command [list apply {{p} {set ::_local $p}}]
        set tp NONE
        foreach e $::_emitted {
            if {[lindex $e 0] ne "file" || [lindex $e 1] ne "<Update>"} continue
            set tp [dict get [lrange $e 2 end] -thumbpath]
        }
        list local=[expr {$::_local eq $src}] thumb=$tp
    } -result {local=1 thumb=}

test file-uncache {uncache deletes the cached download and every thumbnail size} {*}$file_env -body {
    set url https://h/uncache.png
    set full  [$::_client file CachePath $url]
    set thumb [$::_client file ThumbPath $url 320]
    file mkdir [file dirname $full]
    file mkdir [file dirname $thumb]
    close [open $full w]
    close [open $thumb w]
    $::_client file uncache -url $url
    list [file exists $full] [file exists $thumb]
} -result {0 0}

# An outgoing attachment still uploading carries its local source path as the
# url. uncache must drop the derived thumbnail but never the original file.
test file-uncache-keeps-local-source {uncache leaves a local source file untouched} {*}$file_env -body {
    set src [file join $::_upcache mine.png]
    set w 8; set h 8
    set px [string repeat [binary format cccc 1 2 3 255] [expr {$w * $h}]]
    set f [open $src wb]
    puts -nonewline $f [::tclwuffs::encode_png $w $h $px]
    close $f
    $::_client file download -url $src
    set thumb [$::_client file ThumbPath $src 320]
    set thumbWas [file exists $thumb]
    $::_client file uncache -url $src
    list srcKept=[file exists $src] thumbWas=$thumbWas \
        thumbGone=[expr {![file exists $thumb]}]
} -result {srcKept=1 thumbWas=1 thumbGone=1}

if {$::_old_xdg eq ""} {
    unset -nocomplain ::env(XDG_CACHE_HOME)
} else {
    set ::env(XDG_CACHE_HOME) $::_old_xdg
}
file delete -force -- $::_upcache
