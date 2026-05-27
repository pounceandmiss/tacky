# Jingle <-> SDP conversion (XEP-0167 RTP + XEP-0176 ICE-UDP + XEP-0320 DTLS + XEP-0338 BUNDLE).
#
# API:
#   jinglesdp::to_sdp $jingleStanza ?-initiator 1|0?
#       $jingleStanza is the <jingle> element node-dict.
#       Returns an SDP string.
#
#   jinglesdp::from_sdp $sdpString ?-creator initiator|responder?
#                                  ?-initiator 1|0?
#       Returns a <jingle> element node-dict (no action/sid set; caller adds them).
#
# Mirrors eu.siacs.conversations.xmpp.jingle.SessionDescription from Conversations.

namespace eval jinglesdp {
    variable LINE_DIVIDER             "\r\n"
    variable HARDCODED_MEDIA_PROTOCOL "UDP/TLS/RTP/SAVPF"
    variable HARDCODED_MEDIA_PORT     9
    variable HARDCODED_CONNECTION     "IN IP4 0.0.0.0"
    variable HARDCODED_ORIGIN         "- 8770656990916039506 2 IN IP4 127.0.0.1"
    variable HARDCODED_ICE_OPTIONS    {trickle}

    variable NS_JINGLE        urn:xmpp:jingle:1
    variable NS_RTP           urn:xmpp:jingle:apps:rtp:1
    variable NS_DTLS          urn:xmpp:jingle:apps:dtls:0
    variable NS_GROUPING      urn:xmpp:jingle:apps:grouping:0
    variable NS_ICE_UDP       urn:xmpp:jingle:transports:ice-udp:1
    variable NS_RTP_HDREXT    urn:xmpp:jingle:apps:rtp:rtp-hdrext:0
    variable NS_RTP_FEEDBACK  urn:xmpp:jingle:apps:rtp:rtcp-fb:0
    variable NS_RTP_SSMA      urn:xmpp:jingle:apps:rtp:ssma:0
    variable NS_ICE_OPTION    "http://gultsch.de/xmpp/drafts/jingle/transports/ice-udp/option"

    variable ICE_OPTION_WELL_KNOWN {trickle renomination}

    # Counter for deterministic candidate ids when parsing SDP. Real Jingle
    # uses random UUIDs, but a monotonic counter is sufficient for our use.
    variable _candidateCounter 0
}

# --- multimap helpers (for SDP attribute lists, NOT XML nodes) ------------
# An SDP attribute "multimap" is a flat list {key val key val ...} preserving
# insertion order, since SDP cares about order and may repeat keys.

proc jinglesdp::mm_get_all {mm key} {
    set out {}
    foreach {k v} $mm {
        if {$k eq $key} { lappend out $v }
    }
    return $out
}

proc jinglesdp::mm_first {mm key {default ""}} {
    foreach {k v} $mm {
        if {$k eq $key} { return $v }
    }
    return $default
}

proc jinglesdp::mm_has {mm key} {
    foreach {k v} $mm {
        if {$k eq $key} { return 1 }
    }
    return 0
}

# --- senders <-> media-attribute mapping ---------------------------------

# Senders enum value ("both"/"initiator"/"responder"/"none") -> SDP attribute.
proc jinglesdp::senders_to_sdp {senders initiator} {
    switch -- $senders {
        "" -
        both       { return sendrecv }
        none       { return inactive }
        initiator  { return [expr {$initiator ? "sendonly" : "recvonly"}] }
        responder  { return [expr {$initiator ? "recvonly" : "sendonly"}] }
        default    { return sendrecv }
    }
}

# Multimap of media attributes + initiator flag -> senders enum.
proc jinglesdp::senders_from_mm {mm initiator} {
    if {[mm_has $mm sendrecv]} { return both }
    if {[mm_has $mm inactive]} { return none }
    if {[mm_has $mm sendonly]} { return [expr {$initiator ? "initiator" : "responder"}] }
    if {[mm_has $mm recvonly]} { return [expr {$initiator ? "responder" : "initiator"}] }
    return both
}

# --- to_sdp: jingle stanza -> SDP string ---------------------------------

proc jinglesdp::to_sdp {jingleStanza args} {
    variable LINE_DIVIDER
    variable HARDCODED_MEDIA_PROTOCOL
    variable HARDCODED_MEDIA_PORT
    variable HARDCODED_CONNECTION
    variable HARDCODED_ORIGIN
    variable NS_RTP
    variable NS_GROUPING
    variable NS_ICE_UDP

    array set opts {-initiator 1}
    array set opts $args

    set sessionAttrs {}
    set group [xsearch $jingleStanza group -ns $NS_GROUPING -get node]
    if {$group ne ""} {
        set semantics [xsearch $group -get @semantics]
        set tags [xsearch $group content -gather @name]
        lappend sessionAttrs group "$semantics [join $tags { }]"
    }
    lappend sessionAttrs msid-semantic " WMS my-media-stream"

    set mediaBlocks {}
    xsearch $jingleStanza content -script content {
        set name [xsearch $content -get @name]
        set sendersAttr [xsearch $content -get @senders]
        set description [xsearch $content description -ns $NS_RTP -get node]
        set transport [xsearch $content transport -ns $NS_ICE_UDP -get node]
        if {$description eq "" || $transport eq ""} continue

        set mediaAttrs {}
        jinglesdp::AppendTransportAttrs $transport mediaAttrs

        set formats {}
        xsearch $description payload-type -script pt {
            set id [xsearch $pt -get @id]
            if {$id eq ""} { error "payload-type missing id" }
            lappend formats $id
            lappend mediaAttrs rtpmap [jinglesdp::PayloadTypeToSdp $pt]

            set params [xsearch $pt parameter -gather node]
            if {[llength $params] >= 1} {
                lappend mediaAttrs fmtp [jinglesdp::ParamsToFmtp $id $params]
            }
            xsearch $pt rtcp-fb -script fb {
                lappend mediaAttrs rtcp-fb [jinglesdp::FbToSdp $id $fb]
            }
            xsearch $pt rtcp-fb-trr-int -script fb {
                lappend mediaAttrs rtcp-fb "$id trr-int [xsearch $fb -get @value]"
            }
        }

        xsearch $description rtcp-fb -script fb {
            lappend mediaAttrs rtcp-fb [jinglesdp::FbToSdp "*" $fb]
        }
        xsearch $description rtcp-fb-trr-int -script fb {
            lappend mediaAttrs rtcp-fb "* trr-int [xsearch $fb -get @value]"
        }

        xsearch $description rtp-hdrext -script ext {
            set extId [xsearch $ext -get @id]
            set uri [xsearch $ext -get @uri]
            if {$extId eq "" || $uri eq ""} {
                error "rtp-hdrext missing id or uri"
            }
            lappend mediaAttrs extmap "$extId $uri"
        }
        if {[llength [xsearch $description extmap-allow-mixed]] > 0} {
            lappend mediaAttrs extmap-allow-mixed ""
        }

        xsearch $description ssrc-group -script sg {
            set sem [xsearch $sg -get @semantics]
            set ssrcs [xsearch $sg source -gather @ssrc]
            lappend mediaAttrs ssrc-group "$sem [join $ssrcs { }]"
        }

        xsearch $description source -script src {
            set sid [xsearch $src -get @ssrc]
            xsearch $src parameter -script p {
                set pn [xsearch $p -get @name]
                set pv [xsearch $p -get @value]
                if {$pv eq ""} {
                    lappend mediaAttrs ssrc "$sid $pn"
                } else {
                    lappend mediaAttrs ssrc "$sid $pn:$pv"
                }
            }
        }

        lappend mediaAttrs mid $name
        lappend mediaAttrs [senders_to_sdp $sendersAttr $opts(-initiator)] ""

        if {[llength [xsearch $description rtcp-mux -ns $NS_RTP]] > 0 || $group ne ""} {
            lappend mediaAttrs rtcp-mux ""
        }
        lappend mediaAttrs rtcp "9 IN IP4 0.0.0.0"

        xsearch $transport candidate -script cand {
            lappend mediaAttrs candidate [jinglesdp::CandidateToSdp $cand]
        }

        set mediaType [xsearch $description -get @media]
        lappend mediaBlocks [dict create \
            media         $mediaType \
            port          $HARDCODED_MEDIA_PORT \
            protocol      $HARDCODED_MEDIA_PROTOCOL \
            connection    $HARDCODED_CONNECTION \
            formats       $formats \
            attrs         $mediaAttrs]
    }

    set lines {}
    lappend lines "v=0"
    lappend lines "o=$HARDCODED_ORIGIN"
    lappend lines "s=-"
    lappend lines "t=0 0"
    AppendSdpAttrs lines $sessionAttrs

    foreach m $mediaBlocks {
        lappend lines "m=[dict get $m media] [dict get $m port] [dict get $m protocol] [join [dict get $m formats] { }]"
        lappend lines "c=[dict get $m connection]"
        AppendSdpAttrs lines [dict get $m attrs]
    }

    return [join $lines $LINE_DIVIDER]$LINE_DIVIDER
}

proc jinglesdp::AppendSdpAttrs {linesVar mm} {
    upvar 1 $linesVar lines
    foreach {k v} $mm {
        if {$v eq ""} {
            lappend lines "a=$k"
        } else {
            lappend lines "a=$k:$v"
        }
    }
}

proc jinglesdp::AppendTransportAttrs {transport mmVar} {
    variable NS_DTLS
    variable NS_ICE_OPTION
    variable ICE_OPTION_WELL_KNOWN
    variable HARDCODED_ICE_OPTIONS
    upvar 1 $mmVar mm

    set ufrag [xsearch $transport -get @ufrag]
    set pwd [xsearch $transport -get @pwd]
    if {$ufrag eq ""} { error "transport missing ufrag" }
    if {$pwd eq ""}   { error "transport missing pwd" }
    lappend mm ice-ufrag $ufrag
    lappend mm ice-pwd $pwd

    set iceOptions {}
    foreach c [xsearch $transport * -ns $NS_ICE_OPTION -gather node] {
        set name [dict get $c tag]
        if {[lsearch -exact $ICE_OPTION_WELL_KNOWN $name] >= 0} {
            lappend iceOptions $name
        }
    }
    if {[llength $iceOptions] == 0} { set iceOptions $HARDCODED_ICE_OPTIONS }
    lappend mm ice-options [join $iceOptions { }]

    set fp [xsearch $transport fingerprint -ns $NS_DTLS -get node]
    if {$fp ne ""} {
        set hash [xsearch $fp -get @hash]
        set body [xsearch $fp -get body]
        if {$hash eq "" || $body eq ""} { error "DTLS-SRTP missing hash" }
        lappend mm fingerprint "$hash $body"
        set setup [xsearch $fp -get @setup]
        if {$setup ne ""} { lappend mm setup $setup }
    }
}

proc jinglesdp::PayloadTypeToSdp {pt} {
    set id [xsearch $pt -get @id]
    set name [xsearch $pt -get @name]
    set clock [xsearch $pt -get @clockrate]
    set channels [xsearch $pt -get @channels]
    if {$name eq ""} { error "payload-type missing name" }
    if {$channels eq "" || $channels == 1} {
        return "$id $name/$clock"
    } else {
        return "$id $name/$clock/$channels"
    }
}

proc jinglesdp::FbToSdp {id fb} {
    set type [xsearch $fb -get @type]
    set sub [xsearch $fb -get @subtype]
    if {$type eq ""} { error "rtcp-fb missing type" }
    if {$sub eq ""} {
        return "$id $type"
    } else {
        return "$id $type $sub"
    }
}

proc jinglesdp::ParamsToFmtp {id params} {
    if {[llength $params] == 1} {
        set p [lindex $params 0]
        set name [xsearch $p -get @name]
        set value [xsearch $p -get @value]
        if {$name eq ""} {
            return "$id $value"
        } else {
            return "$id $name=$value"
        }
    }
    set parts {}
    foreach p $params {
        set name [xsearch $p -get @name]
        set value [xsearch $p -get @value]
        if {$name eq "" || $value eq ""} { error "fmtp parameter missing name or value" }
        lappend parts "$name=$value"
    }
    return "$id [join $parts {;}]"
}

proc jinglesdp::CandidateToSdp {cand} {
    set foundation [xsearch $cand -get @foundation]
    set component [xsearch $cand -get @component]
    set protocol [string tolower [xsearch $cand -get @protocol]]
    set priority [xsearch $cand -get @priority]
    set ip [xsearch $cand -get @ip]
    set port [xsearch $cand -get @port]
    foreach var {foundation component protocol priority ip port} {
        if {[set $var] eq ""} { error "candidate missing $var" }
    }
    if {$protocol ne "udp"} {
        error "'$protocol' is not a supported protocol"
    }
    set extra {}
    set type [xsearch $cand -get @type]
    if {$type ne ""} { lappend extra typ $type }
    set relAddr [xsearch $cand -get @rel-addr]
    if {$relAddr ne ""} { lappend extra raddr $relAddr }
    set relPort [xsearch $cand -get @rel-port]
    if {$relPort ne ""} { lappend extra rport $relPort }
    set generation [xsearch $cand -get @generation]
    if {$generation ne ""} { lappend extra generation $generation }
    return "$foundation $component $protocol $priority $ip $port [join $extra { }]"
}

# --- from_sdp: SDP string -> jingle stanza --------------------------------

proc jinglesdp::from_sdp {sdp args} {
    variable NS_JINGLE
    variable NS_GROUPING

    array set opts {-creator initiator -initiator 1}
    array set opts $args

    set parsed [ParseSdp $sdp]
    set sessionAttrs [dict get $parsed attrs]
    set mediaList [dict get $parsed media]

    set groupVal [mm_first $sessionAttrs group]
    set groupSem ""
    set groupTags {}
    if {$groupVal ne ""} {
        set parts [split $groupVal " "]
        if {[llength $parts] >= 2} {
            set groupSem [lindex $parts 0]
            set groupTags [lrange $parts 1 end]
        }
    }

    j jingle -ns $NS_JINGLE {
        if {$groupSem ne ""} {
            j group -ns $NS_GROUPING -semantics $groupSem {
                foreach name $groupTags {
                    j content -ns $NS_GROUPING -name $name
                }
            }
        }
        foreach media $mediaList {
            j #as-is [BuildContent $media $sessionAttrs \
                $opts(-creator) $opts(-initiator)]
        }
    }
}

# Parse a raw SDP string into {attrs {} media {{...} {...}}} with each media
# block carrying its own media/port/protocol/formats/connection/attrs.
proc jinglesdp::ParseSdp {sdp} {
    set sessionAttrs {}
    set media {}
    set curMedia ""
    set curAttrs {}

    foreach rawLine [split $sdp "\n"] {
        set line [string trimright $rawLine "\r"]
        if {[string length $line] < 2 || [string index $line 1] ne "="} continue
        set key [string index $line 0]
        set value [string range $line 2 end]
        switch -- $key {
            c {
                if {$curMedia eq ""} continue
                dict set curMedia connection $value
            }
            a {
                set pair [split $value ":"]
                set k [lindex $pair 0]
                if {[llength $pair] >= 2} {
                    set v [join [lrange $pair 1 end] ":"]
                } else {
                    set v ""
                }
                if {$curMedia eq ""} {
                    lappend sessionAttrs $k $v
                } else {
                    lappend curAttrs $k $v
                }
            }
            m {
                if {$curMedia ne ""} {
                    dict set curMedia attrs $curAttrs
                    lappend media $curMedia
                }
                set parts [split $value " "]
                set curMedia [dict create \
                    media [lindex $parts 0] \
                    port [lindex $parts 1] \
                    protocol [lindex $parts 2] \
                    formats [lrange $parts 3 end] \
                    connection "" \
                    attrs {}]
                set curAttrs {}
            }
        }
    }
    if {$curMedia ne ""} {
        dict set curMedia attrs $curAttrs
        lappend media $curMedia
    }
    return [dict create attrs $sessionAttrs media $media]
}

# Build a <content> node from one parsed media block.
proc jinglesdp::BuildContent {media sessionAttrs creator initiator} {
    variable NS_JINGLE

    set mediaAttrs [dict get $media attrs]
    set name [mm_first $mediaAttrs mid [dict get $media media]]
    set senders [senders_from_mm $mediaAttrs $initiator]

    set sendersOpts {}
    if {$senders ne "both"} { lappend sendersOpts -senders $senders }

    j content -ns $NS_JINGLE -creator $creator -name $name {*}$sendersOpts {
        j #as-is [BuildDescription $media]
        j #as-is [BuildTransport $media $sessionAttrs]
    }
}

# Build the <description xmlns='...rtp:1'> child.
proc jinglesdp::BuildDescription {media} {
    variable NS_RTP
    variable NS_RTP_HDREXT
    variable NS_RTP_FEEDBACK
    variable NS_RTP_SSMA

    set mediaAttrs [dict get $media attrs]

    # Collect rtcp-fb by payload id (or "*" for description-level)
    set fbMap {}
    foreach val [mm_get_all $mediaAttrs rtcp-fb] {
        set parts [split $val " "]
        if {[llength $parts] < 2} continue
        set id [lindex $parts 0]
        set type [lindex $parts 1]
        set sub [expr {[llength $parts] >= 3 ? [lindex $parts 2] : ""}]
        if {$type eq "trr-int" && $sub ne ""} {
            set fb [j rtcp-fb-trr-int -ns $NS_RTP_FEEDBACK -value $sub]
        } else {
            if {$sub eq ""} {
                set fb [j rtcp-fb -ns $NS_RTP_FEEDBACK -type $type]
            } else {
                set fb [j rtcp-fb -ns $NS_RTP_FEEDBACK -type $type -subtype $sub]
            }
        }
        dict lappend fbMap $id $fb
    }

    # Collect fmtp parameters per payload id
    set fmtpMap {}
    foreach val [mm_get_all $mediaAttrs fmtp] {
        set sp [split $val " "]
        if {[llength $sp] < 2} continue
        set id [lindex $sp 0]
        set rest [join [lrange $sp 1 end] " "]
        set params {}
        foreach pair [split $rest ";"] {
            set kv [split $pair "="]
            if {[llength $kv] == 2} {
                lappend params [j parameter -ns $NS_RTP \
                    -name [lindex $kv 0] -value [lindex $kv 1]]
            }
        }
        dict set fmtpMap $id $params
    }

    j description -ns $NS_RTP -media [dict get $media media] {
        if {[dict exists $fbMap "*"]} {
            foreach fb [dict get $fbMap "*"] { j #as-is $fb }
        }

        foreach rtpmap [mm_get_all $mediaAttrs rtpmap] {
            set pair [split $rtpmap " "]
            if {[llength $pair] < 2} continue
            set id [lindex $pair 0]
            set sp [split [lindex $pair 1] "/"]
            if {[llength $sp] < 2} continue
            set ptName [lindex $sp 0]
            set clock [lindex $sp 1]
            set channels [expr {[llength $sp] >= 3 ? [lindex $sp 2] : 1}]
            set chanOpt {}
            if {$channels != 1} { set chanOpt [list -channels $channels] }
            j payload-type -id $id -name $ptName -clockrate $clock {*}$chanOpt {
                if {[dict exists $fmtpMap $id]} {
                    foreach p [dict get $fmtpMap $id] { j #as-is $p }
                }
                if {[dict exists $fbMap $id]} {
                    foreach fb [dict get $fbMap $id] { j #as-is $fb }
                }
            }
        }

        foreach extval [mm_get_all $mediaAttrs extmap] {
            set sp [split $extval " "]
            if {[llength $sp] < 2} continue
            j rtp-hdrext -ns $NS_RTP_HDREXT \
                -id [lindex $sp 0] -uri [join [lrange $sp 1 end] " "]
        }
        if {[mm_has $mediaAttrs extmap-allow-mixed]} {
            j extmap-allow-mixed -ns $NS_RTP_HDREXT
        }

        foreach val [mm_get_all $mediaAttrs ssrc-group] {
            set sp [split $val " "]
            if {[llength $sp] < 2} continue
            j ssrc-group -ns $NS_RTP_SSMA -semantics [lindex $sp 0] {
                foreach ssrc [lrange $sp 1 end] {
                    j source -ssrc $ssrc
                }
            }
        }

        set sourceMap {}
        set sourceOrder {}
        foreach val [mm_get_all $mediaAttrs ssrc] {
            set sp [split $val " "]
            if {[llength $sp] < 2} continue
            set sid [lindex $sp 0]
            set rest [join [lrange $sp 1 end] " "]
            set kv [split $rest ":"]
            set pn [lindex $kv 0]
            set pv [expr {[llength $kv] >= 2 ? [join [lrange $kv 1 end] ":"] : ""}]
            if {![dict exists $sourceMap $sid]} {
                lappend sourceOrder $sid
                dict set sourceMap $sid {}
            }
            if {$pv eq ""} {
                set p [j parameter -name $pn]
            } else {
                set p [j parameter -name $pn -value $pv]
            }
            set existing [dict get $sourceMap $sid]
            lappend existing $p
            dict set sourceMap $sid $existing
        }
        foreach sid $sourceOrder {
            j source -ns $NS_RTP_SSMA -ssrc $sid {
                foreach p [dict get $sourceMap $sid] { j #as-is $p }
            }
        }

        if {[mm_has $mediaAttrs rtcp-mux]} {
            j rtcp-mux -ns $NS_RTP
        }
    }
}

# Build the <transport xmlns='...ice-udp:1'> child.
proc jinglesdp::BuildTransport {media sessionAttrs} {
    variable NS_ICE_UDP
    variable NS_DTLS
    variable NS_ICE_OPTION
    variable ICE_OPTION_WELL_KNOWN

    set mediaAttrs [dict get $media attrs]
    set ufrag [mm_first $mediaAttrs ice-ufrag]
    set pwd [mm_first $mediaAttrs ice-pwd]
    set fpRaw [mm_first $mediaAttrs fingerprint [mm_first $sessionAttrs fingerprint]]
    set setupVal [mm_first $mediaAttrs setup [mm_first $sessionAttrs setup]]
    set iceOptions [mm_first $mediaAttrs ice-options]

    set tOpts {}
    if {$ufrag ne ""} { lappend tOpts -ufrag $ufrag }
    if {$pwd ne ""}   { lappend tOpts -pwd $pwd }

    j transport -ns $NS_ICE_UDP {*}$tOpts {
        if {$fpRaw ne "" && $setupVal ne ""} {
            set sp [split $fpRaw " "]
            if {[llength $sp] >= 2} {
                set hash [lindex $sp 0]
                set body [join [lrange $sp 1 end] " "]
                j fingerprint -ns $NS_DTLS -hash $hash -setup $setupVal #body $body
            }
        }
        if {$iceOptions ne ""} {
            foreach opt [split $iceOptions " "] {
                if {[lsearch -exact $ICE_OPTION_WELL_KNOWN $opt] < 0} continue
                j $opt -ns $NS_ICE_OPTION
            }
        }
        foreach val [mm_get_all $mediaAttrs candidate] {
            set cand [BuildCandidate $val]
            if {$cand ne ""} { j #as-is $cand }
        }
    }
}

proc jinglesdp::BuildCandidate {value} {
    variable NS_ICE_UDP
    variable _candidateCounter

    set parts [split $value " "]
    if {[llength $parts] < 6} { return "" }
    set extraOpts {}
    set extra [lrange $parts 6 end]
    for {set i 0} {$i < [llength $extra] - 1} {incr i 2} {
        set k [lindex $extra $i]
        set v [lindex $extra [expr {$i+1}]]
        switch -- $k {
            typ        { lappend extraOpts -type $v }
            raddr      { lappend extraOpts -rel-addr $v }
            rport      { lappend extraOpts -rel-port $v }
            generation { lappend extraOpts -generation $v }
        }
    }
    j candidate -ns $NS_ICE_UDP \
        -foundation [lindex $parts 0] \
        -component [lindex $parts 1] \
        -protocol [string tolower [lindex $parts 2]] \
        -priority [lindex $parts 3] \
        -ip [lindex $parts 4] \
        -port [lindex $parts 5] \
        -id "cand[incr _candidateCounter]" \
        {*}$extraOpts
}
