package require snit

# One rendered attachment, embedded in the chat text widget. Draws a caption
# (image) or an Open/Save chip (file), with the thumbnail and a transfer
# progress/Retry row added later via `setImage` / `setState`. The widget knows
# its own url/id/idx and routes every user action (open, save, click-to-load,
# retry, the right-click menu) straight to -command; chatarea just creates it
# and forwards setImage/setState by message key+idx.
snit::widget attachment {
    hulltype ttk::frame

    option -command -default ""       ;# {*}$cmd <action> ...; see chatarea
    option -url  -default ""
    option -kind -default file        ;# image | file
    option -name -default ""
    option -id   -default ""          ;# message id, passed to load/retry callbacks
    option -idx  -default 0           ;# attachment index within the message
    option -scroll-target -default "" ;# text widget wheel events relay to

    constructor args {
        $self configurelist $args
        if {$options(-kind) eq "image"} {
            ttk::label $win.cap -text $options(-name) -foreground blue -cursor hand2
            bind $win.cap <Button-1> [mymethod Click]
            pack $win.cap -side top -anchor w
        } else {
            set chip [ttk::frame $win.chip]
            ttk::label  $chip.name -text $options(-name)
            ttk::button $chip.open -text "Open" -style Toolbutton \
                -command [mymethod Open]
            ttk::button $chip.save -text "Save" -style Toolbutton \
                -command [mymethod Save]
            pack $chip.name $chip.open $chip.save -side left -padx 2
            pack $chip -side top -anchor w
        }
        $self RelayScroll $win
        $self BindMenu $win
    }

    method Cb {name args} {
        {*}$options(-command) $name {*}$args
    }

    # Image caption/thumbnail click: open the image when its thumbnail is shown,
    # else (re)load it (e.g. after "Delete from cache" cleared it).
    method Click {} {
        if {[$self hasImage]} {
            $self Open
        } else {
            $self Cb load $options(-url) $options(-id) $options(-idx)
        }
    }

    method Open {} { $self Cb open $options(-url) }
    method Save {} { $self Cb save $options(-url) $options(-name) }

    method hasImage {} { winfo exists $win.img }
    method dropImage {} { catch {destroy $win.img} }

    # Add the backend-produced thumbnail (already downscaled) above the caption.
    method setImage {path} {
        if {[winfo exists $win.img]} return
        if {[catch {image create photo -file $path} photo]} return
        ttk::label $win.img -image $photo -cursor hand2
        # Tk photos aren't auto-freed when their last referencing widget dies,
        # so tie this one's lifetime to the label so cull/clear/uncache release it.
        bind $win.img <Destroy> [list catch [list image delete $photo]]
        if {[winfo exists $win.cap]} {
            bind $win.img <Button-1> [mymethod Click]
            pack $win.img -side top -anchor w -before $win.cap
        } else {
            pack $win.img -side top -anchor w
        }
        $self RelayScroll $win.img
        $self BindMenu $win.img
    }

    # Transfer state row: a progress bar with Cancel while active, an error +
    # Retry on failure, removed on done or idle. upload/download use
    # separate rows ($win.up / $win.dl) so an uploading image keeps both its
    # bar and its thumbnail.
    method setState {direction state loaded total} {
        set w $win.[expr {$direction eq "upload" ? "up" : "dl"}]
        switch -- $state {
            done - idle { catch {destroy $w} }
            failed { $self ShowFailed $w $direction }
            active { $self ShowActive $w $direction $loaded $total }
        }
    }

    method ShowActive {w direction loaded total} {
        if {![winfo exists $w.bar]} {
            catch {destroy $w}
            ttk::frame $w
            ttk::progressbar $w.bar -length 200
            ttk::label $w.lbl -foreground #888888
            ttk::button $w.cancel -text "Cancel" -style Toolbutton \
                -command [mymethod Cancel $direction]
            pack $w.bar $w.lbl $w.cancel -side left -padx {0 6}
            pack $w -side top -anchor w -pady {2 0}
            $self RelayScroll $w
        }
        $w.lbl configure -text \
            [expr {$direction eq "upload" ? "Uploading..." : "Downloading..."}]
        if {$total > 0} {
            $w.bar configure -mode determinate \
                -value [expr {100.0 * $loaded / $total}]
        } else {
            $w.bar configure -mode indeterminate
            catch {$w.bar start}
        }
    }

    method ShowFailed {w direction} {
        catch {destroy $w}
        ttk::frame $w
        ttk::label $w.lbl -foreground #c0504d -text \
            [expr {$direction eq "upload" ? "Upload failed" : "Download failed"}]
        ttk::button $w.retry -text "Retry" -style Toolbutton \
            -command [mymethod Retry $direction]
        pack $w.lbl $w.retry -side left -padx {0 6}
        pack $w -side top -anchor w -pady {2 0}
        $self RelayScroll $w
    }

    method Cancel {direction} {
        $self Cb cancel $direction $options(-url) $options(-id)
    }

    # Upload retry re-runs the upload; download retry re-fetches the thumbnail
    # (same path as the click-to-load placeholder).
    method Retry {direction} {
        if {$direction eq "upload"} {
            $self Cb retry $options(-id)
        } else {
            $self Cb load $options(-url) $options(-id) $options(-idx)
        }
    }

    # Embedded windows in the text widget swallow wheel events; forward them
    # (and any later descendants') to the text so scrolling keeps working when
    # the pointer is over an attachment. Mirrors chatscrollbtn.
    method RelayScroll {w} {
        set t $options(-scroll-target)
        if {$t eq ""} return
        bind $w <Button-4>   [list event generate $t <Button-4>]
        bind $w <Button-5>   [list event generate $t <Button-5>]
        bind $w <MouseWheel> [list event generate $t <MouseWheel> -delta %D]
        foreach c [winfo children $w] { $self RelayScroll $c }
    }

    # Bind the right-click menu on $w and its descendants; the thumbnail arrives
    # after the chip/caption, so setImage runs this again for it.
    method BindMenu {w} {
        bind $w <Button-3> [mymethod Menu %X %Y]
        foreach c [winfo children $w] { $self BindMenu $c }
    }

    # The right-click menu is identical for every attachment; build it lazily,
    # once per widget, with its actions bound to this one.
    method Menu {X Y} { tk_popup [$self MenuWidget] $X $Y }

    method MenuWidget {} {
        set m $win.menu
        if {[winfo exists $m]} { return $m }
        menu $m -tearoff 0
        $m add command -label "Open"              -command [mymethod Open]
        $m add command -label "Show in folder"    -command [mymethod OpenFolder]
        $m add command -label "Delete from cache" -command [mymethod Uncache]
        return $m
    }

    method OpenFolder {} { $self Cb openfolder $options(-url) }

    # Drop the cached copy on disk and the inline thumbnail; the message keeps
    # its caption/chip and re-fetches the next time the thumbnail is requested.
    method Uncache {} {
        $self dropImage
        $self Cb uncache $options(-url)
    }
}

# Open a downloaded attachment with the platform's default handler.
proc attachment_os_open {path} {
    catch {
        if {$::tcl_platform(os) eq "Darwin"} {
            exec open $path &
        } elseif {$::tcl_platform(platform) eq "windows"} {
            exec cmd /c start "" $path &
        } else {
            exec xdg-open $path &
        }
    }
}
