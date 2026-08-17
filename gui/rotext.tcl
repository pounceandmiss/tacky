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

    constructor {args} {
        installhull using text -insertwidth 0 -width 50 -wrap word
        # Apply an options passed at creation time.
        $self configurelist $args
    }

    # Pixels of content sitting outside the viewport, above and below it.
    method {viewport above} {} {
        $hull count -ypixels 0.0 @0,0
    }

    method {viewport below} {} {
        $hull count -ypixels @0,[winfo height $win] end-1line
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
    # method ins {index chars tagList}
    delegate method del to hull as delete

    # Pass all other methods and options to the real text widget, so
    # that the remaining behavior is as expected.
    delegate method * to hull
    delegate option * to hull
}

# Tag setup shared by the read-only info panels. Returns the bold font, which
# callers also style their own tags with.
proc infotext_tags {t} {
    set boldfont TkTextFont_bold
    if {$boldfont ni [font names]} {
        font create $boldfont {*}[font configure TkTextFont] -weight bold
    }
    $t tag configure heading -font TkHeadingFont -spacing1 10 -spacing3 4
    $t tag configure bold -font $boldfont
    $t tag configure indent -lmargin1 14 -lmargin2 14
    return $boldfont
}
