# Unit tests for roster subscription management (RFC 6121 §3)
package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

set roster_common [tacky_env -mock conn \
    -account user@example.com \
    -bound-jid user@example.com/res1 \
    -extra-setup {$::_client.conn clear}]

# -- Outgoing: subscribe ------------------------------------------------------

test roster-subscribe-sends-stanza {subscribe sends correct presence stanza} \
    {*}$roster_common \
    -body {
        tacky roster subscribe -acc user@example.com -jid alice@example.com
        set sent [lindex [$_client.conn get_written] 0]
        list [xsearch $sent -get @type] [xsearch $sent -get @to]
    } -result {subscribe alice@example.com}

# -- Outgoing: approve --------------------------------------------------------

test roster-approve-sends-stanza {approve sends correct presence stanza} \
    {*}$roster_common \
    -body {
        tacky roster approve -acc user@example.com -jid alice@example.com
        set sent [lindex [$_client.conn get_written] 0]
        list [xsearch $sent -get @type] [xsearch $sent -get @to]
    } -result {subscribed alice@example.com}

# -- Outgoing: unsubscribe ----------------------------------------------------

test roster-unsubscribe-sends-stanza {unsubscribe sends correct presence stanza} \
    {*}$roster_common \
    -body {
        tacky roster unsubscribe -acc user@example.com -jid alice@example.com
        set sent [lindex [$_client.conn get_written] 0]
        list [xsearch $sent -get @type] [xsearch $sent -get @to]
    } -result {unsubscribe alice@example.com}

# -- Outgoing: deny -----------------------------------------------------------

test roster-deny-sends-stanza {deny sends correct presence stanza} \
    {*}$roster_common \
    -body {
        tacky roster deny -acc user@example.com -jid alice@example.com
        set sent [lindex [$_client.conn get_written] 0]
        list [xsearch $sent -get @type] [xsearch $sent -get @to]
    } -result {unsubscribed alice@example.com}

# -- Outgoing: add (convenience) ----------------------------------------------

test roster-add-sends-item-and-subscribe {add sends roster item IQ + subscribe presence} \
    {*}$roster_common \
    -body {
        tacky roster add -acc user@example.com -jid alice@example.com -name Alice
        set written [$_client.conn get_written]
        # First stanza: IQ set with roster item
        set iq [lindex $written 0]
        set iqType [xsearch $iq -get @type]
        set itemJid [xsearch $iq query item -get @jid]
        # Second stanza: presence subscribe
        set pres [lindex $written 1]
        set presType [xsearch $pres -get @type]
        set presTo [xsearch $pres -get @to]
        list $iqType $itemJid $presType $presTo
    } -result {set alice@example.com subscribe alice@example.com}

# -- Incoming: subscribe emits event ------------------------------------------

test roster-incoming-subscribe-emits {incoming subscribe emits roster <Subscribe>} \
    {*}$roster_common \
    -body {
        set _got {}
        tacky listen roster <Subscribe> -type subscribe {apply {{ev} {
            set ::_got $ev
        }}}
        $_client.conn feed [j presence -type subscribe -from bob@example.com/res]
        list [dict get $_got -jid] [dict get $_got -type]
    } -result {bob@example.com subscribe}

# -- Incoming: subscribed emits event -----------------------------------------

test roster-incoming-subscribed-emits {incoming subscribed emits roster <Subscribe>} \
    {*}$roster_common \
    -body {
        set _got {}
        tacky listen roster <Subscribe> -type subscribed {apply {{ev} {
            set ::_got $ev
        }}}
        $_client.conn feed [j presence -type subscribed -from bob@example.com/res]
        list [dict get $_got -jid] [dict get $_got -type]
    } -result {bob@example.com subscribed}

# -- Incoming: unsubscribe emits event ----------------------------------------

test roster-incoming-unsubscribe-emits {incoming unsubscribe emits roster <Subscribe>} \
    {*}$roster_common \
    -body {
        set _got {}
        tacky listen roster <Subscribe> -type unsubscribe {apply {{ev} {
            set ::_got $ev
        }}}
        $_client.conn feed [j presence -type unsubscribe -from bob@example.com/res]
        list [dict get $_got -jid] [dict get $_got -type]
    } -result {bob@example.com unsubscribe}

# -- Incoming: unsubscribed emits event ---------------------------------------

test roster-incoming-unsubscribed-emits {incoming unsubscribed emits roster <Subscribe>} \
    {*}$roster_common \
    -body {
        set _got {}
        tacky listen roster <Subscribe> -type unsubscribed {apply {{ev} {
            set ::_got $ev
        }}}
        $_client.conn feed [j presence -type unsubscribed -from bob@example.com/res]
        list [dict get $_got -jid] [dict get $_got -type]
    } -result {bob@example.com unsubscribed}

# -- Incoming: subscription presence does not reach presencemod ----------------

test roster-subscription-not-tracked-as-availability {subscription presence is not tracked as availability} \
    {*}$roster_common \
    -body {
        $_client.conn feed [j presence -type subscribe -from bob@example.com/res]
        tacky presence isOnline -acc user@example.com -jid bob@example.com
    } -result {0}
