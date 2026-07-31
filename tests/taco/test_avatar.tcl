# Tests for taco_avatar: cache priming on visible, XEP-0084 over XEP-0153
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set avatar_common [tacky_env -mock conn -taco-client {
    -host test.example.com -port 5222
    -username user -password pass -resource res
}]

# Helper: seed a cached avatar. -data "" stores metadata without the blob.
proc avatar_seed {jid hash args} {
    array set opts {-source pubsub -data "imagebytes" -width 64 -height 64}
    array set opts $args
    set bytes [string length $opts(-data)]
    c db eval {
        INSERT OR REPLACE INTO avatar_metadata(jid, hash, type, bytes, width, height, source)
        VALUES ($jid, $hash, 'image/png', $bytes, $opts(-width), $opts(-height), $opts(-source))
    }
    if {$opts(-data) ne ""} {
        c db eval {
            INSERT OR REPLACE INTO avatar_data(hash, data) VALUES ($hash, $opts(-data))
        }
    }
}

# Helper: collect avatar <Update> events as {jid hash} pairs
proc avatar_watch {} {
    set ::avatar_updates {}
    tacky listen avatar <Update> {apply {{ev} {
        lappend ::avatar_updates [list [dict get $ev -jid] [dict get $ev -hash]]
    }}}
}

proc avatar_row {jid} {
    c db eval {
        SELECT hash, width, source FROM avatar_metadata WHERE jid=$jid
    } row {
        return [list $row(hash) $row(width) $row(source)]
    }
    return {}
}

# Helper: a vCard IQ result carrying a PHOTO
proc vcard_result {jid data} {
    set b64 [binary encode base64 -maxlen 0 $data]
    j iq -type result -from $jid {
        j vCard -ns vcard-temp {
            j PHOTO {
                j TYPE #body image/png
                j BINVAL #body $b64
            }
        }
    }
}

# Helper: presence with <x xmlns='vcard-temp:x:update'>; empty hash = no <photo>
proc vcard_presence {from hash} {
    if {$hash eq ""} {
        return [j presence -from $from {
            j x -ns vcard-temp:x:update
        }]
    }
    j presence -from $from {
        j x -ns vcard-temp:x:update {
            j photo #body $hash
        }
    }
}

# visible primes from cache

test avatar-visible-primes-cached {visible surfaces an already-cached avatar} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com abc123 -source vcard
        avatar_watch
        c avatar visible -jid room@muc.example.com
        update idletasks
        set ::avatar_updates
    } -result {{room@muc.example.com abc123}}

test avatar-visible-primes-strips-join {a group chat JID's ?join suffix is not part of the lookup} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com abc123 -source vcard
        avatar_watch
        c avatar visible -jid room@muc.example.com?join
        update idletasks
        set ::avatar_updates
    } -result {{room@muc.example.com abc123}}

test avatar-visible-no-data-silent {visible stays quiet when the bytes are not cached} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com abc123 -source vcard -data ""
        avatar_watch
        c avatar visible -jid room@muc.example.com
        update idletasks
        set ::avatar_updates
    } -result {}

test avatar-visible-once-per-transition {only the 0->1 visible transition primes} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com abc123 -source vcard
        avatar_watch
        c avatar visible -jid room@muc.example.com
        c avatar visible -jid room@muc.example.com
        update idletasks
        llength $::avatar_updates
    } -result 1

test avatar-visible-reprimes-after-invisible {a fresh 0->1 transition primes again} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com abc123 -source vcard
        avatar_watch
        c avatar visible -jid room@muc.example.com
        c avatar invisible -jid room@muc.example.com
        c avatar visible -jid room@muc.example.com
        update idletasks
        llength $::avatar_updates
    } -result 2

# XEP-0084 (PEP) beats XEP-0153 (vCard)

test avatar-vcard-keeps-pubsub {a vCard result never overwrites a PEP avatar} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com pephash -source pubsub
        avatar_watch
        c avatar OnVCardResult alice@example.com \
            [vcard_result alice@example.com "legacybytes"]
        update idletasks
        list [avatar_row alice@example.com] $::avatar_updates
    } -result {{pephash 64 pubsub} {}}

test avatar-vcard-presence-no-wipe {an empty vCard photo does not clear a PEP avatar} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com pephash -source pubsub
        avatar_watch
        c avatar OnVCardPresence alice@example.com \
            [vcard_presence alice@example.com ""]
        update idletasks
        list [avatar_row alice@example.com] $::avatar_updates
    } -result {{pephash 64 pubsub} {}}

test avatar-vcard-presence-clears-vcard {an empty vCard photo does clear a vCard avatar} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com/nick vc -source vcard
        avatar_watch
        c avatar OnVCardPresence room@muc.example.com/nick \
            [vcard_presence room@muc.example.com/nick ""]
        update idletasks
        list [avatar_row room@muc.example.com/nick] $::avatar_updates
    } -result {{} {{room@muc.example.com/nick {}}}}

test avatar-vcard-writes-when-no-pubsub {vCard still stores an avatar for a JID with no PEP row} \
    {*}$avatar_common \
    -body {
        avatar_watch
        set data "occupantbytes"
        c avatar OnVCardResult room@muc.example.com/nick \
            [vcard_result room@muc.example.com/nick $data]
        update idletasks
        set hash [::sha1::sha1 $data]
        list [avatar_row room@muc.example.com/nick] \
             [expr {$::avatar_updates eq [list [list room@muc.example.com/nick $hash]]}]
    } -result [list [list [::sha1::sha1 "occupantbytes"] 0 vcard] 1]
