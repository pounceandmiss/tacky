# XEP-0393 Message Styling parser
#
# Public procs:
#   messagestyling::parse body -> dict {display_body $str entities $flatList}
#   messagestyling::enrich msgDict -> msgDict with body replaced by display_body
#                                     and formatting key added
#
# Entities are {type offset length} triples with offsets into display_body.
# Compound types are sorted alphabetically and joined with "." (e.g. bold.italic).

namespace eval messagestyling {
    namespace export parse enrich
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
    set displayOffset 0
    set i 0

    while {$i < $numLines} {
	set line [lindex $lines $i]

	# --- Preformatted block ---
	if {[string match "```*" $line]} {
	    # Look for closing fence
	    set closeIdx -1
	    for {set j [expr {$i + 1}]} {$j < $numLines} {incr j} {
		if {[string match "```*" [lindex $lines $j]]} {
		    set closeIdx $j
		    break
		}
	    }
	    if {$closeIdx != -1} {
		# Collect inner lines
		set inner {}
		for {set k [expr {$i + 1}]} {$k < $closeIdx} {incr k} {
		    lappend inner [lindex $lines $k]
		}
		set content [join $inner \n]
		if {[llength $displayParts] > 0} {
		    append displayOffset 0 ;# no-op, just for clarity
		    set displayOffset [string length [join $displayParts \n]]
		    incr displayOffset 1 ;# for the \n separator
		}
		lappend displayParts $content
		set partStart [expr {[string length [join $displayParts \n]] - [string length $content]}]
		lappend allEntities preformatted $partStart [string length $content]
		set i [expr {$closeIdx + 1}]
		continue
	    }
	    # Unclosed fence: treat opening line as literal plain text
	    lappend displayParts $line
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
	    # Recalculate display offset
	    if {[llength $displayParts] > 0} {
		set displayOffset [expr {[string length [join $displayParts \n]] + 1}]
	    } else {
		set displayOffset 0
	    }
	    # Parse spans within quoted text
	    set parsed [ParseSpansInText $quoteText $displayOffset]
	    lappend displayParts [dict get $parsed display]
	    set qLen [string length [dict get $parsed display]]
	    lappend allEntities quote $displayOffset $qLen
	    foreach {t o l} [dict get $parsed entities] {
		lappend allEntities $t $o $l
	    }
	    continue
	}

	# --- Plain line: parse spans ---
	if {[llength $displayParts] > 0} {
	    set displayOffset [expr {[string length [join $displayParts \n]] + 1}]
	} else {
	    set displayOffset 0
	}
	set parsed [ParseSpansInText $line $displayOffset]
	lappend displayParts [dict get $parsed display]
	foreach {t o l} [dict get $parsed entities] {
	    lappend allEntities $t $o $l
	}
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
    dict set msg body [dict get $parsed display_body]
    set entities [dict get $parsed entities]
    if {[llength $entities] > 0} {
	dict set msg formatting $entities
    }
    return $msg
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

	set resolved [ResolveEntities $dSpans $lineOffset]
	foreach {t o l} $resolved {
	    lappend entities $t $o $l
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
			# Empty span — not valid
			break
		    }
		    lappend completed [list $type $openIdx $i]
		    # Remove matched entry and all entries after it (stranded)
		    set stack [lrange $stack 0 [expr {$s - 1}]]
		    set closed 1
		    break
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
		    } else {
			# Check if previous char is an opening delimiter that
			# is on the stack (adjacent opener)
			set prevCh [string index $line [expr {$i - 1}]]
			if {($prevCh eq "*" || $prevCh eq "_" || $prevCh eq "~" || $prevCh eq "`")} {
			    # Check if there's a stack entry for position i-1
			    foreach entry $stack {
				if {[lindex $entry 1] == $i - 1} {
				    set canOpen 1
				    break
				}
			    }
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
    # Collect all delimiter positions to skip
    set skipSet {}
    foreach span $spans {
	lassign $span type openIdx closeIdx
	dict set skipSet $openIdx 1
	dict set skipSet $closeIdx 1
    }

    # Build display string and input→display offset map
    set display ""
    set mapInputToDisplay {}
    set dIdx 0
    set len [string length $line]
    for {set i 0} {$i < $len} {incr i} {
	if {[dict exists $skipSet $i]} {
	    dict set mapInputToDisplay $i -1
	} else {
	    append display [string index $line $i]
	    dict set mapInputToDisplay $i $dIdx
	    incr dIdx
	}
    }

    # Convert spans to display coordinates
    # For open: display position is the first non-skipped char after openIdx
    # For close: display position is the last non-skipped char before closeIdx
    set displaySpans {}
    foreach span $spans {
	lassign $span type openIdx closeIdx
	# Display start = first non-skipped position after opener
	set dStart -1
	for {set p [expr {$openIdx + 1}]} {$p < $closeIdx} {incr p} {
	    if {[dict get $mapInputToDisplay $p] >= 0} {
		set dStart [dict get $mapInputToDisplay $p]
		break
	    }
	}
	# Display end = position after last non-skipped char before closer
	set dEnd -1
	for {set p [expr {$closeIdx - 1}]} {$p > $openIdx} {incr p -1} {
	    if {[dict get $mapInputToDisplay $p] >= 0} {
		set dEnd [expr {[dict get $mapInputToDisplay $p] + 1}]
		break
	    }
	}
	if {$dStart >= 0 && $dEnd > $dStart} {
	    lappend displaySpans [list $type $dStart $dEnd]
	}
    }

    return [dict create display $display spans $displaySpans]
}

# ResolveEntities: convert potentially overlapping spans into non-overlapping
# entities with compound type names.
# Input: list of {type displayStart displayEnd}, baseOffset for global positioning
# Returns flat list: type offset length type offset length ...
proc messagestyling::ResolveEntities {displaySpans baseOffset} {
    if {[llength $displaySpans] == 0} {
	return {}
    }

    # Collect all boundary points
    set boundaries {}
    foreach span $displaySpans {
	lassign $span type dStart dEnd
	lappend boundaries $dStart
	lappend boundaries $dEnd
    }
    set boundaries [lsort -integer -unique $boundaries]

    # For each interval between consecutive boundaries, find active types
    set result {}
    set numBounds [llength $boundaries]
    for {set b 0} {$b < $numBounds - 1} {incr b} {
	set iStart [lindex $boundaries $b]
	set iEnd [lindex $boundaries [expr {$b + 1}]]

	# Find all types active in this interval
	set activeTypes {}
	foreach span $displaySpans {
	    lassign $span type dStart dEnd
	    if {$dStart <= $iStart && $dEnd >= $iEnd} {
		lappend activeTypes $type
	    }
	}

	if {[llength $activeTypes] > 0} {
	    set activeTypes [lsort -unique $activeTypes]
	    set compoundType [join $activeTypes .]
	    set offset [expr {$baseOffset + $iStart}]
	    set length [expr {$iEnd - $iStart}]
	    lappend result $compoundType $offset $length
	}
    }

    # Merge adjacent entities with the same type
    set merged {}
    set prevType ""
    set prevOffset 0
    set prevLength 0
    foreach {type offset length} $result {
	if {$type eq $prevType && $offset == $prevOffset + $prevLength} {
	    set prevLength [expr {$prevLength + $length}]
	} else {
	    if {$prevType ne ""} {
		lappend merged $prevType $prevOffset $prevLength
	    }
	    set prevType $type
	    set prevOffset $offset
	    set prevLength $length
	}
    }
    if {$prevType ne ""} {
	lappend merged $prevType $prevOffset $prevLength
    }

    return $merged
}
