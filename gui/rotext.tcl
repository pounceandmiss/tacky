::snit::widgetadaptor rotext {

    constructor {args} {
        installhull using text -insertwidth 0
        # Apply an options passed at creation time.
        $self configurelist $args
    }

    # Disable the insert and delete methods, to make this readonly.
    method insert {args} {}
    method delete {args} {}

    method yview {args} {
        event generate $win <<Yview>> -data $args
        $hull yview {*}$args
    }
    
    # Enable ins and del as synonyms, so the program can insert and
    # delete.
    delegate method ins to hull as insert
    delegate method del to hull as delete
    
    # Pass all other methods and options to the real text widget, so
    # that the remaining behavior is as expected.
    delegate method * to hull
    delegate option * to hull
}

snit::widgetadaptor chattext {
    #Makes text readonly, exposes <<Yview>> event to track scrolling
    variable compensating
    option -on-yview -default control::no-op
    
    constructor {args} {
        installhull using text -insertwidth 0 -width 50 -wrap word
        set compensating no
        # Apply an options passed at creation time.
        $self configurelist $args
    }
    method OnMap {} {
        
    }
        
    method getPixelsAbove {} {
        set pixelsAbove [$text count -ypixels 0.0 @0,0]
    }
    
    method getPixelsBelow {} {
        set pixelsBelow [$text count -ypixels @0,[winfo height $text] end-1line]
    }
    method {viewport beyond} {} {
        set pixelsAbove [$hull count -ypixels 0.0 @0,0]
        set pixelsBelow [$hull count -ypixels @0,[winfo height $self] end-1line]
        list $pixelsAbove $pixelsBelow
    }
    
    # Disable the insert and delete methods, to make this readonly.
    method insert {args} {}
    method delete {args} {}

    method yview {args} {
        event generate $win <<Yview>> -data $args
        {*}$options(-on-yview) $args
        $hull yview {*}$args
    }

    method compensate {script} {
        uplevel [list myinsertAt0 $win $script]
    }

    # Enable ins and del as synonyms, so the program can insert and
    # delete.
    delegate method ins to hull as insert
    # method ins {index chars tagList}
    delegate method del to hull as delete
    
    # Pass all other methods and options to the real text widget, so
    # that the remaining behavior is as expected.
    delegate method * to hull
    delegate option * to hull
}

proc insertAndCompensate {text script} {
    # We are abusing the text widget to display an endlessly scrolling chat view.
    # When we insert a message on top, the text widget will "scroll" upwards, because
    # that is how you expect a text widget to function
    # (it's not even considered scrolling by text logic I think)
    # - but not what you want in a chat view.
    # So we compensate for the described "scroll" by telling `text` to scroll in the
    # opposite direction by however many pixels we inserted. 

    # How we do it:
    # 1. Force-calculate line sizes (see ASYNCHRONOUS UPDATE OF LINE HEIGHTS in man text)
    # 2. Check if the message being inserted is on screen (last line is enough)
    # 3. Scroll by as many pixels as are in the message

    $text mark set msgInsert beforeMessages
    uplevel $script
    $text sync
    if {[$text bbox msgInsert] ne ""} {
        # puts l
        set pixels [$text count -ypixels beforeMessages msgInsert]
        # For some reason if we only insert 1 line (15 pixels),
        # the text scrolls up nonetheless as if ignoring it
        incr pixels
        $text yview scroll $pixels pixels
    }    
}


proc myinsertAt0 {t script} {
    $t mark set tmp msgins
    $t mark gravity tmp left
    lassign [$t bbox @0,0] x y width height
    uplevel $script
    $t sync
    if {[$t bbox tmp] == ""} {
        return
    }
    # puts sern
    set pixels [$t count -ypixels tmp msgins]
    set extra [expr {[$t cget -borderwidth] +
                     [$t cget -pady] +
                     [$t cget -highlightthickness] }]

    $t yview scroll [expr {$pixels-$y+$extra}] pixels

    
}
