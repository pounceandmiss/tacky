# rowlist has no Tk in it, so these assert the ordering and identity rules
# directly - no widget, no geometry, no event loop.

proc rl_new {} {
    catch {rl destroy}
    rowlist rl
    return rl
}

proc rl_fill {args} {
    rl_new
    foreach {key sort} $args { rl insert $key $sort }
    return rl
}

test rowlist-orders-by-sort {rows land in ascending sort order whatever the insert order} \
    -body {
        rl_fill c 300 a 100 b 200
        rl keys
    } -result {a b c}

test rowlist-ties-break-on-key {rows sharing a sort order by key, and both survive} \
    -body {
        rl_fill bob@example.com 100 alice@example.com 100
        list [rl size] [rl keys]
    } -result {2 {alice@example.com bob@example.com}}

test rowlist-slots-are-unique-and-not-reused {a removed row's slot is never handed out again} \
    -body {
        rl_new
        set first [rl insert a 100]
        rl remove a
        set second [rl insert b 200]
        rl clear
        set third [rl insert c 300]
        expr {$first ne $second && $second ne $third && $first ne $third}
    } -result 1

test rowlist-keyof-round-trips {a slot resolves back to the key that owns it} \
    -body {
        rl_new
        set slot [rl insert room@conf.example.com?join|1700 1700]
        list [rl keyof $slot] [rl keyof 99999]
    } -result {room@conf.example.com?join|1700 {}}

test rowlist-successor-is-the-row-to-insert-before {successor reports the first row sorting after} \
    -body {
        rl_fill a 100 c 300
        # Between the two, before the first, and past the last.
        list [rl keyof [rl successor b 200]] \
             [rl keyof [rl successor aa 50]] \
             [rl successor z 400]
    } -result {c a {}}

test rowlist-merge-keeps-untouched-fields {a single-field merge leaves the other fields alone} \
    -body {
        rl_new
        rl insert a 100 {server_status "" remote_status none}
        rl merge a {remote_status delivered}
        list [rl field a server_status] [rl field a remote_status]
    } -result {{} delivered}

test rowlist-merge-cannot-rewrite-identity {slot, key and sort ignore a merge that names them} \
    -body {
        rl_new
        set slot [rl insert a 100]
        rl merge a [list slot 999 key b sort 500]
        list [rl field a slot] [rl keys] [rl field a sort] [expr {$slot ne 999}]
    } -result {1 a 100 1}

test rowlist-absent-key-is-quiet {lookups and mutations on an unknown key don't throw} \
    -body {
        rl_fill a 100
        rl merge nosuch {server_status failed}
        list [rl index nosuch] [rl slot nosuch] [rl get nosuch] \
             [rl field nosuch payload] [rl remove nosuch] [rl size]
    } -result {-1 {} {} {} {} 1}

test rowlist-at-handles-empty-and-end {at returns "" when empty and accepts end} \
    -body {
        rl_new
        set whenEmpty [rl at 0]
        rl insert a 100
        rl insert b 200
        list $whenEmpty [dict get [rl at 0] key] [dict get [rl at end] key]
    } -result {{} a b}

test rowlist-clear-returns-what-it-dropped {clear hands back the rows so a caller can release their resources} \
    -body {
        rl_new
        rl insert a 100 {avatar_jid alice@example.com}
        rl insert b 200 {avatar_jid bob@example.com}
        set dropped [lmap row [rl clear] {dict get $row avatar_jid}]
        list $dropped [rl size]
    } -result {{alice@example.com bob@example.com} 0}

catch {rl destroy}
