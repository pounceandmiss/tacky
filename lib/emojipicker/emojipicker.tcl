#!/usr/bin/env wish
# Self-contained emoji picker package - a snit widget plus a demo harness.
#
#   package require emojipicker
#   emojipicker $w -command CMD   embed it; CMD is called with the chosen glyph
#   wish emojipicker.tcl          run the demo
#
# It also fires <<EmojiSelected>> on the widget, with the glyph in %d.
#
# The glyph table is generated - see tools/emoji/gen_emoji.tcl. Rendering uses a
# single text widget, not 1900 buttons: each glyph is one tagged span, and a
# search just clears and re-inserts the matches. The table ships in emoji/
# beside this file and is parsed lazily on first open.

package require Tk
package require snit
package provide emojipicker 0.1

namespace eval ::emoji {
    # Font used for the glyph grid. Noto Color Emoji is uniform-width, so a
    # plain -wrap char layout already lines the glyphs up into a grid.
    variable glyphFont {"Noto Color Emoji" 18}
    variable tableFile [file join [file dirname [info script]] emoji emojitable.tcl]
}

# Load the table lazily, on first picker open.
proc ::emoji::ensure_table {} {
    variable table
    variable tableFile
    if {![info exists table]} { source $tableFile }
}

# Read-only text for the glyph grid - editing neutered, ins/del exposed for the
# owner. Namespaced so it never collides with an app-level `rotext`.
snit::widgetadaptor ::emoji::rotext {
    constructor args {
        installhull using text -insertwidth 0
        $self configurelist $args
    }
    method insert args {}
    method delete args {}
    delegate method ins to hull as insert
    delegate method del to hull as delete
    delegate method * to hull
    delegate option * to hull
}

snit::widget emojipicker {
    hulltype ttk::frame

    option -command ""           ;# invoked with the chosen glyph
    option -columns 12           ;# glyphs per row in the grid

    component search             ;# ttk::entry - text search
    component cats               ;# ttk::frame - category selector buttons
    component grid               ;# text widget - the glyph grid
    component status             ;# ttk::label - hovered glyph name

    variable searchVar ""
    variable activeCategory ""   ;# category shown when not searching
    variable slot                ;# tag name -> {glyph name}
    variable catItems            ;# category -> list of records (built once)
    variable catOrder {}         ;# categories in table order
    variable nameOf              ;# glyph -> name (for recents lookup)
    variable recents {}          ;# most-recently-picked glyphs (in-memory)

    constructor args {
        ::emoji::ensure_table

        install search using ttk::entry $win.search \
            -textvariable [myvar searchVar]
        install cats using ttk::frame $win.cats

        set f $win.gridf
        ttk::frame $f
        install grid using ::emoji::rotext $f.t \
            -font $::emoji::glyphFont -wrap char -cursor arrow \
            -relief flat -padx 4 -pady 4 -highlightthickness 0 \
            -spacing1 2 -spacing3 2 -width 13 -height 9 \
            -yscrollcommand [list $f.sb set]
        ttk::scrollbar $f.sb -command [list $grid yview]
        grid $grid $f.sb -sticky nsew
        grid rowconfigure $f 0 -weight 1
        grid columnconfigure $f 0 -weight 1

        install status using ttk::label $win.status -anchor w -text " "

        pack $search -fill x -padx 6 -pady {6 3}
        pack $cats   -fill x -padx 4
        pack $f      -fill both -expand yes -padx 6 -pady 3
        pack $status -fill x -padx 6 -pady {0 4}

        $self configurelist $args
        $grid configure -width [expr {$options(-columns) + 1}]

        $grid tag configure heading \
            -font {TkDefaultFont 9 bold} -spacing1 8 -spacing3 4 \
            -foreground gray40 -justify left
        $grid tag configure cell -spacing1 0
        $grid tag bind cell <Enter>    [mymethod Hover %x %y]
        $grid tag bind cell <Motion>   [mymethod Hover %x %y]
        $grid tag bind cell <Leave>    [list $status configure -text " "]
        $grid tag bind cell <Button-1> [mymethod Click %x %y]

        # Mouse-only: keep the grid out of Tab traversal and bounce any focus
        # back to the search box, so typing always lands there, not in the grid.
        $grid configure -takefocus 0
        bind $grid <FocusIn> [list focus $search]

        $self BuildIndex
        $self BuildCategoryBar
        set activeCategory [lindex $catOrder 0]
        trace add variable [myvar searchVar] write [mymethod OnSearch]
        $self Render
        focus $search
    }

    destructor {
        catch {trace remove variable [myvar searchVar] write [mymethod OnSearch]}
    }

    # --- index: bucket the flat table by category, once ---

    method BuildIndex {} {
        foreach rec $::emoji::table {
            lassign $rec char name keywords cat
            if {![info exists catItems($cat)]} { lappend catOrder $cat }
            lappend catItems($cat) $rec
            set nameOf($char) $name
        }
    }

    # --- category selector ---
    #
    # "Recent" is a pseudo-category fed from in-memory picks.

    method BuildCategoryBar {} {
        set icon {
            Recent             \U1F551
            "Smileys & Emotion" \U1F600  "People & Body" \U1F44B
            "Animals & Nature" \U1F43B   "Food & Drink"  \U1F34E
            "Travel & Places"  \U2708    "Activities"    \U26BD
            "Objects"          \U1F4A1   "Symbols"       \U1F523
            "Flags"            \U1F3C1
        }
        set n 0
        foreach {group glyph} $icon {
            set b $cats.c[incr n]
            ttk::radiobutton $b -style Toolbutton -text $glyph \
                -value $group -variable [myvar activeCategory] \
                -command [mymethod SelectCategory] -takefocus 0
            # Same focus bounce as the grid: keep typing in the search box.
            bind $b <FocusIn> [list focus $search]
            pack $b -side left
        }
    }

    method SelectCategory {} {
        # activeCategory is set by the radiobutton; clearing search renders it.
        set searchVar ""
    }

    # --- rendering ---

    method OnSearch {args} { $self Render }

    method Render {} {
        $grid del 1.0 end
        array unset slot
        set i 0
        set query [string trim [string tolower $searchVar]]

        if {$query ne ""} {
            $self RenderSearch $query i
        } elseif {$activeCategory eq "Recent"} {
            $self RenderGlyphs [lmap c $recents {list $c $nameOf($c)}] i
            if {$i == 0} { $grid ins end "\n   no recently used emoji yet" }
        } else {
            $self RenderGlyphs $catItems($activeCategory) i
        }
        $grid yview moveto 0
    }

    # Search spans every category; results are grouped under category headings.
    method RenderSearch {query iVar} {
        upvar 1 $iVar i
        foreach cat $catOrder {
            if {$cat eq "Recent"} continue
            set hits [lmap rec $catItems($cat) {
                if {![string match "*$query*" \
                        [string tolower "[lindex $rec 1] [lindex $rec 2]"]]} continue
                set rec
            }]
            if {[llength $hits]} {
                $grid ins end "$cat\n" heading
                $self RenderGlyphs $hits i
            }
        }
        if {$i == 0} {
            $grid ins end "\n   no emoji match \"[string trim $searchVar]\""
        }
    }

    # Lay records out into the glyph grid. `iVar` is the running slot counter.
    method RenderGlyphs {records iVar} {
        upvar 1 $iVar i
        set col 0
        foreach rec $records {
            lassign $rec char name
            set tag c$i
            set slot($tag) [list $char $name]
            $grid ins end $char [list cell $tag]
            incr i
            if {[incr col] >= $options(-columns)} {
                $grid ins end "\n"
                set col 0
            }
        }
        if {$col != 0} { $grid ins end "\n" }
    }

    # --- interaction ---

    method focusSearch {} { focus $search }

    method TagAt {x y} {
        foreach t [$grid tag names "@$x,$y"] {
            if {[string match c* $t] && [info exists slot($t)]} { return $t }
        }
        return ""
    }

    method Hover {x y} {
        set t [$self TagAt $x $y]
        if {$t eq ""} { return }
        lassign $slot($t) char name
        $status configure -text "$char  $name"
    }

    method Click {x y} {
        set t [$self TagAt $x $y]
        if {$t eq ""} { return }
        set char [lindex $slot($t) 0]
        # bump recents (most-recent first, dedup, cap 24)
        set recents [lrange [linsert [lsearch -all -inline -not -exact \
            $recents $char] 0 $char] 0 23]
        if {$activeCategory eq "Recent" && $searchVar eq ""} { $self Render }
        if {$options(-command) ne ""} {
            uplevel #0 [list {*}$options(-command) $char]
        }
        event generate $win <<EmojiSelected>> -data $char
    }
}

# Demo harness: only runs when this file is executed directly, not sourced.

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    proc bgerror {msg} { puts stderr $::errorInfo }
    wm title . "emoji picker"
    ttk::style theme use clam

    ttk::entry .out -width 50
    emojipicker .pick -command {.out insert end} -columns 12
    bind .pick <<EmojiSelected>> {puts "picked: %d"}

    pack .pick -fill both -expand yes
    pack .out  -fill x -padx 6 -pady 6
    # Leave focus where the picker put it (its search box), not on .out.
}
