package require tdom
package require snit
namespace eval ::jab {}
# Public API:
#
#   xmppreader $name ?options?
#     Expat-based incremental XML stream parser.
#     Options:
#       -channel $chan      Channel to read from (set non-blocking automatically)
#       -command $cmd       Callback for each top-level stanza (receives node dict)
#       -header-command $cmd  Callback for the stream header element
#       -footer-command $cmd  Callback for the stream footer (closing </stream:stream>)
#       -error-command $cmd   Callback for read errors and EOF
#     Methods:
#       start               Begin reading from -channel via fileevent
#       pause               Stop reading (remove fileevent)
#       feed $data           Parse an XML chunk directly
#     Type method:
#       xmppreader string ?options? $xml   Parse an XML string, return node dict
#
#   ::jab::readChannel $chan ?options?   Create an xmppreader for $chan and start it
#   ::jab::cancelRead $chan              Stop and destroy a channel's reader
#
#   j $tag ?-attr val ...? ?body?   Build a node dict (nestable DSL)
#   j #as-is $node                  Insert a pre-built node dict as a child
#
#   jwrite $stanza                  Serialize a node dict to XML string
#   jwrite $chan $stanza            Serialize and write to channel
#   jwrite -pretty ?$chan? $stanza  Serialize with indentation
#
#   ::jab::header ?$chan? ?attrs?   Generate and optionally send a <stream:stream> header
#
# Example:
#   set stanza [j iq -type set -to draugr.de {
#       j query -ns urn:xmpp:mam:2 {
#           j x -ns jabber:x:data -type submit {
#               j field -var FORM_TYPE -type hidden {
#                   j value #body urn:xmpp:mam:2
#               }
#               j field -var with {
#                   j value #body user@example.com
#               }
#           }
#       }
#   }]

# This file offers facilities for working with xml in a manner that would suit
# xmpp. It depends only on expat and doesn't use any of tdom's dom facilities.
# Why I don't just use tdom's dom facilities:
# 1. tdom works with tcl handles as opposed to tcl values, thus introducing
# the issue of memory management
# 2. tdom offers no way for the wicked partial dom reading and building like
# xmpp mandates - so I'd have to write the xmppreader class by hand anyway
# 3. tdom makes working with namespaces awkward - you have to set up a custom
# prefix for each namespace, and xmpp uses namespaces all over the place.
# Provided the above, a custom xml representation just seemed easier than
# hacking around tdom.

# An xml node is stored as a dict: {tag message body {} tail {} children {} ns
# {} attrs {id 12}}.  It might've been more efficient to make it a list, but
# that'd take slightly more effort. Also I probably shouldn't've separated
# out "ns".

# The node dicts carry no info on prefixes: those are added while converting
# to xml.

# Then there's a j command. Works like this: j $tag -attr val $script,
# where script will add children by also simply calling j.

proc xesc {content} {
    string map {
        < &lt;
        > &gt;
        & &amp;
        \" &quot;
        ' &apos;
    } $content
}


snit::type xmppreader {
    # command prefix for each read
    # for the header and stanza it's a j object
    # for footer and eof it's ""
    option -command -default control::no-op
    option -error-command -default control::no-op
    option -header-command -default control::no-op
    option -footer-command -default control::no-op
    
    # zap whitespaces (you don't want this in real life circumstance)
    option -zap -default no
    
    # (optional) channel that will be parsed when you call `start`
    option -channel
    
    variable Expat
    variable Cb
    variable NodeList
    
    constructor {args} {
	install expat using expat $self.expat -namespace -final no \
	    -elementstartcommand [mymethod OnElemStart]\
	    -elementendcommand [mymethod OnElemEnd] \
	    -characterdatacommand [mymethod OnCdata]
	set Expat $self.expat
	set NodeList {}
	$self configurelist $args
	
	if {$options(-channel) ne ""} {
	    fconfigure $options(-channel) -blocking no
	}
    }
    
    method OnReadable {} {
	if {[catch {set chunk [read $options(-channel)]}]} {
	    jlog debug "Read error: $::errorInfo"
	    {*}$options(-error-command) "Read error: $::errorInfo"
	    $self pause
	    return
	}
	
	if {$chunk eq "" && [chan eof $options(-channel)]} {
	    $self pause
	    {*}$options(-error-command) -
	    return
	}
	$self feed $chunk
    }
    
    method start {} {
	fileevent  $options(-channel) readable [mymethod OnReadable]
    }
    
    method pause {} {
	catch {fileevent $options(-channel) readable {}}
    }
    
    method feed {data} {
        $Expat parse $data
    }
    
    destructor {
	$self pause
	catch {$Expat delete}
    }
    
    method OnElemStart {tag attrs} {
	set ns {}
	regexp {(.*):(.*)} $tag -> ns tag
	set node [list tag $tag ns $ns children {} attrs {}]
	
	foreach {attrName attrVal} $attrs {
	    set attrNs {}
	    if {[regexp {(.*):(.*)} $attrName -> attrNs attrName]} {
		dict set node attrs [list $attrNs $attrName]  $attrVal
	    } else {
		dict set node attrs $attrName  $attrVal
	    }
	}
	if {[llength $NodeList] == 0} {
	    dict set node body {}
	    dict set node tail {}
	    {*}$options(-header-command) $node
	}
	lappend NodeList $node
    }
    
    method OnElemEnd tag {
	# Pop the last element from the list and add it as the last
	# child to the now-last element
	set node [lpop NodeList end]
	if {![dict exists $node body]} {
	    dict set node body {}
	}
	if {![dict exists $node tail]} {
	    dict set node tail {}
	}
	if {[llength $NodeList] > 1} {
	    set parent [lpop NodeList end]
	    dict lappend parent children $node
	    lappend NodeList $parent
	} elseif {[llength $NodeList] == 1} {
	    {*}$options(-command) $node
	}  elseif {[llength $NodeList] == 0} {
	    {*}$options(-footer-command) {}
	}
    }
    
    method OnCdata cdata {
	if {$options(-zap) && [string is space $cdata]} {
	    return
	}
	set node [lpop NodeList end]
	if {[dict get $node children] eq ""} {
	    dict append node body $cdata
	} else {
	    dict with node {
		set child [lpop children]
		dict append child tail $cdata
		lappend children $child
	    }
	}
	lappend NodeList $node
    }

    typevariable String

    typemethod string {args} {
	set xmlString [lindex $args end]
	set args [lrange $args 0 end-1]
	$type $type.tmp {*}$args -command [list set [mytypevar String]]
	$type.tmp feed <dummy>$xmlString</dummy>
	$type.tmp destroy
	set tmp $String
	unset String
	set tmp
    }
}

proc ::jab::readChannel {chan args} {
    variable Readers
    set Readers($chan) [xmppreader reader.[incr ::Counter] -channel $chan {*}$args]
    $Readers($chan) start
}

proc ::jab::cancelRead {chan} {
    variable Readers
    if {[info exists Readers($chan)]} {
	set reader $Readers($chan)
	unset Readers($chan)
	$reader pause
	# Clear channel so the deferred destructor won't remove a
	# replacement reader's fileevent on the same channel.
	$reader configure -channel ""
	after idle [list $reader destroy]
    }
}

proc j {tag args} {
    upvar ___jStore store
    
    set IamMain [expr {![info exists store]}]
    if {$tag in "#as-is /as-is"} {
	set node [lindex $args 0]
	if {[llength $args] != 1 || ![dict exists $node tag]} {
	    error "Usage: j #as-is \$node"
	}

	lappend store /as-is $node
    } else {	
	set haveScript [expr {[llength $args] % 2 > 0}]
	
	set opts $args
	if {$haveScript} {
	    set opts [lrange $args 0 end-1]
	}
	lappend store $tag $opts
	if {$haveScript} {
	    uplevel [lindex $args end]
	}
	lappend store /end {}
	
    }
    if {!$IamMain} {
	    return
    }
    # This does the same as the XmppStringReader does to prevent duplicating
    set NodeList {}
    
    foreach {tag data} $store {
	switch -- $tag {
	    /as-is {
		# data is the ready-made child (not surrounded by a list)
		set node $data
		
		set parent [lpop NodeList end]
		dict lappend parent children $node
		lappend NodeList $parent
		
	    }
	    /end {
		set node [lpop NodeList end]
		if {[llength $NodeList] > 0} {
		    set parent [lpop NodeList end]
		    dict lappend parent children $node
		    lappend NodeList $parent
		}
	    }
	    default {
		set node {body {} tail {} children {} ns {} attrs {}}
		dict set node tag $tag
		foreach {k v} $data {
		    switch -regexp -matchvar match -- $k {
			-ns {
			    dict set node ns $v
			}
			@(.*) -
			-(.*) {
			    lassign $match -> attrName
			    dict set node attrs $attrName $v
			}
			.body -
			"#body" {
			    dict set node body $v
			}
		    }
		}
		
		lappend NodeList $node
	    }
	}
    }
    
    set store {}
    uplevel unset ___jStore 
    set node
}

proc ::jab::header {{chan ""} args} {
    set attrs {xml:lang en version 1.0 xmlns jabber:client
	xmlns:stream http://etherx.jabber.org/streams}
    set attrs [dict merge $attrs $args]
    set res "<stream:stream [GetAttrsString $attrs -1]>"

    if {$chan ne ""} {
	puts -nonewline $chan $res
	flush $chan
    }
    set res
}


interp alias {} jwrite {} ::jab::write

proc ::jab::GetAttrsString {attrs {indent 0} {Prefixes {
	    http://www.w3.org/XML/1998/namespace xml
	    http://etherx.jabber.org/streams stream
    }}} {
    set res ""
    foreach {k v} $attrs {
	if {[lindex $k 1] ne ""} {
	    # Doing this because I stumbled upon
	    # http://www.w3.org/1999/02/22-rdf-syntax-ns# in my message
	    # history, even though I was told xmpp doesn't use attr
	    # prefixes Expat doesn't seem to let us know what the original
	    # prefix is so we make up our own...  An attr's namespace
	    # prefix can only be specified as a separate attr. We put that
	    # helper attr directly before the helper attr.  Xml is made by
	    # mentally ill people.
	    set attrNs [lindex $k 0]
	    if {[dict exists $Prefixes $attrNs]} {
		set prefix [dict get $Prefixes [lindex $k 0]]
	    } else {
		set prefix pref[incr ::Counter]
		lappend res "xmlns:$prefix='[xesc $attrNs]' "
	    }
	    
	    set k $prefix:[lindex $k 1]	
	}
	lappend res "$k='[xesc $v]'" 
    }
    set out [join $res " "]
    if {$indent > -1 && [string length $out] > 20} {
	set attrIndent \n[string repeat " " $indent]
	set out [join $res $attrIndent]
    }
    set out
}

proc ::jab::write {args} {
    set indent -1
    set chan ""

    switch -- [llength $args] {
	1 {
	    set stanza [lindex $args 0]
	}
	2 {
	    if {[lindex $args 0] eq "-pretty"} {
		set indent 0
	    } else {
		set chan [lindex $args 0]
	    }
	}
	3 {
	    lassign $args - chan stanza
	    set indent 0
	}
	default {
	    error "Usage: jwrite ?-pretty? ?\$chan? \$stanza"
	}
    }
    
    set stanza [lindex $args end]
    
    set prefixes {
	    http://www.w3.org/XML/1998/namespace xml
	    http://etherx.jabber.org/streams stream
    }

    set res [::jab::_write $stanza $indent $prefixes ""]
    
    if {$chan ne ""} {
	puts -nonewline $chan $res
	flush $chan
    }
    
    set res
}

proc ::jab::_write {stanza indentN prefixes prevNs} {
    set indent ""
    if {$indentN > -1} {
	set indent \n[string repeat " " $indentN]
	incr indentN
    }
    set tag [dict get $stanza tag]
    if {[dict exists $prefixes [dict get $stanza ns]]} {
	set tag [dict get $prefixes [dict get $stanza ns]]:[dict get $stanza tag]
    }
    
    append res "$indent<$tag"

    set attrsIndentN -1

    if {$indentN > -1} {
	set attrsIndentN [expr {$indentN + [string length "<$tag"]}]
    }
    
    if {[dict get $stanza ns] ne "" && [dict get $stanza ns] ne $prevNs} {
	set prevNs [dict get $stanza ns]
	append res " " xmlns='[xesc [dict get $stanza ns]]'
	if {$indentN > -1 && [dict get $stanza attrs] ne ""} {
	    append res \n [string repeat " " [expr {$attrsIndentN - 1}]]
	}
    }
    
    if {[dict get $stanza attrs] ne ""} {
	append res " " [GetAttrsString [dict get $stanza attrs] $attrsIndentN ]
    }
    
    if {[dict get $stanza body] ne ""
	|| [dict get $stanza children] ne ""} {

	append res >[xesc [dict get $stanza body]]
	foreach child [dict get $stanza children] {
	    append res [::jab::_write $child $indentN $prefixes $prevNs]
	}
	
	# Only for pretty mode: if no children and content is short, closing tag on the same line
	set ClosingIndent $indent
	if {[dict get $stanza children] eq "" && [string length [dict get $stanza body]] < 30} {
	    set ClosingIndent ""
	}

	append res $ClosingIndent</$tag>[xesc [dict get $stanza tail]]
    } else {
	append res />
    }	
    set res
}
