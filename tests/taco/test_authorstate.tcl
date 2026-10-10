# Tests for taco_authorstate (per-chat author display state).
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

set author_common [tacky_env -mock conn -account $acc]

proc roster_set {jid name} {
    $::_client db eval {
        INSERT OR REPLACE INTO roster_item(jid, name, subscription, ask, approved)
        VALUES ($jid, $name, 'both', '', 0)
    }
}

proc pep_nick_set {jid nick} {
    $::_client db eval {
        INSERT OR REPLACE INTO pep_nick(jid, nick) VALUES ($jid, $nick)
    }
}

proc insert_msg {chatJid fromJid args} {
    set defaults [dict create \
        timestamp [clock microseconds] \
        from_resource "" body "hi" server_id "" own_id "" raw_xml "" \
        server_status ""]
    set msg [dict merge $defaults [dict create chat_jid $chatJid from_jid $fromJid] $args]
    $::_client message messagestore store [list $msg]
}

# -- 1:1 resolution -----------------------------------------------------------

test author-1to1-bare-fallback {1:1 with no roster/PEP entry returns bare JID for both authors} \
    {*}$author_common \
    -body {
        set names [tacky author get -acc $acc -chat alice@example.com]
        list [dict get $names alice@example.com] \
             [dict get $names user@test.example.com]
    } -result {alice@example.com user@test.example.com}

test author-1to1-roster-name-wins {1:1 prefers roster name when present} \
    {*}$author_common \
    -body {
        roster_set alice@example.com "Alice Wonderland"
        set names [tacky author get -acc $acc -chat alice@example.com]
        dict get $names alice@example.com
    } -result {Alice Wonderland}

test author-1to1-pep-nick-fallback {1:1 falls back to PEP nick when no roster name} \
    {*}$author_common \
    -body {
        pep_nick_set alice@example.com "Wonderland"
        set names [tacky author get -acc $acc -chat alice@example.com]
        dict get $names alice@example.com
    } -result {Wonderland}

test author-1to1-roster-wins-over-pep {1:1 roster name takes precedence over PEP nick} \
    {*}$author_common \
    -body {
        roster_set alice@example.com "RosterAlice"
        pep_nick_set alice@example.com "PepAlice"
        set names [tacky author get -acc $acc -chat alice@example.com]
        dict get $names alice@example.com
    } -result {RosterAlice}

test author-1to1-own-nick-resolved {1:1 resolves own bare via PEP nick} \
    {*}$author_common \
    -body {
        pep_nick_set user@test.example.com "MeMyself"
        set names [tacky author get -acc $acc -chat alice@example.com]
        dict get $names user@test.example.com
    } -result {MeMyself}

# -- MUC resolution -----------------------------------------------------------

test author-muc-historical-from-store {MUC seeds entries from distinct from_jids in the message store} \
    {*}$author_common \
    -body {
        insert_msg room@muc.example.com?join room@muc.example.com/alice
        insert_msg room@muc.example.com?join room@muc.example.com/bob
        set names [tacky author get -acc $acc -chat room@muc.example.com?join]
        list [dict get $names room@muc.example.com/alice] \
             [dict get $names room@muc.example.com/bob]
    } -result {alice bob}

test author-muc-pm-historical {MUC PM seeds entries from distinct from_jids in the message store} \
    {*}$author_common \
    -body {
        insert_msg room@muc.example.com/alice room@muc.example.com/alice
        set names [tacky author get -acc $acc -chat room@muc.example.com/alice]
        dict get $names room@muc.example.com/alice
    } -result {alice}

# -- Events -------------------------------------------------------------------

test author-emit-on-roster-change {roster <Changed> for an active 1:1 peer emits author <Changed>} \
    {*}$author_common \
    -body {
        # Seed the cache for the chat
        tacky author get -acc $acc -chat alice@example.com
        set ::_got {}
        tacky listen author <Changed> -acc $acc \
            -chat alice@example.com {apply {{ev} { set ::_got $ev }}}
        roster_set alice@example.com "AliceUpdated"
        $::_client emit roster <Changed> -action update -jid alice@example.com
        list [dict get $::_got -from] [dict get $::_got -name]
    } -result {alice@example.com AliceUpdated}

test author-emit-on-nick-change {nick <Changed> for an active peer emits author <Changed>} \
    {*}$author_common \
    -body {
        tacky author get -acc $acc -chat alice@example.com
        set ::_got {}
        tacky listen author <Changed> -acc $acc \
            -chat alice@example.com {apply {{ev} { set ::_got $ev }}}
        pep_nick_set alice@example.com "NickedAlice"
        $::_client emit nick <Changed> -jid alice@example.com
        list [dict get $::_got -from] [dict get $::_got -name]
    } -result {alice@example.com NickedAlice}

test author-no-emit-on-no-diff {no event when re-resolving yields the same name} \
    {*}$author_common \
    -body {
        roster_set alice@example.com "Alice"
        tacky author get -acc $acc -chat alice@example.com
        set ::_got NONE
        tacky listen author <Changed> -acc $acc \
            -chat alice@example.com {apply {{ev} { set ::_got $ev }}}
        $::_client emit roster <Changed> -action update -jid alice@example.com
        set ::_got
    } -result {NONE}

test author-emit-only-for-tracked-chats {events for untracked chats do not emit} \
    {*}$author_common \
    -body {
        # Track only alice's chat. Then change bob's name.
        tacky author get -acc $acc -chat alice@example.com
        roster_set bob@example.com "Bob"
        set ::_got NONE
        tacky listen author <Changed> -acc $acc \
            {apply {{ev} { set ::_got $ev }}}
        $::_client emit roster <Changed> -action update -jid bob@example.com
        set ::_got
    } -result {NONE}

# A nick the room showed only by presence goes when the occupant leaves or
# changes nick, or when we leave; one the store has messages from stays for
# the history.
test author-muc-presence-only-nick-goes-with-the-occupant \
    {a presence-only author goes on leave or nick change, an author with stored messages stays} \
    {*}$author_common \
    -body {
        set room room@muc.example.com
        insert_msg $room?join $room/talker
        tacky author get -acc $acc -chat $room?join
        foreach n {lurker cycler talker stayer} {
            $::_client emit muc <Presence> -jid $room -nick $n -occupant {}
        }
        $::_client emit muc <Presence> -jid $room -nick cycler2 -occupant {}
        $::_client emit muc <NickChanged> -jid $room -oldNick cycler -newNick cycler2 \
            -self 0 -occupant {}
        $::_client emit muc <Unavailable> -jid $room -nick lurker -reason "" \
            -codes {} -occupant {}
        $::_client emit muc <Unavailable> -jid $room -nick talker -reason "" \
            -codes {} -occupant {}
        set mid [lsort [dict keys [tacky author get -acc $acc -chat $room?join]]]
        $::_client emit muc <Left> -jid $room -nick me -involuntary 0 -codes {}
        list $mid [lsort [dict keys [tacky author get -acc $acc -chat $room?join]]]
    } -result {{room@muc.example.com/cycler2 room@muc.example.com/stayer room@muc.example.com/talker} room@muc.example.com/talker}
