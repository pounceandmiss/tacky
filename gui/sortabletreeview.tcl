# sortabletreeview - ttk::treeview wrapper with clickable column-header sorting.
#
# Transparently delegates all methods/options to the underlying treeview.
# Clicking a column header sorts by that column; clicking again toggles
# ascending/descending.  Sort indicators (▲/▼) are appended to the
# heading text of the active sort column.
#
# Options:
#   -sorttypes  dict mapping column IDs to sort type (ascii, integer, real).
#               Columns not listed default to ascii.
#               Example: -sorttypes {age integer salary real}
#
# Added methods:
#   sortby col ?-order ascending|descending?   — sort programmatically
#   sortcolumn                                  — returns current sort column
#   sortorder                                   — returns current sort order

snit::widgetadaptor sortabletreeview {

    delegate method * to hull except heading
    delegate option * to hull except -columns

    option -sorttypes -default {}
    option -columns -default {} -configuremethod SetColumns

    variable sortColumn ""
    variable sortOrder "ascending"
    variable headingTexts -array {}

    constructor {args} {
        # Grab -columns before installhull so we can pass it through
        set idx [lsearch -exact $args -columns]
        if {$idx >= 0} {
            set cols [lindex $args [expr {$idx + 1}]]
            set args [lreplace $args $idx [expr {$idx + 1}]]
        } else {
            set cols {}
        }

        installhull using ttk::treeview -columns $cols
        $self configurelist $args

        set options(-columns) $cols
        $self SetupHeadings
    }

    # ------------------------------------------------------------------
    # -columns configuration
    # ------------------------------------------------------------------

    method SetColumns {option value} {
        set options(-columns) $value
        $hull configure -columns $value
        $self SetupHeadings
    }

    # ------------------------------------------------------------------
    # Heading intercept
    # ------------------------------------------------------------------

    method heading {col args} {
        if {[llength $args] == 0} {
            return [$hull heading $col]
        }
        set textIdx [lsearch -exact $args -text]
        if {$textIdx >= 0} {
            set valIdx [expr {$textIdx + 1}]
            if {$valIdx < [llength $args]} {
                # Setter: cache original text
                set txt [lindex $args $valIdx]
                set headingTexts($col) $txt
                # If this column is currently sorted, re-append indicator
                if {$col eq $sortColumn} {
                    set indicator [expr {$sortOrder eq "ascending" ? " \u25B2" : " \u25BC"}]
                    set args [lreplace $args $valIdx $valIdx "${txt}${indicator}"]
                }
                return [$hull heading $col {*}$args]
            } else {
                # Getter: return displayed text from hull
                return [$hull heading $col -text]
            }
        }
        $hull heading $col {*}$args
    }

    # ------------------------------------------------------------------
    # Sort setup
    # ------------------------------------------------------------------

    method SetupHeadings {} {
        # Configure heading command for #0 (tree column)
        set text0 [$hull heading #0 -text]
        set headingTexts(#0) $text0
        $hull heading #0 -command [mymethod SortBy #0]

        # Configure heading command for each data column
        foreach col $options(-columns) {
            set txt [$hull heading $col -text]
            set headingTexts($col) $txt
            $hull heading $col -command [mymethod SortBy $col]
        }
    }

    # ------------------------------------------------------------------
    # Sorting
    # ------------------------------------------------------------------

    method SortBy {col} {
        if {$col eq $sortColumn} {
            # Toggle direction
            set sortOrder [expr {$sortOrder eq "ascending" ? "descending" : "ascending"}]
        } else {
            set sortColumn $col
            set sortOrder "ascending"
        }

        $self DoSort $col $sortOrder
        $self UpdateIndicators
    }

    method DoSort {col order} {
        # Determine sort type
        set sortType "ascii"
        if {[dict exists $options(-sorttypes) $col]} {
            set sortType [dict get $options(-sorttypes) $col]
        }

        # Map sort type to lsort flag
        switch -- $sortType {
            integer { set sortFlag "-integer" }
            real    { set sortFlag "-real" }
            default { set sortFlag "-ascii" }
        }

        set dirFlag [expr {$order eq "ascending" ? "-increasing" : "-decreasing"}]

        # Sort children recursively starting from root
        $self SortChildren "" $col $sortFlag $dirFlag
    }

    method SortChildren {parent col sortFlag dirFlag} {
        set children [$hull children $parent]
        if {[llength $children] <= 1} {
            # Still recurse into single child's children
            foreach child $children {
                $self SortChildren $child $col $sortFlag $dirFlag
            }
            return
        }

        # Build list of {sortKey itemId}
        set pairs {}
        set isNumeric [expr {$sortFlag in {"-integer" "-real"}}]
        foreach child $children {
            if {$col eq "#0"} {
                set key [$hull item $child -text]
            } else {
                set key [$hull set $child $col]
            }
            # Ensure numeric sort keys are valid numbers, default to 0
            if {$isNumeric && ![string is double -strict $key]} {
                set key 0
            }
            lappend pairs [list $key $child]
        }

        # Sort
        set sorted [lsort $sortFlag $dirFlag -index 0 $pairs]

        # Reorder
        set idx 0
        foreach pair $sorted {
            $hull move [lindex $pair 1] $parent $idx
            incr idx
        }

        # Recurse into children
        foreach child [$hull children $parent] {
            $self SortChildren $child $col $sortFlag $dirFlag
        }
    }

    method UpdateIndicators {} {
        # Clear indicator from all columns
        if {[info exists headingTexts(#0)]} {
            $hull heading #0 -text $headingTexts(#0)
        }
        foreach col $options(-columns) {
            if {[info exists headingTexts($col)]} {
                $hull heading $col -text $headingTexts($col)
            }
        }

        # Set indicator on current sort column
        if {$sortColumn ne ""} {
            set base ""
            if {[info exists headingTexts($sortColumn)]} {
                set base $headingTexts($sortColumn)
            }
            set indicator [expr {$sortOrder eq "ascending" ? " \u25B2" : " \u25BC"}]
            $hull heading $sortColumn -text "${base}${indicator}"
        }
    }

    # ------------------------------------------------------------------
    # Public methods
    # ------------------------------------------------------------------

    method sortby {col args} {
        set order ""
        set i 0
        while {$i < [llength $args]} {
            switch -- [lindex $args $i] {
                -order {
                    incr i
                    set order [lindex $args $i]
                }
                default {
                    error "unknown option \"[lindex $args $i]\": must be -order"
                }
            }
            incr i
        }

        set sortColumn $col
        if {$order ne ""} {
            set sortOrder $order
        } else {
            set sortOrder "ascending"
        }

        $self DoSort $col $sortOrder
        $self UpdateIndicators
    }

    method sortcolumn {} {
        return $sortColumn
    }

    method sortorder {} {
        return $sortOrder
    }
}
