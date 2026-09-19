# enrich_store_message turns a store dict into what chatarea draws. Author
# names reach it through a resolver (authornames in production), so these use a
# resolver that shouts, making it obvious which values went through it.

proc md_store {args} {
    dict merge {
        from_jid alice@example.com
        timestamp 100
        server_status ""
        content {type text body hi}
    } $args
}

proc md_shout {jid} { string toupper $jid }

test messagedict-author-goes-through-the-resolver {display_name is resolved, not the raw JID} \
    -body {
        dict get [enrich_store_message [md_store] md_shout] display_name
    } -result ALICE@EXAMPLE.COM

test messagedict-reply-author-goes-through-the-resolver {a reply's author resolves the same way a message author does} \
    -body {
        set d [enrich_store_message [md_store \
            reply_id m1 reply_to bob@example.com \
            reply_author_jid room@conf.example.com/bob] md_shout]
        dict get $d reply_author
    } -result ROOM@CONF.EXAMPLE.COM/BOB

test messagedict-reply-author-defaults-to-reply-to {with no reply_author_jid the reply_to JID is resolved instead} \
    -body {
        set d [enrich_store_message [md_store \
            reply_id m1 reply_to bob@example.com] md_shout]
        dict get $d reply_author
    } -result BOB@EXAMPLE.COM

test messagedict-key-and-sort-are-the-timestamp {a single chat identifies and places rows by timestamp} \
    -body {
        set d [enrich_store_message [md_store timestamp 1700] md_shout]
        list [dict get $d key] [dict get $d sort]
    } -result {1700 1700}

test messagedict-media-content-splits-into-caption-and-attachments {a media payload draws as a caption plus attachments, not a body} \
    -body {
        set d [enrich_store_message [md_store content {
            type media caption "look" attachments {{type image url /tmp/a.png name a.png}}
        }] md_shout]
        list [dict get $d caption] [llength [dict get $d attachments]] [dict get $d body]
    } -result {look 1 {}}

# -- message_preview: the one-line reading of a chat's newest message --------

test preview-1to1-incoming-is-bare {a peer's message in a 1:1 is just its text} \
    -body {
        message_preview [md_store is_outgoing 0] 0
    } -result hi

test preview-outgoing-says-you {your own message is prefixed You:} \
    -body {
        message_preview [md_store is_outgoing 1] 0
    } -result {You: hi}

test preview-groupchat-names-the-nick {a room-mate's message is prefixed with their nick} \
    -body {
        message_preview [md_store from_jid room@conf.example.com/bob is_outgoing 0] 1
    } -result {bob: hi}

test preview-groupchat-own-still-says-you {your own room message says You, not your nick} \
    -body {
        message_preview [md_store from_jid room@conf.example.com/me is_outgoing 1] 1
    } -result {You: hi}

test preview-tombstone {a retracted message reads as deleted} \
    -body {
        message_preview [dict remove [md_store retracted 1 is_outgoing 1] content] 0
    } -result {You: Message deleted}

test preview-media-caption-wins {a captioned attachment previews its caption} \
    -body {
        message_preview [md_store content {
            type media caption "the roof" attachments {{type image name roof.jpg}}
        }] 0
    } -result {the roof}

test preview-photo {a caption-less image reads as Photo} \
    -body {
        message_preview [md_store content {
            type media caption "" attachments {{type image name roof.jpg}}
        }] 0
    } -result Photo

test preview-file-by-name {a caption-less file reads as its name} \
    -body {
        message_preview [md_store content {
            type media caption "" attachments {{type file name notes.pdf}}
        }] 0
    } -result notes.pdf

test preview-several-attachments-count {more than one attachment is counted} \
    -body {
        message_preview [md_store content {
            type media caption "" attachments {{type image name a.png} {type file name b.pdf}}
        }] 0
    } -result {2 attachments}

test preview-one-line {newlines and runs of whitespace collapse to one line} \
    -body {
        message_preview [md_store content {type text body "first\n\n  second\tline "}] 0
    } -result {first second line}

test preview-truncates {a long body is cut with an ellipsis at the limit} \
    -body {
        set body [string repeat x 100]
        set p [message_preview [md_store content [list type text body $body]] 0 20]
        list [string length $p] [string index $p end]
    } -result [list 20 …]
