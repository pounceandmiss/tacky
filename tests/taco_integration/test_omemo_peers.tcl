# End-to-end cover for peer visibility: whether a contact who has never
# messaged us, and who isn't on our roster, can find our OMEMO identity
# through PEP alone. Uses two accounts of its own - every other integration
# file logs romeo and juliet in and out, and each login leaves another dead
# device id behind on their devicelist.

package require tcltest
package require tacky::testhelpers
package require tacky::testhelpers::integration
package require libtacky
package require taco

namespace eval ::test::omemo_peer_int {

    variable HOST    "example.local"
    variable TIMEOUT 10000

    # OWNER announces; PEER reads what OWNER announced.
    variable OWNER "omemob@example.local"
    variable PEER  "omemoa@example.local"

    variable DEVICELIST "eu.siacs.conversations.axolotl.devicelist"
    variable BUNDLES    "eu.siacs.conversations.axolotl.bundles"
    variable NS_PUBSUB  "http://jabber.org/protocol/pubsub"
    variable NS_OWNER   "http://jabber.org/protocol/pubsub#owner"

    variable _counter 0

    proc setup {} {
        variable HOST
        variable OWNER
        variable PEER
        tacky account add -acc $PEER  -password omemoapass \
            -domain $HOST -username omemoa
        tacky account add -acc $OWNER -password omemobpass \
            -domain $HOST -username omemob
        tacky account enable -acc $PEER
        tacky account enable -acc $OWNER
        ::test::helpers::waitEvents {
            {conn <State> -acc omemoa@example.local -state connected}
            {conn <State> -acc omemob@example.local -state connected}
        }
        ::test::helpers::waitEvents {
            {message <CatchupDone> -acc omemoa@example.local}
            {message <CatchupDone> -acc omemob@example.local}
        }
        # The announce trails catchup by several round-trips. Wait for our
        # own id, not just a non-empty list: the node still carries the ids
        # earlier tests in this file left on it.
        set client [tacky client $OWNER]
        if {[waitOwnDevice $client $OWNER] eq ""} {
            error "owner's device never reached the devicelist"
        }
        # Bundles publish on a separate chain, and a peer that reads the
        # devicelist before the bundle lands gives up on that device for
        # the rest of its connection.
        if {[waitOwnBundle $client $OWNER] eq ""} {
            error "owner's bundle never reached PEP"
        }
    }

    proc awaitEvent {args} {
        variable TIMEOUT
        set script [lindex $args end]
        set listenerArgs [lrange $args 0 end-1]
        set var [namespace current]::_await_[incr [namespace current]::_counter]
        set $var ""
        # <New> fires for our own sends too, synchronously, so without this
        # guard the await settles on the message we just sent.
        set tag [tacky listen {*}$listenerArgs [list apply {{var argsL} {
            if {[dict exists $argsL -message]
                && [dict get $argsL -message is_outgoing]} return
            set $var $argsL
        }} $var]]
        uplevel 1 $script
        try {
            ::test::helpers::waitVar $var $TIMEOUT
        } on error {msg} {
            tacky unlisten $tag
            error "awaitEvent timeout waiting for [lrange $listenerArgs 0 1]: $msg"
        }
        tacky unlisten $tag
        return [set $var]
    }

    # One IQ from $client, blocking until its reply.
    proc iqCall {client args} {
        variable TIMEOUT
        set var [namespace current]::_iq_[incr [namespace current]::_counter]
        set $var ""
        $client iq request {*}$args -command [list apply {{v stanza} {
            set $v [list reply $stanza]
        }} $var]
        ::test::helpers::waitVar $var $TIMEOUT
        return [lindex [set $var] 1]
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

    # {<iq type> <device ids>} for $owner's devicelist as $client sees it.
    proc fetchDevices {client owner} {
        variable DEVICELIST
        variable NS_PUBSUB
        set reply [iqCall $client -type get -to $owner -payload \
            [j pubsub -ns $NS_PUBSUB {
                j items -node $DEVICELIST
            }]]
        set devices [list]
        foreach d [xsearch $reply pubsub items item list device] {
            lappend devices [xsearch $d -get @id]
        }
        return [list [xsearch $reply -get @type] $devices]
    }

    proc waitOwnDevice {client owner} {
        set dev [$client omemo device_id]
        return [pollUntil {
            expr {$dev in [lindex [fetchDevices $client $owner] 1]}
        }]
    }

    proc haveBundle {client owner dev} {
        variable BUNDLES
        variable NS_PUBSUB
        set node ${BUNDLES}:${dev}
        set reply [iqCall $client -type get -to $owner -payload \
            [j pubsub -ns $NS_PUBSUB {
                j items -node $node
            }]]
        return [expr {[xsearch $reply -get @type] eq "result"
                      && [llength [xsearch $reply pubsub items item bundle]] > 0}]
    }

    proc waitOwnBundle {client owner} {
        set dev [$client omemo device_id]
        return [pollUntil { haveBundle $client $owner $dev }]
    }

    proc accessModel {client node} {
        variable NS_OWNER
        set reply [iqCall $client -type get -payload \
            [j pubsub -ns $NS_OWNER {
                j configure -node $node
            }]]
        foreach f [xsearch $reply pubsub configure x field] {
            if {[xsearch $f -get @var] eq "pubsub#access_model"} {
                return [xsearch $f value -get body]
            }
        }
        return ""
    }

    proc setAccessModel {client node model} {
        variable NS_OWNER
        set reply [iqCall $client -type get -payload \
            [j pubsub -ns $NS_OWNER {
                j configure -node $node
            }]]
        set form [::tacky::forms::apply \
            [::tacky::forms::parse [xsearch $reply pubsub configure x \
                -ns jabber:x:data -get node]] \
            [list pubsub#access_model $model]]
        set submit [::tacky::forms::serialize $form]
        set ack [iqCall $client -type set -payload \
            [j pubsub -ns $NS_OWNER {
                j configure -node $node {
                    j #as-is $submit
                }
            }]]
        return [xsearch $ack -get @type]
    }

    set common [concat {-constraints withServer} \
        [tacky_env -extra-setup { ::test::omemo_peer_int::setup }]]

    # Nothing but PEP connects these two, so a failed announce shows up as
    # encrypt() holding the message pending until the await times out.
    test omemo-int-peer-cold-discovery \
        {an unsubscribed peer discovers our devicelist and encrypts to us} \
        {*}$common -body {
            set pclient [tacky client $::test::omemo_peer_int::PEER]
            lassign [::test::omemo_peer_int::fetchDevices \
                $pclient $::test::omemo_peer_int::OWNER] type devices
            set ev [::test::omemo_peer_int::awaitEvent message <New> \
                -acc $::test::omemo_peer_int::OWNER \
                -jid $::test::omemo_peer_int::PEER {
                    tacky message send \
                        -acc $::test::omemo_peer_int::PEER \
                        -chat $::test::omemo_peer_int::OWNER \
                        -body "sight unseen"
                }]
            set msg [dict get $ev -message]
            list peer_read $type \
                announced [expr {[llength $devices] > 0}] \
                body [string trimright [::test::helpers::msgText $msg]] \
                encryption [dict get $msg encryption]
        } -result {peer_read result announced 1 body {sight unseen} encryption omemo}

    test omemo-int-peer-publish-recovers-locked-node \
        {a devicelist node locked to whitelist is republished and reopened} \
        {*}$common -body {
            set oclient [tacky client $::test::omemo_peer_int::OWNER]
            set pclient [tacky client $::test::omemo_peer_int::PEER]
            set node $::test::omemo_peer_int::DEVICELIST
            set dev [$oclient omemo device_id]

            set started [::test::omemo_peer_int::accessModel $oclient $node]
            ::test::omemo_peer_int::setAccessModel $oclient $node whitelist
            set locked [::test::omemo_peer_int::accessModel $oclient $node]
            lassign [::test::omemo_peer_int::fetchDevices \
                $pclient $::test::omemo_peer_int::OWNER] lockedType _

            # The publish-options precondition now fails, so this second id
            # only lands if the recovery path runs.
            $oclient omemo DoPublishDevicelist [list $dev 424242]
            set reopened [::test::omemo_peer_int::pollUntil {
                expr {[::test::omemo_peer_int::accessModel $oclient $node]
                      eq "open"}
            }]
            lassign [::test::omemo_peer_int::fetchDevices \
                $pclient $::test::omemo_peer_int::OWNER] afterType afterDevs

            list started $started locked $locked \
                peer_blocked_while_locked $lockedType \
                reopened [expr {$reopened eq "1"}] \
                peer_reads_again $afterType \
                announced [expr {424242 in $afterDevs}]
        } -result {started open locked whitelist peer_blocked_while_locked error reopened 1 peer_reads_again result announced 1}
}
