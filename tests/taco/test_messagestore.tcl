# Unit tests for taco_messagestore

set ms_common {
    -setup {
	sqlite3 testdb :memory:
	taco_messagestore create store -db testdb
    }
    -cleanup {
	store destroy
	testdb close
    }
}

# Helper: build a message dict with defaults
proc ms_msg {args} {
    set defaults {
	timestamp 1000000 chat_jid alice@example.com
	from_jid alice@example.com/phone body hello
	server_id "" origin_id "" raw_xml ""
    }
    return [dict merge $defaults $args]
}

# Helper: store a batch with a fresh region
proc ms_batch {messages {jid alice@example.com}} {
    store region new r
    store store batch $messages r
}

# Helper: count distinct regions for a jid
proc ms_regions {{jid alice@example.com}} {
    testdb eval {SELECT COUNT(DISTINCT region) FROM chat_message WHERE chat_jid=$jid}
}

# -- basic --------------------------------------------------------------------

test messagestore-basic-store-and-get {store a batch, get it back in chronological order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body first] \
	    [ms_msg timestamp 200 body second] \
	    [ms_msg timestamp 300 body third]]
	set msgs [store get alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {first second third}

test messagestore-basic-timestamp-bump {identical timestamps are bumped +1 preserving insertion order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 100 body b] \
	    [ms_msg timestamp 100 body c]]
	set msgs [store get alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {a b c}

# -- dedup --------------------------------------------------------------------

test messagestore-dedup-server-id {duplicate server_id is not inserted twice} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id sid1 body first]]
	ms_batch [list \
	    [ms_msg timestamp 200 server_id sid1 body duplicate]]
	llength [store get alice@example.com]
    } -result {1}

test messagestore-dedup-origin-id {duplicate origin_id is not inserted twice} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 origin_id oid1 body first]]
	ms_batch [list \
	    [ms_msg timestamp 200 origin_id oid1 body duplicate]]
	llength [store get alice@example.com]
    } -result {1}

test messagestore-dedup-content-same-batch {content dedup within batch when IDs empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id "" origin_id "" body hello] \
	    [ms_msg timestamp 100 server_id "" origin_id "" body hello]]
	llength [store get alice@example.com]
    } -result {1}

test messagestore-dedup-content-across-batches {content dedup across batches when IDs empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body hello] \
	    [ms_msg timestamp 200 body world]]
	ms_batch [list \
	    [ms_msg timestamp 100 body hello] \
	    [ms_msg timestamp 200 body world]]
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}
    } -result {2}

test messagestore-dedup-content-merges-regions {content dedup merges regions like server_id dedup} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body hello] \
	    [ms_msg timestamp 200 body world]]
	ms_batch [list \
	    [ms_msg timestamp 100 body hello] \
	    [ms_msg timestamp 200 body world]]
	ms_regions
    } -result {1}

test messagestore-dedup-content-different-body-not-deduped {same timestamp different body not falsely deduped} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body hello]]
	ms_batch [list \
	    [ms_msg timestamp 100 body goodbye]]
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}
    } -result {2}

test messagestore-dedup-content-different-from-not-deduped {same timestamp+body different sender not falsely deduped} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 from_jid alice@example.com/phone body hello]]
	ms_batch [list \
	    [ms_msg timestamp 100 from_jid bob@example.com/phone body hello]]
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}
    } -result {2}

test messagestore-dedup-isolation-across-chats {same origin_id in different chats stored independently} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com origin_id oid1 body hi]]
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid bob@example.com origin_id oid1 body hi]] bob@example.com
	set a [llength [store get alice@example.com]]
	set b [llength [store get bob@example.com]]
	list $a $b
    } -result {1 1}

test messagestore-dedup-both-ids-match-server {both IDs set, dedup fires on server_id match} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id sid1 origin_id oid1 body first]]
	ms_batch [list \
	    [ms_msg timestamp 200 server_id sid1 origin_id oid_other body dup]]
	llength [store get alice@example.com]
    } -result {1}

test messagestore-dedup-both-ids-match-origin {both IDs set, dedup fires on origin_id match} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id sid1 origin_id oid1 body first]]
	ms_batch [list \
	    [ms_msg timestamp 200 server_id sid_other origin_id oid1 body dup]]
	llength [store get alice@example.com]
    } -result {1}

# -- pagination ---------------------------------------------------------------

test messagestore-pagination-before {-before returns messages older than timestamp} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get alice@example.com -before 300]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 a b}

test messagestore-pagination-limit {-limit caps result count} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get alice@example.com -limit 2]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-pagination-after {-after returns messages newer than timestamp, ascending} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get alice@example.com -after 100]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-pagination-after-limit {-after respects -limit} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get alice@example.com -after 100 -limit 1]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body]
    } -result {1 b}

test messagestore-pagination-region-boundary {-before crosses into previous region} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	set latest [store get alice@example.com]
	set older [store get alice@example.com -before 500]
	list [llength $latest] \
	     [dict get [lindex $latest 0] body] \
	     [dict get [lindex $latest 1] body] \
	     [llength $older] \
	     [dict get [lindex $older 0] body] \
	     [dict get [lindex $older 1] body]
    } -result {2 c d 2 a b}

test messagestore-get-limit-larger-than-available {-limit larger than message count returns all} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	llength [store get alice@example.com -limit 1000]
    } -result {3}

test messagestore-get-before-with-limit {-before combined with -limit returns correct slice} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]]
	set msgs [store get alice@example.com -before 400 -limit 2]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

# -- region assignment --------------------------------------------------------

test messagestore-batch-assigns-region {batch assigns all messages to one region} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100] \
	    [ms_msg timestamp 200] \
	    [ms_msg timestamp 300]]
	ms_regions
    } -result {1}

test messagestore-multi-page-same-region {two batches with same region share one region} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]] r
	store store batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]] r
	ms_regions
    } -result {1}

test messagestore-batch-overlapping-merges {overlapping batch via server_id merges regions} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s1] \
	    [ms_msg timestamp 200 server_id s2]]
	ms_batch [list \
	    [ms_msg timestamp 200 server_id s2] \
	    [ms_msg timestamp 300 server_id s3]]
	ms_regions
    } -result {1}

test messagestore-live-assigns-region {single batch assigns one region} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 100]] r
	ms_regions
    } -result {1}

test messagestore-live-same-region {multiple batches with same region var share one region} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 100]] r
	store store batch [list [ms_msg timestamp 200]] r
	store store batch [list [ms_msg timestamp 300]] r
	ms_regions
    } -result {1}

test messagestore-reconnect-different-regions {new region new creates separate region} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 100]] r
	store store batch [list [ms_msg timestamp 200]] r
	store region new r
	store store batch [list [ms_msg timestamp 500]] r
	ms_regions
    } -result {2}

test messagestore-region-new-unique {region new assigns distinct values} \
    {*}$ms_common \
    -body {
	store region new r1
	store region new r2
	expr {$r1 != $r2}
    } -result {1}

# -- bridge -------------------------------------------------------------------

test messagestore-bridge-merges-regions {bridge merges two regions into one} \
    {*}$ms_common \
    -body {
	store region new r1
	store store batch [list [ms_msg timestamp 100 body a] [ms_msg timestamp 200 body b]] r1
	store region new r2
	store store batch [list [ms_msg timestamp 500 body c] [ms_msg timestamp 600 body d]] r2
	store bridge alice@example.com r1 r2
	ms_regions
    } -result {1}

test messagestore-bridge-enables-cross-range-get {after bridge, get returns all messages} \
    {*}$ms_common \
    -body {
	store region new r1
	store store batch [list [ms_msg timestamp 100 body a] [ms_msg timestamp 200 body b]] r1
	store region new r2
	store store batch [list [ms_msg timestamp 500 body c] [ms_msg timestamp 600 body d]] r2
	store bridge alice@example.com r1 r2
	set msgs [store get alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 3] body]
    } -result {4 a d}

test messagestore-bridge-updates-upvar {bridge sets r2 to r1} \
    {*}$ms_common \
    -body {
	store region new r1
	store store batch [list [ms_msg timestamp 100 body a]] r1
	store region new r2
	store store batch [list [ms_msg timestamp 500 body b]] r2
	set orig_r1 $r1
	store bridge alice@example.com r1 r2
	list [expr {$r2 == $orig_r1}] [expr {$r1 == $r2}]
    } -result {1 1}

test messagestore-bridge-noop-same-region {bridge with same region is no-op} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 100 body a]] r
	set r2 $r
	store bridge alice@example.com r r2
	ms_regions
    } -result {1}

# -- server_id driven region merging -----------------------------------------

test messagestore-serverid-dup-merges-regions {server_id dup merges overlapping regions} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s1 body a] \
	    [ms_msg timestamp 200 server_id s2 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 server_id s5 body e] \
	    [ms_msg timestamp 600 server_id s6 body f]]
	ms_batch [list \
	    [ms_msg timestamp 300 server_id s3 body c] \
	    [ms_msg timestamp 400 server_id s4 body d] \
	    [ms_msg timestamp 500 server_id s5 body dup]]
	ms_regions
    } -result {2}

test messagestore-no-serverid-separate-regions {batches without IDs stay separate} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body e] \
	    [ms_msg timestamp 600 body f]]
	ms_batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]]
	ms_regions
    } -result {3}

test messagestore-all-deduped-no-extra {all-dup batch merges regions} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 origin_id oid1 body first]]
	ms_batch [list [ms_msg timestamp 200 origin_id oid1 body duplicate]]
	ms_regions
    } -result {1}

test messagestore-overlap-merges-proven {batch with dup merges into existing region} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 50 server_id s1 body old]]
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s_new body new] \
	    [ms_msg timestamp 200 server_id s1 body dup]]
	ms_regions
    } -result {1}

test messagestore-merge-updates-upvar {dup-triggered merge unifies DB under caller region} \
    {*}$ms_common \
    -body {
	store region new r1
	store store batch [list [ms_msg timestamp 100 server_id s1 body a]] r1
	store region new r2
	store store batch [list \
	    [ms_msg timestamp 200 server_id s_new body b] \
	    [ms_msg timestamp 100 server_id s1 body dup]] r2
	set msgs [store get alice@example.com]
	list [llength $msgs] [ms_regions]
    } -result {2 1}

# -- edge cases: get ---------------------------------------------------------

test messagestore-get-empty-chat {get on a jid with no messages returns empty list} \
    {*}$ms_common \
    -body {
	store get nobody@example.com
    } -result {}

test messagestore-get-before-after-exclusive {-before and -after together raise error} \
    {*}$ms_common \
    -body {
	list [catch {store get alice@example.com -before 200 -after 100} err] $err
    } -result {1 {-before and -after are mutually exclusive}}

test messagestore-get-before-at-region-start {-before at first timestamp returns empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	store get alice@example.com -before 100
    } -result {}

test messagestore-get-after-region-boundary {-after stays within region of nearest message} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	set msgs [store get alice@example.com -after 100]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 b}

test messagestore-get-after-gap {-after in gap crosses into next region} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	set msgs [store get alice@example.com -after 300]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 c d}

test messagestore-get-before-gap {-before in gap crosses into previous region} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	set msgs [store get alice@example.com -before 400]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 a b}

test messagestore-get-no-cursor-multiple-ranges {no cursor returns latest region} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	set msgs [store get alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 c d}

test messagestore-get-after-beyond-all-data {-after beyond all messages returns empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	store get alice@example.com -after 9999
    } -result {}

test messagestore-get-before-below-all-data {-before below all messages returns empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	store get alice@example.com -before 1
    } -result {}

# -- edge cases: store batch / live ------------------------------------------

test messagestore-live-dedup-no-extend {deduped message does not create extra rows} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 100 origin_id oid1 body first]] r
	store store batch [list [ms_msg timestamp 200 origin_id oid1 body duplicate]] r
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com'}
    } -result {1}

test messagestore-batch-out-of-order-timestamps {batch with non-chronological timestamps preserves caller order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	set msgs [store get alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {c a b}

test messagestore-batch-decreasing-timestamps {batch with decreasing timestamps preserves caller order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 300 body x] \
	    [ms_msg timestamp 200 body y] \
	    [ms_msg timestamp 100 body z]]
	set msgs [store get alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {x y z}

test messagestore-batch-bumped-ts-covered {bumped timestamps all retrievable} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 100 body b] \
	    [ms_msg timestamp 100 body c]]
	set msgs [store get alice@example.com -after 100]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-get-after-at-exact-last {-after at exact last timestamp returns empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	store get alice@example.com -after 300
    } -result {}

test messagestore-batch-single-message {single-message batch works} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 42 body only]]
	set msgs [store get alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 only}

test messagestore-empty-batch-noop {empty batch is a no-op} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch {} r
	testdb eval {SELECT count(*) FROM chat_message}
    } -result {0}

test messagestore-live-earlier-timestamp {messages with earlier timestamp in same region are visible} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list [ms_msg timestamp 500 body late]] r
	store store batch [list [ms_msg timestamp 100 body early]] r
	set msgs [store get alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 early late}

test messagestore-multi-batch-all-visible {multiple batches in same region all visible} \
    {*}$ms_common \
    -body {
	store region new r
	store store batch [list \
	    [ms_msg timestamp 1000 body p1a] \
	    [ms_msg timestamp 1010 body p1b]] r
	store store batch [list \
	    [ms_msg timestamp 980 body p2a] \
	    [ms_msg timestamp 990 body p2b]] r
	llength [store get alice@example.com]
    } -result {4}

# -- multi-chat isolation -----------------------------------------------------

test messagestore-multi-chat-isolation {get only returns messages for requested chat} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com body alice-msg]]
	ms_batch [list \
	    [ms_msg timestamp 200 chat_jid bob@example.com body bob-msg]] bob@example.com
	llength [store get alice@example.com]
    } -result {1}

# -- parallel regions --------------------------------------------------------

test messagestore-parallel-regions-overlapping {MAM and live regions stay separate} \
    {*}$ms_common \
    -body {
	store region new mam
	store region new live

	store store batch [list [ms_msg timestamp 500 body live1]] live
	store store batch [list \
	    [ms_msg timestamp 100 server_id s1 body mam1] \
	    [ms_msg timestamp 200 server_id s2 body mam2]] mam
	store store batch [list [ms_msg timestamp 600 body live2]] live
	store store batch [list \
	    [ms_msg timestamp 300 server_id s3 body mam3] \
	    [ms_msg timestamp 400 server_id s4 body mam4]] mam

	set latest [store get alice@example.com]
	set older [store get alice@example.com -before 500]
	list [ms_regions] \
	     [llength $latest] \
	     [dict get [lindex $latest 0] body] \
	     [dict get [lindex $latest 1] body] \
	     [llength $older] \
	     [dict get [lindex $older 0] body] \
	     [dict get [lindex $older 3] body]
    } -result {2 2 live1 live2 4 mam1 mam4}

test messagestore-parallel-regions-bridge-unifies {bridge merges MAM and live regions} \
    {*}$ms_common \
    -body {
	store region new mam
	store region new live

	store store batch [list \
	    [ms_msg timestamp 100 server_id s1 body a] \
	    [ms_msg timestamp 200 server_id s2 body b]] mam
	store store batch [list [ms_msg timestamp 500 body c]] live
	store store batch [list [ms_msg timestamp 600 body d]] live

	store bridge alice@example.com mam live
	set msgs [store get alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 3] body]
    } -result {4 a d}

test messagestore-parallel-multi-chat-isolation {MAM backfill for one chat does not affect another chat} \
    {*}$ms_common \
    -body {
	store region new alice_mam
	store region new alice_live
	store region new bob_live

	# Alice: live message, then MAM backfill
	store store batch [list [ms_msg timestamp 500 chat_jid alice@example.com body alice-live]] alice_live
	store store batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com server_id as1 body alice-mam1] \
	    [ms_msg timestamp 200 chat_jid alice@example.com server_id as2 body alice-mam2]] alice_mam

	# Bob: independent live messages
	store store batch [list \
	    [ms_msg timestamp 300 chat_jid bob@example.com body bob-live1] \
	    [ms_msg timestamp 400 chat_jid bob@example.com body bob-live2]] bob_live

	set alice_latest [store get alice@example.com]
	set alice_older [store get alice@example.com -before 500]
	set bob_msgs [store get bob@example.com]
	list [llength $alice_latest] [dict get [lindex $alice_latest 0] body] \
	     [llength $alice_older] [dict get [lindex $alice_older 0] body] \
	     [llength $bob_msgs] [dict get [lindex $bob_msgs 0] body] [dict get [lindex $bob_msgs 1] body]
    } -result {1 alice-live 2 alice-mam1 2 bob-live1 bob-live2}

test messagestore-parallel-multi-chat-bridge-isolated {bridging one chat does not merge another chat's regions} \
    {*}$ms_common \
    -body {
	store region new alice_mam
	store region new alice_live
	store region new bob_mam
	store region new bob_live

	# Both chats: MAM + live
	store store batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com server_id as1 body alice-old]] alice_mam
	store store batch [list \
	    [ms_msg timestamp 500 chat_jid alice@example.com body alice-new]] alice_live
	store store batch [list \
	    [ms_msg timestamp 100 chat_jid bob@example.com server_id bs1 body bob-old]] bob_mam
	store store batch [list \
	    [ms_msg timestamp 500 chat_jid bob@example.com body bob-new]] bob_live

	# Bridge only alice
	store bridge alice@example.com alice_mam alice_live

	set alice_msgs [store get alice@example.com]
	set bob_latest [store get bob@example.com]
	set bob_older [store get bob@example.com -before 500]
	list [llength $alice_msgs] \
	     [dict get [lindex $alice_msgs 0] body] [dict get [lindex $alice_msgs 1] body] \
	     [llength $bob_latest] [dict get [lindex $bob_latest 0] body] \
	     [llength $bob_older] [dict get [lindex $bob_older 0] body]
    } -result {2 alice-old alice-new 1 bob-new 1 bob-old}

test messagestore-parallel-multi-chat-serverid-merge-isolated {server_id merge in one chat does not affect another} \
    {*}$ms_common \
    -body {
	# Alice: two separate batches that will merge via server_id overlap
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com server_id as1 body alice-a]]
	ms_batch [list \
	    [ms_msg timestamp 200 chat_jid alice@example.com server_id as2 body alice-b] \
	    [ms_msg timestamp 100 chat_jid alice@example.com server_id as1 body alice-dup]]

	# Bob: separate batch that should stay independent
	ms_batch [list \
	    [ms_msg timestamp 300 chat_jid bob@example.com server_id bs1 body bob-x]] bob@example.com

	set alice_msgs [store get alice@example.com]
	set bob_msgs [store get bob@example.com]
	set alice_regions [testdb eval {SELECT COUNT(DISTINCT region) FROM chat_message WHERE chat_jid='alice@example.com'}]
	set bob_regions [testdb eval {SELECT COUNT(DISTINCT region) FROM chat_message WHERE chat_jid='bob@example.com'}]
	list [llength $alice_msgs] $alice_regions \
	     [llength $bob_msgs] $bob_regions
    } -result {2 1 1 1}

# -- row format ---------------------------------------------------------------

test messagestore-row-no-region-key {message dicts do not contain region key} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 body test]]
	set msg [lindex [store get alice@example.com] 0]
	dict exists $msg region
    } -result {0}
