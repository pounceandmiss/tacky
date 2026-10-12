# XEP-0393 Message Styling parser
#
# Public procs:
#   messagestyling::parse body -> dict {display_body $str entities $flatList}
#   messagestyling::links display entities -> flat {link offset length ...}
#   messagestyling::enrich msgDict -> msgDict with body replaced by display_body
#                                     and formatting key added
#
# Entities are {type offset length} triples with offsets into display_body.
# Each entity has a single type; overlapping styles are emitted as separate
# overlapping entities, and the renderer combines them.
#
# Links are not XEP-0393: nothing on the wire marks them, every client finds
# them in the text. Finding them here gives each frontend the same answer, in
# the same offsets as the styling.

namespace eval messagestyling {
    namespace export parse links enrich
}

proc messagestyling::parse {body} {
    # Fast path: no styling characters at all
    if {![regexp {[*_~`>]} $body]} {
        return [dict create display_body $body entities {}]
    }

    set lines [split $body \n]
    set numLines [llength $lines]
    set displayParts {}
    set allEntities {}
    # Start offset of the next part; joining displayParts to get it is quadratic
    set displayOffset 0
    # A fence scan that hits the end rules out a close for every later line too
    set noMoreFences 0
    set i 0

    while {$i < $numLines} {
        set line [lindex $lines $i]

        # --- Preformatted block ---
        if {[string match "```*" $line]} {
            # Look for closing fence
            set closeIdx -1
            if {!$noMoreFences} {
                for {set j [expr {$i + 1}]} {$j < $numLines} {incr j} {
                    if {[string match "```*" [lindex $lines $j]]} {
                        set closeIdx $j
                        break
                    }
                }
                if {$closeIdx == -1} {
                    set noMoreFences 1
                }
            }
            if {$closeIdx != -1} {
                set content [join [lrange $lines [expr {$i + 1}] [expr {$closeIdx - 1}]] \n]
                lappend displayParts $content
                lappend allEntities preformatted $displayOffset [string length $content]
                incr displayOffset [expr {[string length $content] + 1}]
                set i [expr {$closeIdx + 1}]
                continue
            }
            # Unclosed fence: treat opening line as literal plain text
            lappend displayParts $line
            incr displayOffset [expr {[string length $line] + 1}]
            incr i
            continue
        }

        # --- Block quote ---
        if {[regexp {^> } $line]} {
            set quoteLines {}
            while {$i < $numLines && [regexp {^> (.*)} [lindex $lines $i] -> stripped]} {
                lappend quoteLines "> $stripped"
                incr i
            }
            set quoteText [join $quoteLines \n]
            # Parse spans within quoted text
            set parsed [ParseSpansInText $quoteText $displayOffset]
            set qDisplay [dict get $parsed display]
            lappend displayParts $qDisplay
            lappend allEntities quote $displayOffset [string length $qDisplay]
            foreach {t o l} [dict get $parsed entities] {
                lappend allEntities $t $o $l
            }
            incr displayOffset [expr {[string length $qDisplay] + 1}]
            continue
        }

        # --- Plain line: parse spans ---
        set parsed [ParseSpansInText $line $displayOffset]
        set dLine [dict get $parsed display]
        lappend displayParts $dLine
        foreach {t o l} [dict get $parsed entities] {
            lappend allEntities $t $o $l
        }
        incr displayOffset [expr {[string length $dLine] + 1}]
        incr i
    }

    set displayBody [join $displayParts \n]
    return [dict create display_body $displayBody entities $allEntities]
}

proc messagestyling::enrich {msg} {
    if {![dict exists $msg body] || [dict get $msg body] eq ""} {
        return $msg
    }
    set parsed [parse [dict get $msg body]]
    set display [dict get $parsed display_body]
    dict set msg body $display
    set entities [dict get $parsed entities]
    # Outside parse, whose fast path skips a body with no styling characters -
    # which is most bodies that are only a link.
    lappend entities {*}[links $display $entities]
    if {[llength $entities] > 0} {
        dict set msg formatting $entities
    }
    return $msg
}

# Only schemes a sender writes out in full and that open something harmless.
# A bare "www." stays text, so the covered text is always the target and the
# span needs no href of its own. `entities` are the styling spans over the
# same text: a link inside code is quoted, not something to follow.
proc messagestyling::links {display entities} {
    if {![regexp -nocase {https?://|mailto:|geo:} $display]} {
        return {}
    }
    set code {}
    foreach {t o l} $entities {
        if {$t in {monospace preformatted}} {
            lappend code $o [expr {$o + $l}]
        }
    }
    set out {}
    foreach range [regexp -all -inline -indices -nocase \
            {\m(?:https?://|mailto:|geo:)[^\s<>"]+} $display] {
        lassign $range start last
        set url [string range $display $start $last]
        regexp -nocase {^(?:https?://|mailto:|geo:)} $url scheme
        set url [TrimLinkTail $url]
        if {[string length $url] <= [string length $scheme]} {
            continue
        }
        set end [expr {$start + [string length $url]}]
        set inCode 0
        foreach {cs ce} $code {
            if {$start < $ce && $end > $cs} {
                set inCode 1
                break
            }
        }
        if {!$inCode} {
            lappend out link $start [expr {$end - $start}]
        }
    }
    return $out
}

# Punctuation that ends the sentence rather than the link, and a closing
# bracket the link never opened: "(see https://example.com/a)" leaves the
# paren out, "https://example.com/a_(b)" keeps it.
proc messagestyling::TrimLinkTail {url} {
    set pairs [dict create ) ( \] \[ \} \{]
    while {$url ne ""} {
        set ch [string index $url end]
        if {$ch in {. , ; : ! ? ' *}} {
            set url [string range $url 0 end-1]
            continue
        }
        if {[dict exists $pairs $ch]} {
            # split yields one more piece than there are separators.
            set opens [llength [split $url [dict get $pairs $ch]]]
            set closes [llength [split $url $ch]]
            if {$closes > $opens} {
                set url [string range $url 0 end-1]
                continue
            }
        }
        break
    }
    return $url
}

# Parse spans in a (possibly multi-line) text block.
# Returns dict {display $str entities $list}
proc messagestyling::ParseSpansInText {text baseOffset} {
    set lines [split $text \n]
    set displayLines {}
    set entities {}
    set lineOffset $baseOffset

    foreach line $lines {
        set spans [FindSpans $line]
        set built [BuildDisplay $line $spans]
        set dLine [dict get $built display]
        set dSpans [dict get $built spans]
        lappend displayLines $dLine

        foreach span $dSpans {
            lassign $span type dStart dEnd
            lappend entities $type [expr {$lineOffset + $dStart}] [expr {$dEnd - $dStart}]
        }
        set lineOffset [expr {$lineOffset + [string length $dLine] + 1}]
    }

    return [dict create display [join $displayLines \n] entities $entities]
}

# FindSpans: stack-based left-to-right scan of a line.
# Returns list of {type inputOpenIdx inputCloseIdx} where indices point
# to the first and last character of the delimiter in the input string.
proc messagestyling::FindSpans {line} {
    set len [string length $line]
    set stack {}
    # Unmatched openers per type, so a delimiter with none skips the stack scan
    set openCounts {}
    set completed {}
    set i 0
    set inMono 0

    while {$i < $len} {
        set ch [string index $line $i]

        # Check if this is a delimiter character
        if {$ch eq "*" || $ch eq "_" || $ch eq "~" || $ch eq "`"} {
            set type [DelimType $ch]

            if {$inMono} {
                # Inside monospace: only backtick can close
                if {$ch eq "`"} {
                    # Find the matching open on stack
                    set found -1
                    for {set s [expr {[llength $stack] - 1}]} {$s >= 0} {incr s -1} {
                        if {[lindex [lindex $stack $s] 0] eq "monospace"} {
                            set found $s
                            break
                        }
                    }
                    if {$found >= 0} {
                        set openEntry [lindex $stack $found]
                        set openIdx [lindex $openEntry 1]
                        # Content between delimiters must be non-empty
                        if {$i > $openIdx + 1} {
                            lappend completed [list monospace $openIdx $i]
                            # Remove matched entry and everything after it
                            foreach e [lrange $stack $found end] {
                                dict incr openCounts [lindex $e 0] -1
                            }
                            set stack [lrange $stack 0 [expr {$found - 1}]]
                            set inMono 0
                        }
                    }
                }
                incr i
                continue
            }

            # Try to close: find topmost unmatched open of same type
            set closed 0
            if {[dict exists $openCounts $type] && [dict get $openCounts $type] > 0} {
                for {set s [expr {[llength $stack] - 1}]} {$s >= 0} {incr s -1} {
                    set entry [lindex $stack $s]
                    if {[lindex $entry 0] eq $type} {
                        set openIdx [lindex $entry 1]
                        # Closing rules: NOT preceded by whitespace, must have content
                        set prevChar [string index $line [expr {$i - 1}]]
                        if {[string is space $prevChar]} {
                            break
                        }
                        if {$i <= $openIdx + 1} {
                            # Empty span - not valid
                            break
                        }
                        lappend completed [list $type $openIdx $i]
                        # Remove matched entry and all entries after it (stranded)
                        foreach e [lrange $stack $s end] {
                            dict incr openCounts [lindex $e 0] -1
                        }
                        set stack [lrange $stack 0 [expr {$s - 1}]]
                        set closed 1
                        break
                    }
                }
            }

            if {!$closed} {
                # Try to open
                # Opening rules: at line start, after whitespace, or after
                # another stacked opening directive. NOT followed by whitespace.
                set canOpen 0
                if {$i == 0} {
                    set canOpen 1
                } else {
                    set prevChar [string index $line [expr {$i - 1}]]
                    if {[string is space $prevChar]} {
                        set canOpen 1
                    } elseif {$prevChar eq "*" || $prevChar eq "_"
                              || $prevChar eq "~" || $prevChar eq "`"} {
                        # Stack positions only increase, so an opener at i-1
                        # can only be the top entry.
                        set top [lindex $stack end]
                        if {[llength $top] && [lindex $top 1] == $i - 1} {
                            set canOpen 1
                        }
                    }
                }

                if {$canOpen} {
                    # NOT followed by whitespace
                    set nextIdx [expr {$i + 1}]
                    if {$nextIdx < $len} {
                        set nextChar [string index $line $nextIdx]
                        if {![string is space $nextChar]} {
                            lappend stack [list $type $i]
                            dict incr openCounts $type
                            if {$type eq "monospace"} {
                                set inMono 1
                            }
                        }
                    } elseif {$nextIdx == $len} {
                        # Delimiter at end of line can't open (nothing follows)
                    }
                }
            }
        }
        incr i
    }

    return $completed
}

proc messagestyling::DelimType {ch} {
    switch -- $ch {
        "*" { return bold }
        "_" { return italic }
        "~" { return overstrike }
        "`" { return monospace }
    }
}

# BuildDisplay: given the input line and list of {type openIdx closeIdx} spans,
# produce display string (delimiters stripped) and display-offset spans.
# Returns dict {display $str spans {list of {type displayStart displayEnd}}}
proc messagestyling::BuildDisplay {line spans} {
    set len [string length $line]

    # Collect all delimiter positions to skip
    set skip [lrepeat $len 0]
    foreach span $spans {
        lassign $span type openIdx closeIdx
        lset skip $openIdx 1
        lset skip $closeIdx 1
    }

    # Build display string and input -> display offset map (-1 for delimiters)
    set display ""
    set map [lrepeat $len -1]
    set dIdx 0
    for {set i 0} {$i < $len} {incr i} {
        if {![lindex $skip $i]} {
            append display [string index $line $i]
            lset map $i $dIdx
            incr dIdx
        }
    }

    # Nearest kept position at or after / at or before each index, so a span
    # converts to display coordinates without scanning its delimiter run
    set nextKept [lrepeat [expr {$len + 1}] -1]
    for {set i [expr {$len - 1}]} {$i >= 0} {incr i -1} {
        if {[lindex $map $i] >= 0} {
            lset nextKept $i $i
        } else {
            lset nextKept $i [lindex $nextKept [expr {$i + 1}]]
        }
    }
    set prevKept [lrepeat $len -1]
    set last -1
    for {set i 0} {$i < $len} {incr i} {
        if {[lindex $map $i] >= 0} {
            set last $i
        }
        lset prevKept $i $last
    }

    # Convert spans to display coordinates
    # For open: display position is the first non-skipped char after openIdx
    # For close: display position is the last non-skipped char before closeIdx
    set displaySpans {}
    foreach span $spans {
        lassign $span type openIdx closeIdx
        set dStart -1
        set p [lindex $nextKept [expr {$openIdx + 1}]]
        if {$p >= 0 && $p < $closeIdx} {
            set dStart [lindex $map $p]
        }
        set dEnd -1
        set p [lindex $prevKept [expr {$closeIdx - 1}]]
        if {$p >= 0 && $p > $openIdx} {
            set dEnd [expr {[lindex $map $p] + 1}]
        }
        if {$dStart >= 0 && $dEnd > $dStart} {
            lappend displaySpans [list $type $dStart $dEnd]
        }
    }

    return [dict create display $display spans $displaySpans]
}
