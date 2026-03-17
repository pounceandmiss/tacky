# Composite entry widget for passwords and such which hides input by
# default which can be toggled using the checkbutton

snit::widget showableentry {
    hulltype ttk::frame
    component entry
    component checkbutton
    option -reveal -default 0
    option -showable -default 1 -readonly yes
    delegate option * to entry
    delegate method * to entry
    delegate method instate to hull
    delegate method state to hull

    constructor args {
        install entry using ttk::entry $win.entry
        $self configurelist $args
        pack $entry -fill both -expand yes
        if {$options(-showable)} {
            install checkbutton using ttk::checkbutton $win.checkbutton \
                -text "Reveal" \
                -command [mymethod ToggleShow] \
                -variable [myvar options(-reveal)]
            pack $checkbutton -anchor w
        }
        $self ToggleShow
        bind $win <FocusIn> [list focus $entry]
    }
    
    method ToggleShow {} {
        set character ""
        if {!$options(-reveal)} {
            set character *
        }
        $entry configure -show $character
    }
}
