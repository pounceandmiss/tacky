# XEP-0461 Message Replies + XEP-0428 Fallback Indication
#
# Public procs:
#   reply::parse msgNode          -> {id to}  ('' '' when not a reply)
#   reply::strip_fallback node b  -> body with the quoted-reply span(s) dropped
#   reply::quote_end body end     -> where a reply's quote ends, `end` read
#                                     in the unit that closes a line
#   reply::quote quoteBody        -> {prefix len}  outgoing "> " quote + its
#                                     codepoint length (the XEP-0428 fallback end)
#   reply::pick_id isMuc serverId originId ownId -> the id a peer resolves against
#
# quote and strip_fallback are inverses: quote prepends the fallback span,
# strip_fallback removes it.

namespace eval reply {
    namespace export parse strip_fallback quote_end quote pick_id
}

# Extract {reply_id reply_to} from a <message> node, or {"" ""}.
proc reply::parse {msgNode} {
    set replyNode [lindex [xsearch $msgNode reply -ns urn:xmpp:reply:0] 0]
    if {$replyNode eq ""} {
        return [list "" ""]
    }
    list [xsearch $replyNode -get @id] [xsearch $replyNode -get @to]
}

# Drop the quoted-reply fallback span(s) from a reply body. start/end are
# codepoint indices, end-exclusive; spans are removed right-to-left so
# earlier indices stay valid. A span from 0 may end in another unit
# (reply::quote_end).
proc reply::strip_fallback {msgNode body} {
    set ranges {}
    foreach fb [xsearch $msgNode fallback -ns urn:xmpp:fallback:0] {
        if {[xsearch $fb -get @for] ne "urn:xmpp:reply:0"} continue
        foreach b [xsearch $fb body] {
            set start [xsearch $b -get @start]
            set end   [xsearch $b -get @end]
            if {$start eq ""} { set start 0 }
            if {$end eq ""}   { set end [string length $body] }
            if {![string is integer -strict $start]
                || ![string is integer -strict $end]} continue
            if {$start == 0} { set end [reply::quote_end $body $end] }
            lappend ranges [list $start $end]
        }
    }
    foreach r [lsort -integer -index 0 -decreasing $ranges] {
        lassign $r start end
        if {$start < 0} { set start 0 }
        if {$end > [string length $body]} { set end [string length $body] }
        if {$start >= $end} continue
        set body [string replace $body $start [expr {$end - 1}]]
    }
    return $body
}

# Where a reply's quote ends in `body`, given the `end` its fallback names.
#
# A compatibility workaround, not the protocol: XEP-0428 counts code points,
# but QXmpp (and so Kaidan) counts QString length, UTF-16 code units, and a
# client counting UTF-8 bytes would be wrong the same way. Read as code
# points, such an end cuts a quote with emoji in it into the reply's own
# words.
#
# `end` stands when it closes a line of the body (the quote is whole lines,
# ending in a newline), which a conforming client's always does. When it
# does not, it is read as UTF-16 code units and then as UTF-8 bytes, and the
# first reading that closes a line is taken. With no reading closing a
# line, `end` stands as sent.
proc reply::quote_end {body end} {
    set len [string length $body]
    if {$end > 0 && $end < $len
            && [string index $body [expr {$end - 1}]] eq "\n"} {
        return $end
    }
    foreach unit {utf16 utf8} {
        set n 0
        set i 0
        foreach ch [split $body ""] {
            if {$n >= $end} break
            set c [scan $ch %c]
            if {$unit eq "utf16"} {
                incr n [expr {$c > 0xFFFF ? 2 : 1}]
            } else {
                incr n [expr {$c < 0x80 ? 1 : $c < 0x800 ? 2
                    : $c < 0x10000 ? 3 : 4}]
            }
            incr i
        }
        if {$n == $end && $i > 0 && $i < $len
                && [string index $body [expr {$i - 1}]] eq "\n"} {
            return $i
        }
    }
    return $end
}

# Build the "> "-prefixed quote of the replied-to body for the outgoing wire
# message. Returns {prefix len}: len is the prefix codepoint length, which is
# the end offset of the XEP-0428 fallback span.
proc reply::quote {quoteBody} {
    set prefix ""
    foreach line [split $quoteBody \n] {
        append prefix "> $line\n"
    }
    return [list $prefix [string length $prefix]]
}

# Reply id another client resolves against, by chat kind: MUC uses the
# stanza-id (server_id), and only it: occupants match nothing else, so our
# own send before its echo has none to give. 1:1 uses the origin-id, since
# peers never see our server id, falling through to the next id when one
# is absent.
proc reply::pick_id {isMuc serverId originId ownId} {
    if {$isMuc} { return $serverId }
    foreach c [list $originId $ownId $serverId] {
        if {$c ne ""} { return $c }
    }
    return ""
}
