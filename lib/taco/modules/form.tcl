namespace eval ::tacky {}
namespace eval ::tacky::forms {}

# XEP-0004 data forms as plain dicts. A form has a type (form/submit/cancel/
# result), optional title and instructions, and a fields list. Each field is a
# dict of var, type, label, required, and value (always a list of strings, so
# single and multi-value fields read the same), plus optional options and media.
# The media dict is just a {cid type} reference; the byte payload lives with
# whoever owns the form, not in here.

# XML <x jabber:x:data> node -> form dict.
proc ::tacky::forms::parse {formNode} {
    set type [xsearch $formNode -get @type]
    if {$type eq ""} {
        set type form
    }
    set form [dict create type $type fields {}]

    set title [xsearch $formNode title -get body]
    if {$title ne ""} {
        dict set form title $title
    }
    if {[xsearch $formNode instructions] ne ""} {
        dict set form instructions [xsearch $formNode instructions -get body]
    }

    set fields {}
    set fixedCounter 0
    foreach fieldNode [xsearch $formNode field] {
        if {[dict exists $fieldNode attrs var]} {
            set var [dict get $fieldNode attrs var]
        } else {
            # var is optional for fixed fields; synthesise an internal key
            set var _fixed[incr fixedCounter]
        }

        set field [dict create var $var type text-single]
        foreach k {type label} {
            if {[dict exists $fieldNode attrs $k]} {
                dict set field $k [dict get $fieldNode attrs $k]
            }
        }
        if {![dict exists $field label]} {
            dict set field label $var
        }
        dict set field required [expr {[xsearch $fieldNode required] ne ""}]

        # Values are always a list, one element per <value> child.
        set vals {}
        xsearch $fieldNode value -script vnode {
            lappend vals [xsearch $vnode -get body]
        }
        dict set field value $vals

        # Options (list-single / list-multi)
        set opts {}
        foreach optNode [xsearch $fieldNode option] {
            set optLabel [xsearch $optNode -get @label]
            set optValue [xsearch $optNode value -get body]
            if {$optLabel eq ""} {
                set optLabel $optValue
            }
            lappend opts [dict create label $optLabel value $optValue]
        }
        if {[llength $opts] > 0} {
            dict set field options $opts
        }

        # Media (XEP-0158): a cid: uri referencing an inline BOB payload
        if {[set media [xsearch $fieldNode media -get node]] ne ""} {
            set uri [string trim [xsearch $media uri -get body]]
            regexp {(.*):(.*)} $uri -> uriPrefix uriBody
            if {$uriPrefix ne "cid"} {
                error "Unknown uri: $uri"
            }
            dict set field media [dict create \
                cid $uriBody \
                type [xsearch $media uri -get @type]]
        }

        lappend fields $field
    }
    dict set form fields $fields
    return $form
}

# form dict -> a bare submit <x> node; the caller adds the <query> wrapper.
# Fixed fields are dropped, hidden ones kept so FORM_TYPE round-trips.
proc ::tacky::forms::serialize {form} {
    set type [expr {[dict exists $form type] ? [dict get $form type] : "submit"}]
    if {$type eq "form"} {
        set type submit
    }
    j x -ns jabber:x:data -type $type {
        foreach field [dict get $form fields] {
            if {[dict get $field type] eq "fixed"} {
                continue
            }
            j field -type [dict get $field type] -var [dict get $field var] {
                foreach v [dict get $field value] {
                    j value .body $v
                }
            }
        }
    }
}

# Fill field values from a {var value ...} map and mark the form submit.
# Multi-value types take the input as a list; others keep it as one value.
proc ::tacky::forms::apply {form values} {
    dict set form type submit
    set fields {}
    foreach field [dict get $form fields] {
        set var [dict get $field var]
        if {[dict exists $values $var]} {
            set raw [dict get $values $var]
            if {[dict get $field type] in {list-multi jid-multi text-multi}} {
                dict set field value $raw
            } else {
                dict set field value [list $raw]
            }
        }
        lappend fields $field
    }
    dict set form fields $fields
    return $form
}

# Copy field values from an old form into a refetched one, but only for fields
# that have no value yet in the new form. Preserves user input across a resend.
proc ::tacky::forms::restore {old new} {
    set oldvals {}
    foreach field [dict get $old fields] {
        if {[llength [dict get $field value]] > 0} {
            dict set oldvals [dict get $field var] [dict get $field value]
        }
    }
    set fields {}
    foreach field [dict get $new fields] {
        set var [dict get $field var]
        if {[llength [dict get $field value]] == 0 && [dict exists $oldvals $var]} {
            dict set field value [dict get $oldvals $var]
        }
        lappend fields $field
    }
    dict set new fields $fields
    return $new
}

# {cid var ...} lookup of the fields carrying media, for BOB payload matching.
proc ::tacky::forms::mediaMap {form} {
    set result {}
    foreach field [dict get $form fields] {
        if {[dict exists $field media]} {
            lappend result [dict get $field media cid] [dict get $field var]
        }
    }
    return $result
}
