# Message entry widget: a text area for composing messages with a send button.
# Fires -send-command with the message text when the user clicks Send or
# presses Return (Shift-Return inserts a newline).

package require snit
package require emojipicker

snit::widget messageentry {
    hulltype ttk::frame
    component text
    component scrollbar
    component sendbutton
    component attachbutton
    component emojibutton
    component grip

    option -send-command -default ""
    option -attach-command -default ""
    option -request-voice-command -default ""

    # "normal" or "visitor"
    variable voiceState normal

    # Toplevel hosting the emoji picker while open, "" when closed
    variable emojiPopup ""
    # When the popup was last closed by a grab-click on the emoji button (ms);
    # lets the button's own release-command read as a close, not a reopen.
    variable emojiClosedAt 0

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

        install emojibutton using ttk::button $win.emoji \
            -style Toolbutton \
            -image mate/22x22/emotes/face-smile.png \
            -command [mymethod ToggleEmojiPopup]

        # Accessory slot just left of Send for caller-supplied context
        # controls (e.g. the OMEMO lock toggle in 1:1 chats). Empty otherwise.
        ttk::frame $win.accessory

        grid $win.grip -row 0 -column 0 -columnspan 5 -sticky ew
        grid $win.text -row 1 -column 0 -sticky nsew
        grid $win.attach -row 1 -column 1 -sticky n -padx {4 0}
        grid $win.emoji -row 1 -column 2 -sticky n -padx {4 0}
        grid $win.accessory -row 1 -column 3 -sticky n -padx {4 0}
        grid $win.send -row 1 -column 4 -sticky n -padx {4 0}
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

    destructor {
        catch {destroy $emojiPopup}
    }

    # Override-redirect toplevel so it escapes the chat window and we get to
    # place it - the WM won't position ordinary toplevels under XWayland.
    method ToggleEmojiPopup {} {
        if {$emojiPopup ne "" && [winfo exists $emojiPopup]} {
            $self CloseEmojiPopup
            return
        }
        # Swallow the release-command from the click that just grab-closed it.
        if {[clock milliseconds] - $emojiClosedAt < 250} return
        set pop $win.emojipop
        toplevel $pop -borderwidth 1 -relief solid
        wm withdraw $pop
        wm overrideredirect $pop 1
        if {[tk windowingsystem] eq "x11"} {
            catch {wm attributes $pop -type popup_menu}
        }
        emojipicker $pop.p -command [mymethod InsertEmoji]
        pack $pop.p -expand yes -fill both
        bind $pop <Escape> [mymethod CloseEmojiPopup]
        bind $pop <ButtonPress> [mymethod OnGrabClick %X %Y]
        bind $pop <FocusOut> [mymethod OnPopupFocusOut]
        bind $pop <Destroy> [mymethod OnEmojiPopupGone %W $pop]
        set emojiPopup $pop
        # Place once sized, so we can offset by its height to sit above the button.
        after idle [mymethod ShowEmojiPopup $pop]
    }

    # Place above the button, flipping below / clamping so it stays on screen.
    method ShowEmojiPopup {pop} {
        if {![winfo exists $pop]} return
        set pw [winfo reqwidth $pop]
        set ph [winfo reqheight $pop]
        set bx [winfo rootx $emojibutton]
        set by [winfo rooty $emojibutton]
        set sw [winfo screenwidth $pop]
        set sh [winfo screenheight $pop]

        # Small gap so it clears the button rather than overlapping the bar.
        set gap 4
        set x [expr {min($bx, $sw - $pw)}]
        if {$x < 0} { set x 0 }
        set y [expr {$by - $ph - $gap}]
        if {$y < 0} { set y [expr {$by + [winfo height $emojibutton] + $gap}] }
        set y [expr {min($y, $sh - $ph)}]
        if {$y < 0} { set y 0 }

        wm transient $pop [winfo toplevel $win]
        wm geometry $pop +$x+$y
        wm deiconify $pop
        raise $pop
        # Global grab routes every click to us, so a press on any other window
        # dismisses the popup; local grab as a fallback if it's refused.
        if {[catch {ttk::globalGrab $pop}]} { catch {grab $pop} }
        # Grab eats the button's <Leave>; clear its stuck active look by hand.
        $emojibutton state {!active !pressed}
        $pop.p focusSearch
    }

    method OnEmojiPopupGone {w pop} {
        if {$w eq $pop} { set emojiPopup "" }
    }

    method CloseEmojiPopup {} {
        if {$emojiPopup ne "" && [winfo exists $emojiPopup]} {
            catch {ttk::releaseGrab $emojiPopup}
            destroy $emojiPopup
        }
        $emojibutton state {!active !pressed}
    }

    # FocusOut only reaches the toplevel when focus leaves its whole subtree.
    # Defer so [focus] reflects the new target before we decide.
    method OnPopupFocusOut {} {
        if {$emojiPopup eq "" || ![winfo exists $emojiPopup]} return
        after idle [mymethod CloseIfFocusLost]
    }

    # Close if focus landed outside the popup (another toplevel, or - when
    # [focus] is empty - another application).
    method CloseIfFocusLost {} {
        if {$emojiPopup eq "" || ![winfo exists $emojiPopup]} return
        set f [focus -displayof $emojiPopup]
        if {$f eq "" || [winfo toplevel $f] ne $emojiPopup} {
            $self CloseEmojiPopup
        }
    }

    # Close on a click outside the popup. If it hit the emoji button, arm the
    # guard so its release-command doesn't immediately reopen.
    method OnGrabClick {X Y} {
        if {$emojiPopup eq "" || ![winfo exists $emojiPopup]} return
        set x0 [winfo rootx $emojiPopup]
        set y0 [winfo rooty $emojiPopup]
        if {$X < $x0 || $X >= $x0 + [winfo width $emojiPopup]
         || $Y < $y0 || $Y >= $y0 + [winfo height $emojiPopup]} {
            if {[winfo containing $X $Y] eq $emojibutton} {
                set emojiClosedAt [clock milliseconds]
            }
            $self CloseEmojiPopup
        }
    }

    method InsertEmoji {glyph} {
        $text insert insert $glyph
        focus $text
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
            $emojibutton configure -state disabled
            catch {destroy $emojiPopup}
        } else {
            $sendbutton configure -text "" \
                -image elementary/22x22/actions/mail-send.png \
                -command [mymethod Send]
            $text configure -state normal
            $attachbutton configure -state normal
            $emojibutton configure -state normal
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

    # Replace the whole composer content (used when starting an edit).
    method set {txt} {
        $text delete 1.0 end
        $text insert end $txt
    }
}
