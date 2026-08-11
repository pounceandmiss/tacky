# Store-dict helpers shared by chatview and searchwindow.

# The user-visible text of a stored message dict: a text message's body or a
# media message's caption; "" for a tombstone or a caption-less attachment.
proc message_text {storeDict} {
    if {![dict exists $storeDict content]} { return "" }
    set content [dict get $storeDict content]
    switch -- [dict get $content type] {
        media { return [dict get $content caption] }
        text  { return [dict get $content body] }
    }
    return ""
}

# Shared enrichment: converts a store dict (from_jid, server_status,
# timestamp, body, etc.) into the display dict that chatarea expects.
# `resolve` is a command prefix called as {*}$resolve $jid, returning what to
# call that author - see authornames.
proc enrich_store_message {storeDict resolve} {
    set fromJid [dict get $storeDict from_jid]
    set displayName [{*}$resolve $fromJid]
    set serverStatus [dict get $storeDict server_status]
    set remoteStatus [expr {[dict exists $storeDict remote_status]
        ? [dict get $storeDict remote_status] : "none"}]
    # Direction comes from the backend (own_id-derived); the view doesn't
    # re-derive it. Older dicts without the flag fall back to "incoming".
    set isOutgoing [expr {[dict exists $storeDict is_outgoing]
        && [dict get $storeDict is_outgoing]}]
    # `key` identifies the row, `sort` places it. Both are the timestamp,
    # which is unique within one chat; a caller drawing several chats into
    # one area overrides `key` with something that separates them.
    set d [dict create \
        key          [dict get $storeDict timestamp] \
        sort         [dict get $storeDict timestamp] \
        from_jid     $fromJid \
        display_name $displayName \
        avatar_jid   $fromJid \
        timestamp    [dict get $storeDict timestamp] \
        body         "" \
        is_outgoing  $isOutgoing \
        server_status $serverStatus \
        remote_status $remoteStatus \
        encryption   [expr {[dict exists $storeDict encryption] ? [dict get $storeDict encryption] : ""}] \
        fail_reason  [expr {[dict exists $storeDict fail_reason] ? [dict get $storeDict fail_reason] : ""}]]
    # XEP-0308/0424 state (backend booleans). A retracted message renders as
    # a tombstone; an edited one gets an "(edited)" marker.
    dict set d edited [expr {[dict exists $storeDict edited]
        && [dict get $storeDict edited]}]
    dict set d retracted [expr {[dict exists $storeDict retracted]
        && [dict get $storeDict retracted]}]
    # Typed content union (payload kind). Absent on a retracted tombstone,
    # which DrawMessage handles via the `retracted` flag before reading content.
    if {[dict exists $storeDict content]} {
        set content [dict get $storeDict content]
        if {[dict get $content type] eq "media"} {
            dict set d attachments [dict get $content attachments]
            dict set d caption [dict get $content caption]
        } else {
            dict set d body [dict get $content body]
        }
        if {[dict exists $content formatting]} {
            dict set d formatting [dict get $content formatting]
        }
        # Search hits only: where the query matched, in formatting's offsets.
        if {[dict exists $content matches]} {
            dict set d matches [dict get $content matches]
        }
    }
    if {[dict exists $storeDict reply_id] && [dict get $storeDict reply_id] ne ""} {
        set rto [dict get $storeDict reply_to]
        dict set d reply_id [dict get $storeDict reply_id]
        dict set d reply_to $rto
        # reply_author_jid is normalized by the backend (nick for MUC, bare for
        # 1:1), so it resolves the same way an author does.
        set raj [expr {[dict exists $storeDict reply_author_jid]
            ? [dict get $storeDict reply_author_jid] : $rto}]
        set ra [expr {$raj eq "" ? $rto : [{*}$resolve $raj]}]
        dict set d reply_author $ra
        if {[dict exists $storeDict reply_body]} {
            dict set d reply_body [dict get $storeDict reply_body]
        }
    }
    # XEP-0444 reactions: backend hands per-emoji {reactors mine}; the count
    # is derived from the reactor list at render time.
    if {[dict exists $storeDict reactions]
        && [dict size [dict get $storeDict reactions]] > 0} {
        dict set d reactions [dict get $storeDict reactions]
    }
    return $d
}
