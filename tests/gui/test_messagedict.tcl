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
