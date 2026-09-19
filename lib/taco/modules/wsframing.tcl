# wsframing.tcl - XMPP over WebSocket (RFC 7395), the framing half.
#
# Over TCP a session is one long XML document opened by <stream:stream> and
# closed by </stream:stream>, with stanzas as its children. Over a WebSocket
# each message is a complete element of its own, and the stream open and close
# become two elements in their own namespace:
#
#   <open  xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='...' version='1.0'/>
#   <close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>
#
# Everything above the transport in taco - the reader in xmpprw, conn's stream
# restart after SASL, its </stream:stream> on close - is written for the
# document shape, so this translates between the two in both directions:
#
#   out   a raw write from baseconn -> the message to send
#         <stream:stream ...>  ->  <open .../>        (the XML declaration goes)
#         </stream:stream>     ->  <close/>
#         a stanza             ->  the stanza, with xmlns='jabber:client' added
#   in    a received message -> bytes to feed the XML reader
#         <open .../>          ->  <stream:stream ...>  (the reader wants a root)
#         <close/>             ->  </stream:stream>
#         a stanza             ->  unchanged
#
# The stanza namespace is the easy thing to get wrong: a framed message has no
# root to inherit jabber:client from, so RFC 7395 3.4 requires each one to
# carry the declaration itself. `out` adds it to any element that has none.
#
# Nothing here does I/O. The transport is baseconn's -transport websocket
# branch, over ::wschan (zippy's emscripten/wschan.c) in a browser.

namespace eval ::wsframing {
    # RFC 7395 §3.1: the WebSocket subprotocol a server must agree to, and
    # §3.7: the namespace of the two framing elements.
    variable SUBPROTOCOL xmpp
    variable NS urn:ietf:params:xml:ns:xmpp-framing
    # What a stanza is in, absent a stream root to inherit it from.
    variable STANZA_NS jabber:client

    # The attributes of <open/> worth carrying across, in the order RFC 7395's
    # examples use. Anything else - the xmlns declarations of the stream
    # header, above all - is the other shape's business.
    variable OPEN_ATTRS {from to id version xml:lang}
}

# The conventional endpoint for a host that publishes no other. The real
# answer is XEP-0156 (a host-meta lookup for a urn:xmpp:alt-connections
# link), which needs an HTTP fetch this does not do; a server that follows
# the convention is reachable without one, and -ws-url covers the rest.
proc ::wsframing::url {host {scheme wss}} {
    return "$scheme://$host/xmpp-websocket"
}

# -- outgoing ---------------------------------------------------------------

# One raw write from baseconn, as the message to put on the wire. Everything
# taco writes is either a stream header, a stream footer, or one serialized
# stanza (see baseconn's writeNow), and those are the three cases below.
proc ::wsframing::out {data} {
    set text [Undeclare $data]
    if {[string match "</stream:stream>*" $text]} {
        return [close_element]
    }
    if {[regexp {^<stream:stream[\s/>]} $text]} {
        return [open_element [Attrs $text]]
    }
    return [DeclareStanzaNs $text]
}

# <open/>, from the attributes of the <stream:stream> header it replaces.
proc ::wsframing::open_element {{attrs {}}} {
    variable NS
    variable OPEN_ATTRS

    set out "<open xmlns='[xesc $NS]'"
    foreach name $OPEN_ATTRS {
        if {[dict exists $attrs $name]} {
            append out " $name='[xesc [dict get $attrs $name]]'"
        }
    }
    # RFC 7395 §3.4: version is required on <open/>, and a header that left it
    # out meant 1.0 all the same.
    if {![dict exists $attrs version]} {
        append out " version='1.0'"
    }
    return "$out/>"
}

proc ::wsframing::close_element {{attrs {}}} {
    variable NS

    set out "<close xmlns='[xesc $NS]'"
    foreach {name value} $attrs {
        append out " $name='[xesc $value]'"
    }
    return "$out/>"
}

# -- incoming ---------------------------------------------------------------

# One received message, as bytes for the XML reader. A stanza is passed
# through untouched: it is already the text the reader would have seen inside
# a stream, and re-serializing it could only lose something.
proc ::wsframing::in {message} {
    set text [Undeclare $message]
    lassign [Framing $text] kind attrs
    switch -- $kind {
        open {
            # The reader wants the root element a TCP stream would have begun
            # with; ::jab::header supplies the two xmlns declarations that
            # make the stanzas under it parse the same way.
            return [::jab::header "" {*}$attrs]
        }
        close { return "</stream:stream>" }
    }
    return $message
}

# Is this message <open/> or <close/> in the framing namespace? Returns
# {open|close attrs} or {} - and answers "no" for anything whose namespace
# does not check out, rather than guessing from the element name.
proc ::wsframing::Framing {text} {
    variable NS
    variable OPEN_ATTRS

    if {![regexp {^<([^\s/>]+)} $text -> tag]} {
        return {}
    }
    set parts [split $tag :]
    set local [lindex $parts end]
    if {$local ni {open close}} {
        return {}
    }
    set attrs [Attrs $text]
    # A prefixed <f:open xmlns:f='...'/> is as legal as the usual unprefixed
    # form, so the declaration to check is whichever one binds this element.
    set decl [expr {[llength $parts] > 1 ? "xmlns:[lindex $parts 0]" : "xmlns"}]
    if {![dict exists $attrs $decl] || [dict get $attrs $decl] ne $NS} {
        return {}
    }
    set kept {}
    foreach name $OPEN_ATTRS {
        if {[dict exists $attrs $name]} {
            dict set kept $name [dict get $attrs $name]
        }
    }
    return [list $local $kept]
}

# -- shared -----------------------------------------------------------------

# Drop a leading XML declaration and surrounding space. ::jab::header does not
# emit one, but xmpp_starttls does, and a framed message is an element, not a
# document of its own.
proc ::wsframing::Undeclare {text} {
    set text [string trim $text]
    regsub {^<\?xml[^>]*\?>\s*} $text "" text
    return $text
}

# The attributes of the first start tag, as a dict. The input is always
# something jwrite or ::jab::header produced, where every value is escaped
# (xesc escapes > as well) and quoted, so the first unquoted > really does end
# the tag.
proc ::wsframing::Attrs {text} {
    set attrs {}
    set pattern {([^\s=/<>"']+)\s*=\s*(?:'([^']*)'|"([^"]*)")}
    if {![regexp {^<[^\s/>]+((?:[^>"']|"[^"]*"|'[^']*')*)} $text -> rest]} {
        return $attrs
    }
    foreach {- name single double} [regexp -all -inline $pattern $rest] {
        # Not expr's ternary: it would renumber a value that looks like a
        # number, and a stream id of 007 is a string.
        if {$single eq ""} { set single $double }
        dict set attrs $name [Unescape $single]
    }
    return $attrs
}

proc ::wsframing::Unescape {text} {
    return [string map {&lt; < &gt; > &quot; \" &apos; ' &amp; &} $text]
}

# RFC 7395 §3.4: a stanza travels as a document of its own, so it carries the
# namespace declaration it would otherwise have inherited from the stream
# root. One that already declares a default namespace - <auth/> during SASL,
# say - is left alone.
proc ::wsframing::DeclareStanzaNs {text} {
    variable STANZA_NS

    if {![regexp {^<([^\s/>]+)} $text -> tag]} {
        return $text
    }
    # A prefixed element carries its own binding, and one that already
    # declares a default namespace is not ours to relabel.
    if {[string first ":" $tag] >= 0 || [dict exists [Attrs $text] xmlns]} {
        return $text
    }
    set rest [string range $text [expr {1 + [string length $tag]}] end]
    return "<$tag xmlns='[xesc $STANZA_NS]'$rest"
}
