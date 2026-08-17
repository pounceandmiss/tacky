# Unit tests for chatview — end-to-end from stanza to widget
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco
package require tacky::mockconn
package require tclwuffs

set acc user@test.example.com

# -- helpers --------------------------------------------------------------------

# Feed a chat message stanza through the mock client.
proc cv_feed {body sid args} {
    $::_client conn feed [j message -type chat \
        -from alice@example.com/phone {
        j body #body $body
        j stanza-id -ns urn:xmpp:sid:0 -id $sid -by user@test.example.com
        if {[dict exists $args -stamp]} {
            j delay -ns urn:xmpp:delay -stamp [dict get $args -stamp]
        }
    }]
}

# Build a MAM <result> node wrapping a message.
proc mam_result {args} {
    set defaults {id sid1 queryid "" from alice@example.com to "" body hello stamp 2024-01-01T00:00:00Z origin_id ""}
    set opts [dict merge $defaults $args]
    set oid [dict get $opts origin_id]
    set qid [dict get $opts queryid]
    set rid [dict get $opts id]
    set toJid [dict get $opts to]
    set msgAttrs [list -from [dict get $opts from]]
    if {$toJid ne ""} {
        lappend msgAttrs -to $toJid
    }
    if {$oid ne ""} {
        lappend msgAttrs -id $oid
    }
    j result -ns urn:xmpp:mam:2 -id $rid -queryid $qid {
        j forwarded -ns urn:xmpp:forward:0 {
            j delay -ns urn:xmpp:delay -stamp [dict get $opts stamp]
            j message {*}$msgAttrs {
                j body #body [dict get $opts body]
            }
        }
    }
}

# Find MAM IQs with a specific 'with' filter among written stanzas.
# Returns the first match, or all matches with -all.
proc cv_find_mam_iq {jid args} {
    set all [expr {"-all" in $args}]
    set result {}
    foreach stanza [$::_client conn get_written] {
        set qnode [xsearch $stanza query -ns urn:xmpp:mam:2]
        if {$qnode eq ""} continue
        set withVal [xsearch [lindex $qnode 0] x field @var with value -get body]
        if {$withVal eq $jid} {
            if {!$all} { return $stanza }
            lappend result $stanza
        }
    }
    if {$all} { return $result }
    return ""
}

# Complete a MAM IQ with messages and fin.
# messages: list of {id body stamp} triples
# complete: whether to mark the archive as fully fetched
proc cv_complete_mam_with {iqStanza messages {complete true}} {
    set iqId [dict get $iqStanza attrs id]
    set qid [xsearch $iqStanza query -ns urn:xmpp:mam:2 -get @queryid]

    foreach {id body stamp} $messages {
        set rn [mam_result id $id queryid $qid \
            from alice@example.com/phone body $body stamp $stamp]
        $::_client mam onResultMessage [j message -from user@test.example.com {
            j /as-is $rn
        }]
    }

    set first [lindex $messages 0]
    set last  [lindex $messages end-2]

    $::_client iq feed [j iq -type result -id $iqId {
        j fin -ns urn:xmpp:mam:2 -complete $complete {
            j set -ns http://jabber.org/protocol/rsm {
                if {$first ne ""} {
                    j first #body $first
                    j last #body $last
                }
            }
        }
    }]
}

# Complete all pending MAM queries with empty archives.
proc cv_complete_mam {} {
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] ne ""} {
            cv_complete_mam_with $stanza {}
        }
    }
    $::_client conn clear
}

# Create tacky + mock client + avatarcache. Pair with cv_cleanup.
proc cv_setup {} { mock_backend_up }

proc cv_cleanup {} {
    destroy .cv
    mock_backend_down
}

# Create chatview. Options:
#   -pack    — pack the widget and set a small geometry (for thirst tests)
#   -nomam   — don't complete the initial MAM query (test completes it)
proc cv_create {args} {
    chatview .cv -acc user@test.example.com \
        -jid alice@example.com
    if {"-pack" in $args} {
        pack .cv -fill both -expand yes
        wm geometry . 400x200
    }
    wait
    if {"-nomam" ni $args} {
        cv_complete_mam
        wait
    }
}

# Simulate a server echo (MUC-style) for a previously sent message.
# sentTs: the timestamp (= own_id) of the sent message
# echoSid: server_id for the echo
# echoStamp: ISO timestamp for the echo (defaults to same as sentTs)
proc cv_muc_echo {sentTs echoSid {echoStamp ""}} {
    if {$echoStamp eq ""} {
        set echoStamp [FormatTimestampISO $sentTs]
    }
    $::_client message ingestLive alice@example.com [j message -type chat \
        -from alice@example.com/phone -id $sentTs {
        j body #body "echo"
        j stanza-id -ns urn:xmpp:sid:0 -id $echoSid -by user@test.example.com
        j delay -ns urn:xmpp:delay -stamp $echoStamp
    }] 1
}

# Create tacky + chatview packed with 15 messages so the view overflows.
# direction: incoming | outgoing. Pair with cv_cleanup.
proc cv_overflow_setup {{direction incoming}} {
    cv_setup
    for {set i 0} {$i < 15} {incr i} {
        if {$direction eq "outgoing"} {
            tacky message send -acc $::acc \
                -chat alice@example.com -body "fill $i"
        } else {
            cv_feed "fill $i" seed$i
        }
    }
    cv_create -pack
}

# -- common setup: tacky + empty chatview ready for live messages ---------------

set cv_common {
    -setup   { cv_setup; cv_create }
    -cleanup { cv_cleanup }
}

# -- live message ---------------------------------------------------------------

test chatview-live-message {stanza fed through client appears in chatview} \
    {*}$cv_common \
    -body {
        cv_feed "hello world" srv1
        wait
        set ids [.cv messages keys]
        list [llength $ids] [expr {[.cv messages newest] ne ""}]
    } -result {1 1}

test chatview-author-falls-back-to-the-jid {an author the name cache doesn't know is labelled by JID} \
    {*}$cv_common \
    -body {
        cv_feed "hello" srv-author1
        wait
        # A 1:1 from_jid is bare after normalisation, so there is no resource
        # to use as a nick and the JID itself is the label.
        [.cv textwidget] get {*}[[.cv textwidget] tag ranges author.alice@example.com]
    } -result alice@example.com

test chatview-formatting-overlap-combines {overlapping bold+italic render as one compound tag, not last-wins} \
    {*}$cv_common \
    -body {
        cv_feed "*_bold italic_*" srv-fmt1
        wait
        # The GUI combines the two overlapping single-type spans into the
        # compound entity.bold.italic tag; italic is never applied on its own.
        set ranges [[.cv textwidget] tag ranges entity.bold.italic]
        list [[.cv textwidget] get {*}$ranges] \
             [llength [[.cv textwidget] tag ranges entity.italic]]
    } -result {{bold italic} 0}

test chatview-live-dedup {duplicate stanza-id does not create second message} \
    {*}$cv_common \
    -body {
        cv_feed "hello" srv1
        wait
        cv_feed "hello" srv1
        wait
        llength [.cv messages keys]
    } -result {1}

test chatview-no-body-ignored {message without body does not appear} \
    {*}$cv_common \
    -body {
        $::_client conn feed [j message -type chat \
            -from alice@example.com/phone {
            j active -ns http://jabber.org/protocol/chatstates
        }]
        wait
        llength [.cv messages keys]
    } -result {0}

# -- sent + confirmed -----------------------------------------------------------

test chatview-sent-appears {sent message appears in chatview} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat alice@example.com \
            -body "outgoing msg"
        wait
        llength [.cv messages keys]
    } -result {1}

test chatview-sendfile-optimistic {sendFile shows the message immediately in an uploading state} \
    {*}$cv_common \
    -body {
        set tmp /tmp/cv_sendfile_[pid].png
        set fh [open $tmp w]; puts -nonewline $fh "x"; close $fh
        # Upload stalls at service discovery (mock server never replies),
        # so the optimistic message stays in the uploading state.
        tacky message sendFile -acc $::acc \
            -chat alice@example.com -path $tmp
        wait
        set id [.cv messages newest]
        set res [list n=[llength [.cv messages keys]] \
            bar=[winfo exists [.cv attachment path $id 0].up.bar]]
        file delete $tmp
        set res
    } -result {n=1 bar=1}

test chatview-sendfile-image-thumbnail \
    {an outgoing image is thumbnailed by the backend and rendered inline} \
    {*}$cv_common \
    -body {
        set tmp /tmp/cv_img_[pid].png
        set w 120; set h 80
        set px [string repeat [binary format cccc 200 80 40 255] [expr {$w * $h}]]
        set f [open $tmp wb]
        puts -nonewline $f [::tclwuffs::encode_png $w $h $px]
        close $f
        tacky message sendFile -acc $::acc -chat alice@example.com -path $tmp
        wait
        set id [.cv messages newest]
        set res [winfo exists [.cv attachment path $id 0].img]
        file delete $tmp
        set res
    } -result 1

# A held-back autofetch is not a failure: caption only, no error row.
test chatview-autofetch-blocked-renders-plain-caption \
    {an image from a non-contact under the contacts policy draws no error row} \
    {*}$cv_common \
    -body {
        tacky setting set -key attachment_autofetch -value contacts
        $::_client conn feed [j message -type chat \
            -from alice@example.com/phone {
            j body #body "https://h.invalid/pic.png"
            j x -ns jabber:x:oob { j url #body "https://h.invalid/pic.png" }
            j stanza-id -ns urn:xmpp:sid:0 -id oob1 -by user@test.example.com
        }]
        wait
        set id [.cv messages newest]
        list cap=[winfo exists [.cv attachment path $id 0].cap] \
             img=[winfo exists [.cv attachment path $id 0].img] \
             errorRow=[winfo exists [.cv attachment path $id 0].dl]
    } -result {cap=1 img=0 errorRow=0}

# A loopback server that accepts and never answers, so a download it serves
# stays in flight.
proc cv_deaf_server {} {
    set ::_cv_conns {}
    set srv [socket -server {apply {{ch a p} {lappend ::_cv_conns $ch}}} \
        -myaddr 127.0.0.1 0]
    return [list $srv [lindex [fconfigure $srv -sockname] 2]]
}

proc cv_deaf_stop {srv} {
    foreach c $::_cv_conns { catch {close $c} }
    catch {close $srv}
}

# Cancelling a download is not a failure: the row goes, leaving the caption
# that reloads on click.
test chatview-cancel-download-drops-the-progress-row \
    {cancelling an inline image download leaves a plain caption} \
    {*}$cv_common \
    -body {
        lassign [cv_deaf_server] srv port
        set url http://127.0.0.1:$port/pic.png
        $::_client conn feed [j message -type chat \
            -from alice@example.com/phone {
            j body #body $url
            j x -ns jabber:x:oob { j url #body $url }
            j stanza-id -ns urn:xmpp:sid:0 -id oobc1 -by user@test.example.com
        }]
        wait
        set f [.cv attachment path [.cv messages newest] 0]
        set inFlight [list bar=[winfo exists $f.dl.bar] \
            cancel=[winfo exists $f.dl.cancel]]
        $f.dl.cancel invoke
        wait
        set res [list $inFlight row=[winfo exists $f.dl] cap=[winfo exists $f.cap]]
        cv_deaf_stop $srv
        set res
    } -result {{bar=1 cancel=1} row=0 cap=1}

# An upload is a message already written, so cancelling keeps the row and
# offers Retry.
test chatview-cancel-upload-offers-retry \
    {cancelling an upload leaves the failed row with its Retry button} \
    {*}$cv_common \
    -body {
        set tmp /tmp/cv_cancel_[pid].png
        set px [string repeat [binary format cccc 10 20 30 255] 64]
        set fh [open $tmp wb]
        puts -nonewline $fh [::tclwuffs::encode_png 8 8 $px]
        close $fh
        # Upload stalls at service discovery (mock server never replies), so it
        # is still in flight when the test clicks.
        tacky message sendFile -acc $::acc -chat alice@example.com -path $tmp
        wait
        set f [.cv attachment path [.cv messages newest] 0]
        set inFlight [winfo exists $f.up.cancel]
        $f.up.cancel invoke
        wait
        set res [list cancel=$inFlight bar=[winfo exists $f.up.bar] \
            retry=[winfo exists $f.up.retry]]
        file delete $tmp
        set res
    } -result {cancel=1 bar=0 retry=1}

test chatview-sm-ack-shows-receipt {SM ack triggers Patch and shows checkmark} \
    {*}$cv_common \
    -body {
        # Plaintext chat: with OMEMO on, the send would park on
        # devicelist warming (mock server never answers) and no
        # message would reach the wire to be acked
        tacky omemo setEnabled -acc $::acc -jid alice@example.com -value 0
        tacky message send -acc $::acc -chat alice@example.com \
            -body "outgoing msg"
        wait
        set sentId [.cv messages newest]
        # Check no checkmark yet (pending)
        set tag [.cv messages tag $sentId].receipt
        set ranges [[.cv textwidget] tag ranges $tag]
        set before [[.cv textwidget] get {*}$ranges]
        # Trigger SM ack
        set sentStanza [lindex [$::_client conn get_written] end]
        $::_client message OnSmAck \
            -stanzas [list $sentStanza]
        wait
        set ranges [[.cv textwidget] tag ranges $tag]
        set after [[.cv textwidget] get {*}$ranges]
        list before=$before after=$after
    } -result "{before= } {after= \u2713}"

test chatview-multiple-outgoing-order {multiple outgoing messages appear in send order} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat alice@example.com -body "one"
        wait
        tacky message send -acc $::acc -chat alice@example.com -body "two"
        wait
        tacky message send -acc $::acc -chat alice@example.com -body "three"
        wait
        llength [.cv messages keys]
    } -result {3}

test chatview-outgoing-interleaved {outgoing interleaved with incoming in correct order} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat alice@example.com -body "out1"
        wait
        set ts1 [.cv messages newest]
        cv_feed "incoming" srv-in
        wait
        tacky message send -acc $::acc -chat alice@example.com -body "out2"
        wait
        set ids [.cv messages keys]
        list [llength $ids] [expr {[lindex $ids 0] == $ts1}]
    } -result {3 1}

test chatview-muc-echo-same-ts {echo with same timestamp confirms in place} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat alice@example.com -body "hello"
        wait
        set sentId [.cv messages newest]
        cv_muc_echo $sentId echo-sid1
        wait
        set tag [.cv messages tag $sentId].receipt
        set ranges [[.cv textwidget] tag ranges $tag]
        set receipt [[.cv textwidget] get {*}$ranges]
        list [llength [.cv messages keys]] receipt=$receipt
    } -result "1 {receipt= \u2713}"

test chatview-muc-echo-different-ts {echo with different timestamp moves message} \
    {*}$cv_common \
    -body {
        tacky message send -acc $::acc -chat alice@example.com -body "hello"
        wait
        set sentId [.cv messages newest]
        # Echo at 1 second later
        set echoTs [expr {$sentId + 1000000}]
        set echoStamp [FormatTimestampISO $echoTs]
        cv_muc_echo $sentId echo-sid2 $echoStamp
        wait
        set ids [.cv messages keys]
        set newId [lindex $ids 0]
        # Old id should be gone, new id should be present
        set tag [.cv messages tag $newId].receipt
        set ranges [[.cv textwidget] tag ranges $tag]
        set receipt [[.cv textwidget] get {*}$ranges]
        list [llength $ids] [expr {$sentId ni $ids}] \
            [expr {$newId == $echoTs}] receipt=$receipt
    } -result "1 1 1 {receipt= \u2713}"

test chatview-muc-echo-reorders {echo reorders message among interleaved messages} \
    {*}$cv_common \
    -body {
        cv_feed "A" srv-a -stamp 2025-01-01T12:00:00Z
        wait
        set tsA [.cv messages newest]
        tacky message send -acc $::acc -chat alice@example.com -body "X"
        wait
        set tsX [.cv messages newest]
        cv_feed "B" srv-b
        wait
        set tsB [.cv messages newest]
        set countBefore [llength [.cv messages keys]]
        # Echo X at timestamp after B
        set echoTs [expr {$tsB + 1000000}]
        cv_muc_echo $tsX echo-reorder [FormatTimestampISO $echoTs]
        wait
        set ids [.cv messages keys]
        # Expected: A, B, X' — X moved after B
        list count=$countBefore \
            [llength $ids] \
            [expr {[lindex $ids 0] == $tsA}] \
            [expr {[lindex $ids 1] == $tsB}] \
            [expr {[lindex $ids 2] == $echoTs}]
    } -result {count=3 3 1 1 1}

test chatview-muc-echo-reorders-4msg {MUC echo with new timestamp reorders 4-message view} \
    {*}$cv_common \
    -body {
        # Setup: A(100) → X(200,pending) → B(300) → C(400)
        cv_feed "A" srv-a -stamp 2025-01-01T12:00:00Z
        wait
        set tsA [.cv messages newest]
        tacky message send -acc $::acc -chat alice@example.com -body "X"
        wait
        set tsX [.cv messages newest]
        cv_feed "B" srv-b
        wait
        set tsB [.cv messages newest]
        cv_feed "C" srv-c
        wait
        set tsC [.cv messages newest]
        # Verify initial order: A, X, B, C
        set before [.cv messages keys]
        # Echo X at timestamp between B and C
        set echoTs [expr {$tsB + ($tsC - $tsB) / 2}]
        cv_muc_echo $tsX echo-4msg [FormatTimestampISO $echoTs]
        wait
        set after [.cv messages keys]
        # Expected: A, B, X', C — X moved between B and C
        list [llength $before] [llength $after] \
            [expr {[lindex $after 0] == $tsA}] \
            [expr {[lindex $after 1] == $tsB}] \
            [expr {[lindex $after 2] == $echoTs}] \
            [expr {[lindex $after 3] == $tsC}]
    } -result {4 4 1 1 1 1}

foreach {direction seedCmd} {
    outgoing {tacky message send -acc $::acc -chat alice@example.com -body "pending"}
    incoming {cv_feed "before catchup" srv1}
} {
    test chatview-${direction}-survives-catchup \
        "$direction still visible after CatchupDone (no reload under holes)" \
        {*}$cv_common \
        -body {
            eval $seedCmd
            wait
            set countBefore [llength [.cv messages keys]]
            tacky emit message <CatchupDone> -count 5
            wait
            set countAfter [llength [.cv messages keys]]
            list before=$countBefore after=$countAfter
        } -result {before=1 after=1}
}

# Store a message without the widget seeing it, standing in for what a
# catchup writes: no <New>, but the pushed tail still moves.
proc cv_store_behind {body sid stamp} {
    set ts [ParseTimestamp $stamp]
    $::_client message messagestore store [list [dict create \
        timestamp $ts chat_jid alice@example.com \
        from_jid alice@example.com/phone body $body \
        server_id $sid own_id "" raw_xml ""]]
    tacky emit message <Tail> -acc $::acc -jid alice@example.com -timestamp $ts
}

test chatview-catchup-repaints-own-chat {CatchupDone for this chat pulls in what catchup stored} \
    {*}$cv_common \
    -body {
        cv_feed "before catchup" srv1 -stamp 2024-01-01T10:00:00Z
        wait
        set countBefore [llength [.cv messages keys]]
        cv_store_behind "arrived while away" srv2 2024-01-01T11:00:00Z
        tacky emit message <CatchupDone> -acc $::acc -jid alice@example.com -count 1
        wait
        set countAfter [llength [.cv messages keys]]
        list before=$countBefore after=$countAfter
    } -result {before=1 after=2}

test chatview-catchup-ignores-other-chat {CatchupDone for a different chat is not our repaint} \
    {*}$cv_common \
    -body {
        cv_feed "before catchup" srv1 -stamp 2024-01-01T10:00:00Z
        wait
        cv_store_behind "arrived while away" srv2 2024-01-01T11:00:00Z
        tacky emit message <CatchupDone> -acc $::acc -jid bob@example.com -count 1
        wait
        llength [.cv messages keys]
    } -result {1}

test chatview-catchup-account-wide-reconciles {the account-wide settle repaints a 1:1, which gets no bracket of its own} \
    {*}$cv_common \
    -body {
        cv_feed "before catchup" srv1 -stamp 2024-01-01T10:00:00Z
        wait
        cv_store_behind "arrived while away" srv2 2024-01-01T11:00:00Z
        tacky emit message <CatchupDone> -acc $::acc -jid "" -count 1
        wait
        llength [.cv messages keys]
    } -result {2}

test chatview-catchup-no-repaint-off-tail {a view away from the tail is not repainted under the user} \
    {*}$cv_common \
    -body {
        cv_feed "one" srv1 -stamp 2024-01-01T10:00:00Z
        cv_feed "two" srv2 -stamp 2024-01-01T11:00:00Z
        wait
        # goto a non-end target leaves the live tail (AtTail 0)
        .cv goto [.cv messages newest] -source local
        wait
        cv_store_behind "arrived while away" srv3 2024-01-01T12:00:00Z
        tacky emit message <CatchupDone> -acc $::acc -jid alice@example.com -count 1
        wait
        llength [.cv messages keys]
    } -result {2}

# 1:1 views take the account-wide bracket, so the jid defaults to empty.
proc cv_catchup_start {{jid ""}} {
    tacky emit message <CatchupStarted> -acc $::acc -jid $jid
    wait
}

proc cv_catchup_done {{jid ""} {count 0}} {
    tacky emit message <CatchupDone> -acc $::acc -jid $jid -count $count
    wait
}

test chatview-catchup-defers-live-message {a message arriving mid-sync lands only once the sync settles} \
    {*}$cv_common \
    -body {
        cv_feed "before catchup" srv1 -stamp 2024-01-01T10:00:00Z
        wait
        cv_catchup_start
        cv_feed "during catchup" srv2 -stamp 2024-01-01T11:00:00Z
        wait
        set during [llength [.cv messages keys]]
        cv_catchup_done
        list during=$during after=[llength [.cv messages keys]]
    } -result {during=1 after=2}

test chatview-catchup-declines-page-short-of-tail {a page that stops short of the tail is not appended} \
    {*}$cv_common \
    -body {
        cv_feed "before catchup" srv1 -stamp 2024-01-01T10:00:00Z
        wait
        cv_store_behind "arrived while away" srv2 2024-01-01T11:00:00Z
        # A tail beyond anything stored stands in for a hole between the
        # window and the real tail: the fetched page can't reach it.
        tacky emit message <Tail> -acc $::acc -jid alice@example.com \
            -timestamp [ParseTimestamp 2024-01-01T20:00:00Z]
        cv_catchup_done alice@example.com 1
        llength [.cv messages keys]
    } -result {1}

test chatview-catchup-shows-indicator {the sync bracket shows and hides the overlay} \
    {*}$cv_common \
    -body {
        set idle [.cv loading visible]
        cv_catchup_start
        set busy [.cv loading visible]
        cv_catchup_done
        list $idle $busy [.cv loading visible]
    } -result {0 1 0}

test chatview-catchup-indicator-ignores-other-chat {another chat's sync shows nothing here} \
    {*}$cv_common \
    -body {
        cv_catchup_start bob@example.com
        .cv loading visible
    } -result {0}

# Fail every outstanding archive query the way a server with no MAM would.
proc cv_fail_mam {} {
    foreach stanza [$::_client conn get_written] {
        if {[xsearch $stanza query -ns urn:xmpp:mam:2] eq ""} continue
        $::_client iq feed [j iq -type error -id [dict get $stanza attrs id] {
            j error -type cancel {
                j service-unavailable -ns urn:ietf:params:xml:ns:xmpp-stanzas
            }
        }]
    }
    $::_client conn clear
}

test chatview-history-error-shows-why {a page that could not reach the archive says so} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        set idle [.cv loading visible]
        cv_fail_mam
        wait
        list $idle [.cv loading visible] [.cv loading cget -text]
    } -result {0 1 {This server keeps no message archive}}

test chatview-history-error-frees-the-direction {a failed page does not wedge the loader} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        cv_fail_mam
        wait
        # The gate OnThirsty consults before asking for another page.
        ::tacky listening .cv/new
    } -result {0}

# -- scroll-to-bottom on incoming/outgoing ---------------------------------------

# Parameterised scroll test: direction × scroll position.
#   direction: incoming | outgoing
#   scrollPos: at-end  | scrolled-up
foreach {direction scrollPos result} {
    outgoing at-end      {before=1 after=1}
    outgoing scrolled-up {before=0 after=0}
    incoming at-end      {before=1 after=1}
    incoming scrolled-up {before=0 after=0}
} {
    test chatview-${direction}-scroll-${scrollPos} \
        "$direction while $scrollPos" \
        -setup { cv_overflow_setup $direction } \
        -cleanup { cv_cleanup } \
        -body {
            if {$scrollPos eq "scrolled-up"} {
                [.cv textwidget] yview moveto 0
                wait
            }
            set atEndBefore [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
            if {$direction eq "outgoing"} {
                tacky message send -acc $::acc \
                    -chat alice@example.com -body "one more"
            } else {
                cv_feed "new msg" srv-new
            }
            wait
            set atEndAfter [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
            list before=$atEndBefore after=$atEndAfter
        } -result $result
}

# -- scroll button visibility ----------------------------------------------------

test chatview-scrollbtn-hidden-at-end {scroll button hidden when at bottom} \
    -setup { cv_overflow_setup } \
    -cleanup { cv_cleanup } \
    -body {
        expr {![.cv scrollbtn visible]}
    } -result {1}

test chatview-scrollbtn-shown-when-scrolled-up {scroll button appears when scrolled up and hides on return} \
    -setup { cv_overflow_setup } \
    -cleanup { cv_cleanup } \
    -body {
        [.cv textwidget] yview moveto 0
        event generate [.cv textwidget] <<Yview>>
        wait
        set shownAfterScroll [expr {[.cv scrollbtn visible]}]
        [.cv textwidget] see end
        event generate [.cv textwidget] <<Yview>>
        wait
        set hiddenAfterReturn [expr {![.cv scrollbtn visible]}]
        list shown=$shownAfterScroll hidden=$hiddenAfterReturn
    } -result {shown=1 hidden=1}

# Regression: an inline thumbnail that arrives after a message is drawn grows
# the last line below the viewport. If we don't re-pin to the tail, atEnd flips
# and the scroll-to-bottom button spuriously appears (and sticks).
test chatview-scrollbtn-hidden-after-async-thumbnail \
    {scroll button stays hidden when an inline thumbnail loads at the tail} \
    -setup { cv_overflow_setup } \
    -cleanup { cv_cleanup } \
    -body {
        set hiddenBefore [expr {![.cv scrollbtn visible]}]
        set tmp /tmp/cv_scrollimg_[pid].png
        set w 120; set h 80
        set px [string repeat [binary format cccc 200 80 40 255] [expr {$w * $h}]]
        set f [open $tmp wb]
        puts -nonewline $f [::tclwuffs::encode_png $w $h $px]
        close $f
        tacky message sendFile -acc $::acc -chat alice@example.com -path $tmp
        wait
        set id [.cv messages newest]
        set hasImg [winfo exists [.cv attachment path $id 0].img]
        set hiddenAfter [expr {![.cv scrollbtn visible]}]
        file delete $tmp
        list hiddenBefore=$hiddenBefore img=$hasImg hiddenAfter=$hiddenAfter
    } -result {hiddenBefore=1 img=1 hiddenAfter=1}

# -- history loading -------------------------------------------------------------

test chatview-live-after-history {live message appears when history is already displayed} \
    -setup {
        cv_setup
        cv_feed "seeded 1" seed1
        cv_feed "seeded 2" seed2
        cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
        set countBefore [llength [.cv messages keys]]
        cv_feed "live msg" srv-live
        wait
        set countAfter [llength [.cv messages keys]]
        list before=$countBefore after=$countAfter
    } -result {before=2 after=3}

test chatview-live-after-mam-history {live message appears when MAM history is displayed} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        set mamIq [cv_find_mam_iq alice@example.com]
        cv_complete_mam_with $mamIq {
            sid1 "mam 1" 2024-01-01T10:00:00Z
            sid2 "mam 2" 2024-01-01T11:00:00Z
        }
        wait
        set countBefore [llength [.cv messages keys]]
        cv_feed "live msg" srv-live
        wait
        set countAfter [llength [.cv messages keys]]
        list before=$countBefore after=$countAfter
    } -result {before=2 after=3}

test chatview-initial-load-mam {empty DB triggers MAM and results appear in widget} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        set mamIq [cv_find_mam_iq alice@example.com]
        if {$mamIq eq ""} { error "no MAM IQ for alice@example.com" }
        cv_complete_mam_with $mamIq {
            sid1 "mam msg 1" 2024-01-01T10:00:00Z
            sid2 "mam msg 2" 2024-01-01T11:00:00Z
            sid3 "mam msg 3" 2024-01-01T12:00:00Z
        }
        wait
        llength [.cv messages keys]
    } -result {3}

test chatview-scroll-up-loads-more {initial MAM load then thirst fetches older via MAM} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        # 1. Complete initial MAM with 3 messages, incomplete archive
        set mamIq [cv_find_mam_iq alice@example.com]
        if {$mamIq eq ""} { error "no initial MAM IQ" }
        cv_complete_mam_with $mamIq {
            sid1 "msg 1" 2024-01-01T10:00:00Z
            sid2 "msg 2" 2024-01-01T11:00:00Z
            sid3 "msg 3" 2024-01-01T12:00:00Z
        } false
        $::_client conn clear
        wait

        set countAfterInitial [llength [.cv messages keys]]

        # 2. Thirst should have fired for "old" and sent a -before MAM query
        set mamIq2 [cv_find_mam_iq alice@example.com]
        if {$mamIq2 eq ""} { error "no scroll-up MAM IQ" }

        # 3. Feed 2 older messages
        cv_complete_mam_with $mamIq2 {
            sid-old1 "older 1" 2024-01-01T08:00:00Z
            sid-old2 "older 2" 2024-01-01T09:00:00Z
        }
        wait

        set countAfterScroll [llength [.cv messages keys]]
        list initial=$countAfterInitial scrolled=$countAfterScroll
    } -result {initial=3 scrolled=5}

test chatview-scroll-up-multi-page {thirst fires again after each MAM backfill page} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        # 1. Complete initial MAM with 3 messages, incomplete archive
        set mamIq [cv_find_mam_iq alice@example.com]
        if {$mamIq eq ""} { error "no initial MAM IQ" }
        cv_complete_mam_with $mamIq {
            sid1 "msg 1" 2024-01-01T10:00:00Z
            sid2 "msg 2" 2024-01-01T11:00:00Z
            sid3 "msg 3" 2024-01-01T12:00:00Z
        } false
        $::_client conn clear
        wait

        set countAfterInitial [llength [.cv messages keys]]

        # 2. Thirst should have fired → first backfill MAM query
        set mamIq2 [cv_find_mam_iq alice@example.com]
        if {$mamIq2 eq ""} { error "no first backfill MAM IQ" }
        cv_complete_mam_with $mamIq2 {
            sid-old1 "older 1" 2024-01-01T08:00:00Z
            sid-old2 "older 2" 2024-01-01T09:00:00Z
        } false
        $::_client conn clear
        wait

        set countAfterFirst [llength [.cv messages keys]]

        # 3. Second backfill — "new" direction is short-circuited by
        #    DB check (cursor at latest), so only "old" MAM fires.
        set mamIq3 [cv_find_mam_iq alice@example.com]
        if {$mamIq3 eq ""} { error "no second backfill MAM IQ" }
        cv_complete_mam_with $mamIq3 {
            sid-old3 "oldest 1" 2024-01-01T06:00:00Z
            sid-old4 "oldest 2" 2024-01-01T07:00:00Z
        } false
        $::_client conn clear
        wait

        set countAfterSecond [llength [.cv messages keys]]

        # 4. Third backfill — the "new" direction's complete=true
        #    must not have blocked this.
        set mamIq4 [cv_find_mam_iq alice@example.com]
        if {$mamIq4 eq ""} { error "no third backfill MAM IQ — synced too early?" }
        cv_complete_mam_with $mamIq4 {
            sid-old5 "oldest 3" 2024-01-01T04:00:00Z
            sid-old6 "oldest 4" 2024-01-01T05:00:00Z
        }
        wait

        set countAfterThird [llength [.cv messages keys]]
        list initial=$countAfterInitial first=$countAfterFirst \
            second=$countAfterSecond third=$countAfterThird
    } -result {initial=3 first=5 second=7 third=9}

test chatview-thirst-loads-older {thirst loads older messages from local DB} \
    -setup {
        cv_setup
        foreach {sid body stamp} {
            s1 "older 1" 2024-01-01T08:00:00Z
            s2 "older 2" 2024-01-01T09:00:00Z
            s3 "msg 3"   2024-01-01T10:00:00Z
            s4 "msg 4"   2024-01-01T11:00:00Z
            s5 "msg 5"   2024-01-01T12:00:00Z
        } {
            cv_feed $body $sid -stamp $stamp
        }
        cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
        llength [.cv messages keys]
    } -result {5}

# -- goto (jump to date) --------------------------------------------------------

test chatview-goto-timestamp {goto -source remote fetches MAM then displays around anchor} \
    -setup {
        cv_setup
        cv_feed "recent 1" r1
        cv_feed "recent 2" r2
        cv_create -pack
    } \
    -cleanup { cv_cleanup } \
    -body {
        set countBefore [llength [.cv messages keys]]

        # Jump to a date in the past (remote fetch)
        $::_client conn clear
        .cv goto [ParseTimestamp 2024-06-15T12:00:00Z] -source remote
        wait

        set countPending [llength [.cv messages keys]]

        # Complete the MAM query — OnGoto stores results, getAround
        # returns them, OnGotoDone clears and reloads
        set mamIq [cv_find_mam_iq alice@example.com]
        if {$mamIq eq ""} { error "no MAM IQ" }
        cv_complete_mam_with $mamIq {
            s1 "msg 1" 2024-06-15T12:00:01Z
            s2 "msg 2" 2024-06-15T12:30:00Z
            s3 "msg 3" 2024-06-15T13:00:00Z
        }

        set countAfter [llength [.cv messages keys]]

        # First result should be visible (anchor is nearest to target date)
        set firstId [ParseTimestamp 2024-06-15T12:00:01Z]
        set hasFirst [expr {$firstId in [.cv messages keys]}]
        list before=$countBefore pending=$countPending \
            after=$countAfter hasFirst=$hasFirst
    } -result {before=2 pending=2 after=5 hasFirst=1}

test chatview-reply-jump {clicking a reply jumps to and highlights the target} \
    -setup { cv_setup; cv_create -pack } \
    -cleanup { cv_cleanup } \
    -body {
        cv_feed "the original" srv-tgt
        wait
        set tsTarget [.cv messages newest]
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j body #body "the reply"
            j stanza-id -ns urn:xmpp:sid:0 -id srv-rpl -by user@test.example.com
            j reply -ns urn:xmpp:reply:0 -to alice@example.com -id srv-tgt
        }]
        wait
        # Simulate a click on the reply reference.
        .cv OnReplyJump [list srv-tgt alice@example.com]
        wait
        [.cv textwidget] tag cget [.cv messages tag $tsTarget] -background
    } -result {yellow}

test chatview-reply-select {selecting Reply emits ReplyTo carrying the target id and body snippet} \
    -setup { cv_setup; cv_create -pack } \
    -cleanup { cv_cleanup } \
    -body {
        cv_feed "original text here" srv-sel
        wait
        set id [.cv messages newest]
        set ::_replyto {}
        bind .cv <<ReplyTo>> {set ::_replyto %d}
        .cv actions reply $id
        wait
        list [expr {[lindex $::_replyto 0] eq $id}] [lindex $::_replyto 2]
    } -result {1 {original text here}}

# -- stale cursor guard ---------------------------------------------------------

test chatview-stale-old-discarded {cleanup invalidation discards stale old-direction response} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        # Initial load, incomplete archive → thirst fires for old
        set mamIq [cv_find_mam_iq alice@example.com]
        cv_complete_mam_with $mamIq {
            sid1 "msg 1" 2024-01-01T10:00:00Z
            sid2 "msg 2" 2024-01-01T11:00:00Z
            sid3 "msg 3" 2024-01-01T12:00:00Z
        } false
        $::_client conn clear
        wait

        set countBefore [llength [.cv messages keys]]

        # Old-direction MAM query is now in flight
        set mamIq2 [cv_find_mam_iq alice@example.com]
        if {$mamIq2 eq ""} { error "no thirst MAM IQ" }

        # Simulate a cull of the old direction while the response is in
        # flight. This unlistens the callback and cancels the backend query,
        # so the stale response should never reach OnLoadDone.
        .cv OnCulled {old}

        # Complete the now-stale MAM response
        cv_complete_mam_with $mamIq2 {
            sid-old1 "older 1" 2024-01-01T08:00:00Z
            sid-old2 "older 2" 2024-01-01T09:00:00Z
        }
        wait

        set countAfter [llength [.cv messages keys]]
        list before=$countBefore after=$countAfter
    } -result {before=3 after=3}

test chatview-fresh-load-after-invalidation {new thirst re-requests and loads after invalidation} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        # Initial load, incomplete
        set mamIq [cv_find_mam_iq alice@example.com]
        cv_complete_mam_with $mamIq {
            sid1 "msg 1" 2024-01-01T10:00:00Z
            sid2 "msg 2" 2024-01-01T11:00:00Z
            sid3 "msg 3" 2024-01-01T12:00:00Z
        } false
        $::_client conn clear
        wait

        # Old thirst in flight
        set mamIq2 [cv_find_mam_iq alice@example.com]
        if {$mamIq2 eq ""} { error "no first thirst MAM IQ" }

        # Invalidate
        .cv OnCulled {old}
        $::_client conn clear

        # Kick a new cleanup cycle — in real use the user is scrolling,
        # but here the widget is idle so we nudge it.
        event generate [.cv textwidget] <<Yview>>
        wait

        # Thirst should re-fire with a fresh cursor → new MAM query
        set mamIq3 [cv_find_mam_iq alice@example.com]
        if {$mamIq3 eq ""} { error "no re-requested MAM IQ after invalidation" }

        # Complete the fresh request
        cv_complete_mam_with $mamIq3 {
            sid-old1 "older 1" 2024-01-01T08:00:00Z
            sid-old2 "older 2" 2024-01-01T09:00:00Z
        }
        wait

        llength [.cv messages keys]
    } -result {5}

test chatview-goto-cancels-inflight {goto end discards in-flight thirst response} \
    -setup { cv_setup; cv_create -pack -nomam } \
    -cleanup { cv_cleanup } \
    -body {
        # Initial load, incomplete
        set mamIq [cv_find_mam_iq alice@example.com]
        cv_complete_mam_with $mamIq {
            sid1 "msg 1" 2024-01-01T10:00:00Z
            sid2 "msg 2" 2024-01-01T11:00:00Z
            sid3 "msg 3" 2024-01-01T12:00:00Z
        } false
        $::_client conn clear
        wait

        # Old thirst in flight
        set mamIq2 [cv_find_mam_iq alice@example.com]
        if {$mamIq2 eq ""} { error "no thirst MAM IQ" }

        # goto end — cancels in-flight loads via unlisten + message cancel
        .cv goto end
        $::_client conn clear
        wait
        cv_complete_mam
        wait

        set countAfterGoto [llength [.cv messages keys]]

        # Complete stale old-direction MAM
        cv_complete_mam_with $mamIq2 {
            sid-old1 "older 1" 2024-01-01T08:00:00Z
            sid-old2 "older 2" 2024-01-01T09:00:00Z
        }
        wait

        set countAfterStale [llength [.cv messages keys]]
        list goto=$countAfterGoto stale=$countAfterStale
    } -result {goto=3 stale=3}

test chatview-live-dropped-when-tail-culled {live message ignored after new-direction cull} \
    {*}$cv_common \
    -body {
        cv_feed "anchor" srv-anchor
        wait
        set countBefore [llength [.cv messages keys]]
        # Simulate chatarea culling the tail. AtTail flips false, so
        # subsequent live <New> events should be dropped.
        .cv OnCulled {new}
        cv_feed "while-paused" srv-paused
        wait
        set countAfter [llength [.cv messages keys]]
        list before=$countBefore after=$countAfter
    } -result {before=1 after=1}

# -- chatarea apply tests -------------------------------------------------------

# Helper: build a message dict suitable for chatarea apply
proc ca_msg {id body} {
    dict create key $id sort $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 0 server_status ""
}

proc ca_outgoing {id body {status pending}} {
    dict create key $id sort $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 1 server_status $status
}

proc ca_patch {id} {
    dict create key $id sort $id server_status ""
}

proc ca_reply {id body replyId replyTo author replyBody} {
    dict create key $id sort $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 0 server_status "" \
        reply_id $replyId reply_to $replyTo reply_author $author \
        reply_body $replyBody
}

proc ca_msg_att {id body attachments args} {
    set d [dict create key $id sort $id body $body \
        display_name test avatar_jid "" \
        timestamp $id is_outgoing 0 server_status "" \
        attachments $attachments]
    # The backend supplies `caption` (body minus a redundant attachment URL);
    # callers pass it explicitly when the rendered text matters.
    if {[llength $args]} { dict set d caption [lindex $args 0] }
    return $d
}

proc ca_upload {id status attachments} {
    dict create key $id sort $id body "" \
        display_name You avatar_jid "" \
        timestamp $id is_outgoing 1 server_status $status \
        attachments $attachments
}

set ca_common {
    -setup   { chatarea .ca; update }
    -cleanup { destroy .ca }
}

test chatarea-apply-forward {forward batch lands in timestamp order} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"] \
            [ca_msg 300 "msg C"]]
        .ca messages keys
    } -result {100 200 300}

test chatarea-apply-backward {newest-first batch lands in timestamp order} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 500 "msg E"]]
        .ca apply [list \
            [ca_msg 400 "msg D"] \
            [ca_msg 300 "msg C"] \
            [ca_msg 200 "msg B"]]
        .ca messages keys
    } -result {200 300 400 500}

test chatarea-apply-tombstone {empty-body messages still take a slot in the timeline} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 ""] \
            [ca_msg 300 "msg C"] \
            [ca_msg 400 ""] \
            [ca_msg 500 "msg E"]]
        .ca messages keys
    } -result {100 200 300 400 500}

test chatarea-apply-patch-on-displayed {patch entry alongside a new insert applies and inserts} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 500 "msg E"]]
        .ca apply [list \
            [ca_patch 500] \
            [ca_msg 400 "msg D"]]
        .ca messages keys
    } -result {400 500}

test chatarea-apply-out-of-order {batch with non-monotonic timestamps lands sorted} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "A"] \
            [ca_msg 300 "C"] \
            [ca_msg 200 "B"]]
        .ca messages keys
    } -result {100 200 300}

test chatarea-apply-dedup {already displayed message is patched not duplicated} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        # Re-apply same messages
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        .ca messages keys
    } -result {100 200}

# Identity and position are separate inputs: rows sharing a `sort` are distinct
# rows, and a key may be any string.

test chatarea-distinct-keys-same-sort {rows sharing a sort position stay separate rows} \
    {*}$ca_common \
    -body {
        set a [dict replace [ca_msg 100 "from alice"] key alice@example.com|100]
        set b [dict replace [ca_msg 100 "from bob"]   key bob@example.com|100]
        .ca apply [list $a $b]
        set content [[.ca textwidget] get 1.0 end-1c]
        list [llength [.ca messages keys]] \
             [string match "*from alice*from bob*" $content]
    } -result {2 1}

test chatarea-key-with-dots-and-at {a key carrying dots and an @ draws and resolves back} \
    {*}$ca_common \
    -body {
        set key room@conf.example.com?join|1700
        .ca apply [list [dict replace [ca_msg 100 "hi"] key $key]]
        set tag [.ca messages tag $key]
        lassign [.ca messages body-range $key] first last
        pack .ca -expand yes -fill both
        update idletasks
        set clicked ""
        bind .ca <<MessageClick>> {set clicked %d}
        lassign [[.ca textwidget] bbox $first] bx by
        event generate [.ca textwidget] <Button-1> -x [expr {$bx + 2}] -y [expr {$by + 2}]
        wait
        list [expr {$tag ne ""}] [[.ca textwidget] get $first $last] $clicked
    } -result [list 1 hi room@conf.example.com?join|1700]

test chatarea-patch-receipt {Patch with server_status updates receipt checkmark} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_outgoing 100 "hello"]]
        # Receipt tag should exist but show no checkmark (pending)
        set tag [.ca messages tag 100].receipt
        set ranges [[.ca textwidget] tag ranges $tag]
        set before [expr {[llength $ranges] > 0
            ? [[.ca textwidget] get {*}$ranges] : "MISSING"}]
        # Patch: server confirms receipt
        .ca apply [list [ca_patch 100]]
        set ranges [[.ca textwidget] tag ranges $tag]
        set after [expr {[llength $ranges] > 0
            ? [[.ca textwidget] get {*}$ranges] : "MISSING"}]
        list before=$before after=$after
    } -result "{before= } {after= \u2713}"

test chatarea-reply-preview-rendered {a reply renders a clickable preview with author and snippet} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_reply 100 "the reply" rid1 room@x/bob bob "the original text"]]
        set content [[.ca textwidget] get 1.0 end-1c]
        list [string match "*bob*the original text*the reply*" $content] \
             [expr {"[.ca messages tag 100].replyref" in [[.ca textwidget] tag names]}]
    } -result {1 1}

test chatarea-reactions-rendered {a message's reactions render emoji+count chips, styled and clickable} \
    {*}$ca_common \
    -body {
        .ca apply [list [dict merge [ca_msg 100 "hi"] {
            reactions {
                👍 {reactors {bob carol} mine 1}
                ❤️ {reactors {bob} mine 0}
            }
        }]]
        set content [[.ca textwidget] get 1.0 end-1c]
        list [string match "*👍 2*❤️ 1*" $content] \
             [expr {"[.ca messages tag 100].reactions" in [[.ca textwidget] tag names]}] \
             [expr {[[.ca textwidget] tag bind [.ca messages tag 100].react.1 <Button-1>] ne ""}]
    } -result {1 1 1}

test chatarea-reactions-update-in-place {reactions update swaps only the chip row, leaving the body intact} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 100 "hi there"]]
        # Add a chip row where there was none.
        .ca reactions update 100 {👍 {reactors {bob} mine 0}}
        set added [list \
            [string match "*hi there*👍 1*" [[.ca textwidget] get 1.0 end-1c]] \
            [expr {[llength [[.ca textwidget] tag ranges [.ca messages tag 100].reactions]] > 0}]]
        # Change the set.
        .ca reactions update 100 {👍 {reactors {bob carol} mine 1}}
        set changed [string match "*👍 2*" [[.ca textwidget] get 1.0 end-1c]]
        # Retract everything: chip row gone, body still present, message kept.
        .ca reactions update 100 {}
        set cleared [list \
            [llength [[.ca textwidget] tag ranges [.ca messages tag 100].reactions]] \
            [string match "*hi there*" [[.ca textwidget] get 1.0 end-1c]] \
            [expr {100 in [.ca messages keys]}]]
        concat $added $changed $cleared
    } -result {1 1 1 0 1 1}

# -- attachments ----------------------------------------------------------------

test chatarea-attachment-image-caption {image attachment renders a clickable caption frame} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]]]]
        set f [.ca attachment path 100 0]
        list [winfo exists $f] [winfo exists $f.cap]
    } -result {1 1}

test chatarea-attachment-file-chip {file attachment renders name + Open/Save buttons} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/d.pdf" \
            [list [dict create url https://h/d.pdf type file name d.pdf size "" mime ""]]]]
        set f [.ca attachment path 100 0].chip
        list [winfo exists $f.name] [winfo exists $f.open] [winfo exists $f.save]
    } -result {1 1 1}

test chatarea-image-load-above-keeps-viewport \
    {a thumbnail loading above the viewport must not move the view} \
    -setup {
        set ::ca_png /tmp/ca_relay_[pid].png
        set im [image create photo -width 400 -height 300]
        $im put #336699 -to 0 0 400 300
        $im write $::ca_png -format png
        image delete $im
        chatarea .ca
        pack .ca -fill both -expand yes
        wm geometry . 440x540
        update
    } \
    -cleanup {
        destroy .ca
        file delete -- $::ca_png
        unset -nocomplain ::ca_png
    } \
    -body {
        # 21 messages; the image is on a mid message (id 200).
        set msgs {}
        for {set i 0} {$i <= 20} {incr i} {
            set id [expr {100 + $i * 10}]
            if {$id == 200} {
                lappend msgs [ca_msg_att $id "" [list [dict create \
                    url $::ca_png type image name p.png size "" mime ""]]]
            } else {
                lappend msgs [ca_msg $id "line $i\nbody $i\ntail $i"]
            }
        }
        .ca apply $msgs
        # Park message 150 at the top of the viewport, with the image (200)
        # on-screen below it. A thumbnail popping in on 200 must not shift
        # the content the user is already reading above it.
        [.ca textwidget] see [.ca messages tag 150].first
        [.ca textwidget] sync; update
        set before [lindex [[.ca textwidget] bbox [.ca messages tag 150].first] 1]
        .ca attachment image 200 0 $::ca_png
        [.ca textwidget] sync; update
        set after [lindex [[.ca textwidget] bbox [.ca messages tag 150].first] 1]
        list visBefore=[expr {$before ne ""}] visAfter=[expr {$after ne ""}] \
             stable=[expr {$before ne "" && $after ne "" \
                 && abs($after - $before) < 30}]
    } -result {visBefore=1 visAfter=1 stable=1}

test chatarea-attachment-scroll-relay {attachment widgets relay wheel events to the text} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/d.pdf" \
            [list [dict create url https://h/d.pdf type file name d.pdf size "" mime ""]]]]
        set f [.ca attachment path 100 0]
        list [expr {[bind $f <Button-4>] ne ""}] \
             [expr {[bind $f.chip.name <MouseWheel>] ne ""}] \
             [expr {[bind $f.chip.open <Button-5>] ne ""}]
    } -result {1 1 1}

test chatarea-attachment-uploading-bar {an uploading attachment shows a progress bar} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_upload 100 uploading \
            [list [dict create url /tmp/x.png type image name x.png size "" mime ""]]]]
        winfo exists [.ca attachment path 100 0].up.bar
    } -result 1

test chatarea-attachment-progress {attachment state active sets the bar value} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_upload 100 uploading \
            [list [dict create url /tmp/x.png type image name x.png size "" mime ""]]]]
        .ca attachment state 100 0 upload active 50 100
        expr {abs([[.ca attachment path 100 0].up.bar cget -value] - 50) < 0.01}
    } -result 1

test chatarea-attachment-uploaded-removes-bar {upload done removes the progress bar} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_upload 100 uploading \
            [list [dict create url /tmp/x.png type image name x.png size "" mime ""]]]]
        .ca attachment state 100 0 upload done 0 0
        winfo exists [.ca attachment path 100 0].up
    } -result 0

test chatarea-attachment-failed-retry {a failed upload shows a Retry button} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_upload 100 failed \
            [list [dict create url /tmp/d.pdf type file name d.pdf size "" mime ""]]]]
        winfo exists [.ca attachment path 100 0].up.retry
    } -result 1

test chatarea-attachment-done-then-failed-transition {uploaded then failed swaps bar for Retry} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_upload 100 uploading \
            [list [dict create url /tmp/x.png type image name x.png size "" mime ""]]]]
        set hadBar [winfo exists [.ca attachment path 100 0].up.bar]
        .ca attachment state 100 0 upload failed 0 0
        list bar=$hadBar retry=[winfo exists [.ca attachment path 100 0].up.retry] \
            barGone=[expr {![winfo exists [.ca attachment path 100 0].up.bar]}]
    } -result {bar=1 retry=1 barGone=1}

test chatarea-attachment-download-bar {a download active state shows a progress bar} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]]]]
        .ca attachment state 100 0 download active 30 100
        list bar=[winfo exists [.ca attachment path 100 0].dl.bar] \
            val=[expr {abs([[.ca attachment path 100 0].dl.bar cget -value] - 30) < 0.01}]
    } -result {bar=1 val=1}

test chatarea-attachment-download-done-removes-bar {download done removes the bar} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]]]]
        .ca attachment state 100 0 download active 30 100
        .ca attachment state 100 0 download done 0 0
        winfo exists [.ca attachment path 100 0].dl
    } -result 0

test chatarea-attachment-empty-caption-no-body {an empty caption renders no body text} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]] \
            ""]]
        set r [[.ca textwidget] tag ranges [.ca messages tag 100].body]
        expr {[llength $r] == 0 || [[.ca textwidget] get {*}$r] eq ""}
    } -result 1

test chatarea-attachment-caption-rendered {a non-empty caption is shown as the body text} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "see this https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]] \
            "see this https://h/p.png"]]
        set r [[.ca textwidget] tag ranges [.ca messages tag 100].body]
        [.ca textwidget] get {*}$r
    } -result {see this https://h/p.png}

test chatarea-attachment-image-missing-frame {attachment image on an unknown id is a no-op} \
    {*}$ca_common \
    -body {
        .ca attachment image 999 0 /nonexistent/path.png
        winfo exists [.ca attachment path 999 0]
    } -result 0

test chatarea-attachment-image-bad-path {attachment image with an undecodable file leaves no image} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]]]]
        .ca attachment image 100 0 /nonexistent/path.png
        winfo exists [.ca attachment path 100 0].img
    } -result 0

test chatarea-attachment-image-frees-photo {destroying the thumbnail label frees its Tk photo} \
    -setup {
        set ::cap_png /tmp/ca_leak_[pid].png
        set im [image create photo -width 20 -height 20]
        $im put #abcdef -to 0 0 20 20
        $im write $::cap_png -format png
        image delete $im
        chatarea .ca
        pack .ca
        update
    } \
    -cleanup { destroy .ca; file delete -- $::cap_png; unset -nocomplain ::cap_png } \
    -body {
        .ca apply [list [ca_msg_att 100 "https://h/p.png" \
            [list [dict create url https://h/p.png type image name p.png size "" mime ""]]]]
        set before [llength [image names]]
        .ca attachment image 100 0 $::cap_png
        set during [llength [image names]]
        destroy [.ca attachment path 100 0].img
        update
        set after [llength [image names]]
        list grew=[expr {$during > $before}] cleaned=[expr {$after == $before}]
    } -result {grew=1 cleaned=1}

# -- highlight / system ---------------------------------------------------------

test chatarea-highlight-message {highlight applies yellow and clears previous} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [ca_msg 200 "msg B"]]
        .ca highlight message 100
        set bg1 [[.ca textwidget] tag cget [.ca messages tag 100] -background]
        .ca highlight message 200
        set bg1after [[.ca textwidget] tag cget [.ca messages tag 100] -background]
        set bg2 [[.ca textwidget] tag cget [.ca messages tag 200] -background]
        list first=$bg1 first_after=$bg1after second=$bg2
    } -result {first=yellow first_after= second=yellow}

test chatarea-highlight-clear {highlight clear removes background} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 100 "msg A"]]
        .ca highlight message 100
        set before [[.ca textwidget] tag cget [.ca messages tag 100] -background]
        .ca highlight clear
        set after [[.ca textwidget] tag cget [.ca messages tag 100] -background]
        list before=$before after=$after
    } -result {before=yellow after=}

test chatarea-system-insert {system message is inserted with system tag} \
    {*}$ca_common \
    -body {
        .ca system insert "Connection lost"
        set content [[.ca textwidget] get 1.0 end-1c]
        set tags [[.ca textwidget] tag names 1.0]
        list [string match *Connection\ lost* $content] \
            [expr {"system" in $tags}]
    } -result {1 1}

# -- chatarea pagination signals ------------------------------------------------

# Wrap [.ca textwidget] so 'viewport above|below' returns ::mock_above /
# ::mock_below, read fresh each call so a test can shrink them as it deletes.
proc ca_install_pixel_mock {} {
    rename .ca.text _real_ca_text
    proc ::.ca.text args {
        if {[lindex $args 0] eq "viewport"} {
            if {[lindex $args 1] eq "above"} {
                return [expr {$::mock_above}]
            } else {
                return [expr {$::mock_below}]
            }
        }
        return [_real_ca_text {*}$args]
    }
}
proc ca_uninstall_pixel_mock {} {
    catch {rename ::.ca.text {}}
    catch {rename _real_ca_text {}}
}

set ca_signals_common {
    -setup {
        set ::ca_thirsty {}
        set ::ca_culled {}
        set ::mock_above 0
        set ::mock_below 0
        chatarea .ca \
            -thirst-command [list apply {{dir id} {lappend ::ca_thirsty [list $dir $id]}}] \
            -cull-command   [list apply {{dirs} {lappend ::ca_culled $dirs}}]
        pack .ca -fill both -expand yes
        wm geometry . 400x200
        update
        ca_install_pixel_mock
    }
    -cleanup {
        ca_uninstall_pixel_mock
        destroy .ca
        unset -nocomplain ::ca_thirsty ::ca_culled ::mock_above ::mock_below
    }
}

test chatarea-highlight-matches-tags-each-range {the backend's ranges index the body, not the row} \
    {*}$ca_common \
    -body {
        # Offsets are into the body alone; the author "test" precedes it.
        .ca apply [list [ca_msg 100 "the cat sat on the cat mat"]]
        .ca highlight matches 100 {4 3 19 3}
        set r [[.ca textwidget] tag ranges search_match]
        list [expr {[llength $r] / 2}] \
            [[.ca textwidget] get [lindex $r 0] [lindex $r 1]] \
            [[.ca textwidget] get [lindex $r 2] [lindex $r 3]]
    } -result {2 cat cat}

test chatarea-highlight-matches-tags-a-caption {a media row's ranges index its caption} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "http://ex/a.png" \
            {{url http://ex/a.png type file name a.png size "" mime ""}} \
            "look, a cat"]]
        .ca highlight matches 100 {8 3}
        [.ca textwidget] get {*}[[.ca textwidget] tag ranges search_match]
    } -result {cat}

test chatarea-highlight-matches-survives-an-empty-body {a caption-less attachment draws no body to index} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg_att 100 "http://ex/a.png" \
            {{url http://ex/a.png type file name a.png size "" mime ""}} ""]]
        .ca highlight matches 100 {0 3}
        [.ca textwidget] tag ranges search_match
    } -result {}

test chatarea-replace-redraws-in-place {a replaced row keeps its position and shows the new content} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        .ca replace 200 [ca_msg 200 "b revised"]
        list [.ca messages keys] \
             [string match "*a*b revised*c*" [[.ca textwidget] get 1.0 end-1c]] \
             [string match "*b\n*" [[.ca textwidget] get 1.0 end-1c]]
    } -result {{100 200 300} 1 0}

test chatarea-replace-can-rekey {a replacement carrying a new key and sort moves the row} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        # What a server-relocated send looks like: same row, new identity.
        .ca replace 200 [ca_msg 400 "b"]
        list [.ca messages keys] \
             [string match "*a*c*b*" [[.ca textwidget] get 1.0 end-1c]]
    } -result {{100 300 400} 1}

test chatarea-replace-ignores-an-undrawn-key {replacing a row that isn't displayed draws nothing} \
    {*}$ca_common \
    -body {
        .ca apply [list [ca_msg 100 "a"]]
        .ca replace 999 [ca_msg 999 "ghost"]
        list [.ca messages keys] \
             [string match "*ghost*" [[.ca textwidget] get 1.0 end-1c]]
    } -result {100 0}

# The decisions themselves are slicepolicy's, and tested there. These two
# check the wiring: a real scroll event reaches the policy, and what the policy
# asks for lands on the right rows.

test chatarea-thirsts-through-the-scroll-path {a thin buffer asks for more at both edges, keyed by the edge rows} \
    {*}$ca_signals_common \
    -body {
        set ::mock_above 100
        set ::mock_below 100
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        event generate [.ca textwidget] <<Yview>>
        update
        set ::ca_thirsty
    } -result {{old 100} {new 300}}

test chatarea-culls-through-the-scroll-path {a full buffer drops rows and erases what they drew} \
    {*}$ca_signals_common \
    -body {
        # mock_above never falls, so the drop loop runs until nothing is left.
        set ::mock_above 9999
        set ::mock_below 0
        .ca apply [list \
            [ca_msg 100 "a"] \
            [ca_msg 200 "b"] \
            [ca_msg 300 "c"]]
        event generate [.ca textwidget] <<Yview>>
        update
        list [.ca messages keys] $::ca_culled [[.ca textwidget] get 1.0 end-1c]
    } -result {{} old {}}

# -- edits (XEP-0308) / retractions (XEP-0424/0425) -----------------------------

test chatarea-edited-marker {an edited message renders the (edited) marker} \
    {*}$ca_common \
    -body {
        .ca apply [list [dict merge [ca_outgoing 100 "hello"] {edited 1}]]
        set r [[.ca textwidget] tag ranges edited]
        list [expr {[llength $r] > 0}] \
             [string match "*(edited)*" [[.ca textwidget] get 1.0 end-1c]]
    } -result {1 1}

test chatarea-retracted-tombstone {a retracted message renders a tombstone and keeps its slot} \
    {*}$ca_common \
    -body {
        .ca apply [list \
            [ca_msg 100 "msg A"] \
            [dict merge [ca_msg 200 "secret"] {retracted 1}] \
            [ca_msg 300 "msg C"]]
        set tomb [[.ca textwidget] tag ranges tombstone]
        list [expr {[llength $tomb] > 0}] \
             [string match "*deleted*" [[.ca textwidget] get 1.0 end-1c]] \
             [expr {![string match "*secret*" [[.ca textwidget] get 1.0 end-1c]]}] \
             [.ca messages keys]
    } -result {1 1 1 {100 200 300}}

test chatview-edit-redraws-body {a received correction redraws the message body in place} \
    -setup { cv_setup; cv_create } -cleanup cv_cleanup \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m1 {
            j origin-id -ns urn:xmpp:sid:0 -id m1
            j body #body "helo"
        }]
        wait
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j replace -ns urn:xmpp:message-correct:0 -id m1
            j body #body "hello world"
        }]
        wait
        set txt [[.cv textwidget] get 1.0 end-1c]
        list [string match "*hello world*" $txt] \
             [string match "*(edited)*" $txt]
    } -result {1 1}

test chatview-retract-tombstones {a received self-retraction redraws the message as a tombstone} \
    -setup { cv_setup; cv_create } -cleanup cv_cleanup \
    -body {
        $::_client conn feed [j message -type chat -from alice@example.com/phone -id m1 {
            j origin-id -ns urn:xmpp:sid:0 -id m1
            j body #body "secret"
        }]
        wait
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j retract -ns urn:xmpp:message-retract:1 -id m1
        }]
        wait
        set txt [[.cv textwidget] get 1.0 end-1c]
        list [string match "*deleted*" $txt] \
             [expr {![string match "*secret*" $txt]}]
    } -result {1 1}

test chatview-edit-at-tail-keeps-tail-pinned \
    {editing the newest message while at the bottom keeps it in view} \
    -setup { cv_overflow_setup } -cleanup cv_cleanup \
    -body {
        [.cv textwidget] see end
        wait
        set atEndBefore [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
        # Grow the last message ("fill 14" -> seed14) by several lines. Without
        # re-pinning the tail, the new content drifts below the fold and the
        # view is no longer at the bottom.
        $::_client conn feed [j message -type chat -from alice@example.com/phone {
            j replace -ns urn:xmpp:message-correct:0 -id seed14
            j body #body "edited\nmuch\ntaller\nnow"
        }]
        wait
        set atEndAfter [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
        list $atEndBefore $atEndAfter
    } -result {1 1}

test chatview-send-confirm-timestamp-move-keeps-tail \
    {a sent message whose confirm moves its timestamp stays pinned to the tail} \
    -setup { cv_overflow_setup } -cleanup cv_cleanup \
    -body {
        # OMEMO on would park the send on devicelist warming; disable it so
        # the message reaches the wire and can be confirmed.
        tacky omemo setEnabled -acc $::acc -jid alice@example.com -value 0
        tacky message send -acc $::acc -chat alice@example.com -body "hello"
        wait
        set atEndAfterSend [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
        set sentId [.cv messages newest]
        # Server confirms with a stamp 1s later: this fires a <Confirmed>
        # event that deletes and re-inserts the row at its new timestamp.
        # Without re-pinning, the top-anchored reinsert drifts off the tail.
        cv_muc_echo $sentId echo-move [FormatTimestampISO [expr {$sentId + 1000000}]]
        wait
        set atEndAfterMove [expr {[lindex [[.cv textwidget] yview] 1] >= 1.0}]
        list $atEndAfterSend $atEndAfterMove
    } -result {1 1}

# Count embedded padlock images across the whole view.
proc cv_lock_count {} {
    set n 0
    foreach img [[.cv textwidget] image names] {
        if {[[.cv textwidget] image cget $img -image]
                eq "mate/16x16/status/stock_lock.png"} { incr n }
    }
    return $n
}

test chatview-plaintext-resend-drops-the-padlock \
    {a <Status> carrying a cleared encryption stamp redraws the row unlocked} \
    -setup { cv_setup } -cleanup cv_cleanup \
    -body {
        set ts [ParseTimestamp 2024-01-01T10:00:00Z]
        $::_client message messagestore store [list [dict create \
            timestamp $ts chat_jid alice@example.com \
            from_jid $::acc body "secret" \
            server_id "" own_id oid-lock raw_xml "" \
            server_status failed fail_reason encrypt encryption omemo]]
        cv_create -pack
        wait
        set before [cv_lock_count]
        tacky emit message <Status> -acc $::acc -jid alice@example.com \
            -timestamp $ts -server_status pending -fail_reason "" -encryption ""
        wait
        list before=$before after=[cv_lock_count]
    } -result {before=1 after=0}
