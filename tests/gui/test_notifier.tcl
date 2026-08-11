# notifier - the corner toast that presents notify <Notify>.
#
# Events are emitted from the backend client directly: what is under test is the
# presentation, not the policy that decides an alert is due (test_notify covers
# that).

set nf_acc user@test.example.com

# The controller a toast hands the user off to when clicked.
proc nf_ctl {args} { lappend ::nf_opened $args }

proc nf_new {} {
    catch {nf destroy}
    set ::nf_opened {}
    notifier nf -controller nf_ctl
}

proc nf_cleanup {} {
    catch {nf destroy}
    unset -nocomplain ::nf_opened
    mock_backend_down
}

set nf_common {
    -setup   { mock_backend_up; nf_new }
    -cleanup { nf_cleanup }
}

proc nf_key {jid} { return [list $::nf_acc $jid] }

proc nf_notify {jid body args} {
    array set opts {-unread 1 -mention 0 -nick Alice -timestamp 0}
    array set opts $args
    if {$opts(-timestamp) == 0} { set opts(-timestamp) [clock microseconds] }
    $::_client emit notify <Notify> -jid $jid -timestamp $opts(-timestamp) \
        -nick $opts(-nick) -body $body -unread $opts(-unread) \
        -mention $opts(-mention)
    wait
    return $opts(-timestamp)
}

proc nf_text {jid part} {
    return [[nf windowOf [nf_key $jid]].c.$part cget -text]
}

proc nf_y {jid} {
    regexp {\+(-?\d+)$} [wm geometry [nf windowOf [nf_key $jid]]] -> y
    return $y
}

test notifier-coalesces-per-chat {a second message rewrites the chat's toast} \
    {*}$nf_common -body {
        nf_notify alice@example.com "one"
        nf_notify alice@example.com "two" -unread 2
        list [llength [nf keys]] [nf_text alice@example.com body] \
            [nf_text alice@example.com count]
    } -result {1 two (2)}

test notifier-separate-chats-stack {each chat gets its own toast} \
    {*}$nf_common -body {
        nf_notify alice@example.com "one"
        nf_notify bob@example.com "two"
        llength [nf keys]
    } -result {2}

test notifier-own-read-retracts {reading the chat takes its toast down} \
    {*}$nf_common -body {
        set ts [nf_notify alice@example.com "one"]
        $::_client emit message <OwnRead> -jid alice@example.com -timestamp $ts
        wait
        nf keys
    } -result {}

test notifier-stale-own-read-leaves-it {a watermark behind the message leaves the toast up} \
    {*}$nf_common -body {
        nf_notify alice@example.com "one" -timestamp 5000
        $::_client emit message <OwnRead> -jid alice@example.com -timestamp 4999
        wait
        llength [nf keys]
    } -result {1}

test notifier-dismiss-closes-the-gap {dismissing mid-stack moves the rest down a slot} \
    {*}$nf_common -body {
        foreach jid {a@example.com b@example.com c@example.com} {
            nf_notify $jid "same length body"
        }
        set was [nf_y b@example.com]
        nf Dismiss [nf_key b@example.com]
        wait
        expr {[nf_y c@example.com] == $was}
    } -result {1}

test notifier-click-opens-the-chat {clicking hands the chat to the controller and dismisses} \
    {*}$nf_common -body {
        nf_notify alice@example.com "one"
        nf Activate [nf_key alice@example.com]
        wait
        list $::nf_opened [nf keys]
    } -result {{{OpenChatFor user@test.example.com alice@example.com}} {}}

test notifier-room-jid-loses-the-join-tell {a room toast is labelled with the plain room jid} \
    {*}$nf_common -body {
        nf_notify room@conf.example.com?join "hello" -nick bob -mention 1
        nf_text room@conf.example.com?join sub
    } -result {room@conf.example.com}

test notifier-preview-is-one-line {a multi-line body is flattened for the toast} \
    {*}$nf_common -body {
        nf_notify alice@example.com "first line\n\nsecond    line"
        nf_text alice@example.com body
    } -result {first line second line}

test notifier-teardown-leaves-no-windows {destroying the notifier takes its toasts with it} \
    {*}$nf_common -body {
        nf_notify alice@example.com "one"
        nf_notify bob@example.com "two"
        nf destroy
        lsearch -glob [winfo children .] .toast_*
    } -result {-1}
