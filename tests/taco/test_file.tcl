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
# filename) must be UTF-8 encoded before hashing for the storage path.
test file-unicode-url-hashable {non-ASCII URL can be used for attach/thumb paths} \
    {*}[tacky_env -mock conn -account user@test.example.com] -body {
        set url "https://h/изображение.png"
        set full  [$::_client file AttachPath $url]
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
    dict get $got content attachments
} -result {{url https://h/p.png type image name p.png size 10 mime image/png}}

test file-store-caption-derived {messagestore derives an empty caption for a URL-only body} {*}$file_env -body {
    set att [list [dict create \
        url https://h/p.png type image name p.png size 10 mime image/png]]
    set m [dict create timestamp 5100000 chat_jid bob@example.com \
        from_jid bob@example.com body https://h/p.png server_id sid-2 \
        own_id "" raw_xml "" attachments $att]
    $::_client message messagestore store [list $m]
    set got [lindex [$::_client message messagestore get ids bob@example.com [list 5100000]] 0]
    dict get $got content caption
} -result {}

test file-store-caption-keeps-text {messagestore keeps a body with real text as the caption} {*}$file_env -body {
    set att [list [dict create \
        url https://h/p.png type image name p.png size 10 mime image/png]]
    set m [dict create timestamp 5200000 chat_jid bob@example.com \
        from_jid bob@example.com body "look here https://h/p.png" server_id sid-3 \
        own_id "" raw_xml "" attachments $att]
    $::_client message messagestore store [list $m]
    set got [lindex [$::_client message messagestore get ids bob@example.com [list 5200000]] 0]
    dict get $got content caption
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
    list [dict get $m server_status] \
        [dict get [lindex [dict get $m content attachments] 0] url]
} -result {pending https://h/a.png}

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
    tacky message sendFile -acc $acc -chat bob@example.com -path $tmp
    set msgs [dict get \
        [$::_client message messagestore get latest bob@example.com] messages]
    set m [lindex $msgs 0]
    set res [list [llength $msgs] [dict get $m server_status] \
        [dict get [lindex [dict get $m content attachments] 0] url]]
    file delete $tmp
    set res
} -result [list 1 uploading [file join /tmp uptest_[pid].bin]]

# origin_id is a reply-target key, so a share's row needs it like a send's does.
test file-sendfile-records-its-origin-id {a share's row carries an origin id} {*}$file_env -body {
    set tmp /tmp/uporigin_[pid].bin
    set f [open $tmp w]; puts -nonewline $f "data"; close $f
    tacky message sendFile -acc $acc -chat bob@example.com -path $tmp
    lassign [$::_client db eval {
        SELECT own_id, origin_id FROM chat_message
        WHERE chat_jid='bob@example.com'
    }] ownId originId
    file delete $tmp
    expr {$ownId ne "" && $originId eq $ownId}
} -result 1

# Collect server_status off every message <Status> fired during $script.
proc up_patch_statuses {script} {
    set ::_up_patches {}
    set tag [tacky listen message <Status> {apply {{ev} {
        if {[dict exists $ev -server_status]} {
            lappend ::_up_patches [dict get $ev -server_status]
        }
    }}}]
    uplevel 1 $script
    tacky unlisten $tag
    set ::_up_patches
}

test file-upload-success-patches-pending {a completed upload emits a <Status> flipping the row to pending} {*}$file_env -body {
    up_store_uploading bob@example.com 7300000
    up_patch_statuses {
        $::_client message OnUploaded bob@example.com 7300000 7300000 \
            /tmp/a.png "" https://h/a.png
    }
} -result pending

# Without the markers remote_status can never leave 'sent'.
test file-upload-share-asks-for-markers {the plaintext share requests receipts and markers} {*}$file_env -body {
    up_store_uploading bob@example.com 7350000
    $::_client conn clear
    $::_client message OnUploaded bob@example.com 7350000 7350000 \
        /tmp/a.png "" https://h/a.png
    set stanza [lindex [$::_client conn get_written] end]
    set oob [lindex [xsearch $stanza x -ns jabber:x:oob] 0]
    list [xsearch $oob url -gather body] \
        [llength [xsearch $stanza request -ns urn:xmpp:receipts]] \
        [llength [xsearch $stanza markable -ns urn:xmpp:chat-markers:0]]
} -result {https://h/a.png 1 1}

# The share goes out off the send path, so it has to mark itself in flight or
# the reconnect retry sends the row a second time.
test file-upload-share-not-resent-by-retry {RetryPending leaves a just-sent share alone} {*}$file_env -body {
    up_store_uploading bob@example.com 7360000
    $::_client conn clear
    $::_client message OnUploaded bob@example.com 7360000 7360000 \
        /tmp/a.png "" https://h/a.png
    set afterSend [llength [$::_client conn get_written]]
    $::_client message RetryPending
    list $afterSend [llength [$::_client conn get_written]]
} -result {1 1}

test file-upload-failure-patches-failed {a failed upload emits a <Status> flipping the row to failed} {*}$file_env -body {
    up_store_uploading bob@example.com 7400000
    up_patch_statuses {
        $::_client message OnUploaded bob@example.com 7400000 7400000 \
            /tmp/a.png "" ""
    }
} -result failed

test file-retryupload-patches-uploading {retryUpload emits a <Status> flipping the failed row back to uploading} {*}$file_env -body {
    # A readable source file lets the retry stall at slot discovery (the mock
    # server never replies) instead of failing straight back on an unreadable
    # path, so the only transition is failed -> uploading.
    set f [open /tmp/a.png w]; puts -nonewline $f data; close $f
    up_store_uploading bob@example.com 7500000
    up_ms markUploadFailed bob@example.com 7500000
    set res [up_patch_statuses {
        tacky message retryUpload -acc $acc -chat bob@example.com -timestamp 7500000
    }]
    file delete /tmp/a.png
    set res
} -result uploading

# --- transfer events / download / thumbnails -------------------------------
#
# Sandbox the cache so generated files land in /tmp, not the real ~/.cache.
# Restored at the end of the file.

proc up_readb {path} {
    set f [open $path rb]
    try { return [read $f] } finally { close $f }
}

# Scratch dir for source files; the backend uses its own transient roots.
set ::_upcache [file join /tmp tacky_upcache_[pid]]
file mkdir $::_upcache

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

test file-uncache {uncache deletes the downloaded original and every thumbnail size} {*}$file_env -body {
    set url https://h/uncache.png
    set full  [$::_client file AttachPath $url]
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

test file-paths-split {originals go to the data dir, thumbnails to the cache dir} {*}$file_env -body {
    set url https://h/split.png
    set data  [$::_client cget -data-dir]
    set cache [$::_client cget -cache-dir]
    list data=[string match $data/* [$::_client file AttachPath $url]] \
         thumb=[string match $cache/* [$::_client file ThumbPath $url 320]] \
         distinct=[expr {$data ne $cache}]
} -result {data=1 thumb=1 distinct=1}

# A transient tacky must never put ratchet state or history on disk.
test file-transient-db-in-memory {transient accounts get an in-memory database} \
    {*}[tacky_env -mock conn -account user@test.example.com] -body {
        $::_client cget -db-path
    } -result {:memory:}

# --- Autofetch policy -----------------------------------------------------

proc af_contact {jid {sub both}} {
    $::_client roster StoreItem [j item -jid $jid -subscription $sub]
}

proc af_policy {v} { tacky setting set -key attachment_autofetch -value $v }

# Terminal state and error of the last file <Update> (needs -capture-emit).
proc af_last {} {
    set out {}
    foreach e $::_emitted {
        if {[lindex $e 0] ne "file" || [lindex $e 1] ne "<Update>"} continue
        set ev [lrange $e 2 end]
        set out [list [dict get $ev -state] [dict get $ev -error]]
    }
    return $out
}

test file-autofetch-defaults {unset settings mean everyone, capped at 5 MB} \
    {*}$file_env -body {
        set unset [list [$::_client file AutofetchAllowed stranger@elsewhere.example] \
            [$::_client file AutofetchMax]]
        tacky setting set -key attachment_autofetch_max -value 0
        list $unset stored=[$::_client file AutofetchMax]
    } -result {{1 5242880} stored=0}

test file-autofetch-contacts {contacts policy admits only a subscribed contact} \
    {*}$file_env -body {
        af_policy contacts
        af_contact friend@test.example.com both
        af_contact pending@test.example.com none
        list friend=[$::_client file AutofetchAllowed friend@test.example.com/phone] \
             pending=[$::_client file AutofetchAllowed pending@test.example.com] \
             stranger=[$::_client file AutofetchAllowed stranger@elsewhere.example] \
             nofrom=[$::_client file AutofetchAllowed ""]
    } -result {friend=1 pending=0 stranger=0 nofrom=0}

# MUC images ride on the "everyone" default rather than a special case.
test file-autofetch-muc-not-a-contact {contacts policy does not autofetch a room} \
    {*}$file_env -body {
        af_policy contacts
        set room room@conference.test.example.com
        set underContacts [$::_client file AutofetchAllowed $room/nick]
        af_policy everyone
        list contacts=$underContacts \
             everyone=[$::_client file AutofetchAllowed $room/nick]
    } -result {contacts=0 everyone=1}

test file-autofetch-never {never policy refuses even a contact} {*}$file_env -body {
    af_policy never
    af_contact friend@test.example.com both
    $::_client file AutofetchAllowed friend@test.example.com
} -result 0

test file-autofetch-blocked-download {a gated autofetch goes idle without touching the network} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        af_policy contacts
        set url https://h/tracker.png
        $::_client file download -url $url -auto 1 \
            -from stranger@elsewhere.example
        set full [$::_client file AttachPath $url]
        list [af_last] onDisk=[file exists $full] \
             part=[file exists $full.part]
    } -result {{idle {}} onDisk=0 part=0}

# The gate sits below the on-disk lookups, so a tightened policy must not
# blank an image that is already local.
test file-autofetch-local-still-resolves {a local source resolves even under never} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        af_policy never
        set src [file join $::_upcache already.png]
        set px [string repeat [binary format cccc 1 2 3 255] 64]
        set f [open $src wb]
        puts -nonewline $f [::tclwuffs::encode_png 8 8 $px]
        close $f
        set ::_local NONE
        $::_client file download -url $src -auto 1 \
            -from stranger@elsewhere.example \
            -command [list apply {{p} {set ::_local $p}}]
        list [af_last] local=[expr {$::_local eq $src}]
    } -result {{done {}} local=1}

test file-autofetch-manual-not-gated {a download without -auto ignores the policy} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        af_policy never
        set src [file join $::_upcache manual.png]
        set px [string repeat [binary format cccc 4 5 6 255] 64]
        set f [open $src wb]
        puts -nonewline $f [::tclwuffs::encode_png 8 8 $px]
        close $f
        set ::_local NONE
        $::_client file download -url $src \
            -command [list apply {{p} {set ::_local $p}}]
        list [af_last] local=[expr {$::_local eq $src}]
    } -result {{done {}} local=1}

# --- Autofetch size cap ---------------------------------------------------

proc af_transfer {max} {
    return [$::_client file NewTransfer download https://h/big.png "" $max]
}

test file-autofetch-max-honest-length {an over-cap Content-Length aborts at once} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set id [af_transfer 1000]
        $::_client file ProgressCb $id "" 2000 0
        af_last
    } -result {idle {}}

# A server that understates or omits Content-Length is caught by the bytes.
test file-autofetch-max-lying-length {an over-cap byte count aborts mid-stream} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set id [af_transfer 1000]
        $::_client file ProgressCb $id "" 0 400
        set early [af_last]
        $::_client file ProgressCb $id "" 0 1400
        list early $early late [af_last]
    } -result {early {active {}} late {idle {}}}

test file-autofetch-max-under-cap {a transfer within the cap is left alone} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set id [af_transfer 1000]
        $::_client file ProgressCb $id "" 900 900
        af_last
    } -result {active {}}

test file-autofetch-max-unset-means-unlimited {maxbytes 0 never aborts} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set id [$::_client file NewTransfer download https://h/nolimit.png]
        $::_client file ProgressCb $id "" 999999999 999999999
        af_last
    } -result {active {}}

# --- cancel ---------------------------------------------------------------
#
# ::http::reset runs the request's -command callback before it returns, so only
# a request really on the wire pins down the reason a caller sees. These serve
# one over a loopback socket.

# `mode` is silent (accept and never answer, so the transfer stays active) or
# slow (headers claiming $clen bytes, then a trickle that never ends).
proc cx_start {mode {clen 0}} {
    set ::_cx_conns {}
    set ::_cx_afters {}
    set srv [socket -server [list cx_accept $mode $clen] -myaddr 127.0.0.1 0]
    return [list $srv [lindex [fconfigure $srv -sockname] 2]]
}

proc cx_accept {mode clen ch addr port} {
    lappend ::_cx_conns $ch
    fconfigure $ch -translation binary -blocking 0
    if {$mode eq "silent"} return
    lappend ::_cx_afters [after 10 [list cx_head $ch $clen]]
}

proc cx_head {ch clen} {
    catch {
        puts -nonewline $ch "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n"
        puts -nonewline $ch "Content-Length: $clen\r\n\r\n"
        flush $ch
    }
    cx_body $ch
}

proc cx_body {ch} {
    if {[catch {puts -nonewline $ch [string repeat x 65536]; flush $ch}]} return
    lappend ::_cx_afters [after 20 [list cx_body $ch]]
}

proc cx_stop {srv} {
    foreach a $::_cx_afters { catch {after cancel $a} }
    foreach c $::_cx_conns { catch {close $c} }
    catch {close $srv}
}

# Run the event loop until the transfer reaches a terminal state.
proc cx_settle {} {
    for {set i 0} {$i < 300} {incr i} {
        if {[lindex [af_last] 0] in {done failed}} break
        after 10 {set ::_cx_tick 1}
        vwait ::_cx_tick
    }
    return [af_last]
}

test file-cancel-in-flight-download {cancelling a live download ends idle, not on the transport error} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        lassign [cx_start silent] srv port
        set url http://127.0.0.1:$port/slow.png
        set ::_cx_cb NONE
        $::_client file download -url $url \
            -command [list apply {{p} {set ::_cx_cb $p}}]
        set started [af_last]
        $::_client file cancel -url $url
        set full [$::_client file AttachPath $url]
        set res [list started=[lindex $started 0] [af_last] \
            cb=[expr {$::_cx_cb eq ""}] part=[file exists $full.part]]
        cx_stop $srv
        set res
    } -result {started=active {idle {}} cb=1 part=0}

test file-cancel-in-flight-upload {cancelling an upload stalled at discovery ends it idle} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        set src [file join $::_upcache cancelme.bin]
        set f [open $src wb]
        puts -nonewline $f [string repeat z 4096]
        close $f
        set ::_cx_cb NONE
        $::_client file upload -id 9100000 -path $src \
            -command [list apply {{u} {set ::_cx_cb $u}}]
        $::_client file cancel -id 9100000
        list [af_last] cb=[expr {$::_cx_cb eq ""}]
    } -result {{idle {}} cb=1}

# One transfer serves every caller that asked for the url, so cancelling has to
# resolve them all.
test file-cancel-coalesced-download {cancelling a shared download resolves every caller} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        lassign [cx_start silent] srv port
        set url http://127.0.0.1:$port/shared.png
        set ::_cx_first NONE
        set ::_cx_second NONE
        $::_client file download -url $url \
            -command [list apply {{p} {set ::_cx_first $p}}]
        $::_client file download -url $url \
            -command [list apply {{p} {set ::_cx_second $p}}]
        $::_client file cancel -url $url
        set res [list [af_last] first=[expr {$::_cx_first eq ""}] \
            second=[expr {$::_cx_second eq ""}]]
        cx_stop $srv
        set res
    } -result {{idle {}} first=1 second=1}

test file-cancel-unknown-transfer {cancelling something that isn't running does nothing} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        $::_client file cancel -id 4242
        $::_client file cancel -url https://h/never-started.png
        af_last
    } -result {}

# The size cap aborts the same way cancel does, so its state has to survive
# the http callback too.
test file-autofetch-max-live-request {an over-cap fetch on the wire ends idle, not failed} \
    {*}[tacky_env -mock conn -account $acc -capture-emit 1] -body {
        af_policy everyone
        tacky setting set -key attachment_autofetch_max -value 4096
        lassign [cx_start slow 100000000] srv port
        set url http://127.0.0.1:$port/big.png
        $::_client file download -url $url -auto 1 \
            -from friend@test.example.com
        set res [cx_settle]
        set full [$::_client file AttachPath $url]
        lappend res part=[file exists $full.part] onDisk=[file exists $full]
        cx_stop $srv
        set res
    } -result {idle {} part=0 onDisk=0}

file delete -force -- $::_upcache
