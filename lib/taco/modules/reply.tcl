# XEP-0461 Message Replies + XEP-0428 Fallback Indication
#
# Public procs:
#   reply::parse msgNode          -> {id to}  ('' '' when not a reply)
#   reply::strip_fallback node b  -> body with the quoted-reply span(s) dropped
#   reply::quote quoteBody        -> {prefix len}  outgoing "> " quote + its
#                                     codepoint length (the XEP-0428 fallback end)
#   reply::pick_id isMuc serverId originId ownId -> the id a peer resolves against
#
# quote and strip_fallback are inverses: quote prepends the fallback span,
# strip_fallback removes it.

namespace eval reply {
    namespace export parse strip_fallback quote pick_id
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
# earlier indices stay valid.
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
# stanza-id (server_id); 1:1 uses the origin-id, since peers never see our
# server id. Falls through to the next id when one is absent (our own pending
# send has no server_id yet).
proc reply::pick_id {isMuc serverId originId ownId} {
    if {$isMuc} {
        set candidates [list $serverId $originId $ownId]
    } else {
        set candidates [list $originId $ownId $serverId]
    }
    foreach c $candidates {
        if {$c ne ""} { return $c }
    }
    return ""
}
