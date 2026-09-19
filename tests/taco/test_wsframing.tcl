package require tcltest
namespace import ::tcltest::*
package require taco
package require xmpprw

# -- outgoing ---------------------------------------------------------------

test wsframing-url {the conventional endpoint} -body {
    list [::wsframing::url example.com] [::wsframing::url example.com ws]
} -result {wss://example.com/xmpp-websocket ws://example.com/xmpp-websocket}

test wsframing-out-header {a stream header becomes <open/>} -body {
    ::wsframing::out [::jab::header "" to example.com]
} -result {<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='example.com' version='1.0' xml:lang='en'/>}

test wsframing-out-header-drops-xmlns {the stream's xmlns declarations do not travel} -body {
    set open [::wsframing::out [::jab::header "" to example.com]]
    list [string match {*xmlns:stream*} $open] [string match {*jabber:client*} $open]
} -result {0 0}

test wsframing-out-header-with-decl {an XML declaration is not part of a framed message} -body {
    ::wsframing::out "<?xml version='1.0'?>[::jab::header {} to example.com]"
} -result {<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='example.com' version='1.0' xml:lang='en'/>}

test wsframing-out-footer {a stream footer becomes <close/>} -body {
    ::wsframing::out "</stream:stream>"
} -result {<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>}

test wsframing-out-stanza-ns {a stanza carries the namespace it can no longer inherit} -body {
    ::wsframing::out [jwrite [j message -to bob@example.com -type chat {
        j body -body hello
    }]]
} -result {<message xmlns='jabber:client' to='bob@example.com' type='chat'><body>hello</body></message>}

test wsframing-out-stanza-empty {an empty element keeps being empty} -body {
    ::wsframing::out [jwrite [j presence]]
} -result {<presence xmlns='jabber:client'/>}

test wsframing-out-stanza-own-ns {an element with its own namespace is left alone} -body {
    set auth [jwrite [j auth -ns urn:ietf:params:xml:ns:xmpp-sasl -mechanism PLAIN -body AGEAYg==]]
    expr {[::wsframing::out $auth] eq $auth}
} -result 1

test wsframing-out-stanza-escapes {a > inside an attribute does not end the tag early} -body {
    ::wsframing::out [jwrite [j message -to "a>b@example.com"]]
} -result {<message xmlns='jabber:client' to='a&gt;b@example.com'/>}

# -- incoming ---------------------------------------------------------------

test wsframing-in-open {<open/> becomes the stream root the reader expects} -body {
    set root [::wsframing::in {<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' from='example.com' id='c2s1' version='1.0' xml:lang='en'/>}]
    list [string match {<stream:stream *>} $root] \
         [string match {*from='example.com'*} $root] \
         [string match {*id='c2s1'*} $root] \
         [string match {*xmlns='jabber:client'*} $root] \
         [string match {*xmlns:stream='http://etherx.jabber.org/streams'*} $root]
} -result {1 1 1 1 1}

test wsframing-in-close {<close/> becomes the stream footer} -body {
    ::wsframing::in {<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>}
} -result {</stream:stream>}

test wsframing-in-prefixed {a prefixed framing element is still a framing element} -body {
    ::wsframing::in {<f:close xmlns:f='urn:ietf:params:xml:ns:xmpp-framing'/>}
} -result {</stream:stream>}

test wsframing-in-wrong-ns {an <open/> in another namespace is a stanza like any other} -body {
    set msg {<open xmlns='urn:example:something-else'/>}
    expr {[::wsframing::in $msg] eq $msg}
} -result 1

test wsframing-in-no-ns {an undeclared <close/> is not the framing one} -body {
    set msg {<close/>}
    expr {[::wsframing::in $msg] eq $msg}
} -result 1

test wsframing-in-stanza {a stanza arrives byte for byte} -body {
    set msg {<message xmlns='jabber:client' from='bob@example.com'><body>hi &amp; bye</body></message>}
    expr {[::wsframing::in $msg] eq $msg}
} -result 1

test wsframing-in-features {stream features keep their prefix binding} -body {
    set msg {<stream:features xmlns:stream='http://etherx.jabber.org/streams'><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>}
    expr {[::wsframing::in $msg] eq $msg}
} -result 1

# -- end to end -------------------------------------------------------------
# What the transport actually does with these: feed the translations to the
# same reader a TCP connection uses, and see a stream come out.

test wsframing-reader {a framed session parses as a stream} -setup {
    set ::header {}
    set ::stanzas {}
    set ::footer 0
    xmppreader wsr \
        -command {lappend ::stanzas} \
        -header-command {set ::header} \
        -footer-command {apply {{args} {set ::footer 1}}}
} -body {
    wsr feed [::wsframing::in {<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' from='example.com' id='c2s1' version='1.0'/>}]
    wsr feed [::wsframing::in {<stream:features xmlns:stream='http://etherx.jabber.org/streams'><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>}]
    wsr feed [::wsframing::in {<message xmlns='jabber:client' from='bob@example.com' type='chat'><body>hi</body></message>}]
    wsr feed [::wsframing::in {<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>}]
    list [dict get $::header tag] \
         [dict get $::header attrs] \
         [llength $::stanzas] \
         [dict get [lindex $::stanzas 0] tag] \
         [dict get [lindex $::stanzas 1] tag] \
         [xsearch [lindex $::stanzas 1] body -get body] \
         $::footer
} -cleanup {
    wsr destroy
} -result {stream {{http://www.w3.org/XML/1998/namespace lang} en version 1.0 from example.com id c2s1} 2 features message hi 1}

test wsframing-roundtrip {what we send is what the other side would read back} -body {
    set stanza [j iq -id bind -type set {
        j bind -ns urn:ietf:params:xml:ns:xmpp-bind {
            j resource -body laptop
        }
    }]
    set onWire [::wsframing::out [jwrite $stanza]]
    set back [xmppreader string [::wsframing::in $onWire]]
    list [dict get $back tag] [dict get $back ns] \
         [xsearch $back bind resource -get body]
} -result {iq jabber:client laptop}

cleanupTests
