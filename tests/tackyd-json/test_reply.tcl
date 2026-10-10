# Every request with a token gets exactly one reply.

package require tcltest
namespace import ::tcltest::*
package require json
package require taco
package require json::write
package require tackyd-json

# --- The macro's forms, on a type of their own --------------------------

snit::type taco_replyforms {
    tackymethod value {args} { return 5 }
    tackymethod fails {args} {
        return -code error -errorcode {REPLY TEST} "it failed"
    }
    tackymethod throws {args} { error "it threw" }
    tackymethod -noreturn quiet {args} { return internal }
    tackymethod -async later {args} {
        after 0 [list {*}[dict get $args -command] done]
        return ignored
    }
}

# Every answer $method gives, as {ok|err value ...}.
proc formReplies {method} {
    set ::formGot {}
    taco_replyforms_obj $method \
        -command {apply {{v} {lappend ::formGot ok $v}}} \
        -onerror {apply {{v} {lappend ::formGot err $v}}}
    set ::formTick 0
    after 20 {set ::formTick 1}
    vwait ::formTick
    return $::formGot
}

set formEnv {
    -setup {taco_replyforms create taco_replyforms_obj}
    -cleanup {taco_replyforms_obj destroy}
}

test reply-form-value {a tackymethod replies with its return value} \
    {*}$formEnv -body {
        formReplies value
    } -result {ok 5}

test reply-form-return-code-error {return -code error is an error, not a result} \
    {*}$formEnv -body {
        formReplies fails
    } -result {err {it failed}}

test reply-form-throw {a thrown error goes to -onerror} \
    {*}$formEnv -body {
        formReplies throws
    } -result {err {it threw}}

test reply-form-error-uncaught {without callbacks the error reaches the caller, errorcode and all} \
    {*}$formEnv -body {
        list [catch {taco_replyforms_obj fails} msg opts] $msg \
            [dict get $opts -errorcode]
    } -result {1 {it failed} {REPLY TEST}}

test reply-form-noreturn {-noreturn replies "", whatever the body returned} \
    {*}$formEnv -body {
        formReplies quiet
    } -result {ok {}}

test reply-form-noreturn-direct {-noreturn still returns its value to an in-process caller} \
    {*}$formEnv -body {
        taco_replyforms_obj quiet
    } -result internal

test reply-form-async {-async leaves the reply to the body} \
    {*}$formEnv -body {
        formReplies later
    } -result {ok done}

# --- Declarations match what the bodies do --------------------------------

# Every tackymethod in lib/taco/modules as {module name kind body}.
proc declaredMethods {} {
    set root [file normalize [file join [file dirname [info script]] .. ..]]
    set out {}
    foreach f [lsort [glob [file join $root lib taco modules *.tcl]]] {
        set fh [open $f]; set lines [split [read $fh] \n]; close $fh
        set type ""
        set cur ""
        foreach l $lines {
            if {[regexp {^ {0,4}\S} $l]} {
                if {$cur ne ""} { lappend out $cur; set cur "" }
                regexp {^snit::type\s+(\S+)} $l -> type
                if {[regexp {^    tackymethod\s+(?:(-async|-noreturn)\s+)?(\w+)\s+\S+\s*(.*)$} \
                        $l -> flag name rest]} {
                    set kind [expr {$flag eq "" ? "sync" : [string range $flag 1 end]}]
                    set cur [list [regsub {^taco_} $type {}] $name $kind "$rest\n"]
                }
                continue
            }
            if {$cur ne "" && ![regexp {^\s*#} $l]} {
                lset cur 3 "[lindex $cur 3]$l\n"
            }
        }
        if {$cur ne ""} { lappend out $cur }
    }
    return $out
}

# Whether a body reads -command/-onerror or forwards them.
proc answersItself {body} {
    if {[regexp {opts\(-(command|onerror)\)|dict (get|exists) \$(args|opts) -(command|onerror)} $body]} {
        return 1
    }
    foreach line [split $body \n] {
        if {[regexp {\$(self|client) } $line]
                && [regexp {\{\*\}(\$args|\[dict (set|remove) \$?args)} $line]
                && ![regexp {dict remove \$args[^\]]*-command} $line]} {
            return 1
        }
    }
    return 0
}

test reply-declared-async-matches-body {a method that answers -command itself is declared -async, and only then} \
    -body {
        set wrong {}
        foreach m [declaredMethods] {
            lassign $m module name kind body
            set itself [answersItself $body]
            if {$itself && $kind ne "async"} {
                lappend wrong "$module $name: $kind, but answers itself"
            }
            if {!$itself && $kind eq "async"} {
                lappend wrong "$module $name: async, but never answers"
            }
        }
        join $wrong \n
    } -result {}

# --- Through the JSON dispatcher -----------------------------------------

set ::rsAcc alice@example.com
set ::rsReplies {}

proc rsSink {json} {
    if {[regexp {^\["(result|error)",} $json]} {
        set parts [::json::json2dict $json]
        dict lappend ::rsReplies [lindex $parts 1] \
            [list [lindex $parts 0] [lindex $parts 2]]
    }
}

proc rsSetup {} {
    set ::rsDir [file join [temporaryDirectory] reply-[pid]]
    file delete -force $::rsDir
    file mkdir $::rsDir
    set ::rsReplies {}
    # Before taco: its constructor emits.
    tackyd_json_install_emit rsSink
    taco_type create ::taco -transient 1 \
        -config-dir $::rsDir -data-dir $::rsDir -cache-dir $::rsDir
    # Never enabled: everything here answers offline.
    taco account add -acc $::rsAcc -password secret
}

proc rsCleanup {} {
    catch {taco destroy}
    catch {rename ::tacky {}}
    catch {namespace delete ::tacky_ns}
    catch {file delete -force $::rsDir}
}

proc rsReplies {token} { dict getdef $::rsReplies $token {} }

proc rsPause {ms} {
    set ::rsTick 0
    after $ms {set ::rsTick 1}
    vwait ::rsTick
}

# Every reply to $token: waits up to $ms, then a little more so a second shows.
proc rsRequest {module method argdict token {ms 3000}} {
    set pairs {}
    dict for {k v} $argdict {
        lappend pairs $k [expr {[string is entier -strict $v]
            ? $v : [::json::write string $v]}]
    }
    tackyd_dispatch [::json::write array \
        [::json::write string $module] [::json::write string $method] \
        [::json::write object {*}$pairs] $token]
    set deadline [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $deadline && [rsReplies $token] eq ""} {
        rsPause 20
    }
    rsPause 50
    rsReplies $token
}

test reply-dispatch-trust-error {a refused trust change is an error reply} \
    -setup rsSetup -cleanup rsCleanup -body {
        set r [rsRequest omemo trust \
            [list acc $::rsAcc jid bob@example.com device 1 state trusted] 1]
        set r
    } -result {{error {no trust row for bob@example.com/1}}}

test reply-dispatch-noreturn {a fire-and-forget request is answered with ""} \
    -setup rsSetup -cleanup rsCleanup -body {
        rsRequest account set [list acc $::rsAcc resource desk] 1
    } -result {{result {}}}

test reply-dispatch-forwarding-answers-once {roster add hands its work to item and still answers once} \
    -setup rsSetup -cleanup rsCleanup -body {
        rsRequest roster add [list acc $::rsAcc jid bob@example.com name Bob] 1
    } -result {{result {}}}

test reply-dispatch-prepare-chat {omemo prepareChat answers with one value} \
    -setup rsSetup -cleanup rsCleanup -body {
        rsRequest omemo prepareChat \
            [list acc $::rsAcc jid room@conference.example.com?join] 1
    } -result {{result {}}}

test reply-dispatch-cancel {a cancelled request is answered "cancelled", once} \
    -setup rsSetup -cleanup rsCleanup -body {
        # Offline with nothing stored, history waits on the archive.
        set waiting [rsRequest message history \
            [list acc $::rsAcc chat bob@example.com tag t1] 1 100]
        set cancel [rsRequest message cancel [list acc $::rsAcc tag t1] 2]
        list $waiting $cancel [rsReplies 1]
    } -result {{} {{result {}}} {{error cancelled}}}

test reply-dispatch-avatar-cancel {a cancelled avatar publish answers "cancelled" when its iq ends} \
    -setup rsSetup -cleanup rsCleanup -body {
        set waiting [rsRequest avatar publish [list acc $::rsAcc tag t1 \
            type image/png width 1 height 1 \
            data [binary encode base64 png]] 1 100]
        rsRequest avatar cancel [list acc $::rsAcc tag t1] 2
        rsRequest account disable [list acc $::rsAcc] 3
        list $waiting [rsReplies 1]
    } -result {{} {{error cancelled}}}

test reply-dispatch-disable-fails-waiting {disabling an account answers what was waiting on it} \
    -setup rsSetup -cleanup rsCleanup -body {
        set waiting [rsRequest message history \
            [list acc $::rsAcc chat bob@example.com] 1 100]
        rsRequest account disable [list acc $::rsAcc] 2
        set r [rsReplies 1]
        list $waiting [llength $r] [lindex $r 0 0]
    } -result {{} 1 error}

test reply-dispatch-send {message send answers with the stored row's timestamp} \
    -setup rsSetup -cleanup rsCleanup -body {
        set r [rsRequest message send \
            [list acc $::rsAcc chat bob@example.com body hi] 1]
        set ts [lindex $r 0 1]
        set stored [[taco client $::rsAcc] db eval {
            SELECT timestamp FROM chat_message WHERE chat_jid='bob@example.com'
        }]
        list [llength $r] [lindex $r 0 0] [expr {$stored eq $ts}]
    } -result {1 result 1}

test reply-dispatch-debugtap-write {debugtap write takes XML text, and refuses an unknown tap} \
    -setup rsSetup -cleanup rsCleanup -body {
        set tap [lindex [rsRequest debugtap on [list acc $::rsAcc] 1] 0 1]
        list [rsRequest debugtap write [list tap $tap stanza <presence/>] 2] \
             [rsRequest debugtap write [list tap nosuch stanza <presence/>] 3]
    } -result {{{result {}}} {{error {no debug tap nosuch}}}}

test reply-dispatch-debugtap-on-needs-a-stream {debugtap on with neither -acc nor -token is refused and takes no tap id} \
    -setup rsSetup -cleanup rsCleanup -body {
        set refused [rsRequest debugtap on {} 1]
        set tap [lindex [rsRequest debugtap on [list acc $::rsAcc] 2] 0 1]
        list $refused $tap
    } -result {{{error {debugtap on needs -acc or -token}}} 1}

cleanupTests
