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

proc xesc {content} {
    string map {< &lt; > &gt; & &amp; \" &quot; ' &apos;} $content
}

snit::widgetadaptor xmlstream {
    option -conn -default "" -configuremethod ConfigureConn

    delegate method * to hull
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
            $win.sendbar.btn state disabled
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
        $win.sendbar.btn state !disabled
    }

    constructor args {
        installhull using xmltext
        array set filters {iq 1 presence 0 message 1 nonza 0
            ns ""
        }

        xmlstream_toolbar $win.toolbar -partof $self
        $win.toolbar.filters configure -command [mymethod OnFilters]
        pack $win.toolbar -fill x -before $win.scroll

        ttk::frame $win.sendbar
        text $win.sendbar.input -height 3 -wrap word
        ttk::button $win.sendbar.btn -text Send -command [mymethod Send]
        pack $win.sendbar.btn -side right -fill y
        pack $win.sendbar.input -side left -fill both -expand yes
        bind $win.sendbar.input <Control-Return> "[mymethod Send]; break"
        $win.sendbar.btn state disabled
        pack $win.sendbar -side bottom -fill x -before $win.scroll

        $self configurelist $args
        set stanzas {}
        tacky setting get -key xmlconsole.filters \
            -tag $win -command [mymethod OnLoadFilters]
    }

    method OnLoadFilters {result} {
        set value [dict get $result -value]
        if {$value ne ""} {
            $win.toolbar.filters setFilters $value
        }
    }

    method clear {} {
        $hull clear
        set stanzas {}
    }

    destructor {
        catch {tacky unlisten $win}
        catch {tacky debugtap off -tap $tapId}
    }

    method Send {} {
        set w $win.sendbar.input
        set xml [string trim [$w get 1.0 end-1c]]
        if {$xml eq "" || $writecmd eq ""} return
        try {
            set stanza [xmppreader string -zap yes $xml]
        } on error {msg} {
            $w configure -background #ffcccc
            after 600 [list catch [list $w configure -background white]]
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
        set id [incr ::Counter]
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
                set dir -forwards
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
            set opts(-id) [incr ::Counter]
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
        # $self Write > xmltag
        set closingNewline ""
        if {[dict get $stanza body] ne ""
            || [dict get $stanza children] ne ""} {

            # append res >[xesc [dict get $stanza body]]
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
                    lappend attrs $prefix:[lindex $k 1] $v
                } else {
                    set prefix pref[incr ::Counter]
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
        install clearbutton using ttk::button $self.clearbutton \
            -image image/AdwaitaLegacy/22x22/legacy/edit-clear-all \
            -command [list $options(-partof) clear]
        install godown using ttk::button $win.godown \
            -image mate/22x22/actions/go-down \
            -command [list $options(-partof) seeEnd]
        install searchlabel using ttk::label $win.searchlabel \
            -image image/AdwaitaLegacy/22x22/legacy/system-search
        install searchentry using ttk::entry $self.searchentry \
            -textvariable [myvar query]
        install filters using xmlstream_toolbar_filter $self.filters
        
        pack $clearbutton $godown $searchlabel $searchentry $filters -side left
        trace add variable [myvar query] write [mymethod OnSearch]
        bind $searchentry <Return> [mymethod OnSearchReturnKeyPress next]
        bind $searchentry <Shift-Return> [mymethod OnSearchReturnKeyPress prev]
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
    component ns_label
    component ns
    
    option -client
    variable filters
    option -command
    
    constructor args {
        $self configurelist $args
        array set filters {iq 1 presence 0 message 1 nonza 0
            ns ""
        }
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

    typemethod show {stanza {title "XML Stanza"}} {
        set w .xml_stanza_viewer
        if {[winfo exists $w]} {
            $w.xs configure -stanza $stanza
            wm title $w $title
            wm deiconify $w
            raise $w
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

image create photo image/AdwaitaLegacy/22x22/legacy/edit-clear-all -data\
{iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAYAAADEtGw7AAADV0lEQVR4AaWSA5QrZxxHZ23ET0e1
bdu2nm3UfLZt2zbiVEnWo7XtzMT59cs0ddc552Z8/6QAdIsD71IRq/rHLF/ZP7ph2ceR7hX9o7/7
+/Nui1cPjN11dOo9gnbzSFTo52L5J1Guhf2phB6Jl31I3bZ+uFw4vXowpn+gQd6577Gif1TLtGlU
eI/EKwfEXrTuGOI/OedRnPyqD2x7hgXIvT09asWyT6jr1wyKFxps61F56WtUGhdh9eBEcflH1N09
Ei//OHKOduVLnkbrajTZN+DY9HsFMsA50vPuiK1WKkpqQ//YqpIrsyVp1qHxgVUDYrj1I6iobosZ
g8xBG9QVlr0Kb5nlA1RaZmLN4ERhycfRtwafd0vMmXN2cOazqOZPoejXIaiiX0KOVgnLAbk161KC
plvi3DNUTMaVqXrGeNHPW1gEKbJbSICvUJbxoJc1yBrzzInqLokZY+oTnElZU579lJBnfhX2y0OR
qVsH/sds/B7kcIDVpzzVpYxpXcqzvKWXQ6yZAUfZ9/DUfYnW4gGoLxyNdNM4cD+fBGs65mnr+zYG
lfw8b+4lOOtmw9+yGJ7asfA3Tvnz6K77BoztS2gPKQs6Lc4xpDzNmzWCs3YWPI3z4CgdDG/9BEnY
UtRfOvqbvoW7fhF4s7q4U2Kppxa1w0nKbymbgnruFYgVwySZq3IUmgo+DIm/JkGXgjOrqjoU5+hk
j7ImlUOs/gG1eQNRnvHAnyJfwyTU0K9AKBsSEn8Fb9NK0mNFQ7vijPOaBNYoq6/NfR8V3DB34a83
eRq4t+GuGStJK7LvQ7n9KfjqJ8JdOxr+5qkQa6eTVqiYDjPmTLJHiFwssD/ubS4jm1A+Cf6GyShN
v91d/OsdqGNel7Ktoh8mA12IuvxPfLaz8iUURSUR4ghR/ysmv4iTO5PeyDGo8vJ/uUcUqqeiKneU
u8B6Pyqz3kRLySCyFWPAmRSBQOtaFFrvcOxdk/Qa+U5JSCEkEKIJYf8RE2SEfluWxY/M1KoKWfPV
YqHtCV8NNxau+mVoKPnaV0YPgK95PRij0tW3L9WvQ3FIHkaIJygIvfevTxj40xn5viytKo3WK+oY
g0xkDCkIkqVVaEOJtN2KtghVER36MF6joRJC5zFBESG8rW9/AzmWD2KlKemWAAAAAElFTkSuQmCC}


image create photo image/AdwaitaLegacy/22x22/legacy/system-search -data\
{iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAYAAADEtGw7AAAFNUlEQVR4AYWVA5AkSxqA/8xyV2Na
0z0233p3rLNt+y50gbPt0AXPerbNtW2PZ9qcLkxVVuZVxNpfRCH1pTMRYwyuZ89n0FsowDsRgnFg
sAIAkPscBwRbgMErAw+wV+EOXCPe9lkUpA78ixOEd3oiUUWqimK5uh6QGgTs2ECWyqxw7phppObe
AAZfHnuEZe4ofvnjaIwDeMob8HqFULW4Y3oZjqZsJ5m3kcwDxGNBmFjbht76wY+g/NEtztTrj2pA
yEff+hh77Zbilz+BQsSGc9VRNThryvDGGYss876EidS9RSotYIRABaNJoOY6hSPx7337G3xQxbDn
H79dMilp//ATLH1T8RMfRE8EVO7dGpblVyYFksXVj+uhji3BYFgbHx8JjY5OjBBC4O677941s/u5
PsnMfuTbX3k3L+sp58Sml1/7yNPsXXAdXNueX70FIfhpOMB7XjnPWWmx4RGxZf3LnZ3dqba2pvQH
PvDhzqampvfHYrG+kZGRBpP3vzB37mTiyMGDK977rhE+PT9Xt/dv3zu48nO/PAtXgd2GvMMng3I2
Q6GIgnN844ZXe3q6Eyu7uxc2rFw7q2navW6vHmaOsxMhdKKzs7Mktw2+bGF1bsvG7ayupV62Gbwb
roN3EIx7RcCHcoLBB+I7Y411uY7m9kxzR0fS5wObEIcuLp78vWlKHIAhaYVCVUtLQ+1ionrTyZnE
Z1Y310uEwRhcBzZsWOmXAGxBxVIgci4ej5WjtaGiz43iebDDYbJcLDIL44JFiGBEamvzbp6SFK07
kiiaWBEBDIK6ACF0jdikbhQG8PhkXKWIjs/nNSNK0JCjoqOq9SSX420XSy3xxGNZVBAEN95jSqJg
cRwP1KyA4QD6FcC1YofCsYIBUF+FmFeo3MVxHKOKwkolAEop6+3tpZOTk9SJWYz6/czjOEzGMmXl
VGfcB6SQzQNl7MwvGKPXiDUCW9I60OaAI/hFY0zXdUHTsm7DDCyUy9z8/LzQ19fn/gY4ntewKVi4
omki0QrDDX4iJTNlZliw9YYxtii8ejYHehyVUG8t1EhTz30jnyz5BUvm0o4jWJYlUpqTHPc/lyN8
sVhRJzc/8C5sFFcO1lr4iLtuTAdeukH8p13sVYvAxj1n9eV6msBtUfsLpT3//ubs4mKQUipQWnLF
WERIFzUt79vzwJ8/oCXP/fSd9Tn56KwOUyXO+dNeeP6mO+/HAyjMcXD2fd0oGG1vhKTQQBfzaFJn
ylNUqd3OCCK5xPRKq5x7F9FL/ROxtOzlLHjqBIY9sMJZTBcfOnpm8nM3PYR+MojezGF4YmUMlMFO
jzTrRFiWKFamglGxZDHBrpC4oisbgkv4YArBkSSGXHQ9rH/nJ+Hu+x4imUz2VyfOTP72psfmj9eh
KC/B/xQRxnujoMa8gKI+BNjNk64ApDRgx1Jgz1QExDd2g+DxCIZYD+vW98Ff//E/Yljm586cmX6E
udxw0COXH/TDezgE7xY5GLUpdDEAxCM4r1mwN6XDtpfTfg/Pib+9qzWEI0GPGoh1QWdXN/zz33fb
mrb8trlEYsc1YuRy8bbg3Ee8+CiS+yxf+JfdRwL38SrKap9X+VWwShXqqv1qR89aiMXjcO99D5nJ
bHodD9dzRcxfkrtS4aJUufj1VAyjZNr2XwmlX1nSLK5Q2SMPDg5Bd1eHWK7oH79Zi/FF6SWZdJ1U
uirOjzFEg1WBL0iC0KN4JGbqy9gk9gdvOsYAcFUFV1p+sTL+YhqCCzD3IdFQYJDj8HsA4KFkpvDK
/wGqpIepz2ay4gAAAABJRU5ErkJggg==}

image create photo mate/22x22/actions/go-down -data\
{iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAMAAADzapwJAAACLlBMVEUAAAC3t6+3ubSyta+ztq+t
ra22uLLp6ujo6OavsKuws62oqqOvs6vf4N3Ky8enqaSlraWpraWlqKGmqaKiopmfn5+ipaCeoJqf
oZyUnJSipJ7k5ePj5OGanJabopubn5iZnJaXm5SSmZKbnZeSlY+Dg3yAgX5+gHt8fnp8fHSanZeW
mJORkYqanZjY2tbAwb2TlZGDg3yDhIB2eHSWmZOQk42KioqUlIyVl5KPko2SlI+IiIh8g3yChH5z
dW+Tlo+MjoiDioOAg3xwcW2SkoqPkIyGiIR8fHx+gXtwcm5tbWaLjYeBhH15fHl8gHtvcGxnbmeF
h4Jtb2pqamSAgnxrb2lnZ2d8fHV6fHhqbGdkamR1dXV0eHJoa2VnZ2Bubm5vcWxmaWRkZGQAAAAA
AAA0ODRlamNiZGA2NjIAAAAAAAAAAAAlJSNaXFgkJiQAAAAAAAAAAAAAAAD+/v7y8vD29vTv7+71
9fTm5+Xt7ezu7u3p6ujg4d/u7uz7+/vx8fD5+fjf4Nzs7Orn5+Xw8e/l5eL6+vrv8O/4+PjZ2tbk
5ePCxMDS09Dr7Ong4d75+fnr6+r4+fjX2NTj4+HHyMXP0Mzo6ebb3dnu7+3q6+rU1dHh4d7Gx8PK
ysjk5uLW2NT4+Pd9f3rq6unR083DxMDIycbh4t/S1M/39/b7+/r29/bO0Mrd3tvAwr7ExsLe39zN
z8nr7OrLzce/wb3HycPZ29e9v7u8vLq7vbmbnpp0MP1VAAAAc3RSTlMAIMn5yB/K/v7I+PjI/fzH
H8f4xh4gyfnIH8r+/sghwffBI/j4I8H3wSHA5CXI/fzHJeTA9+QlH8f4xh4l5PfA5CXkwCPk5CXk
5CPk5Erk5CXk5ynk5CUl5OcpJeTkJSXk5ykHG0nq7EwTJztn3moEDxgdI0hG3QAAAR9JREFUGNNj
YIACRiZmFlYGDMDGXszBiSnMVVxSyo0pzMNbxsePKSwgKCQswkAsEBUTl5DEFJaSLpaRReLLySso
KjEwKBeXlKswMKiqqWtogoS1KoortXUYdPWq9A0YDI2qi2uMQcImxbV19aZm5haWVtY2tpUNjU12
IGH75pbWtnYHRyDTxqmyo7Or2xkk7OLa09vX3+5myODuMWHipMlTPL3Adpp5T502feIMH1+/mR2z
Zs/xD4C6xTFw7rz5CyoXLlqwuHFJUDDcjTYhS5ctX7Fy1eo1a0PDkNweHrFu/YaNm6ZvjoxC8WN0
zObpW7Zui41D83t8wvb1OxKT0ESTU1LTdqZnpCSjCmdmZefk5mVnZaIpzy8oLCosyIdxAU8QUY2Y
wZjFAAAAAElFTkSuQmCC
}

image create photo mate/48x48/status/user-offline \
    -data {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
rkJggg==}


image create photo image/mate/48x48/emblems/emblem-downloads.png -file /usr/share/icons/mate/22x22/emblems/emblem-downloads.png

image create photo mate/22x22/status/avatar-default.png -file /usr/share/icons/mate/22x22/status/avatar-default.png
image create photo mate/32x32/status/avatar-default.png -file /usr/share/icons/mate/32x32/status/avatar-default.png

image create photo mate/32x32/status/stock_lock.png -file /usr/share/icons/mate/32x32/status/stock_lock.png

proc xmlconsole {jid} {
    set safe [string map {@ _ . _} $jid]
    set w .xmlconsole-$safe
    if {[winfo exists $w]} {
        wm deiconify $w
        raise $w
        return $w
    }
    toplevel $w
    wm title $w "XML Console — $jid"
    wm geometry $w 600x400
    xmlstream $w.xs -conn [list account $jid]
    pack $w.xs -expand yes -fill both
    return $w
}

