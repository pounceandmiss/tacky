# Message entry widget: a text area for composing messages with a send button.
# Fires -send-command with the message text when the user clicks Send or
# presses Return (Shift-Return inserts a newline).

package require snit

snit::widget messageentry {
    hulltype ttk::frame
    component text
    component scrollbar
    component sendbutton
    component attachbutton
    component grip

    option -send-command -default ""
    option -attach-command -default ""
    option -request-voice-command -default ""

    # "normal" or "visitor"
    variable voiceState normal

    # Y coordinate where the drag started
    variable DragStartY
    # Height of the text widget (in pixels) when the drag started
    variable DragStartH

    constructor args {
        install grip using ttk::frame $win.grip -height 6 -cursor sb_v_double_arrow
        install text using text $win.text \
            -height 3 \
            -wrap word \
            -font {Helvetica 13} \
            -relief sunken -bd 1 \
            -yscrollcommand [mymethod ScrollSet]

        install scrollbar using ttk::scrollbar $win.scrollbar \
            -orient vertical \
            -command [list $win.text yview]

        install sendbutton using ttk::button $win.send \
            -style Toolbutton \
            -image elementary/22x22/actions/mail-send.png \
            -command [mymethod Send]

        install attachbutton using ttk::button $win.attach \
            -style Toolbutton \
            -image mate/22x22/status/mail-attachment.png \
            -command [mymethod Attach]

        # Accessory slot just left of Send for caller-supplied context
        # controls (e.g. the OMEMO lock toggle in 1:1 chats). Empty otherwise.
        ttk::frame $win.accessory

        grid $win.grip -row 0 -column 0 -columnspan 4 -sticky ew
        grid $win.text -row 1 -column 0 -sticky nsew
        grid $win.attach -row 1 -column 1 -sticky n -padx {4 0}
        grid $win.accessory -row 1 -column 2 -sticky n -padx {4 0}
        grid $win.send -row 1 -column 3 -sticky n -padx {4 0}
        grid rowconfigure $win 1 -weight 1
        grid columnconfigure $win 0 -weight 1

        bind $win.grip <ButtonPress-1> [mymethod DragStart %Y]
        bind $win.grip <B1-Motion> [mymethod DragMotion %Y]

        $self configurelist $args

        # Return sends, Shift-Return inserts newline
        bind $win.text <Shift-Return> continue
        bind $win.text <Return> "[mymethod OnReturn %s]; break"
    }

    method OnReturn {state} {
        $self Send
        # if {$state & 1} {
        #     $text insert insert \n
        # } else {
        #     $self Send
        # }
    }

    method Send {} {
        set msg [string trim [$text get 1.0 end-1c]]
        if {$msg eq ""} return
        $text delete 1.0 end
        if {$options(-send-command) ne ""} {
            {*}$options(-send-command) $msg
        }
    }

    method Attach {} {
        if {$options(-attach-command) ne ""} {
            {*}$options(-attach-command)
        }
    }

    method ScrollSet {first last} {
        if {$first == 0.0 && $last == 1.0} {
            grid remove $win.scrollbar
        } else {
            grid $win.scrollbar -row 1 -column 1 -sticky ns
        }
        $scrollbar set $first $last
    }

    method DragStart {y} {
        set DragStartY $y
        set DragStartH [winfo height $text]
    }

    method DragMotion {y} {
        set newH [expr {$DragStartH - ($y - $DragStartY)}]
        set lineH [font metrics [$text cget -font] -linespace]
        set lines [expr {max(1, $newH / $lineH)}]
        $text configure -height $lines
    }

    method setVoiceState {state} {
        set voiceState $state
        if {$state eq "visitor"} {
            $sendbutton configure -image "" -text "Request Voice" \
                -command [mymethod RequestVoice]
            $text configure -state disabled
            $attachbutton configure -state disabled
        } else {
            $sendbutton configure -text "" \
                -image elementary/22x22/actions/mail-send.png \
                -command [mymethod Send]
            $text configure -state normal
            $attachbutton configure -state normal
        }
    }

    method RequestVoice {} {
        if {$options(-request-voice-command) ne ""} {
            {*}$options(-request-voice-command)
        }
    }

    # Container left of the Send button for caller-supplied controls.
    method accessory {} {
        return $win.accessory
    }

    method focus {} {
        focus $text
    }

    method get {} {
        string trim [$text get 1.0 end-1c]
    }

    method insert {txt} {
        $text insert end $txt
    }
}
