namespace eval ::tacky {}
namespace eval ::tacky::forms {}

if 0 {
    XEP-0004 Data Forms

    == Utility procs (tacky::forms namespace) ==

    tolist: XML form node → flat key-value list

    set formList [tacky::forms::tolist $formNode]
    → Returns a flat list suitable for [array set]:
        fields          → {username password captcha}
        instructions    → "Please fill in..."  (if present)
        field,$var,var      → field variable name
        field,$var,type     → text-single (default), text-private, fixed, ...
        field,$var,label    → human label (falls back to var name)
        field,$var,required → 0 or 1
        field,$var,value    → current value (if present)
        field,$var,media    → cid: content-id (if <media> child present)

    Can also populate an existing array by name (returns nothing):
        tacky::forms::tolist $formNode myArray

    tonode: flat key-value list → XML node dict

    set xmlNode [tacky::forms::tonode $formList]
    → Returns an <x xmlns='jabber:x:data' type='submit'> node dict.
      Fixed fields are skipped. Fields with values get <value> children.
    → Use with [j /as-is $xmlNode] to embed in a stanza.

    restore: merge old values into a refetched form

    set merged [tacky::forms::restore $oldList $newList]
    → Copies field values from oldList into newList for fields that:
      - exist in both (by var name)
      - don't already have a value in newList
      - have a value in oldList
    → Use case: preserve user input when the server resends the form.

    == formctrl (snit::type) ==

    OOP wrapper around the flat form data. Owns the form fields and
    stores media data (e.g. CAPTCHA images via XEP-0158) as raw bytes.

    set form [formctrl $name $formList]
    $form fields              → list of field var names
    $form instructions        → instructions text or ""
    $form field $var $key     → value of field,$var,$key
    $form hasField $var $key  → whether field,$var,$key exists
    $form setValue $var $val  → set field,$var,value
    $form setMedia $var $data → store raw media bytes for $var
    $form media $var          → raw bytes or ""
    $form mediaFields         → {cid varName ...}
    $form tonode              → XML submit node
    $form restore $oldForm    → merge old values
    $form dump                → raw array-get list
}

# --- Utility procs ---

# Converts xml form version into more tcl-friendly, flat array format
proc ::tacky::forms::tolist {formNode {formarray ""}} {
    if {$formarray ne ""} {
	upvar $formarray form
    }

    if {[xsearch $formNode instructions] ne ""} {
	set form(instructions) [xsearch $formNode instructions -get body]
    }

    foreach fieldNode [xsearch $formNode field] {
	set formVar [dict get $fieldNode attrs var]
	lappend form(fields) $formVar
	set pref field,$formVar
	set form($pref,type) text-single
	foreach k {var type label} {
	    if {[dict exists $fieldNode attrs $k]} {
		set form($pref,$k) [dict get $fieldNode attrs $k]
	    }
	}
	# If no label supplied, display var name
	if {![info exists form($pref,label)]} {
	    set form($pref,label) $form($pref,var)
	}
	set form($pref,required) [expr {[xsearch $fieldNode required] ne ""}]
	if {[xsearch $fieldNode value] ne ""} {
	    if {$form($pref,type) eq "list-multi" || $form($pref,type) eq "jid-multi" || $form($pref,type) eq "text-multi"} {
		# Collect all <value> children for multi-value types
		set vals {}
		xsearch $fieldNode value -script vnode {
		    lappend vals [xsearch $vnode -get body]
		}
		set form($pref,value) $vals
	    } else {
		set form($pref,value) [xsearch $fieldNode value -get body]
	    }
	}
	# Parse <option> children (for list-single and list-multi)
	set optionNodes [xsearch $fieldNode option]
	if {[llength $optionNodes] > 0} {
	    set opts {}
	    foreach optNode $optionNodes {
		set optLabel [xsearch $optNode -get @label]
		set optValue [xsearch $optNode value -get body]
		if {$optLabel eq ""} {
		    set optLabel $optValue
		}
		lappend opts [list label $optLabel value $optValue]
	    }
	    set form($pref,options) $opts
	}
	if {[set media [xsearch $fieldNode media -get node]] ne ""} {
	    set uri [string trim [xsearch $media uri -get body]]
	    regexp (.*):(.*) $uri -> uriPrefix uriBody
	    if {$uriPrefix ne "cid"} {
		error "Unknown uri: $uri"
	    }
	    set form($pref,media) $uriBody
	}
    }
    if {$formarray eq ""} {
	array get form
    }
}

# Converts from our own tcl array format to xml
proc ::tacky::forms::tonode {list} {
    array set form $list

    j x -ns jabber:x:data -type submit {
	foreach f $form(fields) {
	    if {$form(field,$f,type) eq "fixed"} {
		continue
	    }
	    j field \
		-type $form(field,$f,type) \
		-var $f {
		    if {[info exists form(field,$f,value)]} {
			set ftype $form(field,$f,type)
			if {$ftype in {list-multi jid-multi text-multi}} {
			    foreach v $form(field,$f,value) {
				j value .body $v
			    }
			} else {
			    j value .body $form(field,$f,value)
			}
		    }
		}
	}
    }
}

proc ::tacky::forms::restore {oldlist newlist} {
    # give me lists as received from ::tacky::forms::tolist
    # I'll return newlist with values from oldlist, unless newlist
    # specifies a value already
    # This is to preserve user input even when form is refetched

    array set old $oldlist
    array set new $newlist

    foreach f $old(fields) {
	if {![info exists new(field,$f,var)]
	    || [info exists new(field,$f,value)]
	    || ![info exists old(field,$f,value)]} {
	    continue
	}
	set new(field,$f,value) $old(field,$f,value)
    }

    array get new
}

# --- formctrl snit type ---

snit::type formctrl {
    variable FormData -array {}
    variable MediaCids -array {}
    variable MediaData -array {}

    constructor {formList args} {
	array set FormData $formList
	foreach var $FormData(fields) {
	    if {[info exists FormData(field,$var,media)]} {
		set MediaCids($var) $FormData(field,$var,media)
	    }
	}
    }

    method fields {} { return $FormData(fields) }

    method instructions {} {
	if {[info exists FormData(instructions)]} { return $FormData(instructions) }
	return ""
    }

    method field {var key} { return $FormData(field,$var,$key) }

    method hasField {var key} { return [info exists FormData(field,$var,$key)] }

    method options {var} {
	if {[info exists FormData(field,$var,options)]} {
	    return $FormData(field,$var,options)
	}
	return {}
    }

    method setValue {var value} { set FormData(field,$var,value) $value }

    method setMedia {var data} { set MediaData($var) $data }

    method media {var} {
	if {[info exists MediaData($var)]} { return $MediaData($var) }
	return ""
    }

    method mediaFields {} {
	set result {}
	foreach {var cid} [array get MediaCids] {
	    lappend result $cid $var
	}
	return $result
    }

    method tonode {} {
	::tacky::forms::tonode [array get FormData]
    }

    method restore {oldForm} {
	array set FormData [::tacky::forms::restore [$oldForm dump] [array get FormData]]
    }

    method dump {} { array get FormData }
}
