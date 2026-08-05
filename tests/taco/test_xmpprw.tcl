package require tcltest
namespace import ::tcltest::*
package require xmpprw

# Tag and attribute names are written raw, so jwrite has to refuse a name
# that would break out of the markup rather than emit it.

test xmpprw-xname-accepts-real-names {names xmpp actually uses pass} \
    -body {
        set ok {}
        foreach n {message body x-vcard a.b a-b _x stream:features xml:lang} {
            lappend ok [catch {xname $n}]
        }
        set ok
    } -result {0 0 0 0 0 0 0 0}

test xmpprw-xname-rejects-markup {a name carrying markup is refused} \
    -body {
        set rejected {}
        foreach n [list "q></query><message" "a b" "a'b" "a\"b" "a<b" "&x" \
                {} "1abc" "-x" ".x" "a/b" "a=b" "?pi" "!doctype" "a\nb"] {
            lappend rejected [catch {xname $n}]
        }
        set rejected
    } -result {1 1 1 1 1 1 1 1 1 1 1 1 1 1 1}

test xmpprw-jwrite-rejects-injected-tag {jwrite refuses a tag name with markup} \
    -body {
        set node [j iq -type set {
            j query -ns jabber:iq:register {
                j {q></query></iq><message to='v@x'><body>pwned</body></message><iq><x }
            }
        }]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

test xmpprw-jwrite-rejects-injected-attr {jwrite refuses an attribute name with markup} \
    -body {
        set node [dict create tag message ns jabber:client body {} tail {} \
            children {} attrs [dict create {a='b'/><evil} v]]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

# A namespaced attribute key is {ns localname}; the local half is what
# lands next to the generated prefix.
test xmpprw-jwrite-rejects-injected-prefixed-attr \
    {jwrite refuses a namespaced attribute whose local name carries markup} \
    -body {
        set node [dict create tag message ns jabber:client body {} tail {} \
            children {} attrs [dict create [list urn:x {a='b'/><evil}] v]]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

test xmpprw-jwrite-roundtrips-parsed-stanza {a parsed stanza still serialises} \
    -body {
        set node [xmppreader string {<message from='a@b/c' type='chat'><body>hi &amp; bye</body></message>}]
        jwrite $node
    } -result {<message from='a@b/c' type='chat'><body>hi &amp; bye</body></message>}

# One read takes the whole buffer, so a stanza behind a bad one is only
# delivered if the throw never reaches expat.

proc _xrwSetup {} {
    if {[info commands bgerror] ne ""} {
        rename bgerror _xrwSavedBgerror
    }
    proc bgerror {msg} {lappend ::_xrwBg $msg}
    set ::_xrwBg {}
    set ::_xrwGot {}
    set ::_xrwErr {}
    lassign [chan pipe] ::_xrwRd ::_xrwWr
    fconfigure $::_xrwWr -buffering none -translation lf -encoding utf-8
    fconfigure $::_xrwRd -translation lf -encoding utf-8
}

proc _xrwCleanup {} {
    ::jab::cancelRead $::_xrwRd
    catch {close $::_xrwWr}
    catch {close $::_xrwRd}
    _xrwDrain
    rename bgerror {}
    if {[info commands _xrwSavedBgerror] ne ""} {
        rename _xrwSavedBgerror bgerror
    }
}

proc _xrwDrain {} {
    for {set i 0} {$i < 20} {incr i} {update}
}

test xmpprw-handler-error-keeps-reader-alive \
    {a throwing stanza handler costs one stanza, not the stream} \
    -setup _xrwSetup -body {
        ::jab::readChannel $::_xrwRd -command {apply {n {
            set id [dict get [dict get $n attrs] id]
            lappend ::_xrwGot $id
            if {$id eq "boom"} {error "handler blew up"}
        }}}
        puts -nonewline $::_xrwWr \
            "[::jab::header]<iq id='a'/><iq id='boom'/><iq id='c'/>"
        _xrwDrain
        list $::_xrwGot [expr {[fileevent $::_xrwRd readable] ne ""}] \
            [llength $::_xrwBg] [lindex $::_xrwBg 0]
    } -cleanup _xrwCleanup \
    -result {{a boom c} 1 1 {handler blew up}}

# A stranded half-built stanza would swallow every later one as a child,
# so a malformed stream has to surface as a transport error.
test xmpprw-parse-error-reports-to-error-command \
    {a malformed stanza tears the stream down} \
    -setup _xrwSetup -body {
        ::jab::readChannel $::_xrwRd \
            -command {apply {n {lappend ::_xrwGot [dict get $n tag]}}} \
            -error-command {apply {msg {lappend ::_xrwErr $msg}}}
        puts -nonewline $::_xrwWr \
            "[::jab::header]<iq id='a'/><message><body>x</wrong>"
        _xrwDrain
        list $::_xrwGot [llength $::_xrwErr] \
            [string match "XML parse error:*" [lindex $::_xrwErr 0]]
    } -cleanup _xrwCleanup \
    -result {iq 1 1}

# Without the root on the stack, every following stanza sits at the
# wrong depth and is never dispatched.
test xmpprw-header-error-keeps-stream-root \
    {a throwing header handler still dispatches later stanzas} \
    -setup _xrwSetup -body {
        xmppreader ::_xrwR \
            -header-command {apply {n {error "hdr boom"}}} \
            -command {apply {n {lappend ::_xrwGot [dict get $n tag]}}}
        ::_xrwR feed "[::jab::header]<iq id='a'/>"
        _xrwDrain
        list $::_xrwGot [lindex $::_xrwBg 0]
    } -cleanup {::_xrwR destroy; _xrwCleanup} \
    -result {iq {hdr boom}}
