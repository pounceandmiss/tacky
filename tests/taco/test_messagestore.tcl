package require tcltest
namespace import ::tcltest::*
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

test messagestore-get-latest-multiple-batches {get latest spans multiple batches when no hole separates them} \
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
    } -result {100 100 srv1 {}}

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
    } -result {100 200 0 {}}

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

test messagestore-pending-confirm-visible {confirmed pending (status='') still shows up in get} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_pending [ms_msg timestamp 200 body sent own_id oid1 \
            server_id srv1 server_status ""]
        set msgs [ms_msgs [store get latest alice@example.com]]
        list [llength $msgs] [dict get [lindex $msgs 1] body]
    } -result {2 sent}

# =============================================================================
# Hole: add / remove API
# =============================================================================

test messagestore-hole-add-older {hole add older inserts a hole below the anchor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store hole add alice@example.com older 100
        list [llength [store hole list alice@example.com]] \
             [expr {[lindex [store hole list alice@example.com] 0] < 100}]
    } -result {1 1}

test messagestore-hole-add-newer {hole add newer inserts a hole above the anchor} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store hole add alice@example.com newer 100
        list [llength [store hole list alice@example.com]] \
             [expr {[lindex [store hole list alice@example.com] 0] > 100}]
    } -result {1 1}

test messagestore-hole-add-dedup-per-gap {repeated adds to the same gap are no-ops} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store hole add alice@example.com newer 100
        store hole add alice@example.com newer 100
        store hole add alice@example.com newer 100
        llength [store hole list alice@example.com]
    } -result {1}

test messagestore-hole-add-different-gaps {holes in different gaps both stored} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 500 server_id s5 body e]]
        # Two distinct gaps: older of 100, and between 100 and 500
        store hole add alice@example.com older 100
        store hole add alice@example.com newer 100
        llength [store hole list alice@example.com]
    } -result {2}

test messagestore-hole-add-skips-pending {pendings don't count as gap bounds; hole sits adjacent to citizen} \
    {*}$ms_common \
    -body {
        # Citizen at 100, pending at 1000. The gap "newer of 100" runs
        # from 100 to the next citizen (none) — extending past the
        # pending. Hole is placed adjacent to the citizen at 101.
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        ms_pending [ms_msg timestamp 1000 body p own_id oid1 server_status pending]
        store hole add alice@example.com newer 100
        set sList [store hole list alice@example.com]
        list [llength $sList] [lindex $sList 0]
    } -result {1 101}

test messagestore-hole-remove {hole remove clears the targeted gap} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store hole add alice@example.com newer 100
        set before [llength [store hole list alice@example.com]]
        store hole remove alice@example.com newer 100
        set after [llength [store hole list alice@example.com]]
        list $before $after
    } -result {1 0}

test messagestore-hole-removeBetween {removeBetween deletes holes strictly within range} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 500 server_id s5 body e]]
        store hole add alice@example.com newer 100
        # Hole sits at 101 (BumpTs from 100); span (100, 500)
        store hole removeBetween alice@example.com 100 500
        llength [store hole list alice@example.com]
    } -result {0}

test messagestore-hole-chat-isolation {holes are scoped per chat} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id s1 body a]]
        ms_batch [list \
            [ms_msg timestamp 100 chat_jid bob@example.com server_id bs1 body b]] \
            bob@example.com
        store hole add alice@example.com newer 100
        list [llength [store hole list alice@example.com]] \
             [llength [store hole list bob@example.com]]
    } -result {1 0}

# =============================================================================
# Hole: store-time sweep
# =============================================================================

test messagestore-store-overlap-sweeps-hole {store with real overlap sweeps holes in the batch bracket} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a]]
        store hole add alice@example.com newer 100
        # A batch that overlaps the existing citizen via server_id
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body dup] \
            [ms_msg timestamp 500 server_id s5 body e]]
        llength [store hole list alice@example.com]
    } -result {0}

test messagestore-store-pending-confirm-does-not-sweep {pending->confirmed dedup does not sweep holes} \
    {*}$ms_common \
    -body {
        # Pre-existing citizen + hole
        ms_batch [list \
            [ms_msg timestamp 50 server_id s_old body anchor]]
        store hole add alice@example.com newer 50
        # Pending outgoing
        ms_batch [list \
            [ms_msg timestamp 100 own_id oid1 body sent server_status pending]]
        # Echo: dedup hits via own_id, but the matched row is pending —
        # this is confirmation, not server overlap. Hole must stay
        # (the gap between 50 and 100 is still uncertain).
        ms_batch [list \
            [ms_msg timestamp 100 server_id s_echo own_id oid1 body sent]]
        llength [store hole list alice@example.com]
    } -result {1}

# =============================================================================
# Hole: get truncation
# =============================================================================

test messagestore-get-before-truncates-at-hole {get before stops at hole and signals bounded} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        set r [store get before alice@example.com 600]
        list [llength [ms_msgs $r]] \
             [dict get [lindex [ms_msgs $r] 0] body] \
             [ms_bounded $r]
    } -result {1 c 1}

test messagestore-get-after-truncates-at-hole {get after stops at hole and signals bounded} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c]]
        set r [store get after alice@example.com 100]
        list [llength [ms_msgs $r]] \
             [dict get [lindex [ms_msgs $r] 0] body] \
             [ms_bounded $r]
    } -result {1 b 1}

test messagestore-get-latest-truncates-at-hole {get latest returns only the newest cluster} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{c d} 1}

test messagestore-get-before-ignores-newer-hole {hole on the newer side does not affect get before} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        # Hole sits past the cursor — irrelevant to "older" walks.
        store hole add alice@example.com newer 300
        set r [store get before alice@example.com 300]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{a b} 0}

test messagestore-get-after-ignores-older-hole {hole on the older side does not affect get after} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        # Hole sits older than the cursor — irrelevant to "newer" walks.
        store hole add alice@example.com older 100
        set r [store get after alice@example.com 100]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{b c} 0}

test messagestore-get-latest-with-future-hole {get latest returns citizens when hole sits newer than all of them (reconnect case)} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        # Reconnect-style hole placed after the newest citizen,
        # marking "more might exist newer than this." get latest must
        # still return the existing citizens.
        store hole add alice@example.com newer 200
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{a b} 1}

test messagestore-get-latest-newer-cluster-only {get latest with mid-timeline hole returns only the newest cluster} \
    {*}$ms_common \
    -body {
        # Old cluster + hole separating + new cluster + future
        # reconnect hole. Only the newest cluster should come back.
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d]]
        store hole add alice@example.com newer 600
        set r [store get latest alice@example.com]
        set bodies {}
        foreach m [ms_msgs $r] { lappend bodies [dict get $m body] }
        list $bodies [ms_bounded $r]
    } -result {{c d} 1}

# =============================================================================
# Hole: bounded flag
# =============================================================================

test messagestore-bounded-false-without-hole {no hole -> bounded=false even if result short} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        ms_bounded [store get latest alice@example.com 50]
    } -result {0}

test messagestore-bounded-false-when-limit-satisfied {hole exists but limit satisfied -> bounded=false} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b] \
            [ms_msg timestamp 300 server_id s3 body c]]
        store hole add alice@example.com older 100
        # limit=2 satisfied without touching the hole range
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

test messagestore-get-around-hole-bounds {get around truncates at holes on both sides} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d] \
            [ms_msg timestamp 700 server_id s7 body e]]
        store hole add alice@example.com newer 700
        set result [store get around alice@example.com 600 10]
        set msgs [dict get $result messages]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs end] body] \
             [dict get $result anchor] \
             [dict get $result bounded_before] \
             [dict get $result bounded_after]
    } -result {3 c e 600 1 1}

test messagestore-get-around-hole-one-side-only {get around truncates asymmetrically when hole is one-sided} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id s1 body a] \
            [ms_msg timestamp 200 server_id s2 body b]]
        store hole add alice@example.com newer 200
        ms_batch [list \
            [ms_msg timestamp 500 server_id s5 body c] \
            [ms_msg timestamp 600 server_id s6 body d] \
            [ms_msg timestamp 700 server_id s7 body e]]
        # Hole only on the older side of the anchor; newer side
        # is open. get around should reach forward through e without
        # truncation, but stop on the older side at the hole.
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

test messagestore-search-skips-holes {search results never include hole rows} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id s1 body needle]]
        store hole add alice@example.com newer 100
        store search alice@example.com needle
    } -result {100}

# resolveReply (XEP-0461 target lookup)

test messagestore-resolvereply-stanza-id {server_id is authoritative; resolves with no author hint} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 500 server_id sid-x body target]]
        store resolveReply alice@example.com sid-x
    } -result {500}

test messagestore-resolvereply-origin-id-author {origin_id collision across senders disambiguated by MUC author} \
    -setup {
        sqlite3 testdb :memory:
        taco_messagestore create store -db testdb
    } -cleanup {store destroy; testdb close} \
    -body {
        set jid room@conf.example.com?join
        store store [list \
            [dict create timestamp 100 chat_jid $jid \
                from_jid room@conf.example.com/alice body hi \
                server_id sid1 own_id "" origin_id oxxx raw_xml ""] \
            [dict create timestamp 200 chat_jid $jid \
                from_jid room@conf.example.com/bob body yo \
                server_id sid2 own_id "" origin_id oxxx raw_xml ""]]
        store resolveReply $jid oxxx room@conf.example.com/bob
    } -result {200}

test messagestore-resolvereply-author-mismatch {origin_id match but wrong MUC author resolves to nothing} \
    -setup {
        sqlite3 testdb :memory:
        taco_messagestore create store -db testdb
    } -cleanup {store destroy; testdb close} \
    -body {
        set jid room@conf.example.com?join
        store store [list [dict create timestamp 100 chat_jid $jid \
            from_jid room@conf.example.com/alice body hi \
            server_id sid1 own_id "" origin_id oxxx raw_xml ""]]
        store resolveReply $jid oxxx room@conf.example.com/charlie
    } -result {}

test messagestore-resolvereply-1to1-bare {1:1 author matched by bare JID when reply-to is a full JID} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 300 chat_jid bob@example.com \
            from_jid bob@example.com origin_id u1 body target]]
        store resolveReply bob@example.com u1 bob@example.com/Phone.123
    } -result {300}

test messagestore-resolvereply-notfound {unknown reply id resolves to nothing} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id s1 body x]]
        store resolveReply alice@example.com nope
    } -result {}

test messagestore-reply-body-enriched {a reply's enriched dict carries the target body snippet} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id tgt body "the original"] \
            [ms_msg timestamp 200 server_id rpl body "the reply" \
                reply_id tgt reply_to alice@example.com]]
        set reply [lindex [ms_msgs [store get latest alice@example.com]] end]
        dict get $reply reply_body
    } -result {the original}

test messagestore-reply-body-missing-target {a reply whose target is absent has no reply_body} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 200 server_id rpl body "the reply" \
            reply_id ghost reply_to alice@example.com]]
        set reply [lindex [ms_msgs [store get latest alice@example.com]] 0]
        dict exists $reply reply_body
    } -result {0}

# =============================================================================
# demote
# =============================================================================

test messagestore-demote-blanks-server-id \
    {demote blanks only the targeted server_id; the row still displays} \
    {*}$ms_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 server_id sid1 body a] \
            [ms_msg timestamp 200 server_id sid2 body b]]
        store demote alice@example.com sid1
        set msgs [ms_msgs [store get before alice@example.com 300]]
        set m1 [lindex $msgs 0]
        set m2 [lindex $msgs 1]
        list [dict get $m1 body] [dict get $m1 server_id] \
             [dict get $m2 body] [dict get $m2 server_id]
    } -result {a {} b sid2}

test messagestore-demote-empty-noop {demote with an empty server_id is a no-op} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 server_id sid1 body a]]
        store demote alice@example.com ""
        dict get [lindex [ms_msgs [store get latest alice@example.com]] 0] server_id
    } -result {sid1}

# remote_status (XEP-0184/0333 markers).
proc ms_remote {jid {ts 100}} {
    dict get [lindex [ms_msgs [store get latest $jid]] 0] remote_status
}

test messagestore-remote-status-default-none {a fresh row has remote_status none} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 body a]]
        ms_remote alice@example.com
    } -result none

test messagestore-mark-remote-status-advances {markers advance none->delivered->read} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 body a]]
        set d [store markRemoteStatus alice@example.com oid1 delivered]
        set r [store markRemoteStatus alice@example.com oid1 read]
        list [dict get $d remote_status] [dict get $r remote_status] \
             [ms_remote alice@example.com]
    } -result {delivered read read}

test messagestore-mark-remote-status-forward-only {a lower-rank marker after a higher one is a no-op} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 body a]]
        store markRemoteStatus alice@example.com oid1 read
        set back [store markRemoteStatus alice@example.com oid1 delivered]
        list $back [ms_remote alice@example.com]
    } -result {{} read}

test messagestore-mark-remote-status-matches-origin-id {marker matches origin_id when own_id differs} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 origin_id orig1 body a]]
        store markRemoteStatus alice@example.com orig1 delivered
        ms_remote alice@example.com
    } -result delivered

test messagestore-mark-remote-status-unknown-id-noop {an unmatched target id changes nothing} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 body a]]
        set r [store markRemoteStatus alice@example.com nosuch read]
        list $r [ms_remote alice@example.com]
    } -result {{} none}

test messagestore-mark-remote-status-incoming-ignored {an incoming row (own_id empty) is never marked} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id "" origin_id "" body a]]
        set r [store markRemoteStatus alice@example.com "" read]
        list $r [ms_remote alice@example.com]
    } -result {{} none}

test messagestore-mark-remote-status-wrong-chat-noop {a marker scoped to another chat changes nothing} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 own_id oid1 body a]]
        set r [store markRemoteStatus bob@example.com oid1 read]
        list $r [ms_remote alice@example.com]
    } -result {{} none}

# --- Reactions (XEP-0444) ----------------------------------------------------

test messagestore-reaction-aggregate {reactions aggregate per emoji with reactor lists} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1 body hi]]
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {👍 ❤️} 100
        store applyReaction alice@example.com sid1 carol@x carol@x 0 {👍} 110
        set agg [store reactionsForMessage alice@example.com 5000]
        list [dict get $agg 👍 reactors] [dict get $agg 👍 mine] \
             [dict get $agg ❤️ reactors]
    } -result {{bob@x carol@x} 0 bob@x}

test messagestore-reaction-mine-flag {our own reaction marks the emoji as mine} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        store applyReaction alice@example.com sid1 me@x me@x 1 {🎉} 100
        dict get [store reactionsForMessage alice@example.com 5000] 🎉 mine
    } -result 1

test messagestore-reaction-lww {an older reaction set does not overwrite a newer one} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {👍} 200
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {❤️} 150
        dict keys [store reactionsForMessage alice@example.com 5000]
    } -result 👍

test messagestore-reaction-retract {an empty set retracts a reactor's reactions} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {👍} 100
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {} 110
        dict size [store reactionsForMessage alice@example.com 5000]
    } -result 0

test messagestore-reaction-before-message {a reaction stored before its target surfaces once the message lands} \
    {*}$ms_common \
    -body {
        set early [store applyReaction alice@example.com sid1 bob@x bob@x 0 {👍} 100]
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        list $early [dict keys [store reactionsForMessage alice@example.com 5000]]
    } -result {{} 👍}

test messagestore-reaction-own-set {ownReactions returns our current set for toggling} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        store applyReaction alice@example.com sid1 me@x me@x 1 {👍 🎉} 100
        store ownReactions alice@example.com sid1 me@x
    } -result {👍 🎉}

test messagestore-reaction-enriches-rowtodict {a message dict carries its reactions} \
    {*}$ms_common \
    -body {
        ms_batch [list [ms_msg timestamp 5000 server_id sid1]]
        store applyReaction alice@example.com sid1 bob@x bob@x 0 {👍} 100
        dict get [lindex [ms_msgs [store get latest alice@example.com]] 0] reactions
    } -result {👍 {reactors bob@x mine 0}}
