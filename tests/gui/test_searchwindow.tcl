# Unit tests for searchwindow - chat search with an opt-in server pass
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn

# -- helpers --------------------------------------------------------------------

proc sw_setup {} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc user@test.example.com
    set ::_client [tacky client user@test.example.com]
    $::_client.conn configure -bound-jid user@test.example.com/res1
    $::_client.conn fire_ready 0
    $::_client.conn clear
}

proc sw_cleanup {} {
    destroy .sw
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
}

proc sw_create {} {
    searchwindow .sw -acc user@test.example.com -jid alice@example.com
    wait
}

# The id of the pending field-discovery IQ (a MAM query with no queryid).
proc sw_fields_iq {} {
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""
            && [xsearch $stanza query -ns urn:xmpp:mam:2 -get @queryid] eq ""} {
            return [dict get $stanza attrs id]
        }
    }
    return ""
}

# Answer that discovery with an archive advertising $fields.
proc sw_answer_fields {fields} {
    set iqId [sw_fields_iq]
    $::_client iq feed [j iq -type result -id $iqId {
        j query -ns urn:xmpp:mam:2 {
            j x -ns jabber:x:data -type form {
                j field -var FORM_TYPE -type hidden {
                    j value -body urn:xmpp:mam:2
                }
                foreach f $fields {
                    j field -var $f
                }
            }
        }
    }]
    wait
}

# MAM search queries written so far (discovery carries no queryid).
proc sw_search_queries {} {
    set n 0
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2 -get @queryid] ne ""} {
            incr n
        }
    }
    return $n
}

# -- tests ----------------------------------------------------------------------

test sw-server-box-enabled-when-advertised {an archive advertising a fulltext field unlocks the server box} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.remote cget -state
} -cleanup { sw_cleanup } -result {normal}

test sw-server-box-disabled-when-not-advertised {an archive without one leaves the box off and says why} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end}
    list [.sw.top.remote cget -state] [.sw.top.remote cget -text]
} -cleanup { sw_cleanup } -result {disabled {Server can't search}}

test sw-searches-locally-by-default {an unticked search never reaches the archive} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.entry insert 0 needle
    .sw.top.search invoke
    wait
    sw_search_queries
} -cleanup { sw_cleanup } -result {0}

test sw-ticking-the-box-queries-the-archive {ticking it adds the server pass to the same search} -setup {
    sw_setup
} -body {
    sw_create
    sw_answer_fields {with start end withtext}
    .sw.top.entry insert 0 needle
    .sw.top.remote invoke
    wait
    sw_search_queries
} -cleanup { sw_cleanup } -result {1}

# -- account-wide search --------------------------------------------------------

# A searchwindow with no -jid searches the whole account.
proc sw_create_global {} {
    set ::sw_goto none
    searchwindow .sw -acc user@test.example.com \
        -goto-command {apply {{hit} { set ::sw_goto $hit }}}
    wait
}

proc sw_store {chat ts body {from ""}} {
    if {$from eq ""} { set from $chat }
    $::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid $chat from_jid $from body $body \
        server_id "" own_id "" raw_xml ""]]
}

proc sw_store_own {chat ts body} {
    $::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid $chat from_jid user@test.example.com \
        body $body server_id "" own_id own$ts raw_xml ""]]
}

proc sw_run {query} {
    .sw.top.entry insert 0 $query
    .sw.top.search invoke
    wait
}

proc sw_text {} {
    [.sw.ca textwidget] get 1.0 end
}

test sw-highlights-where-the-backend-matched {the hit is marked in the body as drawn, styling stripped} -setup {
    sw_setup
} -body {
    sw_create
    # Stored with the styling delimiters, drawn without them: an offset taken
    # against the raw body would land a character late.
    sw_store alice@example.com 100 "say *needle* now"
    sw_run needle
    set t [.sw.ca textwidget]
    $t get {*}[$t tag ranges search_match]
} -cleanup { sw_cleanup } -result {needle}

test sw-global-spans-every-chat {results come from every chat, in one time order} -setup {
    sw_setup
} -body {
    sw_create_global
    sw_store alice@example.com 100 "a needle here"
    sw_store bob@example.com 300 "another needle"
    sw_run needle
    .sw.ca messages keys
} -cleanup { sw_cleanup } -result {{alice@example.com 100} {bob@example.com 300}}

# 26 hits over a page of 20, with the tie at 600 straddling the boundary.
test sw-global-load-more-resumes-mid-tie {a second page picks up the tied hit the first one stopped on} -setup {
    sw_setup
} -body {
    sw_create_global
    for {set ts 100} {$ts <= 2500} {incr ts 100} {
        sw_store [expr {($ts / 100) % 2 ? "alice@example.com" : "bob@example.com"}] \
            $ts "needle $ts"
    }
    sw_store alice@example.com 600 "needle 600 again"
    sw_run needle
    set firstPage [llength [.sw.ca messages keys]]
    .sw.bot.more invoke
    wait
    set keys [.sw.ca messages keys]
    list $firstPage [llength $keys] [llength [lsort -unique $keys]]
} -cleanup { sw_cleanup } -result {20 26 26}

test sw-global-hides-the-server-box {no archive spans an account, so the server pass is not offered} -setup {
    sw_setup
} -body {
    sw_create_global
    winfo manager .sw.top.remote
} -cleanup { sw_cleanup } -result {}

test sw-global-click-names-the-chat {a hit identifies itself by chat and timestamp} -setup {
    sw_setup
} -body {
    sw_create_global
    sw_store bob@example.com 300 "the needle"
    sw_run needle
    event generate .sw.ca <<MessageClick>> -data [lindex [.sw.ca messages keys] 0]
    set ::sw_goto
} -cleanup { sw_cleanup } -result {bob@example.com 300}

test sw-global-labels-a-room-row-with-its-room {a room hit says which room it came from} -setup {
    sw_setup
} -body {
    sw_create_global
    sw_store room@conf.example.com?join 300 "the needle" \
        room@conf.example.com/alice
    sw_run needle
    string match "*room@conf.example.com - alice*" [sw_text]
} -cleanup { sw_cleanup } -result {1}

test sw-global-leaves-a-1to1-row-unprefixed {a 1:1 author already names the chat, so it gets no prefix} -setup {
    sw_setup
} -body {
    sw_create_global
    sw_store bob@example.com 300 "the needle"
    sw_run needle
    string match "*bob@example.com -*" [sw_text]
} -cleanup { sw_cleanup } -result {0}

test sw-per-chat-key-stays-a-timestamp {a chat-scoped window keys rows by timestamp alone} -setup {
    sw_setup
} -body {
    sw_create
    sw_store alice@example.com 300 "the needle"
    sw_run needle
    .sw.ca messages keys
} -cleanup { sw_cleanup } -result {300}

# We author messages in every 1:1, so our own bare JID is the one author that
# appears in more than one chat. chatarea repaints an author by JID across every
# row, so a relabel in one chat must not reach rows in the others.
test sw-global-relabel-stays-in-its-own-chat {a name change in one chat leaves the other chat's rows alone} -setup {
    sw_setup
} -body {
    sw_create_global
    sw_store_own alice@example.com 100 "my needle"
    sw_store_own bob@example.com 300 "my needle"
    sw_run needle
    $::_client emit author <Changed> -chat alice@example.com \
        -from user@test.example.com -name Renamed
    wait
    set text [sw_text]
    list [string match "*alice@example.com - Renamed*" $text] \
         [string match "*bob@example.com - *" $text]
} -cleanup { sw_cleanup } -result {1 1}

# authornames seeds from inside its own constructor, so its first announce
# reaches the host before the host has finished building it. An error there is
# routed to an event rather than raised, so assert on the event.
proc sw_watch_errors {} {
    set ::sw_errors {}
    ::tacky listen -tag sw_errwatch error <MethodError> {apply {{ev} {
        lappend ::sw_errors [dict get $ev -message]
    }}}
}

proc sw_seen_errors {} {
    ::tacky unlisten sw_errwatch
    return $::sw_errors
}

test sw-seeding-a-name-cache-is-not-reentrant {building a chat's names mid-announce doesn't rebuild it} -setup {
    sw_setup
} -body {
    sw_watch_errors
    sw_create_global
    sw_store room@conf.example.com?join 300 "the needle" \
        room@conf.example.com/alice
    sw_run needle
    sw_seen_errors
} -cleanup { sw_cleanup } -result {}

test sw-per-chat-seeding-is-not-reentrant {the same holds for a chat-scoped window, which seeds at construction} -setup {
    sw_setup
} -body {
    sw_watch_errors
    sw_create
    sw_seen_errors
} -cleanup { sw_cleanup } -result {}
