package require snit

# rowlist - the ordered set of drawn message rows. No Tk: this is the data
# model a view sits on top of, kept separate so the identity and ordering rules
# can be reasoned about (and tested) without a display.
#
# A row is a dict with three fields this type owns:
#
#   slot   an integer handed out by this type, unique for its lifetime and
#          never reused. The view uses it wherever it needs a name that is
#          safe to interpolate - a Tk tag, a mark, a widget path - because a
#          key may contain dots, spaces or anything else.
#   key    the caller's identity. Opaque here: compared, never parsed, never
#          required to be unique beyond what the caller guarantees.
#   sort   what the list is ordered by, ascending; ties break on `key`.
#
# Any other fields the caller passes to `insert` are carried along untouched.
snit::type rowlist {
    variable Rows {}
    variable NextSlot 0

    # Does a row sort after another? Ties break on the key, so the order is
    # total no matter what the caller's identities look like.
    proc After {aSort aKey bSort bKey} {
        if {$aSort != $bSort} { return [expr {$aSort > $bSort}] }
        return [expr {[string compare $aKey $bKey] > 0}]
    }

    # Position of the row with this key, or -1. The list is small (a view culls
    # to bound it), so a linear scan is enough.
    method index {key} {
        set idx 0
        foreach row $Rows {
            if {[dict get $row key] eq $key} { return $idx }
            incr idx
        }
        return -1
    }

    method size {} { llength $Rows }
    method keys {} { lmap row $Rows {dict get $row key} }

    # The row at a position, or "" when out of range. Accepts `end`.
    method at {idx} {
        if {[llength $Rows] == 0} { return "" }
        lindex $Rows $idx
    }

    # The whole row for a key, or "" when absent.
    method get {key} {
        set idx [$self index $key]
        if {$idx < 0} { return "" }
        lindex $Rows $idx
    }

    # One field of a row, or "" when the row or the field is absent.
    method field {key name} {
        set row [$self get $key]
        if {$row eq "" || ![dict exists $row $name]} { return "" }
        dict get $row $name
    }

    method slot {key} { $self field $key slot }

    # The key owning a slot, or "" - the reverse lookup a view needs when it
    # has read a slot back out of a tag name.
    method keyof {slot} {
        foreach row $Rows {
            if {[dict get $row slot] eq $slot} { return [dict get $row key] }
        }
        return ""
    }

    # Slot of the first row sorting after this key/sort pair, or "" when it
    # would go last. A view asks before inserting, to know what to insert in
    # front of.
    method successor {key sort} {
        foreach row $Rows {
            if {[After [dict get $row sort] [dict get $row key] $sort $key]} {
                return [dict get $row slot]
            }
        }
        return ""
    }

    # Add a row at its sorted position and return its fresh slot. The caller
    # must have checked the key is absent.
    method insert {key sort {fields {}}} {
        set slot [incr NextSlot]
        set row [dict merge $fields \
            [dict create slot $slot key $key sort $sort]]
        set idx 0
        foreach existing $Rows {
            if {[After [dict get $existing sort] [dict get $existing key] \
                     $sort $key]} break
            incr idx
        }
        set Rows [linsert $Rows $idx $row]
        return $slot
    }

    # Merge fields onto an existing row. `slot`, `key` and `sort` are this
    # type's to set, so a patch naming them is ignored.
    method merge {key patch} {
        set idx [$self index $key]
        if {$idx < 0} return
        set row [lindex $Rows $idx]
        dict for {name value} $patch {
            if {$name in {slot key sort}} continue
            dict set row $name $value
        }
        set Rows [lreplace $Rows $idx $idx $row]
    }

    # Drop the row at a position and return it, or "" when out of range.
    # Accepts `end`.
    method removeat {idx} {
        set row [$self at $idx]
        if {$row eq ""} { return "" }
        set Rows [lreplace $Rows $idx $idx]
        return $row
    }

    method remove {key} {
        set idx [$self index $key]
        if {$idx < 0} { return "" }
        $self removeat $idx
    }

    # Empties the list. Slots are not reused afterwards, so a stale slot held
    # by anything outside can never resolve to a new row.
    method clear {} {
        set rows $Rows
        set Rows {}
        return $rows
    }

    method all {} { return $Rows }
}
