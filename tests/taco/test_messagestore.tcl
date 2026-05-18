package require taco

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
        server_id "" own_id "" raw_xml ""
    }
    return [dict merge $defaults $args]
}

# Helper: store a batch of messages
proc ms_batch {messages {jid alice@example.com}} {
    store store $messages
}

# Helper: store a pending outgoing message
proc ms_pending {msg} {
    store store [list $msg]
}

# Helper: count chat_message rows of a given kind
proc ms_count {{kind message} {jid alice@example.com}} {
    testdb eval {
        SELECT COUNT(*) FROM chat_message
        WHERE chat_jid=$jid AND kind=$kind
    }
}

# Helpers: unwrap {messages ... bounded ...} dict from get
proc ms_msgs {result} { dict get $result messages }
proc ms_bounded {result} { dict get $result bounded }

# =============================================================================
# Store: basic
# =============================================================================

test messagestore-basic-store-and-get {store a batch, get it back in chronological order} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body first] \
            [ms_msg timestamp 200 body second] \
            [ms_msg timestamp 300 body third]]
        set msgs [ms_msgs [store get latest alice@example.com]]
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
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {a b c}

test messagestore-batch-single-message {single-message batch works} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 42 body only]]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 only}

test messagestore-batch-empty-noop {empty batch is a no-op} \
    {*}$ms_common \
    -body {
        store store {}
        testdb eval {SELECT count(*) FROM chat_message}
    } -result {0}

test messagestore-batch-out-of-order-timestamps {batch with non-chronological timestamps preserves caller order} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b]]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {c a b}

test messagestore-batch-bumped-ts-covered {bumped timestamps all retrievable} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 100 body b] \
            [ms_msg timestamp 100 body c]]
        set msgs [ms_msgs [store get after alice@example.com 100]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-multi-chat-isolation {get only returns messages for requested chat} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 chat_jid alice@example.com body alice-msg]]
        ms_batch [list \
            [ms_msg timestamp 200 chat_jid bob@example.com body bob-msg]] bob@example.com
        llength [ms_msgs [store get latest alice@example.com]]
    } -result {1}

# =============================================================================
# Store: dedup
# =============================================================================

test messagestore-dedup-server-id {duplicate server_id is not inserted twice} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id sid1 body first]]
        ms_batch [list \
            [ms_msg timestamp 200 server_id sid1 body duplicate]]
        llength [ms_msgs [store get latest alice@example.com]]
    } -result {1}

test messagestore-dedup-own-id {duplicate own_id is not inserted twice} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 own_id oid1 body first]]
        ms_batch [list \
            [ms_msg timestamp 200 own_id oid1 body duplicate]]
        llength [ms_msgs [store get latest alice@example.com]]
    } -result {1}

test messagestore-dedup-both-ids-match-server {both IDs set, dedup fires on server_id match} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id sid1 own_id oid1 body first]]
        ms_batch [list \
            [ms_msg timestamp 200 server_id sid1 own_id oid_other body dup]]
        llength [ms_msgs [store get latest alice@example.com]]
    } -result {1}

test messagestore-dedup-both-ids-match-own {both IDs set, dedup fires on own_id match} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id sid1 own_id oid1 body first]]
        ms_batch [list \
            [ms_msg timestamp 200 server_id sid_other own_id oid1 body dup]]
        llength [ms_msgs [store get latest alice@example.com]]
    } -result {1}

test messagestore-dedup-content-same-batch {content dedup within batch when IDs empty} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id "" own_id "" body hello] \
            [ms_msg timestamp 100 server_id "" own_id "" body hello]]
        llength [ms_msgs [store get latest alice@example.com]]
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
        ms_count
    } -result {2}

test messagestore-dedup-content-different-body-not-deduped {same timestamp different body not falsely deduped} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body hello]]
        ms_batch [list \
            [ms_msg timestamp 100 body goodbye]]
        ms_count
    } -result {2}

test messagestore-dedup-content-different-from-not-deduped {same timestamp+body different sender not falsely deduped} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 from_jid alice@example.com/phone body hello]]
        ms_batch [list \
            [ms_msg timestamp 100 from_jid bob@example.com/phone body hello]]
        ms_count
    } -result {2}

test messagestore-dedup-isolation-across-chats {same own_id in different chats stored independently} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 chat_jid alice@example.com own_id oid1 body hi]]
        ms_batch [list \
            [ms_msg timestamp 100 chat_jid bob@example.com own_id oid1 body hi]] bob@example.com
        set a [llength [ms_msgs [store get latest alice@example.com]]]
        set b [llength [ms_msgs [store get latest bob@example.com]]]
        list $a $b
    } -result {1 1}

# =============================================================================
# Get: basic
# =============================================================================

test messagestore-get-empty-chat {get on a jid with no messages returns empty list} \
    {*}$ms_common \
    -body {
        ms_msgs [store get latest nobody@example.com]
    } -result {}

test messagestore-get-result-shape {get returns {messages bounded} dict} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        set r [store get latest alice@example.com]
        list [dict exists $r messages] [dict exists $r bounded]
    } -result {1 1}

test messagestore-get-before {get before returns messages older than cursor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        set msgs [ms_msgs [store get before alice@example.com 300]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 a b}

test messagestore-get-after {get after returns messages newer than cursor, ascending} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        set msgs [ms_msgs [store get after alice@example.com 100]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-get-latest-multiple-batches {get latest spans multiple batches when no sentinel separates them} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b]]
        ms_batch [list \
            [ms_msg timestamp 500 body c] \
            [ms_msg timestamp 600 body d]]
        set msgs [ms_msgs [store get latest alice@example.com]]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        list [llength $msgs] $bodies
    } -result {4 {a b c d}}

test messagestore-get-before-at-first-ts {get before at oldest timestamp returns empty} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        ms_msgs [store get before alice@example.com 100]
    } -result {}

test messagestore-get-after-at-last-ts {get after at newest timestamp returns empty} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        ms_msgs [store get after alice@example.com 300]
    } -result {}

# =============================================================================
# Get: limit
# =============================================================================

test messagestore-get-latest-with-limit {get latest caps result count at -limit} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        set msgs [ms_msgs [store get latest alice@example.com 2]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-get-before-with-limit {get before with -limit returns correct slice} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 400 body d]]
        set msgs [ms_msgs [store get before alice@example.com 400 2]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 b c}

test messagestore-get-after-with-limit {get after with -limit returns correct slice} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        set msgs [ms_msgs [store get after alice@example.com 100 1]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body]
    } -result {1 b}

test messagestore-get-limit-exceeds-available {-limit larger than message count returns all} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        llength [ms_msgs [store get latest alice@example.com 1000]]
    } -result {3}

# =============================================================================
# Pending outgoings (server_id='', server_status='pending')
# =============================================================================

test messagestore-pending-stored {pending outgoing is stored and visible in get latest} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 sent}

test messagestore-pending-no-server-id {pending outgoing has empty server_id} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        set msg [lindex [ms_msgs [store get latest alice@example.com]] 0]
        dict get $msg server_id
    } -result {}

test messagestore-pending-only {get latest returns pendings when only pendings exist} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body x own_id oid1 server_status pending]
        ms_pending [ms_msg timestamp 200 body y own_id oid2 server_status pending]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 x y}

test messagestore-pending-mixed-with-real {get latest returns pendings interleaved with real} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 300 server_id s3 body c]]
        ms_pending [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

test messagestore-pending-visible-in-get {pending and real rows both appear} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body real]]
        ms_batch [list \
            [ms_msg timestamp 200 own_id oid1 body pending server_status pending]]
        set msgs [ms_msgs [store get latest alice@example.com]]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {real pending}

test messagestore-get-before-includes-pending {get before includes pendings older than cursor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 300 server_id s3 body c] \
            [ms_msg timestamp 500 server_id s5 body e]]
        ms_pending [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        set msgs [ms_msgs [store get before alice@example.com 500]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

test messagestore-get-after-includes-pending {get after includes pendings newer than cursor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 300 server_id s3 body c] \
            [ms_msg timestamp 500 server_id s5 body e]]
        ms_pending [ms_msg timestamp 400 body d own_id oid1 server_status pending]
        set msgs [ms_msgs [store get after alice@example.com 100]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 c d e}

test messagestore-get-around-includes-pending {get around includes nearby pendings} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 400 body d] \
            [ms_msg timestamp 500 body e]]
        ms_pending [ms_msg timestamp 300 body c own_id oid1 server_status pending]
        set result [store get around alice@example.com 300 10]
        set msgs [dict get $result messages]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {a b c d e}

test messagestore-get-around-on-pending-target {get around snapping onto a pending works} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 500 body e]]
        ms_pending [ms_msg timestamp 300 body out own_id oid1 server_status pending]
        set result [store get around alice@example.com 300 10]
        set anchor [dict get $result anchor]
        set msgs [dict get $result messages]
        list $anchor [llength $msgs]
    } -result {300 3}

test messagestore-pending-confirm-same-ts {echo with same timestamp confirms in place} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        set result [store store [list \
            [ms_msg timestamp 100 server_id srv1 own_id oid1 body sent]]]
        set c [lindex [dict get $result confirmed] 0]
        set msg [lindex [ms_msgs [store get latest alice@example.com]] 0]
        list [dict get $c timestamp] [dict get $c newtimestamp] \
             [dict get $msg server_id] [dict get $msg server_status]
    } -result {100 100 srv1 received}

test messagestore-pending-confirm-ts-change {echo with different timestamp moves the row} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        # Echo arrives with server timestamp 200
        set result [store store [list \
            [ms_msg timestamp 200 server_id srv1 own_id oid1 body sent]]]
        set c [lindex [dict get $result confirmed] 0]
        set oldExists [testdb exists {
            SELECT 1 FROM chat_message
            WHERE chat_jid='alice@example.com' AND timestamp=100
        }]
        set newStatus [testdb onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='alice@example.com' AND timestamp=200
        }]
        list [dict get $c timestamp] [dict get $c newtimestamp] \
             $oldExists $newStatus
    } -result {100 200 0 received}

test messagestore-pending-confirm-no-bulk-update {confirming one pending does not move others} \
    {*}$ms_common \
    -body {
        ms_pending [ms_msg timestamp 100 body sent1 own_id oid1 server_status pending]
        ms_pending [ms_msg timestamp 200 body sent2 own_id oid2 server_status pending]
        store store [list \
            [ms_msg timestamp 100 server_id srv1 own_id oid1 body sent1]]
        # sent2 should still be pending (no server_id)
        set sid2 [testdb onecolumn {
            SELECT server_id FROM chat_message
            WHERE chat_jid='alice@example.com' AND timestamp=200
        }]
        set status2 [testdb onecolumn {
            SELECT server_status FROM chat_message
            WHERE chat_jid='alice@example.com' AND timestamp=200
        }]
        list $sid2 $status2
    } -result {{} pending}

test messagestore-pending-confirm-reorders {confirmed pending moves to its new sorted slot} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 300 server_id s3 body b] \
            [ms_msg timestamp 500 server_id s5 body c]]
        ms_pending [ms_msg timestamp 200 body x own_id oid1 server_status pending]

        # Before confirmation: order is a, x, b, c
        set before [ms_msgs [store get latest alice@example.com]]
        set beforeBodies {}
        foreach m $before { lappend beforeBodies [dict get $m body] }

        # Server confirms X at timestamp 400 (between B and C)
        store store [list \
            [ms_msg timestamp 400 server_id srv1 own_id oid1 body x]]

        # After confirmation: order should be a, b, x, c
        set after [ms_msgs [store get latest alice@example.com]]
        set afterBodies {}
        foreach m $after { lappend afterBodies [dict get $m body] }

        list $beforeBodies $afterBodies
    } -result {{a x b c} {a b x c}}

test messagestore-pending-confirm-visible {confirmed pending (status=received) still shows up in get} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_pending [ms_msg timestamp 200 body sent own_id oid1 \
            server_id srv1 server_status received]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] [dict get [lindex $msgs 1] body]
    } -result {2 sent}

# =============================================================================
# Sentinel: add / remove API
# =============================================================================

test messagestore-sentinel-add-older {sentinel add older inserts a sentinel below the anchor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store sentinel add alice@example.com older 100
        list [llength [store sentinel list alice@example.com]] \
             [expr {[lindex [store sentinel list alice@example.com] 0] < 100}]
    } -result {1 1}

test messagestore-sentinel-add-newer {sentinel add newer inserts a sentinel above the anchor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store sentinel add alice@example.com newer 100
        list [llength [store sentinel list alice@example.com]] \
             [expr {[lindex [store sentinel list alice@example.com] 0] > 100}]
    } -result {1 1}

test messagestore-sentinel-add-dedup-per-gap {repeated adds to the same gap are no-ops} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store sentinel add alice@example.com newer 100
        store sentinel add alice@example.com newer 100
        store sentinel add alice@example.com newer 100
        llength [store sentinel list alice@example.com]
    } -result {1}

test messagestore-sentinel-add-different-gaps {sentinels in different gaps both stored} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 500 server_id s5 body e]]
        # Two distinct gaps: older of 100, and between 100 and 500
        store sentinel add alice@example.com older 100
        store sentinel add alice@example.com newer 100
        llength [store sentinel list alice@example.com]
    } -result {2}

test messagestore-sentinel-add-skips-pending {pendings don't count as gap bounds; sentinel sits adjacent to citizen} \
    {*}$ms_common \
    -body {
        # Citizen at 100, pending at 1000. The gap "newer of 100" runs
        # from 100 to the next citizen (none) — extending past the
        # pending. Sentinel is placed adjacent to the citizen at 101.
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        ms_pending [ms_msg timestamp 1000 body p own_id oid1 server_status pending]
        store sentinel add alice@example.com newer 100
        set sList [store sentinel list alice@example.com]
        list [llength $sList] [lindex $sList 0]
    } -result {1 101}

test messagestore-sentinel-remove {sentinel remove clears the targeted gap} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store sentinel add alice@example.com newer 100
        set before [llength [store sentinel list alice@example.com]]
        store sentinel remove alice@example.com newer 100
        set after [llength [store sentinel list alice@example.com]]
        list $before $after
    } -result {1 0}

test messagestore-sentinel-removeBetween {removeBetween deletes sentinels strictly within range} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 500 server_id s5 body e]]
        store sentinel add alice@example.com newer 100
        # Sentinel sits at 101 (BumpTs from 100); span (100, 500)
        store sentinel removeBetween alice@example.com 100 500
        llength [store sentinel list alice@example.com]
    } -result {0}

test messagestore-sentinel-chat-isolation {sentinels are scoped per chat} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id s1 body a]]
        ms_batch [list \
            [ms_msg timestamp 100 chat_jid bob@example.com server_id bs1 body b]] \
            bob@example.com
        store sentinel add alice@example.com newer 100
        list [llength [store sentinel list alice@example.com]] \
             [llength [store sentinel list bob@example.com]]
    } -result {1 0}

# =============================================================================
# Sentinel: store-time sweep
# =============================================================================

test messagestore-store-overlap-sweeps-sentinel {store with real overlap sweeps sentinels in the batch bracket} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store sentinel add alice@example.com newer 100
        # A batch that overlaps the existing citizen via server_id
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body dup] \
            [ms_msg timestamp 500 server_id s5 body e]]
        llength [store sentinel list alice@example.com]
    } -result {0}

test messagestore-store-pending-confirm-does-not-sweep {pending->confirmed dedup does not sweep sentinels} \
    {*}$ms_common \
    -body {
        # Pre-existing citizen + sentinel
        ms_batch [list \
            [ms_msg timestamp 50 server_id s_old body anchor]]
        store sentinel add alice@example.com newer 50
        # Pending outgoing
        ms_batch [list \
            [ms_msg timestamp 100 own_id oid1 body sent server_status pending]]
        # Echo: dedup hits via own_id, but the matched row is pending —
        # this is confirmation, not server overlap. Sentinel must stay
        # (the gap between 50 and 100 is still uncertain).
        ms_batch [list \
            [ms_msg timestamp 100 server_id s_echo own_id oid1 body sent]]
        llength [store sentinel list alice@example.com]
    } -result {1}

# =============================================================================
# Sentinel: get truncation
# =============================================================================

test messagestore-get-before-truncates-at-sentinel {get before stops at sentinel and signals bounded} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        set r [store get before alice@example.com 600]
        list [llength [ms_msgs $r]] \
             [dict get [lindex [ms_msgs $r] 0] body] \
             [ms_bounded $r]
    } -result {1 c 1}

test messagestore-get-after-truncates-at-sentinel {get after stops at sentinel and signals bounded} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c]]
        set r [store get after alice@example.com 100]
        list [llength [ms_msgs $r]] \
             [dict get [lindex [ms_msgs $r] 0] body] \
             [ms_bounded $r]
    } -result {1 b 1}

test messagestore-get-latest-truncates-at-sentinel {get latest returns only the newest cluster} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{c d} 1}

test messagestore-get-before-ignores-newer-sentinel {sentinel on the newer side does not affect get before} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        # Sentinel sits past the cursor — irrelevant to "older" walks.
        store sentinel add alice@example.com newer 300
        set r [store get before alice@example.com 300]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{a b} 0}

test messagestore-get-after-ignores-older-sentinel {sentinel on the older side does not affect get after} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        # Sentinel sits older than the cursor — irrelevant to "newer" walks.
        store sentinel add alice@example.com older 100
        set r [store get after alice@example.com 100]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{b c} 0}

test messagestore-get-latest-with-future-sentinel {get latest returns citizens when sentinel sits newer than all of them (reconnect case)} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        # Reconnect-style sentinel placed after the newest citizen,
        # marking "more might exist newer than this." get latest must
        # still return the existing citizens.
        store sentinel add alice@example.com newer 200
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{a b} 1}

test messagestore-get-latest-newer-cluster-only {get latest with mid-timeline sentinel returns only the newest cluster} \
    {*}$ms_common \
    -body {
        # Old cluster + sentinel separating + new cluster + future
        # reconnect sentinel. Only the newest cluster should come back.
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        store sentinel add alice@example.com newer 600
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{c d} 1}

# =============================================================================
# Sentinel: bounded flag
# =============================================================================

test messagestore-bounded-false-without-sentinel {no sentinel -> bounded=false even if result short} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        ms_bounded [store get latest alice@example.com 50]
    } -result {0}

test messagestore-bounded-false-when-limit-satisfied {sentinel exists but limit satisfied -> bounded=false} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        store sentinel add alice@example.com older 100
        # limit=2 satisfied without touching the sentinel range
        set r [store get before alice@example.com 300 2]
        list [llength [ms_msgs $r]] [ms_bounded $r]
    } -result {2 0}

# =============================================================================
# Get around
# =============================================================================

test messagestore-get-around-nearest {get around finds nearest message and returns context} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 400 body d] \
            [ms_msg timestamp 500 body e]]
        set result [store get around alice@example.com 300 4]
        set msgs [dict get $result messages]
        set anchor [dict get $result anchor]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 2] body] \
             [dict get [lindex $msgs 4] body] \
             $anchor
    } -result {5 a c e 300}

test messagestore-get-around-nearest-inexact {get around snaps to nearest message when target is between} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 500 body c]]
        set result [store get around alice@example.com 190 4]
        set anchor [dict get $result anchor]
        set msgs [dict get $result messages]
        list $anchor [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {200 3 a b c}

test messagestore-get-around-anchor-value {get around anchor = nearest message's timestamp} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body b] \
            [ms_msg timestamp 500 body c]]
        # Target 250 is closest to 300
        set result [store get around alice@example.com 250 4]
        dict get $result anchor
    } -result {300}

test messagestore-get-around-empty {get around on empty chat returns empty messages and empty anchor} \
    {*}$ms_common \
    -body {
        set result [store get around nobody@example.com 500 10]
        list [dict get $result messages] [dict get $result anchor]
    } -result {{} {}}

test messagestore-get-around-sentinel-bounds {get around truncates at sentinels on both sides} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d] \
            [ms_msg timestamp 700 server_id s7 body e]]
        store sentinel add alice@example.com newer 700
        set result [store get around alice@example.com 600 10]
        set msgs [dict get $result messages]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs end] body] \
             [dict get $result anchor] \
             [dict get $result bounded_before] \
             [dict get $result bounded_after]
    } -result {3 c e 600 1 1}

test messagestore-get-around-sentinel-one-side-only {get around truncates asymmetrically when sentinel is one-sided} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store sentinel add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d] \
            [ms_msg timestamp 700 server_id s7 body e]]
        # Sentinel only on the older side of the anchor; newer side
        # is open. get around should reach forward through e without
        # truncation, but stop on the older side at the sentinel.
        set result [store get around alice@example.com 600 10]
        set msgs [dict get $result messages]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        list $bodies \
             [dict get $result anchor] \
             [dict get $result bounded_before] \
             [dict get $result bounded_after]
    } -result {{c d e} 600 1 0}

# =============================================================================
# Search
# =============================================================================

test messagestore-search-skips-sentinels {search results never include sentinel rows} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id s1 body needle]]
        store sentinel add alice@example.com newer 100
        store search alice@example.com needle
    } -result {100}
