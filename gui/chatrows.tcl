# chatrows - the drawn rows of a chat list, on a canvas.
#
# A treeview styles a cell as one piece; here the name is bold, the preview
# dim, the unread count a badge, the time small on the right and the avatar
# spans the row. This widget owns the drawing, selection and hit-testing;
# which rows, and in what order, is the caller's.
#
# Rows are dicts:
#   key      identity, opaque, unique
#   name     first line, bold
#   preview  second line, dim
#   unread   count, drawn as a badge when > 0
#   mention  bool, colours the badge
#   time     microseconds, drawn top-right; 0 draws nothing
#   image    avatar photo, or "" for none
#   tags     styles for the name, set up through `tag configure`
#
# Every row is the same height, so the row under a point is arithmetic. The
# whole list is redrawn on every `set` - a chat list is small - keeping the
# selection and scroll position.

snit::widget chatrows {
    hulltype ttk::frame

    component canvas
    component scrollbar

    # {*}$cmd $key: the selection moved (click or keyboard).
    option -select-command -default ""
    # {*}$cmd $key: a row was opened (double-click or Return).
    option -activate-command -default ""
    # {*}$cmd $key $X $Y: a row was right-clicked, with screen coords.
    option -menu-command -default ""

    # key -> row dict, as last drawn
    variable Rows {}
    # keys in drawn order
    variable Order {}
    # key -> avatar canvas item, for updates in place
    variable Images {}
    variable Selected ""
    # the width last drawn for
    variable Width 0
    # tag -> {-foreground color -font font}, from `tag configure`
    variable Styles {}
    # geometry, from the fonts
    variable RowH
    variable NameY
    variable PreviewY

    typevariable AvatarSize 32
    typevariable Pad 4
    # How far the preview steps in past the name.
    typevariable PreviewStep 16

    # Rows the widget asks for before anything packs around it.
    typevariable DefaultRows 10

    constructor args {
        $self ConfigureFonts
        install canvas using canvas $win.canvas -highlightthickness 0 \
            -takefocus 1 -width 200 -height [expr {$DefaultRows * $RowH}] \
            -background [chatrows_field_background] \
            -yscrollcommand [list $win.scrollbar set]
        install scrollbar using ttk::scrollbar $win.scrollbar \
            -orient vertical -command [list $win.canvas yview]
        $self configurelist $args

        grid $win.canvas $win.scrollbar -sticky nsew
        grid rowconfigure $win $win.canvas -weight 1
        grid columnconfigure $win $win.canvas -weight 1

        bind $canvas <Button-4> {%W yview scroll -3 units}
        bind $canvas <Button-5> {%W yview scroll 3 units}
        bind $canvas <MouseWheel> \
            {%W yview scroll [expr {%D > 0 ? -3 : 3}] units}
        bind $canvas <Button-1> [mymethod OnClick %x %y]
        bind $canvas <Double-1> [mymethod OnDoubleClick %x %y]
        bind $canvas <Button-3> [mymethod OnRightClick %x %y %X %Y]
        bind $canvas <Up> [mymethod Move -1]
        bind $canvas <Down> [mymethod Move 1]
        bind $canvas <Return> [mymethod Activate]
        bind $canvas <Configure> [mymethod OnConfigure %w]
    }

    method ConfigureFonts {} {
        foreach {name base weight} {
            ChatrowsName TkDefaultFont bold
            ChatrowsTime TkSmallCaptionFont normal
        } {
            if {$name ni [font names]} {
                font create $name {*}[font actual $base] -weight $weight
            }
        }
        # Two lines of text, or the avatar, whichever is taller, plus padding.
        set nameH [font metrics ChatrowsName -linespace]
        set previewH [font metrics TkDefaultFont -linespace]
        set RowH [expr {2 * $Pad + max($AvatarSize, $nameH + $previewH + 2)}]
        set NameY [expr {($RowH - $nameH - $previewH - 2) / 2}]
        set PreviewY [expr {$NameY + $nameH + 2}]
    }

    # Name styles, as text-tag options: -foreground and -font.
    method {tag configure} {tag args} {
        dict set Styles $tag [dict merge [dict getdef $Styles $tag {}] $args]
    }

    # The right edge moves with the width, and the text is cut to fit it.
    method OnConfigure {width} {
        if {$width == $Width} return
        set Width $width
        $self set [lmap key $Order {dict get $Rows $key}]
    }

    # `string` cut with an ellipsis to fit `px` pixels of `font`.
    proc Fit {string font px} {
        if {[font measure $font $string] <= $px} { return $string }
        set px [expr {$px - [font measure $font …]}]
        set n [string length $string]
        while {$n > 0 && [font measure $font [string range $string 0 $n-1]] > $px} {
            incr n -1
        }
        return "[string range $string 0 $n-1]…"
    }

    # -- the list -------------------------------------------------------

    method set {rows} {
        set yview [lindex [$canvas yview] 0]
        $canvas delete all
        set Rows {}
        set Order {}
        set Images {}
        set y 0
        foreach row $rows {
            set key [dict get $row key]
            dict set Rows $key $row
            lappend Order $key
            $self Draw $row $y
            incr y $RowH
        }
        $canvas configure -scrollregion [list 0 0 $Width $y]
        if {$Selected ne "" && ![dict exists $Rows $Selected]} {
            set Selected ""
        }
        if {$Selected ne ""} { $self Highlight $Selected }
        $canvas yview moveto $yview
    }

    method keys {} { return $Order }
    method exists {key} { dict exists $Rows $key }
    method row {key} { dict getdef $Rows $key {} }

    # Swap a row's avatar without redrawing.
    method image {key img} {
        if {[dict exists $Images $key]} {
            $canvas itemconfigure [dict get $Images $key] -image $img
        }
    }

    method Draw {row y} {
        set key [dict get $row key]
        set tag row.[lsearch -exact $Order $key]
        # Before the first Configure there is no width to fit to.
        set right [expr {$Width > 1 ? $Width - $Pad : 100000}]
        set img [dict getdef $row image ""]
        set x $Pad
        if {$img ne ""} {
            dict set Images $key [$canvas create image \
                [expr {$x + $AvatarSize / 2}] [expr {$y + $RowH / 2}] \
                -image $img -tags [list $tag avatar]]
            set x [expr {$x + $AvatarSize + $Pad}]
        }

        # Name, cut to leave room for the time at the right edge.
        set when [chatrows_when [dict getdef $row time 0]]
        set nameRight $right
        if {$when ne ""} {
            $canvas create text $right [expr {$y + $NameY}] -anchor ne \
                -text $when -font ChatrowsTime -fill [palette dim] \
                -tags [list $tag time]
            set nameRight [expr {$right - [font measure ChatrowsTime $when] - 2 * $Pad}]
        }
        set style [$self NameStyle [dict getdef $row tags {}]]
        # A row with nothing on its second line centres the name instead.
        set preview [dict getdef $row preview ""]
        set unread [dict getdef $row unread 0]
        if {$preview eq "" && $unread == 0} {
            set nameY [expr {$y + $RowH / 2}]
            set nameAnchor w
        } else {
            set nameY [expr {$y + $NameY}]
            set nameAnchor nw
        }
        $canvas create text $x $nameY -anchor $nameAnchor \
            -text [Fit [dict get $row name] [dict get $style font] \
                [expr {$nameRight - $x}]] \
            -font [dict get $style font] -fill [dict get $style fill] \
            -tags [list $tag name]

        # Preview, cut to leave room for the badge at the right edge.
        set px [expr {$x + $PreviewStep}]
        set previewRight $right
        if {$unread > 0} {
            set badgeFill [palette [expr {[dict getdef $row mention 0]
                ? "mention" : "accent"}]]
            set label [$canvas create text [expr {$right - $Pad}] \
                [expr {$y + $PreviewY + [font metrics TkDefaultFont -linespace] / 2}] \
                -anchor e -text $unread -font ChatrowsTime -fill white \
                -tags [list $tag badge.label]]
            lassign [$canvas bbox $label] bx1 by1 bx2 by2
            set badge [$canvas create rectangle \
                [expr {$bx1 - $Pad}] [expr {$by1 - 1}] \
                [expr {$bx2 + $Pad}] [expr {$by2 + 1}] \
                -fill $badgeFill -outline "" -tags [list $tag badge]]
            $canvas lower $badge $label
            set previewRight [expr {$bx1 - 2 * $Pad}]
        }
        if {$preview ne ""} {
            $canvas create text $px [expr {$y + $PreviewY}] -anchor nw \
                -text [Fit $preview TkDefaultFont [expr {$previewRight - $px}]] \
                -font TkDefaultFont -fill [palette dim] \
                -tags [list $tag preview]
        }
    }

    # The name's font and colour: the row's style tags override the default,
    # later ones winning, and an empty value means no override.
    method NameStyle {tags} {
        set style {font ChatrowsName fill ""}
        dict set style fill [ttk::style lookup Treeview -foreground]
        if {[dict get $style fill] eq ""} { dict set style fill black }
        foreach tag $tags {
            set s [dict getdef $Styles $tag {}]
            if {[dict getdef $s -font ""] ne ""} {
                dict set style font [dict get $s -font]
            }
            if {[dict getdef $s -foreground ""] ne ""} {
                dict set style fill [dict get $s -foreground]
            }
        }
        return $style
    }

    # -- selection ------------------------------------------------------

    method selected {} { return $Selected }

    method select {key} {
        $canvas delete selected
        set Selected ""
        if {$key eq "" || ![dict exists $Rows $key]} return
        set Selected $key
        $self Highlight $key
        $self See $key
    }

    # A filled rectangle under the row, its text recoloured to read on it.
    method Highlight {key} {
        set idx [lsearch -exact $Order $key]
        set y [expr {$idx * $RowH}]
        set bg [ttk::style lookup Treeview -background selected]
        set fg [ttk::style lookup Treeview -foreground selected]
        if {$bg eq ""} { set bg [palette accent] }
        if {$fg eq ""} { set fg white }
        $canvas lower [$canvas create rectangle 0 $y $Width [expr {$y + $RowH}] \
            -fill $bg -outline "" -tags selected]
        foreach item [$canvas find withtag "row.$idx && (name || preview || time)"] {
            $canvas itemconfigure $item -fill $fg
        }
    }

    method See {key} {
        set idx [lsearch -exact $Order $key]
        set top [expr {$idx * $RowH}]
        set total [expr {[llength $Order] * $RowH}]
        if {$total == 0} return
        lassign [$canvas yview] first last
        set viewTop [expr {$first * $total}]
        set viewBottom [expr {$last * $total}]
        if {$top < $viewTop} {
            $canvas yview moveto [expr {double($top) / $total}]
        } elseif {$top + $RowH > $viewBottom} {
            $canvas yview moveto [expr {double($top + $RowH - ($viewBottom - $viewTop)) / $total}]
        }
    }

    method Select {key} {
        $self select $key
        if {$options(-select-command) ne ""} {
            {*}$options(-select-command) $key
        }
    }

    # The key of the row under a point, or "".
    method KeyAt {x y} {
        set idx [expr {int([$canvas canvasy $y] / $RowH)}]
        if {$idx < 0 || $idx >= [llength $Order]} { return "" }
        return [lindex $Order $idx]
    }

    method OnClick {x y} {
        focus $canvas
        set key [$self KeyAt $x $y]
        if {$key eq ""} return
        $self Select $key
    }

    method OnDoubleClick {x y} {
        set key [$self KeyAt $x $y]
        if {$key eq ""} return
        $self Select $key
        $self Activate
    }

    method OnRightClick {x y X Y} {
        set key [$self KeyAt $x $y]
        if {$key eq ""} return
        $self Select $key
        if {$options(-menu-command) ne ""} {
            {*}$options(-menu-command) $key $X $Y
        }
    }

    method Move {delta} {
        if {[llength $Order] == 0} return
        set idx [lsearch -exact $Order $Selected]
        set idx [expr {max(0, min([llength $Order] - 1, $idx + $delta))}]
        $self Select [lindex $Order $idx]
    }

    method Activate {} {
        if {$Selected eq "" || $options(-activate-command) eq ""} return
        {*}$options(-activate-command) $Selected
    }
}

proc chatrows_field_background {} {
    set bg [ttk::style lookup Treeview -fieldbackground]
    if {$bg eq ""} { set bg white }
    return $bg
}

# When a chat last spoke: the time if today, the day if this year, else the
# date. "" for never.
proc chatrows_when {us {now ""}} {
    if {$us == 0} { return "" }
    if {$now eq ""} { set now [clock seconds] }
    set secs [expr {$us / 1000000}]
    if {[clock format $secs -format %Y%m%d] eq [clock format $now -format %Y%m%d]} {
        return [clock format $secs -format %H:%M]
    }
    if {[clock format $secs -format %Y] eq [clock format $now -format %Y]} {
        return [clock format $secs -format "%d %b"]
    }
    return [clock format $secs -format %Y-%m-%d]
}
