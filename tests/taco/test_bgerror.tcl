package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# taco_bg::report is what the daemon and the backend thread install as bgerror.
# Drive it directly: provoking a real background error would need a real bug.

proc _bgLogCapture {record} {
    lappend ::_bgLog $record
}

# Reporting from inside the log sink is the reentrant case.
proc _bgLogReenter {record} {
    lappend ::_bgLog $record
    set ::errorInfo reenter-trace
    ::taco_bg::report reenter
}

set bgenv [tacky_env -capture-emit 1 -extra-setup {
    set ::_bgLog {}
    set ::_bgSavedLogproc [jlog cget -logproc]
    jlog configure -logproc _bgLogCapture
    set ::taco_bg::lastEmit {}
    set ::taco_bg::reporting 0
} -extra-cleanup {
    jlog configure -logproc $::_bgSavedLogproc
    set ::taco_bg::lastEmit {}
    unset -nocomplain ::_bgLog ::_bgSavedLogproc
}]

test bgerror-logs-and-emits {a background error is logged and handed to the frontend} \
    {*}$bgenv -body {
        set ::errorInfo "boom\n    while executing"
        ::taco_bg::report boom
        set emit [lindex $::_emitted 0]
        set eargs [lrange $emit 2 end]
        list [llength $::_bgLog] [llength $::_emitted] \
            [lrange $emit 0 1] [dict get $eargs -message] \
            [string match "boom*while executing" [dict get $eargs -errorinfo]]
    } -result {1 1 {error <Background>} boom 1}

test bgerror-suppresses-a-repeat {a repeat is logged but not emitted twice} \
    {*}$bgenv -body {
        set ::errorInfo boom
        ::taco_bg::report boom
        ::taco_bg::report boom
        ::taco_bg::report other
        list [llength $::_bgLog] [llength $::_emitted]
    } -result {3 2}

test bgerror-frontend-side-logs-and-dispatches \
    {the transport's own reporter logs over the wire and dispatches locally} \
    {*}$bgenv -body {
        set ::_bgSeen {}
        tacky listen error <Background> {apply {{eargs} {lappend ::_bgSeen $eargs}}}
        set ::errorInfo boom-trace
        tacky bgerror boom
        list [llength $::_bgLog] [llength $::_bgSeen] \
            [dict get [lindex $::_bgSeen 0] -message] \
            [dict get [lindex $::_bgSeen 0] -errorinfo]
    } -result {1 1 boom boom-trace}

test bgerror-does-not-recurse {a report raised while reporting is not re-entered} \
    {*}$bgenv -body {
        jlog configure -logproc _bgLogReenter
        set ::errorInfo boom
        ::taco_bg::report boom
        list [llength $::_bgLog] [llength $::_emitted]
    } -result {1 1}

# -- redaction -------------------------------------------------------------
#
# errorInfo prints the failing commands with their arguments, so a trace
# quotes a password, a token, a message's text or an aesgcm:// URL's key
# whenever one was handed to a call beneath the error. Each is blanked
# before it is logged, put on <Background>, or written to stderr.

test bgerror-redacts-secrets {-secret/-password values and JSON secret fields are blanked in the log and on the wire} \
    {*}$bgenv -body {
        set ::errorInfo "couldn't execute \"/nonexistent/helper\": no such file or directory
    while executing
\"open |\[list {*}\$options(-command) 2>@stderr\] r+\"
    invoked from within
\"::taco_directory create dir -domain example.org -secret {correct horse battery} -onerror {apply {{e} {puts \"directory failed: \$e\"}}}\"
    invoked from within
\"::taco account add -acc a@b -password hunter2 -command x\"
    (\"after\" script)
\[\"storage\",\"unlock\",{\"acc\":\"a@b\",\"secret\":\"hunter2\"},3\]"
        ::taco_bg::report {storage unlock -secret hunter2 failed}
        set info [dict get [lrange [lindex $::_emitted 0] 2 end] -errorinfo]
        set msg [dict get [lrange [lindex $::_emitted 0] 2 end] -message]
        set logged [join $::_bgLog \n]
        list [string match "*correct horse*" $info] [string match "*hunter2*" $info] \
            [string match "*hunter2*" $msg] [string match "*hunter2*" $logged] \
            [string match "*correct horse*" $logged] \
            [string match "*-secret <redacted> -onerror*" $info] \
            [string match "*-password <redacted> -command*" $info] \
            [string match {*"secret":"<redacted>"*} $info] \
            [string match "*/nonexistent/helper*" $info]
    } -result {0 0 0 0 0 1 1 1 1}

test bgerror-redacts-tokens-and-keys {-token, -fast_token, -preauth, -key and -deviceKey and their JSON keys are blanked} \
    {*}$bgenv -body {
        set ::errorInfo "boom
    invoked from within
\"::taco account add -acc a@b -token tok-SECRET1 -fast_token SECRET2 -preauth SECRET8 -command x\"
    invoked from within
\"::taco storage unlock -key SECRET3 -deviceKey SECRET4\"
    invoked from within
\"::tacky::wire::dispatch {\[\"storage\",\"unlock\",{\"key\":\"SECRET5\",\"deviceKey\":\"SECRET6\",\"token\":\"SECRET7\"},3\]}\""
        ::taco_bg::report boom
        set info [dict get [lrange [lindex $::_emitted 0] 2 end] -errorinfo]
        list [regexp {SECRET} $info] [regexp {SECRET} [join $::_bgLog \n]] \
            [string match "*-token <redacted> -fast_token <redacted> -preauth <redacted> -command x*" $info] \
            [string match {*"key":"<redacted>","deviceKey":"<redacted>","token":"<redacted>"*} $info]
    } -result {0 0 1 1}

test bgerror-redacts-message-text {-body and -desc values, their JSON keys and an aesgcm key are blanked} \
    {*}$bgenv -body {
        set ::errorInfo "boom
    invoked from within
\"::taco message send -acc a@b -chat r@m -body {wherefore {art} thou SECRET1} -command x\"
    (\"after\" script)
    invoked from within
\"::taco message edit -acc a@b -chat r@m -body SECRET2\"
    invoked from within
\"::tacky::wire::dispatch {\[\"message\",\"send_file\",{\"acc\":\"a@b\",\"desc\":\"SECRET3 \\\"q\\\"\",\"url\":\"aesgcm://h/x#[string repeat ab 44]\"},3\]}\"
    invoked from within
\"::tacky::wire::dispatch {\[\"message\",\"send\",{\"acc\":\"a@b\",\"chat\":\"r@m\",\"body\":\"SECRET4\"},4\]}\""
        ::taco_bg::report boom
        set info [dict get [lrange [lindex $::_emitted 0] 2 end] -errorinfo]
        list [regexp {SECRET|wherefore|abab} $info] [regexp {SECRET|wherefore|abab} [join $::_bgLog \n]] \
            [string match "*-body <redacted> -command x*" $info] \
            [string match {*"desc":"<redacted>","url":"aesgcm://h/x#<redacted>"*} $info] \
            [string match {*"body":"<redacted>"*} $info]
    } -result {0 0 1 1 1}

# Where the call names a value, and everywhere else it turns up: the error's
# own message quoting it, a frame further down that got it as a plain
# argument. A value under four characters is left where it is not named,
# and a `$var` in a frame's source text is not a value.
test bgerror-redacts-a-sensitive-value-wherever-it-is-quoted {the values of -body, -password and an aesgcm key are blanked in the message and every frame, short values and source text kept} \
    {*}$bgenv -body {
        set frag [string repeat ab 44]
        set ::errorInfo "expected integer but got \"wherefore art thou\"
    while executing
\"incr n \$body\"
    (procedure \"Count\" line 2)
    invoked from within
\"Count {wherefore art thou} hunter2-pw $frag\"
    invoked from within
\"::taco message send -acc a@b -chat r@m -body {wherefore art thou} -command x\"
    (\"after\" script)
    invoked from within
\"::tacky::wire::dispatch {\[\"account\",\"add\",{\"acc\":\"a@b\",\"password\":\"hunter2-pw\",\"url\":\"aesgcm://h/x#$frag\",\"desc\":\"ok\"},3\]}\"
    invoked from within
\"j body -body \$text -tag ok\""
        ::taco_bg::report "expected integer but got \"wherefore art thou\" (got \"ok\")"
        set eargs [lrange [lindex $::_emitted 0] 2 end]
        set all [list [dict get $eargs -message] [dict get $eargs -errorinfo] $::_bgLog]
        list [regexp {wherefore|hunter2|abab} $all] \
            [string match {expected integer but got "\[redacted\]" (got "ok")} [dict get $eargs -message]] \
            [string match {*Count {\[redacted\]} \[redacted\] \[redacted\]*} [dict get $eargs -errorinfo]] \
            [string match {*incr n $body*} [dict get $eargs -errorinfo]]
    } -result {0 1 1 1}

# errorInfo quotes a value as `list` would: in braces when they balance, to
# any depth, and with backslashes when they do not. Each is blanked whole.
test bgerror-redacts-a-body-with-nested-braces {a -body value holding two levels of braces is blanked whole, where it is named and where the message quotes it} \
    {*}$bgenv -body {
        set text "fn() { if (x) { y } } SECRETTEXT"
        set ::errorInfo "expected integer but got \"$text\"
    invoked from within
\"::taco message send -acc a@b -chat r@m -body [list $text] -command x\""
        ::taco_bg::report "expected integer but got \"$text\""
        set eargs [lrange [lindex $::_emitted 0] 2 end]
        set info [dict get $eargs -errorinfo]
        list [regexp {SECRETTEXT|if \(x\)} [list [dict get $eargs -message] $info $::_bgLog]] \
            [string match "*-body <redacted> -command x*" $info] \
            [dict get $eargs -message]
    } -result {0 1 {expected integer but got "[redacted]"}}

test bgerror-redacts-a-body-with-an-unbalanced-brace {a -body value that list writes with backslashes is blanked whole, where it is named and where the message quotes it} \
    {*}$bgenv -body {
        set text "smiley :\} face SECRETTEXT"
        set ::errorInfo "expected integer but got \"$text\"
    invoked from within
\"::taco message send -acc a@b -chat r@m -body [list $text] -command x\""
        ::taco_bg::report "expected integer but got \"$text\""
        set eargs [lrange [lindex $::_emitted 0] 2 end]
        set info [dict get $eargs -errorinfo]
        list [regexp {SECRETTEXT|smiley} [list [dict get $eargs -message] $info $::_bgLog]] \
            [string match "*-body <redacted> -command x*" $info] \
            [dict get $eargs -message]
    } -result {0 1 {expected integer but got "[redacted]"}}

test bgerror-redacts-a-json-value-as-it-reads {a body a JSON frame carries with \u escapes is blanked where the message quotes it decoded} \
    {*}$bgenv -body {
        set ::errorInfo "expected integer but got \"café SECRETTEXT\"
    invoked from within
\"::tacky::wire::dispatch {\[\"message\",\"send\",{\"acc\":\"a@b\",\"chat\":\"r@m\",\"body\":\"caf\\u00e9 SECRETTEXT\"},4\]}\""
        ::taco_bg::report "expected integer but got \"café SECRETTEXT\""
        set eargs [lrange [lindex $::_emitted 0] 2 end]
        set info [dict get $eargs -errorinfo]
        list [regexp {SECRETTEXT|caf} [list [dict get $eargs -message] $info $::_bgLog]] \
            [string match {*"body":"<redacted>"*} $info] \
            [dict get $eargs -message]
    } -result {0 1 {expected integer but got "[redacted]"}}

test bgerror-redacts-aesgcm-in-any-spelling {an aesgcm key is blanked in any case of the scheme, JSON-escaped and percent-encoded} \
    {*}$bgenv -body {
        set frag [string repeat cd 44]
        set ::errorInfo "boom
    invoked from within
\"Fetch AESGCM://h/x#$frag {\"u\":\"aesgcm:\\/\\/h\\/x#$frag\"} https://l/?u=aesgcm%3a%2f%2fh%2Fx%23$frag&z=1\""
        ::taco_bg::report boom
        set info [dict get [lrange [lindex $::_emitted 0] 2 end] -errorinfo]
        list [regexp {cdcd} [list $info $::_bgLog]] \
            [string match {*AESGCM://h/x#<redacted>*aesgcm:\\/\\/h\\/x#<redacted>*%23<redacted>&z=1*} $info]
    } -result {0 1}

# The front end's own reporter logs its trace over the wire to the backend's
# log and dispatches it to its listeners: blanked first, the same way.
test bgerror-frontend-side-trace-is-redacted {the transport's own reporter blanks secrets, message text and keys in what it logs and dispatches} \
    {*}$bgenv -body {
        set ::_bgSeen {}
        tacky listen error <Background> {apply {{eargs} {lappend ::_bgSeen $eargs}}}
        set ::errorInfo "boom\n    invoked from within\n\"tacky message send -chat r@m -body {SECRET1 here} -command x\"\n    invoked from within\n\"tacky account add -acc a@b -password SECRET2 -url aesgcm://h/x#[string repeat ab 44]\""
        tacky bgerror "boom -password SECRET3"
        set seen [lindex $::_bgSeen 0]
        list [regexp {SECRET|abab} $::_bgLog] [regexp {SECRET|abab} $seen] \
            [string match "*-body <redacted> -command x*-password <redacted> -url aesgcm://h/x#<redacted>*" \
                [dict get $seen -errorinfo]]
    } -result {0 0 1}

# The re-entered report has no log to go to and writes its trace to stderr,
# which a daemon's host may well keep. In a child, to read its stderr.
test bgerror-reentered-trace-is-redacted-on-stderr {a report raised while reporting writes its trace to stderr without the secrets, the text or the key} \
    -constraints hasProcess -setup {
        set child [makeFile {
            lappend auto_path [file join [pwd] lib]
            package require taco
            set ::taco_bg::reporting 1
            set ::errorInfo "boom\n    invoked from within\n\"::taco message send -chat r@m -body SECRET1 -password SECRET2 -url aesgcm://h/x#[string repeat ab 44]\""
            ::taco_bg::report boom
        } bg-reenter.tcl]
        set errfile [file join [temporaryDirectory] bg-reenter.err]
    } -body {
        exec [info nameofexecutable] $child 2> $errfile
        set err [viewFile bg-reenter.err]
        list [regexp {SECRET|abab} $err] [string match "*-body <redacted>*aesgcm://h/x#<redacted>*" $err]
    } -cleanup {
        removeFile bg-reenter.tcl
        file delete -force $errfile
    } -result {0 1}

# With the wire gone the front end's trace goes to stderr: blanked there too,
# in an interpreter that loads libtacky alone, as the threaded GUI's does.
test bgerror-frontend-stderr-fallback-is-redacted {a front-end trace that cannot be logged reaches stderr without the secrets, the text or the key} \
    -constraints hasProcess -setup {
        set child [makeFile {
            lappend auto_path [file join [pwd] lib]
            package require libtacky
            oo::class create _bgProbe {
                superclass tacky_base
                method _send {args} { error "the wire is gone" }
                method unknown {args} { error "the wire is gone" }
            }
            _bgProbe create p
            set ::errorInfo "boom\n    invoked from within\n\"tacky message send -chat r@m -body SECRET1 -password SECRET2 -url aesgcm://h/x#[string repeat ab 44]\""
            p bgerror boom
            puts taco=[expr {[info commands ::taco_bg::report] ne ""}]
        } bg-frontend.tcl]
        set errfile [file join [temporaryDirectory] bg-frontend.err]
    } -body {
        set out [exec [info nameofexecutable] $child 2> $errfile]
        set err [viewFile bg-frontend.err]
        list $out [regexp {SECRET|abab} $err] \
            [string match "*-body <redacted> -password <redacted> -url aesgcm://h/x#<redacted>*" $err]
    } -cleanup {
        removeFile bg-frontend.tcl
        file delete -force $errfile
    } -result {taco=0 0 1}
