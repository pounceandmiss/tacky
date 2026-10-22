package provide taco::redact 0.1

# The redactions every log and trace goes through, on both sides of the
# wire: taco's (jlog, taco_bg) and the front end's own (libtacky's
# bgerror), which may run in an interpreter that never loads taco, so this
# is a package of its own. Plain text in, text out; nothing here knows a
# stanza.
namespace eval ::taco_redact {
    # errorInfo prints the failing commands with their arguments; a method
    # handed a password, a PIN or a secret carries it as -secret/-password,
    # and `storage unlock` the key and device key, so all of them are
    # blanked before a trace is logged or put on the front-end wire -- as
    # options, and as the JSON keys of a frame the embedded backend's
    # Tcl_EvalObjv puts into errorInfo whole. Tokens go the same way under
    # every name a client gives them (a FAST token, an XEP-0445 -preauth
    # invitation, OAuth's access and refresh tokens, a PKCE verifier, an
    # authorization -code, though not Tcl's own `return -code error`), so
    # a caller that grows one is covered. A message's text (`message send`
    # and `edit`'s -body, `send_file`'s -desc) too: it is the user's, and
    # under OMEMO plaintext the server never sees. A value is read as the
    # word of a Tcl list it is (`word`), whatever braces or backslashes it
    # holds.
    variable secretKeys {secret|password|passphrase|pin|token|preauth|fast_token|oauth_token|oauth_refresh_token|access_token|refresh_token|client_secret|oauth_client_secret|code_verifier|code(?!\s+(?:ok|error|return|break|continue)\M)|key|deviceKey|body|desc}
}

# The one redaction of an aesgcm:// URL (XEP-0454 §4), for
# every log line, trace and debug view: the fragment is the file's iv and
# key, and is never written anywhere but the message and the row it came
# in. It becomes `#<redacted>`; the rest of the URL, and any other URL, is
# shown as it is. The fragment ends where a URL in a line, a Tcl list, a
# JSON string or an XML text or attribute would: at a space, a quote, a
# brace, a backslash or an angle bracket. A fragment already redacted is
# left alone. The scheme is matched in any case, and the URL in two other
# spellings it travels in: a JSON string's, whose slashes may be escaped
# (`aesgcm:\/\/h\/x#key`), and a percent-encoded one (`aesgcm%3A%2F%2F...`,
# a query parameter or a link handed on, in either case of the hex), whose
# fragment begins at `%23` (or a literal `#`) and ends at a `&` as well.
proc ::taco_redact::url {text} {
    set text [regsub -all -nocase {(aesgcm:(?://|\\/\\/)(?:[^\s#"'<>{}\\]|\\/)*)#[^\s"'<>{}\\]+} \
        $text {\1#<redacted>}]
    regsub -all -nocase {(aesgcm%3A%2F%2F(?:[^\s#%"'<>{}\\&]|%(?!23)[0-9a-f]{2})*)(%23|#)[^\s"'<>{}\\&]+} \
        $text {\1\2<redacted>}
}

# A trace (errorInfo, or an error's message): the secret options and JSON
# keys above blanked, and every aesgcm:// URL's key -- and then each such
# value wherever else it turns up, as `[redacted]`: an error's message
# quoting the text it choked on, a frame further down that got it as a
# plain argument. The values are read off the trace itself and off
# `context`, any other text that may name them (the message beside the
# trace, the failing call's own arguments).
proc ::taco_redact::trace {text args} {
    variable secretKeys
    set vals [values [join [list $text {*}$args] \n]]
    set json [string map [list @K $secretKeys] {("(?:@K)"\s*:\s*)"(?:[^"\\]|\\.)*"}]
    set text [options $text $secretKeys {<redacted>}]
    set text [regsub -all -nocase -- $json $text {\1"<redacted>"}]
    set text [url $text]
    if {[llength $vals]} {
        set text [string map [concat {*}[lmap v $vals {list $v {[redacted]}}]] $text]
    }
    return $text
}

# One word of a Tcl list -- how errorInfo prints a command and its
# arguments -- starting at index `at` of `text`: braced (braces nest, a
# backslash quotes the character after it), double-quoted, or bare, with
# backslashes quoting the characters after them (`smiley\ :\}\ face`, how
# `list` writes a value whose braces do not balance). Returns {end value}:
# the index just past the word, and its text with the quoting undone. A
# regular expression would stop at the first inner brace of a nested body,
# or the first space of a backslash-quoted one, and leave the rest.
proc ::taco_redact::word {text at} {
    set n [string length $text]
    set c [string index $text $at]
    if {$c eq "\{"} {
        set depth 0
        for {set i $at} {$i < $n} {incr i} {
            switch -exact -- [string index $text $i] {
                "\\" { incr i }
                "\{" { incr depth }
                "\}" {
                    if {[incr depth -1] == 0} {
                        return [list [expr {$i + 1}] [string range $text [expr {$at + 1}] [expr {$i - 1}]]]
                    }
                }
            }
        }
        return [list $n [string range $text [expr {$at + 1}] end]]
    }
    if {$c eq "\""} {
        for {set i [expr {$at + 1}]} {$i < $n} {incr i} {
            switch -exact -- [string index $text $i] {
                "\\" { incr i }
                "\"" {
                    return [list [expr {$i + 1}] [string range $text [expr {$at + 1}] [expr {$i - 1}]]]
                }
            }
        }
        return [list $n [string range $text [expr {$at + 1}] end]]
    }
    for {set i $at} {$i < $n} {incr i} {
        set ch [string index $text $i]
        if {$ch eq "\\"} { incr i; continue }
        if {[string is space $ch]} break
    }
    set raw [string range $text $at [expr {$i - 1}]]
    if {[string first "\\" $raw] >= 0} {
        catch {set raw [subst -nocommands -novariables $raw]}
    }
    return [list $i $raw]
}

# Every `-key value` in `text` whose key is one of `keys` (a regular
# expression alternation), the value read as the list word it is, replaced
# by `with`; a key inside a value already replaced is not looked at again.
proc ::taco_redact::options {text keys with} {
    set pat [string map [list @K $keys] {-(?:@K)\s+}]
    set out ""
    set at 0
    foreach span [regexp -all -inline -indices -nocase -- $pat $text] {
        lassign $span s e
        if {$s < $at} continue
        incr e
        lassign [word $text $e] end -
        append out [string range $text $at [expr {$e - 1}]] $with
        set at $end
    }
    append out [string range $text $at end]
    return $out
}

# The values a trace names that are blanked wherever they recur: those of
# the options and JSON keys in valueKeys (a message's text and caption, the
# passwords, passphrases, secrets and tokens), and the fragment of every
# aesgcm:// URL. Not -key or -pin: `setting set -key` names a setting, and
# a PIN is too short to look for. A value shorter than MIN_VALUE characters
# is not looked for elsewhere (a "1" or an "ok" would shred the trace; the
# option form above still blanks it where it is named), nor is one that is
# a frame's source text (`$var`, `[cmd]`) or already redacted. Longest
# first, so a value inside another is not cut out of it first.
namespace eval ::taco_redact {
    variable valueKeys {secret|password|passphrase|token|fast_token|oauth_token|oauth_refresh_token|access_token|refresh_token|client_secret|oauth_client_secret|code_verifier|code(?!\s+(?:ok|error|return|break|continue)\M)|deviceKey|body|desc}
    variable MIN_VALUE 4
}
proc ::taco_redact::values {text} {
    variable valueKeys
    variable MIN_VALUE
    set found {}
    set pat [string map [list @K $valueKeys] {-(?:@K)\s+}]
    foreach span [regexp -all -inline -indices -nocase -- $pat $text] {
        lassign $span - e
        lassign [word $text [incr e]] - v
        lappend found $v
    }
    # A JSON string's value as written, and as it reads: `\"`, `\\`, `\/`,
    # `\n`, `\t` and a `\uXXXX` (any non-ASCII character on the wire) undone,
    # so a value an error quotes in the clear is found as well.
    set json [string map [list @K $valueKeys] {"(?:@K)"\s*:\s*"((?:[^"\\]|\\.)*)"}]
    foreach {- v} [regexp -all -inline -nocase -- $json $text] {
        lappend found $v
        if {![catch {subst -nocommands -novariables $v} plain]} { lappend found $plain }
    }
    foreach {- v} [regexp -all -inline -nocase \
            {aesgcm(?::(?://|\\/\\/)|%3A%2F%2F)[^\s#"'<>{}\\]*?(?:#|%23)([^\s"'<>{}\\&]+)} $text] {
        lappend found $v
    }
    set out {}
    foreach v [lsort -unique $found] {
        if {[string length $v] < $MIN_VALUE || [string match {[$\[]*} $v]
                || [string match *<redacted>* $v] || [string match {*\[redacted\]*} $v]} continue
        lappend out $v
    }
    lsort -command [list apply {{a b} {expr {[string length $b] - [string length $a]}}}] $out
}
