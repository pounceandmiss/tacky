# A disabled account's client: still there to read from, touching no network
# (taco_client -enabled). See DOC.md "A disabled account".
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set acc user@test.example.com

set disabled_common [tacky_env -mock conn -account $acc -enabled 0 -capture-emit 1]

# Let the iq module's refusals, which wait for their caller, come in
proc dis_settle {} { update; update }

proc dis_messages {} {
    lmap s [$::_client conn get_written] {
        expr {[dict get $s tag] eq "message" ? $s : [continue]}
    }
}

test disabled-request-fails-at-once {a request is not sent, and is answered with account disabled} \
    {*}$disabled_common -body {
        set ::_got ""
        $::_client iq request -type get -to test.example.com \
            -payload [j ping -ns urn:xmpp:ping] \
            -command {apply {{st} {
                set ::_got [list [xsearch $st -get @type] \
                    [xsearch $st error text -get body]]
            }}}
        set before $::_got
        dis_settle
        list $before $::_got [llength [$::_client conn get_written]]
    } -result {{} {error {account disabled}} 0}

test disabled-writes-nothing {a stanza written while disabled goes nowhere, now or after enable} \
    {*}$disabled_common -body {
        $::_client write [j presence]
        tacky account enable -acc $::acc
        llength [$::_client conn get_written]
    } -result 0

test disabled-connect-dials-nothing {connect does not dial while disabled} \
    {*}$disabled_common -body {
        $::_client connect
        $::_client.conn get_connects
    } -result 0

test disabled-send-waits-for-enable {a message sent while disabled stays pending, and goes out once after enable} \
    {*}$disabled_common -body {
        $::_client omemo setEnabled -jid alice@example.com -value 0
        tacky message send -acc $::acc -chat alice@example.com -body queued
        set status [$::_client db onecolumn {
            SELECT server_status FROM chat_message WHERE body='queued'
        }]
        set before [llength [dis_messages]]
        tacky account enable -acc $::acc
        $::_client conn configure -bound-jid $::acc/res
        $::_client conn fire_ready 0
        # Catchup answers empty, which is what lets RetryPending run
        foreach s [$::_client conn get_written] {
            if {[xsearch $s query -ns urn:xmpp:mam:2] eq ""} continue
            $::_client conn feed [j iq -type result -id [dict get $s attrs id] {
                j fin -ns urn:xmpp:mam:2 -complete true {
                    j set -ns http://jabber.org/protocol/rsm {}
                }
            }]
        }
        dis_settle
        set bodies [lmap s [dis_messages] {xsearch $s body -get body}]
        list $status $before [llength [lsearch -all $bodies queued]]
    } -result {pending 0 1}

test disabled-history-reads-the-store {history comes from the store while disabled} \
    {*}$disabled_common -body {
        $::_client message messagestore store [list [dict create \
            timestamp 1000000 chat_jid alice@example.com \
            from_jid alice@example.com/phone body stored \
            server_id s1 own_id "" raw_xml ""]]
        set ::_hist {}
        $::_client message history -chat alice@example.com \
            -command {apply {{r} { set ::_hist $r }}}
        lmap m $::_hist {dict get $m content body}
    } -result stored

test disabled-history-from-the-server-fails {a history only the server has fails rather than waiting} \
    {*}$disabled_common -body {
        set ::_hist none
        $::_client message history -chat nobody@example.com \
            -command {apply {{r} { set ::_hist [list ok $r] }}} \
            -onerror {apply {{e} { set ::_hist [list error $e] }}}
        dis_settle
        expr {$::_hist ne "none"}
    } -result 1

test disabled-download-refused {a download fails, and an automatic one is held back} \
    {*}$disabled_common -body {
        set ::_dl {}
        $::_client file download -url https://example.com/a.png \
            -onerror {apply {{e} { lappend ::_dl $e }}}
        $::_client file download -url https://example.com/b.png -auto 1 \
            -command {apply {{r} { lappend ::_dl held:$r }}} \
            -onerror {apply {{e} { lappend ::_dl $e }}}
        set ::_dl
    } -result {{account disabled} held:}

test disabled-calls-refused {a call is refused, saying why} \
    {*}$disabled_common -body {
        set ::_emitted {}
        tacky calls start -acc $::acc -to alice@example.com
        list [llength [$::_client conn get_written]] [lmap e $::_emitted {
            expr {[lrange $e 0 1] eq {error <MethodError>}
                ? [dict get [lrange $e 2 end] -message] : [continue]}
        }]
    } -result {0 {{Calls are unavailable while the account is disabled}}}

test disabled-room-join-refused {a room join answers at once and leaves nothing tracked} \
    {*}$disabled_common -body {
        set ::_join {}
        $::_client muc join -jid room@muc.example.com -nick me \
            -command {apply {{r} { set ::_join $r }}}
        list $::_join [$::_client muc isTracked -jid room@muc.example.com]
    } -result {{-jid room@muc.example.com -error account-disabled} 0}

test disabled-upload-refused {an upload fails, saying why} \
    {*}$disabled_common -body {
        set f [makeFile hello disabled-up.txt]
        set ::_emitted {}
        $::_client file upload -path $f
        removeFile disabled-up.txt
        lmap e $::_emitted {
            expr {[lrange $e 0 1] eq {file <Update>}
                ? [dict get [lrange $e 2 end] -error] : [continue]}
        }
    } -result {{account disabled}}

# --- what a refusal must not leave behind --------------------------------

proc dis_written_ns {ns} {
    llength [lmap s [$::_client conn get_written] {
        expr {[xsearch $s * -ns $ns] ne "" ? 1 : [continue]}
    }]
}

test disabled-mam-fields-not-cached {a refused field discovery leaves no "no fulltext" behind} \
    {*}$disabled_common -body {
        $::_client mam discoverFields
        dis_settle
        $::_client configure -enabled 1
        set ::_q {}
        $::_client mam query -fulltext hello -command {apply {{r} { set ::_q $r }}}
        list [dis_written_ns urn:xmpp:mam:2] [dict getdef $::_q error_condition ""]
    } -result {1 {}}

test disabled-muc-service-not-cached {a refused service probe finds nothing now, and asks again later} \
    {*}$disabled_common -body {
        set ::_svc none
        $::_client muc findService -command {apply {{j} { set ::_svc $j }}}
        dis_settle
        set first $::_svc
        $::_client configure -enabled 1
        $::_client muc findService -command {apply {{j} { set ::_svc $j }}}
        list $first [dis_written_ns http://jabber.org/protocol/disco#items]
    } -result {{} 1}

test disabled-bookmark-edit-refused {a bookmark edit is refused, and the table is left as it was} \
    {*}$disabled_common -body {
        set r [catch {tacky bookmarks item -acc $::acc -jid room@muc.example.com \
            -autojoin 1} err]
        list $r $err [$::_client db onecolumn {SELECT count(*) FROM bookmark}]
    } -result {1 {account disabled} 0}

test disabled-online-method-to-onerror {an -online method answers -onerror before changing anything} \
    {*}$disabled_common -body {
        set ::_nick {}
        $::_client nick set -nick romeo -onerror {apply {{e} { set ::_nick $e }}}
        list $::_nick [$::_client bookmarks defaultNick]
    } -result {{account disabled} user}

cleanupTests
