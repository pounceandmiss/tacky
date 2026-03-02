#!/usr/bin/env tclsh
# xsearch - XML Node Search and Filter Function
# 
# Work with nodes as dicts:
# {tag name body text tail text children {list} ns {} attrs {key val ...}}

# package require Tcl 8.6

# Main xsearch implementation
# Usage: xsearch node ?filter ...? ?-gather fields? ?-get fields? ?-script varName body?

if 0 {
    # Get all id attrs
    xsearch $xml level1 -gather @id

    # Get first level1's id attr  
    xsearch $xml level1 -get @id

    # Find level1 tags where id="a"
    xsearch $xml level1 @id a -get tag

    # Get all nested level2 bodies
    xsearch $xml level1 level2 -gather body

    # Process each node
    xsearch $xml level1 -script node {
	puts [dict get $node attrs id]
    }

    # Filter then navigate
    xsearch $xml * @id a level2 @name first -get body
} 
proc xsearch {node args} {
    set results [list $node]
    set gatherFields {}
    set getFields {}
    set scriptBody {}
    set varName {}
    
    set i 0
    while {$i < [llength $args]} {
        set arg [lindex $args $i]
        
        # Handle options
        if {$arg eq "-gather"} {
            incr i
            set gatherFields [lindex $args $i]
            incr i
            continue
        } elseif {$arg eq "-get"} {
            incr i
            set getFields [lindex $args $i]
            incr i
            continue
        } elseif {$arg eq "-script"} {
            incr i
            set varName [lindex $args $i]
            incr i
            set scriptBody [lindex $args $i]
            incr i
            continue
        }

        # Check if this is a field value filter (-field value)
        # Known filterable fields: body, ns, tag, tail
        if {[regexp {^-(body|ns|tag|tail)$} $arg -> fieldName]} {
            if {($i + 1) < [llength $args]} {
                set nextArg [lindex $args [expr {$i + 1}]]
                # Value can be anything including strings starting with -
                set results [filterByField $results $fieldName $nextArg]
                incr i 2
                continue
            }
        }

        # Check if this is an attribute value filter (@attr value)
        # This happens when current arg is @attr and next arg is the value
        if {[string match "@*" $arg] && ($i + 1) < [llength $args]} {
            set nextArg [lindex $args [expr {$i + 1}]]
            # Check if next arg is NOT an option (doesn't start with -)
            if {![string match "-*" $nextArg]} {
                # This is an attribute value filter
                set attrName [string range $arg 1 end]
                set attrValue $nextArg
                set results [filterByAttrValue $results $attrName $attrValue]
                incr i 2
                continue
            }
        }
        
        # Apply normal filter (tag name, position, wildcard, or attribute existence)
        set results [applyFilter $results $arg]
        incr i
    }
    
    # Handle -script option
    if {$scriptBody ne ""} {
        foreach result $results {
            uplevel 1 [list set $varName $result]
            uplevel 1 $scriptBody
        }
        return
    }
    
    # Handle -gather option
    if {$gatherFields ne ""} {
        set gathered {}
        foreach result $results {
            lappend gathered [extractFields $result $gatherFields]
        }
        return $gathered
    }
    
    # Handle -get option
    if {$getFields ne ""} {
        if {[llength $results] > 0} {
            return [extractFields [lindex $results 0] $getFields]
        }
        return {}
    }
    
    # Return results as-is
    return $results
}

# Apply a single filter to a list of nodes
# Returns a list of nodes that match the filter
proc applyFilter {nodes filter} {
    set newResults {}
    
    # Check if filter is a number (position filter)
    if {[string is integer -strict $filter]} {
        foreach node $nodes {
            set children [dict get $node children]
            if {$filter >= 0 && $filter < [llength $children]} {
                lappend newResults [lindex $children $filter]
            }
        }
        return $newResults
    }
    
    # Check if filter is an attribute filter (@attr) - just existence check
    # This is used when we want to filter nodes that have a specific attribute
    if {[string match "@*" $filter]} {
        set attrName [string range $filter 1 end]
        return [filterByAttr $nodes $attrName]
    }
    
    # Check if filter is a tag name or wildcard
    if {$filter eq "*"} {
        # Match any tag - return all children
        foreach node $nodes {
            set children [dict get $node children]
            foreach child $children {
                lappend newResults $child
            }
        }
        return $newResults
    }
    
    # Tag name filter - search in children
    foreach node $nodes {
        set children [dict get $node children]
        foreach child $children {
            if {[dict get $child tag] eq $filter} {
                lappend newResults $child
            }
        }
    }
    return $newResults
}

# Filter nodes by attribute existence
proc filterByAttr {nodes attrName} {
    set filtered {}
    foreach node $nodes {
        set attrs [dict get $node attrs]
        if {[dict exists $attrs $attrName]} {
            lappend filtered $node
        }
    }
    return $filtered
}

# Filter nodes by attribute value
proc filterByAttrValue {nodes attrName attrValue} {
    set filtered {}
    foreach node $nodes {
        set attrs [dict get $node attrs]
        if {[dict exists $attrs $attrName]} {
            if {[dict get $attrs $attrName] eq $attrValue} {
                lappend filtered $node
            }
        }
    }
    return $filtered
}

# Filter nodes by field value (body, ns, tag, tail)
proc filterByField {nodes fieldName fieldValue} {
    set filtered {}
    foreach node $nodes {
        if {[dict exists $node $fieldName]} {
            if {[dict get $node $fieldName] eq $fieldValue} {
                lappend filtered $node
            }
        }
    }
    return $filtered
}

# Extract field values from a node
proc extractFields {node fields} {
    # Handle list of fields
    if {[llength $fields] > 1} {
        set values {}
        foreach field $fields {
            lappend values [extractSingleField $node $field]
        }
        return $values
    }
    
    # Single field
    return [extractSingleField $node $fields]
}

# Extract a single field value from a node
proc extractSingleField {node field} {
    switch -glob $field {
        "@*" {
	    # Check if field is an attribute (@attr)
            set attrName [string range $field 1 end]
            set attrs [dict get $node attrs]
            if {[dict exists $attrs $attrName]} {
                return [dict get $attrs $attrName]
            }
            return {}
        }
        "node" {
	    # Return the whole node if field is "node"
            return $node
        }
        * {
	    # Regular field from node dict
            if {[dict exists $node $field]} {
                return [dict get $node $field]
            }
            return {}
        }
    }
}
