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
                j TYPE -body image/png
                j BINVAL -body $b64
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
            j photo -body $hash
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

test avatar-visible-no-data-silent {an <Update> waits for the bytes, it does not announce a hash the cache cannot serve} \
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

# Helper: a PEP metadata push announcing $hash
proc pep_metadata {from hash} {
    j message -from $from {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node urn:xmpp:avatar:metadata {
                j item -id $hash {
                    j metadata -ns urn:xmpp:avatar:metadata {
                        j info -id $hash -type image/png -bytes 10 \
                            -width 64 -height 64
                    }
                }
            }
        }
    }
}

proc avatar_data_requested {} {
    foreach stanza [c.conn get_written] {
        if {[xsearch $stanza pubsub items -get @node] eq "urn:xmpp:avatar:data"} {
            return 1
        }
    }
    return 0
}

proc avatar_vcard_requested {} {
    foreach stanza [c.conn get_written] {
        if {[xsearch $stanza vCard -ns vcard-temp] ne ""} {
            return 1
        }
    }
    return 0
}

test avatar-visible-survives-disconnect {a dropped connection leaves a visible JID marked} \
    {*}$avatar_common \
    -body {
        c avatar visible -jid alice@example.com
        c bus publish <Disconnect>
        c.conn clear
        c.conn feed [pep_metadata alice@example.com newhash]
        avatar_data_requested
    } -result 1

test avatar-invisible-parks-fetch {an unmarked JID's new hash is parked, not fetched} \
    {*}$avatar_common \
    -body {
        c.conn clear
        c.conn feed [pep_metadata alice@example.com newhash]
        avatar_data_requested
    } -result 0

# Bytes missing behind a cached hash: what a failed fetch, or a process that
# ended between the announcement and the download, leaves in the metadata table.
# The pending-hash dicts that would re-ask are dropped with the session, so the
# next mark is the last thing in a position to.

test avatar-visible-refetches-missing-pubsub-bytes {a mark re-fetches PEP bytes the cache is missing} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com abc123 -data ""
        c.conn clear
        c avatar visible -jid alice@example.com
        avatar_data_requested
    } -result 1

test avatar-visible-refetches-missing-vcard-bytes {a vCard avatar is re-asked of the JID, not of its PEP node} \
    {*}$avatar_common \
    -body {
        avatar_seed room@muc.example.com/nick abc123 -source vcard -data ""
        c.conn clear
        c avatar visible -jid room@muc.example.com/nick
        list [avatar_vcard_requested] [avatar_data_requested]
    } -result {1 0}

test avatar-visible-refetches-missing-bytes-once {a repeated mark does not re-ask for bytes this session already went after} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com abc123 -data ""
        c avatar visible -jid alice@example.com
        c avatar invisible -jid alice@example.com
        c.conn clear
        c avatar visible -jid alice@example.com
        avatar_data_requested
    } -result 0

test avatar-visible-refetches-changed-hash {a hash that moved on since the unanswered fetch is asked for} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com abc123 -data ""
        c avatar visible -jid alice@example.com
        c avatar invisible -jid alice@example.com
        avatar_seed alice@example.com def456 -data ""
        c.conn clear
        c avatar visible -jid alice@example.com
        avatar_data_requested
    } -result 1

test avatar-visible-cached-asks-for-nothing {bytes already held are served without a round trip} \
    {*}$avatar_common \
    -body {
        avatar_seed alice@example.com abc123
        c.conn clear
        c avatar visible -jid alice@example.com
        list [avatar_vcard_requested] [avatar_data_requested]
    } -result {0 0}

test avatar-visible-unknown-jid-asks-for-nothing {a JID with no metadata row has nothing to re-fetch} \
    {*}$avatar_common \
    -body {
        c.conn clear
        c avatar visible -jid stranger@example.com
        list [avatar_vcard_requested] [avatar_data_requested]
    } -result {0 0}

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

# inject: offline cache seeding

test avatar-inject-seeds-cache {inject caches bytes and metadata and emits <Update>} \
    {*}$avatar_common \
    -body {
        avatar_watch
        set hash [c avatar inject -jid alice@example.com -data "seededbytes" \
                      -width 64 -height 64]
        update idletasks
        list [expr {$hash eq [::sha1::sha1 -hex "seededbytes"]}] \
             [c avatar metadata -jid alice@example.com] \
             [c avatar data -hash $hash] \
             $::avatar_updates
    } -result [list 1 \
        [list hash [::sha1::sha1 -hex "seededbytes"] type image/png bytes 11 \
              width 64 height 64] \
        seededbytes \
        [list [list alice@example.com [::sha1::sha1 -hex "seededbytes"]]]]

test avatar-inject-outranks-vcard {an injected avatar is not clobbered by a vCard presence} \
    {*}$avatar_common \
    -body {
        set hash [c avatar inject -jid room@muc.example.com/nick -data "seededbytes"]
        avatar_watch
        c avatar OnVCardPresence room@muc.example.com/nick \
            [vcard_presence room@muc.example.com/nick otherhash]
        update idletasks
        list [lindex [avatar_row room@muc.example.com/nick] 0] $::avatar_updates
    } -result [list [::sha1::sha1 -hex "seededbytes"] {}]

test avatar-inject-empty-clears {empty -data clears the JID and signals removal} \
    {*}$avatar_common \
    -body {
        c avatar inject -jid alice@example.com -data "seededbytes"
        avatar_watch
        set res [c avatar inject -jid alice@example.com -data ""]
        update idletasks
        list $res [avatar_row alice@example.com] $::avatar_updates
    } -result {{} {} {{alice@example.com {}}}}

test avatar-inject-empty-uncached-silent {clearing a JID with no avatar emits nothing} \
    {*}$avatar_common \
    -body {
        avatar_watch
        c avatar inject -jid alice@example.com -data ""
        update idletasks
        set ::avatar_updates
    } -result {}

# publish/disable: local cache and the -command/-onerror contract

proc avatar_iq_error {id text} {
    j iq -type error -id $id {
        j error -type cancel {
            j forbidden -ns urn:ietf:params:xml:ns:xmpp-stanzas
            j text -ns urn:ietf:params:xml:ns:xmpp-stanzas -body $text
        }
    }
}

test avatar-publish-caches-before-echo {a confirmed publish caches locally and answers -command} \
    {*}$avatar_common \
    -body {
        avatar_watch
        set ::avatar_reply pending
        c.conn clear
        c avatar publish -acc user@test.example.com -data "pngbytes" \
            -width 128 -height 128 \
            -command {apply {{msg} {set ::avatar_reply [list replied $msg]}}}
        c.conn feed [j iq -type result \
            -id [xsearch [lindex [c.conn get_written] end] -get @id]]
        c.conn feed [j iq -type result \
            -id [xsearch [lindex [c.conn get_written] end] -get @id]]
        update idletasks
        list $::avatar_reply [avatar_row user@test.example.com] $::avatar_updates
    } -result [list {replied {}} \
        [list [::sha1::sha1 -hex pngbytes] 128 pubsub] \
        [list [list user@test.example.com [::sha1::sha1 -hex pngbytes]]]]

test avatar-publish-rejected {a rejected publish reports through -onerror} \
    {*}$avatar_common \
    -body {
        set ::avatar_err ""
        c.conn clear
        c avatar publish -acc user@test.example.com -data "pngbytes" \
            -onerror {apply {{msg} {set ::avatar_err $msg}}}
        c.conn feed [avatar_iq_error \
            [xsearch [lindex [c.conn get_written] end] -get @id] "No room"]
        list $::avatar_err [avatar_row user@test.example.com]
    } -result {{No room} {}}

test avatar-publish-early-failure-answers {a publish failing before the wire still answers} \
    {*}$avatar_common \
    -body {
        set ::avatar_err ""
        c avatar publish -acc user@test.example.com \
            -onerror {apply {{msg} {set ::avatar_err $msg}}}
        expr {$::avatar_err ne ""}
    } -result 1

test avatar-disable-clears-own-cache {a confirmed disable drops the local copy and signals removal} \
    {*}$avatar_common \
    -body {
        avatar_seed user@test.example.com abc123
        avatar_watch
        c.conn clear
        c avatar disable
        c.conn feed [j iq -type result \
            -id [xsearch [lindex [c.conn get_written] end] -get @id]]
        update idletasks
        list [avatar_row user@test.example.com] $::avatar_updates
    } -result {{} {{user@test.example.com {}}}}

test avatar-disable-rejected {a rejected disable keeps the cache and reports through -onerror} \
    {*}$avatar_common \
    -body {
        avatar_seed user@test.example.com abc123
        avatar_watch
        set ::avatar_err ""
        c.conn clear
        c avatar disable -onerror {apply {{msg} {set ::avatar_err $msg}}}
        c.conn feed [avatar_iq_error \
            [xsearch [lindex [c.conn get_written] end] -get @id] "No room"]
        update idletasks
        list $::avatar_err [lindex [avatar_row user@test.example.com] 0] \
            $::avatar_updates
    } -result {{No room} abc123 {}}

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
