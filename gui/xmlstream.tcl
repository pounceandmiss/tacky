package require xmpprw

# xmlstream.tcl - XML stanza debugger/viewer
#
# Displays live XMPP stanzas (incoming + outgoing) with syntax highlighting,
# filtering by stanza type / namespace, and text search.
#
# Widget hierarchy:
#   xmltext (widget)             — text rendering, pretty-printing, search
#   xmlstream (widgetadaptor)    — wraps xmltext; toolbar, sendbar, connection,
#                                  stanza accumulation, filtering logic
#     xmlstream_toolbar          — clear button, search entry, filter checkboxes
#       xmlstream_toolbar_filter — iq/presence/message/nonza checkboxes + ns entry
#   xmlstanza (widgetadaptor)    — wraps xmltext; single-stanza viewer
#
# Usage:
#   xmlstream .xs -conn [list account $jid]
#   pack .xs -fill both -expand yes
#
# Connection integration:
#   -conn: {type id} pair identifying the connection to tap.
#     type "account" + JID, or type "register" + token.
#     Installs a debug tap via tacky debugtap; removed on destroy
#     or when -conn is reconfigured.
#
# Filtering:
#   Stanzas are accumulated in a list. Toolbar checkboxes (iq, presence,
#   message, nonza) and namespace entry control visibility. Filtered-out
#   stanzas are not inserted into the text widget (or are removed from it),
#   so they won't appear in copied text. Changing a filter re-evaluates
#   all accumulated stanzas, drawing or removing them as needed.

# Unique ids, kept off the global ::Counter that lib/xmpprw also bumps.
namespace eval xmlstream {
    variable StanzaId 0
    variable PrefixId 0
}

proc xesc {content} {
    string map {< &lt; > &gt; & &amp; \" &quot; ' &apos;} $content
}

# What the console shows before the user (or a saved setting) says otherwise.
proc xmlstream_default_filters {} {
    return {iq 1 presence 0 message 1 nonza 0 ns ""}
}

snit::widgetadaptor xmlstream {
    option -conn -default "" -configuremethod ConfigureConn

    delegate method * to hull

    component toolbar
    component sendinput
    component sendbtn

    # list of dicts: {stanza $xml comment $txt id $n drawn 0|1}
    variable stanzas

    variable filters
    variable tapId ""
    variable writecmd ""

    method ConfigureConn {o v} {
        if {$tapId ne ""} {
            tacky unlisten $win
            catch {tacky debugtap off -tap $tapId}
            set tapId ""
            set writecmd ""
            $sendbtn state disabled
        }
        set options($o) $v
        if {$v ne ""} {
            lassign $v type id
            switch -- $type {
                account {
                    tacky debugtap on -acc $id \
                        -tag $win -command [mymethod OnTapReady $v]
                }
                register {
                    tacky debugtap on -token $id \
                        -tag $win -command [mymethod OnTapReady $v]
                }
            }
        }
    }

    method OnTapReady {conn id} {
        if {$options(-conn) ne $conn} {
            catch {tacky debugtap off -tap $id}
            return
        }
        set tapId $id
        tacky listen -tag $win debugtap <Stanza> -tap $tapId \
            [mymethod onStanza]
        set writecmd [list tacky debugtap write -tap $tapId -stanza]
        $sendbtn state !disabled
    }

    constructor args {
        installhull using xmltext
        array set filters [xmlstream_default_filters]

        install toolbar using xmlstream_toolbar $win.toolbar -partof $self
        $toolbar filters configure -command [mymethod OnFilters]
        pack $toolbar -fill x -before $win.scroll

        ttk::frame $win.sendbar
        install sendinput using text $win.sendbar.input -height 3 -wrap word
        install sendbtn using ttk::button $win.sendbar.btn -text Send \
            -command [mymethod Send]
        pack $sendbtn -side right -fill y
        pack $sendinput -side left -fill both -expand yes
        bind $sendinput <Control-Return> "[mymethod Send]; break"
        $sendbtn state disabled
        pack $win.sendbar -side bottom -fill x -before $win.scroll

        bind $win.text <Control-f> "[mymethod FocusSearch]; break"
        bind $sendinput <Control-f> "[mymethod FocusSearch]; break"

        $self configurelist $args
        set stanzas {}
        tacky setting get -key xmlconsole.filters \
            -tag $win -command [mymethod OnLoadFilters]
    }

    method OnLoadFilters {value} {
        if {$value ne ""} {
            $toolbar filters setFilters $value
        }
    }

    method clear {} {
        $hull clear
        set stanzas {}
    }

    method FocusSearch {} {
        $toolbar focusSearch
    }

    destructor {
        catch {tacky unlisten $win}
        catch {tacky debugtap off -tap $tapId}
    }

    method Send {} {
        set w $sendinput
        set xml [string trim [$w get 1.0 end-1c]]
        if {$xml eq "" || $writecmd eq ""} return
        if {[catch {xmppreader string -zap yes $xml} stanza]} {
            set was [$w cget -background]
            $w configure -background #ffcccc
            after 600 [list catch [list $w configure -background $was]]
            return
        }
        {*}$writecmd $stanza
        $w delete 1.0 end
    }

    method OnFilters {filters_} {
        array set filters $filters_
        tacky setting set -key xmlconsole.filters -value $filters_
        set newStanzas {}
        foreach entry $stanzas {
            set want [$self matches [dict get $entry stanza]]
            set drawn [dict get $entry drawn]
            if {$want && !$drawn} {
                $self drawStanza -comment [dict get $entry comment] \
                    -stanza [dict get $entry stanza] \
                    -id [dict get $entry id]
                dict set entry drawn 1
            } elseif {!$want && $drawn} {
                $self removeStanza -id [dict get $entry id]
                dict set entry drawn 0
            }
            lappend newStanzas $entry
        }
        set stanzas $newStanzas
    }

    method onStanza {ev} {
        set dir [dict get $ev -dir]
        set stanza [dict get $ev -stanza]
        set timestamp [clock seconds]
        set comment "$dir at [clock format $timestamp -f %H:%M:%S]"
        set visible [$self matches $stanza]
        set id [incr ::xmlstream::StanzaId]
        if {$visible} {
            $self drawStanza -comment $comment -stanza $stanza -id $id
        }
        lappend stanzas [dict create stanza $stanza comment $comment \
            id $id drawn $visible]
    }

    method matches stanza {
        set tag [dict get $stanza tag]
        foreach type {iq message presence} {
            if {!$filters($type) && $tag eq $type} {
                return no
            }
        }
        if {!$filters(nonza) && $tag ni "iq message presence"} {
            return no
        }
        if {$filters(ns) ne ""
            && [lsearch [xsearch $stanza * -gather ns] *$filters(ns)*] == -1} {
            return no
        }
        return yes
    }
}

snit::widget xmltext {
    variable Prefixes

    hulltype ttk::frame
    component text

    constructor args {
        install text using text $win.text -wrap no \
            -yscrollcommand [list $win.scroll set]
        ttk::scrollbar $win.scroll -orient vertical \
            -command [list $win.text yview]
        pack $win.scroll -side right -fill y
        pack $text -fill both -expand yes
        set Prefixes {
            http://www.w3.org/XML/1998/namespace xml
            http://etherx.jabber.org/streams stream
        }
        $win.text tag configure xmltag -foreground blue
        $win.text tag configure attrname -foreground purple
        $win.text tag configure attrval -foreground green
        $win.text tag configure comment -foreground grey
        $win.text tag configure found -background yellow
    }

    method seeEnd {} {
        $win.text see end
    }

    method clear {} {
        $win.text delete 1.0 end
        foreach mark [$win.text mark names] {
            if {[string match stanza-* $mark]} {
                $win.text mark unset $mark
            }
        }
    }

    method find {what {start 1.0}} {
        set dir -forwards
        switch -- $start {
            next {
                set start [lindex [lindex [$win.text tag ranges found] end] end]
            }
            prev {
                set start [lindex [lindex [$win.text tag ranges found] 0] 0]
                set dir -backwards
            }
        }
        set tag found
        set w $win.text
        foreach {from to} [$w tag ranges $tag] {
            $w tag remove $tag $from $to
        }
        set pos [$w search -count n $dir -- $what $start]
        if {$pos ne ""} {
            $w mark set insert $pos
            $w see $pos
            $w tag add $tag $pos $pos+${n}c
        }
    }


    method Write {chars {tag {}}} {
        $win.text ins end $chars $tag
    }

    method drawComment {commentBody} {
        $self Write <!--$commentBody-->\n comment
    }

    method drawStanza {args} {
        array set opts $args
        if {![info exists opts(-id)]} {
            set opts(-id) [incr ::xmlstream::StanzaId]
        }
        $win.text mark set tmp end-1chars
        $win.text mark gravity tmp left
        if {[info exists opts(-comment)]} {
            $self drawComment $opts(-comment)
        }
        $self drawNode $opts(-stanza)
        $win.text tag add stanza-$opts(-id) tmp end

        set opts(-id)
    }

    method removeStanza {args} {
        array set opts $args
        set tag stanza-$opts(-id)
        if {[$win.text tag ranges $tag] ne ""} {
            $win.text delete $tag.first $tag.last
        }
        $win.text tag delete $tag
    }

    method drawNode {stanza {prevNs ""} {indentN 0}} {
        set indent ""
        if {$indentN > -1} {
            set indent [string repeat " " $indentN]
            incr indentN
        }
        set tag [dict get $stanza tag]
        if {[dict exists $Prefixes [dict get $stanza ns]]} {
            set tag [dict get $Prefixes [dict get $stanza ns]\
                        ]:[dict get $stanza tag]
        }

        $self Write "$indent<$tag" xmltag

        set attrsIndentN -1

        if {$indentN > -1} {
            set attrsIndentN [expr {$indentN + [string length "<$tag"]}]
        }

        set virtualAttrs [dict get $stanza attrs]
        if {[dict get $stanza ns] ne "" && [dict get $stanza ns] ne $prevNs} {
            set prevNs [dict get $stanza ns]
            lappend virtualAttrs xmlns [dict get $stanza ns]
        }


        $self WriteAttrs $virtualAttrs $attrsIndentN
        set closingNewline ""
        if {[dict get $stanza body] ne ""
            || [dict get $stanza children] ne ""} {
            $self Write > xmltag

            if {[dict get $stanza body] ne ""} {
                set bodyIndent ""
                if {[string length [dict get $stanza body]] > 10} {
                    set closingNewline \n$indent
                    set bodyIndent \n[string repeat " " [expr {$indentN + 1}]]
                }
                $self Write $bodyIndent
                $self Write [xesc [dict get $stanza body]]
            }

            foreach child [dict get $stanza children] {
                $self Write \n
                $self drawNode $child [dict get $stanza ns] $indentN
                set closingNewline \n$indent
            }

            $self Write $closingNewline</$tag> xmltag
            $self Write [xesc [dict get $stanza tail]]
        } else {
            $self Write /> xmltag
        }
        if {$indentN == 1} {
            $self Write \n\n
        }
    }

    method WriteAttrs {attrs_ {indent 0}} {
        set attrs ""
        foreach {k v} $attrs_ {
            if {[lindex $k 1] ne ""} {
                # XMPP is not supposed to use attribute prefixes, but real
                # history has them (an rdf-syntax-ns attr turned up in mine).
                # Expat doesn't hand back the original prefix, and a prefix can
                # only be declared by a separate attr, so we invent one and
                # emit the declaration just ahead of the attr that needs it.
                set attrNs [lindex $k 0]
                if {[dict exists $Prefixes $attrNs]} {
                    set prefix [dict get $Prefixes [lindex $k 0]]
                    lappend attrs $prefix:[lindex $k 1] $v
                } else {
                    set prefix pref[incr ::xmlstream::PrefixId]
                    lappend attrs xmlns:$prefix $attrNs
                }

            } else {
                lappend attrs $k $v
            }
        }
        if {$attrs eq ""} {
            return
        }
        $self Write " "

        set nAttrs [expr {[llength $attrs] / 2}]
        foreach {k v} $attrs {
            incr i
            $self Write "$k=" attrname
            $self Write '[xesc $v]' attrval
            if {$i < $nAttrs} {
                $self Write \n[string repeat " " $indent]
            }
        }
    }
}

snit::widget xmlstream_toolbar {
    hulltype ttk::frame
    
    component clearbutton
    component searchlabel
    component searchentry
    component filters
    component godown
    
    option -partof -readonly yes
    variable query
    
    constructor args {
        $self configurelist $args
        install clearbutton using ttk::button $win.clearbutton \
            -image adwaita/22x22/actions/edit-clear-all.png \
            -command [list $options(-partof) clear]
        install godown using ttk::button $win.godown \
            -image mate/22x22/actions/go-down.png \
            -command [list $options(-partof) seeEnd]
        install searchlabel using ttk::label $win.searchlabel \
            -image adwaita/22x22/actions/system-search.png
        install searchentry using ttk::entry $win.searchentry \
            -textvariable [myvar query]
        install filters using xmlstream_toolbar_filter $win.filters
        
        pack $clearbutton $godown $searchlabel $searchentry $filters -side left
        trace add variable [myvar query] write [mymethod OnSearch]
        bind $searchentry <Return> [mymethod OnSearchReturnKeyPress next]
        bind $searchentry <Shift-Return> [mymethod OnSearchReturnKeyPress prev]
    }
    
    # The filter panel, for the owner to configure and seed.
    method filters {args} { {*}$filters {*}$args }

    method focusSearch {} {
        focus $searchentry
        $searchentry selection range 0 end
    }

    method OnSearch args {
        $options(-partof) find $query
    }
    
    method OnSearchReturnKeyPress dir  {
        $options(-partof) find $query $dir
    }
}

snit::widget xmlstream_toolbar_filter {
    hulltype ttk::frame
    component iq
    component presence
    component message
    component nonza
    component ns_label
    component ns
    
    variable filters
    option -command

    constructor args {
        $self configurelist $args
        array set filters [xmlstream_default_filters]
        foreach type {iq presence message nonza} {
            install $type using ttk::checkbutton $win.$type \
                -text $type -variable [myvar filters($type)]
            pack $win.$type -side left
        }
        install ns_label using ttk::label $win.ns_label -text "ns:"
        install ns using ttk::entry $win.ns\
            -textvariable [myvar filters(ns)]
        pack $win.ns_label $win.ns  -side left

        trace add variable [myvar filters] write \
            [mymethod OnFiltersChange]
    }

    method setFilters {filterDict} {
        trace remove variable [myvar filters] write \
            [mymethod OnFiltersChange]
        array set filters $filterDict
        trace add variable [myvar filters] write \
            [mymethod OnFiltersChange]
        {*}$options(-command) [array get filters]
    }

    method OnFiltersChange {name1 name2 op} {
        {*}$options(-command) [array get filters]
    }
    
}

snit::widgetadaptor xmlstanza {
    option -stanza -configuremethod ConfigureStanza

    delegate method * to hull
    delegate option * to hull

    typemethod showxml {xml {title "XML Stanza"}} {
        xmlstanza show [xmppreader string $xml] $title
    }

    typemethod show {stanza {title "XML Stanza"}} {
        set w .xml_stanza_viewer
        if {[raise_existing $w]} {
            $w.xs configure -stanza $stanza
            wm title $w $title
            return $w
        }
        toplevel $w
        wm title $w $title
        wm geometry $w 600x400
        xmlstanza $w.xs -stanza $stanza
        pack $w.xs -expand yes -fill both
        return $w
    }

    constructor args {
        installhull using xmltext
        $self configurelist $args
    }

    method ConfigureStanza {o v} {
        set options($o) $v
        $self clear
        if {$v ne ""} {
            $self drawStanza -stanza $v
        }
    }
}

proc xmlconsole {jid} {
    set safe [path_safe $jid]
    set w .xmlconsole-$safe
    if {[raise_existing $w]} { return $w }
    toplevel $w
    wm title $w "XML Console — $jid"
    wm geometry $w 600x400
    xmlstream $w.xs -conn [list account $jid]
    pack $w.xs -expand yes -fill both
    bind $w <Control-f> [list $w.xs FocusSearch]
    return $w
}

