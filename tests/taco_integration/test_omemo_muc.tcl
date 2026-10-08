# OMEMO in a real group chat (XEP-0384 §5.7): three tacky accounts in a
# members-only, non-anonymous room on the test server. Anna owns the room
# and makes Bea and Cy members; each has OMEMO switched on for it. The
# accounts are this file's own: every login leaves a device id on the
# account's devicelist, and every device on it is one a room message is
# keyed for. mucnone never logs in, so it has no OMEMO at all.

package require tcltest
package require tacky::testhelpers
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::omemo_muc_int {

    variable HOST    "example.local"
    variable TIMEOUT 15000

    variable ANNA "mucoa@example.local"
    variable BEA  "mucob@example.local"
    variable CY   "mucoc@example.local"
    variable NONE "mucnone@example.local"
    variable ROOM ""
    variable CHAT ""

    variable DEVICELIST "eu.siacs.conversations.axolotl.devicelist"
    variable BUNDLES    "eu.siacs.conversations.axolotl.bundles"
    variable NS_PUBSUB  "http://jabber.org/protocol/pubsub"

    variable _counter 0

    # Register a listener, run $script, and return the event's arguments
    # once it fires. Our own <New> (sent synchronously) does not count.
    proc awaitEvent {args} {
        variable TIMEOUT
        set script [lindex $args end]
        set listenerArgs [lrange $args 0 end-1]
        set var [namespace current]::_await_[incr [namespace current]::_counter]
        set $var ""
        set tag [tacky listen {*}$listenerArgs [list apply {{var argsL} {
            if {[dict exists $argsL -message]
                && [dict get $argsL -message is_outgoing]} return
            set $var $argsL
        }} $var]]
        uplevel 1 $script
        try {
            wait_var $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }
        tacky unlisten $tag
        return [set $var]
    }

    # Call a tacky method that answers through -command, and wait for it.
    proc call {args} {
        variable TIMEOUT
        set var [namespace current]::_call_[incr [namespace current]::_counter]
        set $var ""
        tacky {*}$args -command [list apply {{v args} {
            set $v [list ok $args]
        }} $var] -onerror [list apply {{v msg} {
            set $v [list error $msg]
        }} $var]
        wait_var $var $TIMEOUT
        lassign [set $var] status result
        if {$status eq "error"} { error "tacky $args: $result" }
        return $result
    }

    proc pollUntil {script} {
        variable TIMEOUT
        set deadline [expr {[clock milliseconds] + $TIMEOUT}]
        while {[clock milliseconds] < $deadline} {
            set v [uplevel 1 $script]
            if {$v ne "" && $v ne "0"} { return $v }
            set [namespace current]::_tick 0
            after 200 [list set [namespace current]::_tick 1]
            vwait [namespace current]::_tick
        }
        return ""
    }

    proc iqCall {client args} {
        variable TIMEOUT
        set var [namespace current]::_iq_[incr [namespace current]::_counter]
        set $var ""
        $client iq request {*}$args -command [list apply {{v stanza} {
            set $v [list reply $stanza]
        }} $var]
        wait_var $var $TIMEOUT
        return [lindex [set $var] 1]
    }

    # Our device on our devicelist, and its bundle on the server: until then
    # another account reading our keys would leave this device out.
    proc ownKeysUp {acc} {
        variable DEVICELIST
        variable BUNDLES
        variable NS_PUBSUB
        set client [tacky client $acc]
        set dev [$client omemo device_id]
        set listed [pollUntil {
            set reply [iqCall $client -type get -to $acc -payload \
                [j pubsub -ns $NS_PUBSUB { j items -node $DEVICELIST }]]
            expr {$dev in [lmap d [xsearch $reply pubsub items item list device] {
                xsearch $d -get @id
            }]}
        }]
        set bundled [pollUntil {
            set reply [iqCall $client -type get -to $acc -payload \
                [j pubsub -ns $NS_PUBSUB { j items -node ${BUNDLES}:$dev }]]
            expr {[xsearch $reply -get @type] eq "result"
                  && [llength [xsearch $reply pubsub items item bundle]] > 0}
        }]
        if {$listed eq "" || $bundled eq ""} {
            error "$acc: own OMEMO device never reached the server"
        }
    }

    proc members {acc} {
        variable ROOM
        dict keys [dict get [[tacky client $acc] muc members -jid $ROOM] members]
    }

    proc rowOfBody {acc body} {
        variable CHAT
        foreach m [dict get [[tacky client $acc] message messagestore get latest $CHAT] messages] {
            if {[string trimright [::test::helpers::msgText $m]] eq $body} { return $m }
        }
        return ""
    }

    # A member joins, once the room is private as far as it can see.
    proc join {acc nick} {
        variable ROOM
        variable CHAT
        awaitEvent muc <Joined> -acc $acc -jid $ROOM {
            [tacky client $acc] muc join -jid $ROOM -nick $nick
        }
        if {[pollUntil {
            dict get [tacky omemo roomStatus -acc $acc -jid $CHAT] eligible
        }] eq ""} {
            error "$acc: $ROOM never said it is private"
        }
        tacky omemo setEnabled -acc $acc -jid $CHAT -value 1
    }

    proc setAffiliation {target affil} {
        variable ANNA
        variable ROOM
        call muc affiliation -acc $ANNA -jid $ROOM -target $target \
            -affiliation $affil
    }

    proc setup {} {
        variable HOST
        variable ANNA
        variable BEA
        variable CY
        variable ROOM
        variable CHAT
        set ROOM "omemo[clock milliseconds]@conference.$HOST"
        set CHAT ${ROOM}?join

        tacky_init
        foreach {acc user pass} [list $ANNA mucoa mucoapass $BEA mucob mucobpass \
                $CY mucoc mucocpass] {
            tacky account add {*}$::tacky_test_account_args -acc $acc \
                -password $pass -domain $HOST -username $user
            set [namespace current]::caughtUp($acc) 0
            tacky listen message <CatchupDone> -acc $acc [list apply {{var args} {
                set $var 1
            }} [namespace current]::caughtUp($acc)]
            tacky account enable -acc $acc
        }
        foreach acc [list $ANNA $BEA $CY] {
            wait_value [namespace current]::caughtUp($acc) 1 15000
            ownKeysUp $acc
        }

        call muc createRoom -acc $ANNA -jid $ROOM -nick anna -config {
            muc#roomconfig_membersonly 1
            muc#roomconfig_whois anyone
            muc#roomconfig_enablearchiving 1
            mam 1
        }
        setAffiliation $BEA member
        setAffiliation $CY member
        if {[pollUntil {
            dict get [tacky omemo roomStatus -acc $ANNA -jid $CHAT] eligible
        }] eq ""} {
            error "$ROOM never said it is private"
        }
        tacky omemo setEnabled -acc $ANNA -jid $CHAT -value 1
        join $BEA bea
        join $CY cy
        foreach acc [list $ANNA $BEA $CY] {
            if {[pollUntil {
                expr {$BEA in [members $acc] && $CY in [members $acc]
                      && $ANNA in [members $acc]}
            }] eq ""} {
                error "$acc never learned the room's members: [members $acc]"
            }
        }
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    set common {
        -constraints withServer
        -setup { ::test::omemo_muc_int::setup }
        -cleanup { ::test::omemo_muc_int::cleanup }
    }

    test omemo-muc-int-round-trip \
        {a message to the room is encrypted for every member, who all read it, and the sender's echo confirms it} \
        {*}$common -body {
            variable ANNA
            variable BEA
            variable CY
            variable CHAT
            set got {}
            set confirmed [awaitEvent message <Confirmed> -acc $ANNA -jid $CHAT {
                set bea [awaitEvent message <New> -acc $BEA -jid $CHAT {
                    set cy [awaitEvent message <New> -acc $CY -jid $CHAT {
                        tacky message send -acc $ANNA -chat $CHAT -body "hello room"
                    }]
                }]
            }]
            foreach ev [list $bea $cy] {
                set m [dict get $ev -message]
                lappend got [string trimright [::test::helpers::msgText $m]] \
                    [dict get $m encryption]
            }
            set mine [rowOfBody $ANNA "hello room"]
            list $got [dict get $confirmed -server_status] \
                [dict get $mine encryption] \
                [string match "*OMEMO*" [[tacky client $ANNA] message rawxml \
                    -chat $CHAT -timestamp [dict get $mine timestamp]]]
        } -result {{{hello room} omemo {hello room} omemo} {} omemo 1}

    test omemo-muc-int-reply {a member's reply is read by the others} \
        {*}$common -body {
            variable ANNA
            variable BEA
            variable CY
            variable CHAT
            awaitEvent message <New> -acc $BEA -jid $CHAT {
                tacky message send -acc $ANNA -chat $CHAT -body "first"
            }
            set ev [awaitEvent message <New> -acc $ANNA -jid $CHAT {
                tacky message send -acc $BEA -chat $CHAT -body "a reply"
            }]
            set m [dict get $ev -message]
            list [string trimright [::test::helpers::msgText $m]] \
                [dict get $m encryption] [expr {[dict get $m sender_fp] ne ""}]
        } -result {{a reply} omemo 1}

    test omemo-muc-int-member-without-omemo \
        {a member with no OMEMO stops the send and is named; once removed, sending works again} \
        {*}$common -body {
            variable ANNA
            variable BEA
            variable NONE
            variable CHAT
            setAffiliation $NONE member
            if {[pollUntil { expr {$NONE in [members $ANNA]} }] eq ""} {
                error "the room's member list never named $NONE"
            }
            set ev [awaitEvent omemo <MembersUnreachable> -acc $ANNA -jid $CHAT {
                tacky message send -acc $ANNA -chat $CHAT -body "blocked"
            }]
            set failed [pollUntil {
                expr {[dict get [rowOfBody $ANNA blocked] server_status] eq "failed"}
            }]
            setAffiliation $NONE none
            if {[pollUntil { expr {$NONE ni [members $ANNA]} }] eq ""} {
                error "the room's member list still names $NONE"
            }
            set later [awaitEvent message <New> -acc $BEA -jid $CHAT {
                tacky message send -acc $ANNA -chat $CHAT -body "unblocked"
            }]
            list [dict get $ev -members] $failed \
                [expr {[rowOfBody $BEA blocked] eq ""}] \
                [string trimright [::test::helpers::msgText [dict get $later -message]]]
        } -result [list [list [list jid mucnone@example.local reason no_devices]] 1 1 unblocked]

    test omemo-muc-int-archive-after-rejoin \
        {a member who was away reads what was said from the room's archive} \
        -constraints withServer \
        -setup { ::test::omemo_muc_int::setup } \
        -cleanup { ::test::omemo_muc_int::cleanup } -body {
            variable ANNA
            variable CY
            variable ROOM
            variable CHAT
            awaitEvent muc <Left> -acc $CY -jid $ROOM {
                [tacky client $CY] muc leave -jid $ROOM
            }
            awaitEvent message <Confirmed> -acc $ANNA -jid $CHAT {
                tacky message send -acc $ANNA -chat $CHAT -body "while away"
            }
            awaitEvent message <CatchupDone> -acc $CY -jid $CHAT {
                [tacky client $CY] muc join -jid $ROOM -nick cy \
                    -history {maxstanzas 0}
            }
            set m [rowOfBody $CY "while away"]
            list [expr {$m ne ""}] [expr {$m ne "" ? [dict get $m encryption] : ""}]
        } -result {1 omemo}
}

# Interop: slixmpp-omemo (tests/servers/omemo-bot) in the same room, run by
# tests/servers/omemo-bot/with_bot.sh. Told to join, it reads each room
# message as the occupant the room names and answers "echo: <text>" to the
# room, encrypted for everyone in it - so tacky's room message has to open
# in another implementation, and its answer has to open in tacky.
namespace eval ::test::omemo_muc_int {
    test omemo-muc-int-slixmpp-interop \
        {slixmpp-omemo reads a tacky room message, and tacky reads its answer} \
        -constraints {withServer && omemoBot} \
        -setup { ::test::omemo_muc_int::setup } \
        -cleanup { ::test::omemo_muc_int::cleanup } -body {
            variable ANNA
            variable BEA
            variable ROOM
            variable CHAT
            set bot [jid bare $::env(OMEMO_BOT_JID)]
            setAffiliation $bot member
            tacky message send -acc $ANNA -chat $bot -body "MUCJOIN $ROOM slixbot"
            if {[pollUntil {
                expr {[[tacky client $ANNA] muc occupant -jid $ROOM -nick slixbot] ne ""}
            }] eq ""} {
                error "the bot never joined $ROOM"
            }
            # Its devices, fetched now it is a member, before Anna writes.
            if {[pollUntil {
                expr {[llength [[tacky client $ANNA] omemo devicelist -jid $bot]] > 0}
            }] eq ""} {
                error "Anna never had the bot's devicelist"
            }
            set bea ""
            set anna [awaitEvent message <New> -acc $ANNA -jid $CHAT {
                set bea [awaitEvent message <New> -acc $BEA -jid $CHAT {
                    tacky message send -acc $ANNA -chat $CHAT -body "to the bot"
                }]
            }]
            # Bea's first <New> is Anna's message; the bot's answer follows.
            set answer [pollUntil { rowOfBody $BEA "echo: to the bot" }]
            set m [dict get $anna -message]
            list [string trimright [::test::helpers::msgText $m]] \
                [dict get $m encryption] \
                [expr {$answer ne "" ? [dict get $answer encryption] : "none"}]
        } -result {{echo: to the bot} omemo omemo}
}
