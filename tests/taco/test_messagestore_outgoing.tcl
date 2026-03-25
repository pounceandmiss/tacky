package require taco

set ms_out_common {
    -setup {
        sqlite3 testdb :memory:
        taco_messagestore create store -db testdb
    }
    -cleanup {
        store destroy
        testdb close
    }
}

# Helper: get the region of a message by timestamp
proc ms_region_of {ts {jid alice@example.com}} {
    testdb onecolumn {SELECT region FROM chat_message WHERE chat_jid=$jid AND timestamp=$ts}
}

# Helper: store a message in the outgoing region
proc ms_outgoing {msg} {
    set out [store region outgoing]
    store store batch [list $msg] out
}

# -- outgoing region basics ---------------------------------------------------

test messagestore-outgoing-stored {outgoing message is stored and retrievable via get latest} \
    {*}$ms_out_common \
    -body {
        ms_outgoing [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] [dict get [lindex $msgs 0] body]
    } -result {1 sent}

test messagestore-outgoing-separate-region {outgoing messages don't merge into normal regions} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body incoming]]
        ms_outgoing [ms_msg timestamp 200 body sent own_id oid1 server_status pending]
        ms_regions
    } -result {2}

test messagestore-outgoing-region-value {region outgoing returns the sentinel value} \
    {*}$ms_out_common \
    -body {
        store region outgoing
    } -result {-1}

# -- get latest + outgoing ----------------------------------------------------

test messagestore-outgoing-latest-mixed {get latest returns both incoming and outgoing in timestamp order} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

test messagestore-outgoing-latest-only {when only outgoing messages exist, get latest returns them} \
    {*}$ms_out_common \
    -body {
        ms_outgoing [ms_msg timestamp 100 body x own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 200 body y own_id oid2 server_status pending]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body]
    } -result {2 x y}

test messagestore-outgoing-latest-multiple {multiple outgoing messages all appear in get latest} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 300 body c own_id oid2 server_status pending]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

test messagestore-outgoing-latest-newest-is-outgoing {newest message is outgoing, get latest still returns real region + outgoing} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b]]
        ms_outgoing [ms_msg timestamp 500 body out own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b out}

# -- get before + outgoing ----------------------------------------------------

test messagestore-outgoing-before-includes-outgoing {get before includes outgoing messages older than cursor} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        set msgs [store get before alice@example.com 500 [ms_region_of 500]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

test messagestore-outgoing-before-multiple-outgoing {multiple outgoing messages before cursor all included} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 300 body c own_id oid2 server_status pending]
        set msgs [store get before alice@example.com 500 [ms_region_of 500]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 a b c}

# -- get after + outgoing -----------------------------------------------------

test messagestore-outgoing-after-includes-outgoing {get after includes outgoing messages newer than cursor} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 400 body d own_id oid1 server_status pending]
        set msgs [store get after alice@example.com 100 [ms_region_of 100]]
        list [llength $msgs] \
             [dict get [lindex $msgs 0] body] \
             [dict get [lindex $msgs 1] body] \
             [dict get [lindex $msgs 2] body]
    } -result {3 c d e}

# -- region resolve -----------------------------------------------------------

test messagestore-outgoing-resolve-backward {region resolve on outgoing ts with -backward finds nearest older real region} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_outgoing [ms_msg timestamp 200 body out own_id oid1 server_status pending]
        set realReg [testdb onecolumn {
            SELECT region FROM chat_message WHERE timestamp=100
        }]
        set resolved [store region resolve alice@example.com 200 -backward]
        expr {$resolved == $realReg}
    } -result {1}

test messagestore-outgoing-resolve-forward {region resolve on outgoing ts with -forward finds nearest newer real region} \
    {*}$ms_out_common \
    -body {
        ms_outgoing [ms_msg timestamp 100 body out own_id oid1 server_status pending]
        ms_batch [list [ms_msg timestamp 200 body a]]
        set realReg [testdb onecolumn {
            SELECT region FROM chat_message WHERE timestamp=200
        }]
        set resolved [store region resolve alice@example.com 100 -forward]
        expr {$resolved == $realReg}
    } -result {1}

test messagestore-outgoing-resolve-nonoutgoing-passthrough {region resolve on normal message returns its region directly} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        set realReg [testdb onecolumn {
            SELECT region FROM chat_message WHERE timestamp=100
        }]
        set back [store region resolve alice@example.com 100 -backward]
        set fwd [store region resolve alice@example.com 100 -forward]
        list [expr {$back == $realReg}] [expr {$fwd == $realReg}]
    } -result {1 1}

test messagestore-outgoing-resolve-missing-ts {region resolve on nonexistent ts returns empty} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        store region resolve alice@example.com 999 -backward
    } -result {}

test messagestore-outgoing-resolve-no-real-messages {region resolve on outgoing ts when no real regions exist returns empty} \
    {*}$ms_out_common \
    -body {
        ms_outgoing [ms_msg timestamp 100 body out own_id oid1 server_status pending]
        store region resolve alice@example.com 100 -backward
    } -result {}

# -- prev annotation + outgoing -----------------------------------------------

test messagestore-outgoing-prev-chains-through {prev chains through outgoing and incoming messages together} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        list [dict get [lindex $msgs 0] prev] \
             [dict get [lindex $msgs 1] prev] \
             [dict get [lindex $msgs 2] prev]
    } -result {{} 100 200}

test messagestore-outgoing-prev-first-is-outgoing {first message in batch is outgoing; prev still finds DB predecessor} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c]]
        ms_outgoing [ms_msg timestamp 200 body b own_id oid1 server_status pending]
        # get before 300: region is same as 300;
        # returns a(100) + outgoing b(200), both before cursor
        set msgs [store get before alice@example.com 300 [ms_region_of 300]]
        list [dict get [lindex $msgs 0] prev] \
             [dict get [lindex $msgs 1] prev]
    } -result {{} 100}

test messagestore-outgoing-prev-region-boundary-respected {outgoing messages near a region gap don't cause prev to leak across} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b]]
        ms_batch [list \
            [ms_msg timestamp 500 body c] \
            [ms_msg timestamp 600 body d]]
        ms_outgoing [ms_msg timestamp 450 body out own_id oid1 server_status pending]
        # get latest returns region 2 (c,d) + outgoing (out)
        # out(450) is between regions but prev must not leak into region 1
        set msgs [store get latest alice@example.com]
        # order: out(450), c(500), d(600); out's prev is empty (no region 2 predecessor)
        list [llength $msgs] \
             [dict get [lindex $msgs 0] prev] \
             [dict get [lindex $msgs 1] prev] \
             [dict get [lindex $msgs 2] prev]
    } -result {3 {} 450 500}

# -- get around + outgoing ----------------------------------------------------

test messagestore-outgoing-around-includes-outgoing {get around targeting incoming includes nearby outgoing} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 400 body d] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 300 body c own_id oid1 server_status pending]
        set result [store get around alice@example.com 300 10]
        set msgs [dict get $result messages]
        # outgoing message at 300 is nearest; before/after pull from its resolved region + outgoing
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {a b c d e}

test messagestore-outgoing-around-target-is-outgoing {get around snapping to outgoing message still works} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 300 body out own_id oid1 server_status pending]
        set result [store get around alice@example.com 300 10]
        set anchor [dict get $result anchor]
        set msgs [dict get $result messages]
        list $anchor [llength $msgs]
    } -result {300 3}

# -- outgoing + multiple regions ----------------------------------------------

test messagestore-outgoing-across-gap {outgoing in gap between regions; get latest shows latest region + outgoing} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b]]
        ms_batch [list \
            [ms_msg timestamp 500 body c] \
            [ms_msg timestamp 600 body d]]
        ms_outgoing [ms_msg timestamp 350 body gap own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {gap c d}

test messagestore-outgoing-confirmed-still-visible {outgoing message with server_status=received still appears} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_outgoing [ms_msg timestamp 200 body sent own_id oid1 server_status received]
        set msgs [store get latest alice@example.com]
        list [llength $msgs] [dict get [lindex $msgs 1] body]
    } -result {2 sent}

# -- UNION: LIMIT applies only to real-region arm -----------------------------

test messagestore-outgoing-limit-real-only {LIMIT caps real-region arm; outgoing rides alongside unlimited} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 500 body e]]
        ms_outgoing [ms_msg timestamp 150 body o1 own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 250 body o2 own_id oid2 server_status pending]
        # limit=2: only 2 real messages before 500, but both outgoing included
        set msgs [store get before alice@example.com 500 [ms_region_of 500] 2]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {o1 b o2 c}

test messagestore-outgoing-limit-real-only-after {LIMIT on real arm for get after; outgoing unlimited} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body c] \
            [ms_msg timestamp 500 body e] \
            [ms_msg timestamp 700 body g]]
        ms_outgoing [ms_msg timestamp 400 body o1 own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 600 body o2 own_id oid2 server_status pending]
        # limit=2: only 2 real messages after 100, but both outgoing included
        set msgs [store get after alice@example.com 100 [ms_region_of 100] 2]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {c o1 e o2}

test messagestore-outgoing-limit-real-only-latest {LIMIT on real arm for get latest; outgoing unlimited} \
    {*}$ms_out_common \
    -body {
        ms_batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 200 body b] \
            [ms_msg timestamp 300 body c]]
        ms_outgoing [ms_msg timestamp 50 body o1 own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 150 body o2 own_id oid2 server_status pending]
        # limit=2: only 2 real messages (latest), but both outgoing included
        set msgs [store get latest alice@example.com 2]
        set bodies {}
        foreach m $msgs { lappend bodies [dict get $m body] }
        set bodies
    } -result {o1 o2 b c}

# -- region field values -------------------------------------------------------

test messagestore-outgoing-region-field-value {outgoing messages have region=-1 in returned dicts} \
    {*}$ms_out_common \
    -body {
        ms_batch [list [ms_msg timestamp 100 body a]]
        ms_outgoing [ms_msg timestamp 200 body out own_id oid1 server_status pending]
        set msgs [store get latest alice@example.com]
        list [expr {[dict get [lindex $msgs 0] region] > 0}] \
             [dict get [lindex $msgs 1] region]
    } -result {1 -1}

# -- confirmation: timestamp + region move -------------------------------------

test messagestore-outgoing-confirm-moves-region {echo confirmation moves message from outgoing to real region} \
    {*}$ms_out_common \
    -body {
        store region new live
        ms_outgoing [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        # Echo arrives with same timestamp, server_id, matched by own_id
        set result [store store batch [list \
            [ms_msg timestamp 100 server_id srv1 own_id oid1 body sent]] live]
        set confirmed [dict get $result confirmed]
        set c [lindex $confirmed 0]
        # Message should now be in the live region
        set dbRegion [testdb onecolumn {
            SELECT region FROM chat_message WHERE chat_jid='alice@example.com'
        }]
        list [dict get $c timestamp] [dict get $c newtimestamp] \
             [expr {$dbRegion == $live}]
    } -result {100 100 1}

test messagestore-outgoing-confirm-timestamp-change {echo with different timestamp moves message to new position} \
    {*}$ms_out_common \
    -body {
        store region new live
        store store batch [list [ms_msg timestamp 50 body earlier]] live
        ms_outgoing [ms_msg timestamp 100 body sent own_id oid1 server_status pending]
        # Echo arrives with server timestamp 200 (different from local 100)
        set result [store store batch [list \
            [ms_msg timestamp 200 server_id srv1 own_id oid1 body sent]] live]
        set c [lindex [dict get $result confirmed] 0]
        # Old timestamp gone, new timestamp exists
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

test messagestore-outgoing-confirm-no-bulk-merge {confirmation does not bulk-move other outgoing messages} \
    {*}$ms_out_common \
    -body {
        store region new live
        ms_outgoing [ms_msg timestamp 100 body sent1 own_id oid1 server_status pending]
        ms_outgoing [ms_msg timestamp 200 body sent2 own_id oid2 server_status pending]
        # Confirm only oid1 via echo
        store store batch [list \
            [ms_msg timestamp 100 server_id srv1 own_id oid1 body sent1]] live
        # sent2 should still be in outgoing region
        set r2 [testdb onecolumn {
            SELECT region FROM chat_message
            WHERE chat_jid='alice@example.com' AND timestamp=200
        }]
        expr {$r2 == [store region outgoing]}
    } -result {1}

test messagestore-outgoing-reorder-end-to-end {confirmed message reorders correctly in query results} \
    {*}$ms_out_common \
    -body {
        store region new live
        # A(100) → B(300) → C(500) in real region
        store store batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body b] \
            [ms_msg timestamp 500 body c]] live
        # X(200) outgoing, sits between A and B visually
        ms_outgoing [ms_msg timestamp 200 body x own_id oid1 server_status pending]

        # Before confirmation: order is a, x, b, c
        set before [store get latest alice@example.com]
        set beforeBodies {}
        foreach m $before { lappend beforeBodies [dict get $m body] }

        # Server confirms X at timestamp 400 (between B and C)
        store store batch [list \
            [ms_msg timestamp 400 server_id srv1 own_id oid1 body x]] live

        # After confirmation: order should be a, b, x, c
        set after [store get latest alice@example.com]
        set afterBodies {}
        foreach m $after { lappend afterBodies [dict get $m body] }

        # Prev chain should be correct: a→{}, b→100, x→300, c→400
        set prevs {}
        foreach m $after { lappend prevs [dict get $m prev] }

        list $beforeBodies $afterBodies $prevs
    } -result {{a x b c} {a b x c} {{} 100 300 400}}

# -- ComputeMovePatch ---------------------------------------------------------

test messagestore-outgoing-move-patch-followers {ComputeMovePatch computes correct follower entries} \
    {*}$ms_out_common \
    -body {
        store region new live
        store store batch [list \
            [ms_msg timestamp 100 body a] \
            [ms_msg timestamp 300 body b] \
            [ms_msg timestamp 500 body c]] live
        # Simulate: message moved from 200 to 400 (already in DB at 400)
        # We just test the query logic
        testdb eval {
            INSERT INTO chat_message(timestamp,chat_jid,from_jid,body,
                server_id,own_id,raw_xml,region,server_status)
            VALUES(400,'alice@example.com','me@example.com','moved',
                '','','', $live, 'received')
        }
        set result [store ComputeMovePatch alice@example.com 200 400 $live]
        set prev [dict get $result prev]
        set entries [dict get $result entries]
        # moved msg prev = 300 (b is before 400)
        # old follower (after 200) = 300 (b), new prev = 100 (a)
        # new follower (after 400) = 500 (c), new prev = 400
        list $prev \
             [llength $entries] \
             [dict get [lindex $entries 0] timestamp] \
             [dict get [lindex $entries 0] prev] \
             [dict get [lindex $entries 1] timestamp] \
             [dict get [lindex $entries 1] prev]
    } -result {300 2 300 100 500 400}

test messagestore-outgoing-move-patch-no-neighbors {ComputeMovePatch with no neighbors returns only self-referential follower} \
    {*}$ms_out_common \
    -body {
        store region new live
        # Only the moved message exists at newTs
        testdb eval {
            INSERT INTO chat_message(timestamp,chat_jid,from_jid,body,
                server_id,own_id,raw_xml,region,server_status)
            VALUES(400,'alice@example.com','me@example.com','alone',
                '','','', $live, 'received')
        }
        set result [store ComputeMovePatch alice@example.com 200 400 $live]
        # prev is empty (no predecessor), moved message is its own
        # "new follower" (after oldTs=200) — harmless redundancy
        set entries [dict get $result entries]
        list [dict get $result prev] [llength $entries] \
             [dict get [lindex $entries 0] timestamp]
    } -result {{} 1 400}
