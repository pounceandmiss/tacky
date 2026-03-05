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

# Helper: store a batch with an auto-created span
proc ms_batch {messages {jid alice@example.com}} {
    set sid [store span begin $jid]
    store store batch $messages -span $sid
    store span end $sid
}

# -- basic --------------------------------------------------------------------

test messagestore-basic-store-and-get {store a batch, get it back in chronological order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body first] \
	    [ms_msg timestamp 200 body second] \
	    [ms_msg timestamp 300 body third]]
	set msgs [store get -chat alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {first second third}

test messagestore-basic-timestamp-bump {identical timestamps are bumped +1µs preserving insertion order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 100 body b] \
	    [ms_msg timestamp 100 body c]]
	set msgs [store get -chat alice@example.com]
	# Ascending: a(100) b(101) c(102)
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
	llength [store get -chat alice@example.com]
    } -result {1}

test messagestore-dedup-origin-id {duplicate origin_id is not inserted twice} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 origin_id oid1 body first]]
	ms_batch [list \
	    [ms_msg timestamp 200 origin_id oid1 body duplicate]]
	llength [store get -chat alice@example.com]
    } -result {1}

# -- pagination ---------------------------------------------------------------

test messagestore-pagination-before {-before returns messages older than timestamp} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get -chat alice@example.com -before 300]
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
	set msgs [store get -chat alice@example.com -limit 2]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-pagination-hole-boundary {get stops at hole boundary between separate batches} \
    {*}$ms_common \
    -body {
	# Two separate sessions create holes between them
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	# -before 500: nearest hole below is at 499, so range (499,500) is empty
	set empty [store get -chat alice@example.com -before 500]
	# -before 499: nearest hole below is at 99, so range (99,499) = {100,200}
	set msgs [store get -chat alice@example.com -before 499]
	list [llength $empty] [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {0 2 a b}

# -- hole creation -----------------------------------------------------------

test messagestore-batch-creates-hole {store batch session creates a hole before first batch} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100] \
	    [ms_msg timestamp 200] \
	    [ms_msg timestamp 300]]
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {1}

test messagestore-batch-hole-at-min-minus-one {hole is placed at minTs - 1} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100] \
	    [ms_msg timestamp 200]]
	testdb eval {SELECT timestamp FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {99}

test messagestore-multi-page-session-no-extra-holes {multi-page session creates only one hole} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]] -span $sid
	store store batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]] -span $sid
	store span end $sid
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {1}

test messagestore-batch-overlapping-deletes-hole {overlapping batch session deletes hole in range} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s1] \
	    [ms_msg timestamp 200 server_id s2]]
	# Second batch overlaps — its range [200,300] includes ts 200
	# The new session's hole at 199 is in the first batch range
	ms_batch [list \
	    [ms_msg timestamp 200 server_id s2] \
	    [ms_msg timestamp 300 server_id s3]]
	# After both batches, there should be a hole at 99 and one at 199
	# But the second batch deletes holes in [200,300], hole at 199 survives
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]
	set holes
    } -result {99 199}

# -- live with sessions -------------------------------------------------------

test messagestore-live-creates-hole {store live creates a hole before first message} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100]] -span $sid
	store span end $sid
	testdb eval {SELECT timestamp FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {99}

test messagestore-live-extends-session {multiple live messages in one session create one hole} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100]] -span $sid
	store store batch [list [ms_msg timestamp 200]] -span $sid
	store store batch [list [ms_msg timestamp 300]] -span $sid
	store span end $sid
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {1}

test messagestore-live-reconnect {end+begin creates new hole on reconnect} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100]] -span $sid
	store store batch [list [ms_msg timestamp 200]] -span $sid
	store span end $sid
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 500]] -span $sid
	store span end $sid
	set holes [lsort -integer [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]]
	set holes
    } -result {99 499}

# -- bridge -------------------------------------------------------------------

test messagestore-bridge-deletes-holes {bridge removes holes between two ranges} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 body a] [ms_msg timestamp 200 body b]]
	ms_batch [list [ms_msg timestamp 500 body c] [ms_msg timestamp 600 body d]]
	# Holes at 99 and 499
	store bridge -chat alice@example.com -from-ts 99 -to-ts 499
	# Both holes should be deleted
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {0}

test messagestore-bridge-enables-cross-range-get {after bridge, get crosses former boundary} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 body a] [ms_msg timestamp 200 body b]]
	ms_batch [list [ms_msg timestamp 500 body c] [ms_msg timestamp 600 body d]]
	store bridge -chat alice@example.com -from-ts 99 -to-ts 499
	set msgs [store get -chat alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 3] body]
    } -result {4 a d}

# -- begin/end lifecycle -------------------------------------------------------

test messagestore-begin-returns-unique-ids {begin returns incrementing session ids} \
    {*}$ms_common \
    -body {
	set s1 [store span begin alice@example.com]
	set s2 [store span begin alice@example.com]
	store span end $s1
	store span end $s2
	expr {$s1 != $s2}
    } -result {1}

test messagestore-end-cleans-up {end removes session, begin works after} \
    {*}$ms_common \
    -body {
	set s1 [store span begin alice@example.com]
	store span end $s1
	set s2 [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100]] -span $s2
	store span end $s2
	llength [store get -chat alice@example.com]
    } -result {1}

# -- pagination -after --------------------------------------------------------

test messagestore-pagination-after {-after returns messages newer than timestamp, ascending} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	set msgs [store get -chat alice@example.com -after 100]
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
	set msgs [store get -chat alice@example.com -after 100 -limit 1]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body]
    } -result {1 b}

test messagestore-pagination-after-hole-boundary {-after stops at hole boundary} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	# -after 200: within first range, hole at 499 stops it
	set msgs [store get -chat alice@example.com -after 200]
	# No messages above 200 before the next hole
	llength $msgs
    } -result {0}

# -- edge cases: get ---------------------------------------------------------

test messagestore-get-empty-chat {get on a jid with no messages returns {}} \
    {*}$ms_common \
    -body {
	store get -chat nobody@example.com
    } -result {}

test messagestore-get-before-after-exclusive {-before and -after together raise error} \
    {*}$ms_common \
    -body {
	list [catch {store get -chat alice@example.com -before 200 -after 100} err] $err
    } -result {1 {-before and -after are mutually exclusive}}

test messagestore-get-before-at-hole {-before at exact hole returns {}} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	# Hole is at 99; -before 100 has hole at 99 bounding it, nothing in (99,100)
	store get -chat alice@example.com -before 100
    } -result {}

test messagestore-get-after-gap-between-ranges {-after in gap sees next range} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	# -after 300 is in the gap between hole at 99 and hole at 499
	# No hole between 300 and 499, but hole at 499 blocks
	# Actually: 300 is between the two ranges. The next hole above 300 is at 499.
	# Messages > 300 and < 499 with hole=0: none
	set msgs [store get -chat alice@example.com -after 300]
	llength $msgs
    } -result {0}

test messagestore-get-before-gap-between-ranges {-before in gap sees previous range} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	# -before 400: nearest hole below is at 99, so messages in (99, 400) with hole=0
	set msgs [store get -chat alice@example.com -before 400]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 a b}

test messagestore-get-limit-larger-than-available {-limit larger than message count returns all} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	llength [store get -chat alice@example.com -limit 1000]
    } -result {3}

test messagestore-get-before-with-limit {-before combined with -limit returns correct slice} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]]
	# -before 400 -limit 2: the 2 messages just before 400, ascending
	set msgs [store get -chat alice@example.com -before 400 -limit 2]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

# -- edge cases: dedup -------------------------------------------------------

test messagestore-dedup-no-dedup-empty-ids {no dedup when both server_id and origin_id are empty} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id "" origin_id "" body hello] \
	    [ms_msg timestamp 100 server_id "" origin_id "" body hello]]
	# Both inserted (second gets timestamp bumped), no dedup
	llength [store get -chat alice@example.com]
    } -result {2}

test messagestore-dedup-isolation-across-chats {same origin_id in different chats stored independently} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com origin_id oid1 body hi]]
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid bob@example.com origin_id oid1 body hi]] bob@example.com
	set a [llength [store get -chat alice@example.com]]
	set b [llength [store get -chat bob@example.com]]
	list $a $b
    } -result {1 1}

# -- edge cases: store batch / live ------------------------------------------

test messagestore-batch-all-deduped-no-hole {all-deduped batch does not create extra hole} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 origin_id oid1 body first]]
	ms_batch [list [ms_msg timestamp 200 origin_id oid1 body duplicate]]
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=1}
    } -result {1}

test messagestore-live-dedup-no-extend {deduped live message does not create extra messages} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100 origin_id oid1 body first]] -span $sid
	store store batch [list [ms_msg timestamp 200 origin_id oid1 body duplicate]] -span $sid
	store span end $sid
	testdb eval {SELECT count(*) FROM chat_message WHERE chat_jid='alice@example.com' AND hole=0}
    } -result {1}

# -- multi-chat isolation -----------------------------------------------------

test messagestore-multi-chat-isolation {get only returns messages for requested chat} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 chat_jid alice@example.com body alice-msg]]
	ms_batch [list \
	    [ms_msg timestamp 200 chat_jid bob@example.com body bob-msg]] bob@example.com
	llength [store get -chat alice@example.com]
    } -result {1}

# -- edge cases round 2 ------------------------------------------------------

test messagestore-get-no-cursor-multiple-ranges {no cursor returns tail of latest range} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	ms_batch [list \
	    [ms_msg timestamp 500 body c] \
	    [ms_msg timestamp 600 body d]]
	# No -before/-after: picks latest contiguous range
	set msgs [store get -chat alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 c d}

test messagestore-get-after-beyond-all-data {-after beyond all messages returns {}} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	store get -chat alice@example.com -after 9999
    } -result {}

test messagestore-get-before-below-all-data {-before below all messages returns {}} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	store get -chat alice@example.com -before 1
    } -result {}

test messagestore-dedup-both-ids-match-server {both IDs set, dedup fires on server_id match} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id sid1 origin_id oid1 body first]]
	# Same server_id, different origin_id — deduped via OR
	ms_batch [list \
	    [ms_msg timestamp 200 server_id sid1 origin_id oid_other body dup]]
	llength [store get -chat alice@example.com]
    } -result {1}

test messagestore-dedup-both-ids-match-origin {both IDs set, dedup fires on origin_id match} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 server_id sid1 origin_id oid1 body first]]
	# Different server_id, same origin_id — deduped via OR
	ms_batch [list \
	    [ms_msg timestamp 200 server_id sid_other origin_id oid1 body dup]]
	llength [store get -chat alice@example.com]
    } -result {1}

test messagestore-batch-out-of-order-timestamps {batch with non-chronological timestamps preserves caller order} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	set msgs [store get -chat alice@example.com]
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
	set msgs [store get -chat alice@example.com]
	list [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body] \
	     [dict get [lindex $msgs 2] body]
    } -result {x y z}

test messagestore-batch-bumped-ts-covered {bumped timestamps all retrievable} \
    {*}$ms_common \
    -body {
	# All three share timestamp 100; after bumping: 100, 101, 102
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 100 body b] \
	    [ms_msg timestamp 100 body c]]
	# -after 100 must return the bumped messages (101, 102)
	set msgs [store get -chat alice@example.com -after 100]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-get-after-at-exact-last {-after at exact last timestamp returns {}} \
    {*}$ms_common \
    -body {
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b] \
	    [ms_msg timestamp 300 body c]]
	store get -chat alice@example.com -after 300
    } -result {}

test messagestore-live-earlier-timestamp {store live with earlier timestamp: hole moves down, both visible} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 500 body late]] -span $sid
	# Earlier timestamp — hole moves from 499 to 99, both visible
	store store batch [list [ms_msg timestamp 100 body early]] -span $sid
	store span end $sid
	set msgs [store get -chat alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 1] body]
    } -result {2 early late}

test messagestore-batch-single-message {single-message batch works} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 42 body only]]
	set msgs [store get -chat alice@example.com]
	list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 only}

# -- parallel sessions --------------------------------------------------------

test messagestore-parallel-sessions-overlapping {two parallel sessions with overlapping timeframes} \
    {*}$ms_common \
    -body {
	# Simulate: MAM catchup and live connection running concurrently
	set mam [store span begin alice@example.com]
	set live [store span begin alice@example.com]

	# Live message arrives first
	store store batch [list [ms_msg timestamp 500 body live1]] -span $live
	# MAM page 1 arrives (older history)
	store store batch [list \
	    [ms_msg timestamp 100 server_id s1 body mam1] \
	    [ms_msg timestamp 200 server_id s2 body mam2]] -span $mam
	# Another live message
	store store batch [list [ms_msg timestamp 600 body live2]] -span $live
	# MAM page 2 overlaps into live range
	store store batch [list \
	    [ms_msg timestamp 300 server_id s3 body mam3] \
	    [ms_msg timestamp 400 server_id s4 body mam4]] -span $mam

	store span end $mam
	store span end $live

	# Each session created exactly one hole
	set holes [lsort -integer [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]]
	# MAM hole at 99, live hole at 499
	set msgs_latest [store get -chat alice@example.com]
	set msgs_old [store get -chat alice@example.com -before 499]
	list holes $holes \
	     latest_count [llength $msgs_latest] \
	     latest_bodies [list \
		 [dict get [lindex $msgs_latest 0] body] \
		 [dict get [lindex $msgs_latest 1] body]] \
	     old_count [llength $msgs_old] \
	     old_bodies [list \
		 [dict get [lindex $msgs_old 0] body] \
		 [dict get [lindex $msgs_old 1] body] \
		 [dict get [lindex $msgs_old 2] body] \
		 [dict get [lindex $msgs_old 3] body]]
    } -result {holes {99 499} latest_count 2 latest_bodies {live1 live2} old_count 4 old_bodies {mam1 mam2 mam3 mam4}}

test messagestore-parallel-sessions-bridge-unifies {bridge after parallel sessions unifies ranges} \
    {*}$ms_common \
    -body {
	set mam [store span begin alice@example.com]
	set live [store span begin alice@example.com]

	store store batch [list \
	    [ms_msg timestamp 100 server_id s1 body a] \
	    [ms_msg timestamp 200 server_id s2 body b]] -span $mam
	store store batch [list [ms_msg timestamp 500 body c]] -span $live
	store store batch [list [ms_msg timestamp 600 body d]] -span $live

	store span end $mam
	store span end $live

	# Bridge the gap (MAM catchup reached live data)
	store bridge -chat alice@example.com -from-ts 99 -to-ts 499

	set msgs [store get -chat alice@example.com]
	list [llength $msgs] \
	     [dict get [lindex $msgs 0] body] \
	     [dict get [lindex $msgs 3] body]
    } -result {4 a d}

test messagestore-row-no-hole-key {message dicts do not contain hole key} \
    {*}$ms_common \
    -body {
	ms_batch [list [ms_msg timestamp 100 body test]]
	set msg [lindex [store get -chat alice@example.com] 0]
	dict exists $msg hole
    } -result {0}

# -- server_id driven hole deletion ------------------------------------------

test messagestore-batch-serverid-dup-deletes-hole {server_id dup proves overlap, deletes hole between ranges} \
    {*}$ms_common \
    -body {
	# Range 1: ts 100-200, hole at 99
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s1 body a] \
	    [ms_msg timestamp 200 server_id s2 body b]]
	# Range 2: ts 500-600, hole at 499
	ms_batch [list \
	    [ms_msg timestamp 500 server_id s5 body e] \
	    [ms_msg timestamp 600 server_id s6 body f]]
	# Range 3: ts 300-400, last msg is server_id dup of s5
	# server_id s5 found at ts=500 → reachedTs={500}, insertedTs={300,400}
	# hole deletion range [300,500] → kills hole at 499
	ms_batch [list \
	    [ms_msg timestamp 300 server_id s3 body c] \
	    [ms_msg timestamp 400 server_id s4 body d] \
	    [ms_msg timestamp 500 server_id s5 body dup]]
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]
	# Hole at 499 deleted; holes at 99 and 299 remain
	set holes
    } -result {99 299}

test messagestore-batch-no-serverid-no-hole-deletion {batch with no server_ids creates isolated island} \
    {*}$ms_common \
    -body {
	# Range 1: ts 100-200, hole at 99
	ms_batch [list \
	    [ms_msg timestamp 100 body a] \
	    [ms_msg timestamp 200 body b]]
	# Range 2: ts 500-600, hole at 499
	ms_batch [list \
	    [ms_msg timestamp 500 body e] \
	    [ms_msg timestamp 600 body f]]
	# Range 3: ts 300-400, no server_ids → no proof of overlap
	# reachedTs={}, so no holes deleted
	ms_batch [list \
	    [ms_msg timestamp 300 body c] \
	    [ms_msg timestamp 400 body d]]
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]
	# All three holes survive: 99, 299, 499
	set holes
    } -result {99 299 499}

# -- edge cases: empty batch, hole collision, hole-before-delete ordering ----

test messagestore-empty-batch-noop {empty batch is a no-op} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch {} -span $sid
	store span end $sid
	testdb eval {SELECT count(*) FROM chat_message}
    } -result {0}

test messagestore-hole-collision-bumps-down {hole bumps down when minTs-1 is occupied} \
    {*}$ms_common \
    -body {
	# Plant a message at ts=99, exactly where the next batch's hole would go
	ms_batch [list [ms_msg timestamp 99 body blocker]]
	# New batch at ts=100 — hole wants 99, occupied → bumps to 98
	ms_batch [list [ms_msg timestamp 100 body target]]
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]
	set holes
    } -result {97 98}

test messagestore-hole-not-in-proven-range {hole placed before deletion range is not deleted} \
    {*}$ms_common \
    -body {
	# Existing range: ts=50, server_id=s1
	ms_batch [list [ms_msg timestamp 50 server_id s1 body old]]
	# New batch: ts=100 (new) + ts=200 with server_id=s1 (dup of ts=50)
	# reachedTs={50}, insertedTs={100}. Hole at 99.
	# Deletion range [50,100] covers 99 — but hole must be placed
	# before deletion, so it survives only if ordering is correct.
	# Correct behavior: hole at 99 is deleted because [50,100] is proven
	# contiguous via the s1 overlap.
	ms_batch [list \
	    [ms_msg timestamp 100 server_id s_new body new] \
	    [ms_msg timestamp 200 server_id s1 body dup]]
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	    ORDER BY timestamp
	}]
	set holes
    } -result {49}

# -- hole tracks lowest edge ---------------------------------------------------

test messagestore-hole-moves-down {span moves hole down with each older batch} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	# Page 1 (newest)
	store store batch [list \
	    [ms_msg timestamp 1000 body p1a] \
	    [ms_msg timestamp 1010 body p1b] \
	    [ms_msg timestamp 1020 body p1c]] -span $sid
	# Hole should be at 999
	set h1 [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	}]
	# Page 2 (older) — hole should move to 969
	store store batch [list \
	    [ms_msg timestamp 970 body p2a] \
	    [ms_msg timestamp 980 body p2b] \
	    [ms_msg timestamp 990 body p2c]] -span $sid
	set h2 [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	}]
	store span end $sid
	list $h1 $h2
    } -result {999 969}

test messagestore-hole-move-all-visible {moved hole: all pages visible to GetBefore} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list \
	    [ms_msg timestamp 1000 body p1a] \
	    [ms_msg timestamp 1010 body p1b]] -span $sid
	store store batch [list \
	    [ms_msg timestamp 980 body p2a] \
	    [ms_msg timestamp 990 body p2b]] -span $sid
	store span end $sid
	set msgs [store get -chat alice@example.com]
	llength $msgs
    } -result {4}

test messagestore-hole-move-single-hole {only one hole after multiple older batches} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 300 body c]] -span $sid
	store store batch [list [ms_msg timestamp 200 body b]] -span $sid
	store store batch [list [ms_msg timestamp 100 body a]] -span $sid
	store span end $sid
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	}]
	set holes
    } -result {99}

test messagestore-hole-no-move-forward {hole stays when batch is above it} \
    {*}$ms_common \
    -body {
	set sid [store span begin alice@example.com]
	store store batch [list [ms_msg timestamp 100 body first]] -span $sid
	store store batch [list [ms_msg timestamp 500 body second]] -span $sid
	store span end $sid
	set holes [testdb eval {
	    SELECT timestamp FROM chat_message
	    WHERE chat_jid='alice@example.com' AND hole=1
	}]
	set holes
    } -result {99}
