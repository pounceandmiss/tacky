snit::widget jidpassword {
    # jid:      [...]
    # password: [...]

    hulltype ttk::frame
    component jidLabel
    component jidEntry
    component passwordLabel
    component passwordEntry
    # Will contain fields: jid, password
    option -array

    constructor args {
        $self configurelist $args
        install jidLabel using ttk::label $win.jidLabel \
            -text "Jid: "
        install jidEntry using ttk::entry $win.jidEntry \
            -textvariable [set options(-array)](jid)
        install passwordLabel using ttk::label $win.passwordLabel \
            -text "Password: "
        install passwordEntry using showableentry $win.passwordEntry \
            -textvariable  [set options(-array)](password)
        grid $jidLabel $jidEntry -sticky ew -padx 4 -pady 4
        grid $passwordLabel $passwordEntry -sticky ew -padx 4 -pady 4
        grid columnconfigure $win $passwordEntry -weight 1
    }
}

# The account's host, port, tls and srv. With -collapsible the fields hide
# behind a checkbutton, and `args` is empty while it is off.
#
#   connectionfields .c ?-collapsible 1?
#   .c args            -> {-host h -port p -tls t -srv 0|1} or {}
#   .c load $fields    fill from an `account get` dict
snit::widget connectionfields {
    hulltype ttk::frame
    option -collapsible -default 1 -readonly yes

    typevariable Modes {
        Automatic auto
        STARTTLS starttls
        "Direct TLS" direct
        "None (unencrypted)" none
    }

    variable custom 0
    variable host ""
    variable port ""
    variable mode Automatic
    variable srv 1

    constructor args {
        $self configurelist $args
        set f [ttk::frame $win.fields]
        ttk::label $f.hostlbl -text "Host"
        ttk::entry $f.host -textvariable [myvar host]
        ttk::label $f.portlbl -text "Port"
        ttk::spinbox $f.port -from 1 -to 65535 -width 7 \
            -textvariable [myvar port]
        ttk::label $f.modelbl -text "Security"
        ttk::combobox $f.mode -state readonly -textvariable [myvar mode] \
            -values [dict keys $Modes]
        ttk::checkbutton $f.srv -text "Look up the server in DNS (SRV)" \
            -variable [myvar srv]
        ttk::label $f.hint -foreground gray50 -font TkSmallCaptionFont \
            -text "Empty host and port: found automatically"
        ttk::label $f.warning -foreground red3 \
            -text "Password and messages are sent unencrypted"
        grid $f.hostlbl $f.host -sticky ew -padx 4 -pady 2
        grid $f.portlbl $f.port -sticky w -padx 4 -pady 2
        grid $f.modelbl $f.mode -sticky w -padx 4 -pady 2
        grid x $f.srv -sticky w -padx 4 -pady 2
        grid x $f.hint -sticky w -padx 4
        grid x $f.warning -sticky w -padx 4
        grid configure $f.hostlbl $f.portlbl $f.modelbl -sticky w
        grid columnconfigure $f 1 -weight 1
        grid remove $f.warning

        if {$options(-collapsible)} {
            ttk::checkbutton $win.custom -text "Custom server address" \
                -variable [myvar custom] -command [mymethod Show]
            pack $win.custom -anchor w
        } else {
            set custom 1
        }
        trace add variable [myvar mode] write [mymethod Changed]
        trace add variable [myvar host] write [mymethod Changed]
        trace add variable [myvar port] write [mymethod Changed]
        $self Show
        $self Changed
    }

    method Show {} {
        if {$custom} {
            pack $win.fields -fill x -pady 2
        } else {
            pack forget $win.fields
        }
    }

    # SRV only applies with no host and no port
    method Changed {args} {
        set f $win.fields
        if {![winfo exists $f.srv]} return
        $f.srv state [expr {$host eq "" && $port eq "" ? "!disabled" : "disabled"}]
        if {[dict get $Modes $mode] eq "none"} {
            grid $f.warning
        } else {
            grid remove $f.warning
        }
    }

    method args {} {
        if {!$custom} { return {} }
        set p [string trim $port]
        list -host [string trim $host] -port [expr {$p eq "" ? 0 : $p}] \
            -tls [dict get $Modes $mode] -srv $srv
    }

    method load {fields} {
        set host [dict get $fields host]
        set p [dict get $fields port]
        set port [expr {$p == 0 ? "" : $p}]
        set mode Automatic
        dict for {text value} $Modes {
            if {$value eq [dict get $fields tls]} { set mode $text }
        }
        set srv [dict get $fields srv]
        if {$options(-collapsible)} {
            set custom [expr {$host ne "" || $port ne "" || $mode ne "Automatic"
                              || !$srv}]
            $self Show
        }
    }
}

snit::widget signinhull {
    # jid:      [...]
    # password: [...]
    # [   Proceed   ]

    hulltype ttk::frame
    component accountdetails
    component progressbar
    component proceed
    component statuslabel
    component backbutton
    # if specified a "back" button will appear and execute this command
    option -back -readonly yes
    # proceed button command
    delegate option -proceed to proceed as -command
    # Will contain all fields: jid, password
    option -array

    constructor args {
        install proceed using \
            ttk::button $win.proceed \
            -text "Proceed"
        $self configurelist $args

        set inner [ttk::frame $win.inner -padding 16]
        raise $win.proceed

        install accountdetails using jidpassword \
            $win.accountdetails \
            -array $options(-array)
        connectionfields $win.connection

        install progressbar using ttk::progressbar $win.progressbar

        install statuslabel using \
            ttk::label $win.statuslabel

        pack $accountdetails -in $inner -fill x -pady 4
        pack $win.connection -in $inner -fill x -pady 4
        pack $statuslabel -in $inner -fill x -pady 4
        pack $progressbar -in $inner -fill x -pady 4
        pack $proceed -in $inner -pady 8
        if {$options(-back) ne ""} {
            install backbutton using ttk::button $win.back -command $options(-back) -text "Back"
            pack $backbutton -in $inner -pady 4
        }
        pack $inner -expand yes
    }
}

snit::widgetadaptor signin {
    variable Data
    variable jid ""
    variable succeeded 0
    option -onsuccess -default ""
    option -back -readonly yes

    constructor args {
        array set Data {jid "" password ""}
        # Parse args before installhull — $self doesn't exist yet
        array set opts {-onsuccess "" -back ""}
        array set opts $args
        set options(-onsuccess) $opts(-onsuccess)
        set options(-back) $opts(-back)
        set backCmd $opts(-back)
        if {$backCmd ne ""} {
            set backCmd [mymethod OnBack]
        }
        installhull using signinhull \
            -array [myvar Data] \
            -proceed [mymethod Proceed] \
            -back $backCmd
    }

    destructor {
        tacky unlisten $win
        if {!$succeeded && $jid ne ""} {
            catch { tacky account remove -acc $jid }
        }
    }

    method Proceed {} {
        set jid $Data(jid)
        set pw $Data(password)
        if {$jid eq "" || $pw eq ""} {
            $win.statuslabel configure -text "Please enter JID and password"
            return
        }
        $win.progressbar configure -mode indeterminate
        $win.progressbar start
        $win.proceed configure -text "Cancel" -command [mymethod Cancel]
        $win.statuslabel configure -text ""
        tacky listen -tag $win conn <State> -acc $jid -state connected \
            [mymethod OnConnected]
        tacky listen -tag $win conn <AuthError> -acc $jid \
            [mymethod OnFailed "Authentication failed"]
        tacky listen -tag $win conn <ConnError> -acc $jid \
            [mymethod OnFailed "Connection failed"]
        # After a refused add the enable fails too; only the add's error shows
        tacky account add -acc $jid -password $pw {*}[$win.connection args] \
            -tag $win -onerror [mymethod OnAddError]
        tacky account enable -acc $jid -tag $win -onerror {apply {{msg} {}}}
    }

    method OnAddError {msg} {
        tacky unlisten $win
        $self Idle
        $win.statuslabel configure -text $msg
    }

    method Cancel {} {
        tacky unlisten $win
        catch { tacky account remove -acc $jid }
        $self Idle
        $win.statuslabel configure -text ""
    }

    method OnBack {} {
        $self Cancel
        {*}$options(-back)
    }

    method OnConnected {ev} {
        set succeeded 1
        tacky unlisten $win
        $self Idle
        if {$options(-onsuccess) ne ""} {
            {*}$options(-onsuccess) $jid
        }
    }

    # The attempt is over, whatever the outcome: stop the spinner and put the
    # button back to "Proceed".
    method Idle {} {
        $win.progressbar stop
        $win.progressbar configure -mode determinate -value 0
        $win.proceed configure -text "Proceed" -command [mymethod Proceed]
    }

    # The backend would keep retrying a connection error; the next Proceed
    # adds the account afresh.
    method OnFailed {fallback ev} {
        tacky unlisten $win
        catch { tacky account remove -acc $jid }
        set msg [expr {[dict exists $ev -message]
            ? [dict get $ev -message] : $fallback}]
        $self Idle
        $win.statuslabel configure -text $msg
    }
}

snit::widget regform {
    hulltype ttk::frame
    option -formdata -default {} -readonly yes
    variable FormDict {}
    variable Widgets -array {}
    variable MediaImages -array {}

    constructor args {
        $self configurelist $args
        set FormDict $options(-formdata)

        set row 0
        if {[dict exists $FormDict instructions] && [dict get $FormDict instructions] ne ""} {
            ttk::label $win.instructions -text [dict get $FormDict instructions] \
                -wraplength 400
            grid $win.instructions -row $row -columnspan 2 -sticky ew -pady {0 5}
            incr row
        }

        foreach field [dict get $FormDict fields] {
            set var [dict get $field var]
            set type [dict get $field type]
            set label [dict get $field label]
            set val [lindex [dict get $field value] 0]

            switch -- $type {
                hidden {
                    continue
                }
                fixed {
                    ttk::label $win.f$row -text $val
                    grid $win.f$row -row $row -columnspan 2 -sticky ew
                }
                text-private {
                    ttk::label $win.l$row -text "$label:"
                    set w [showableentry $win.f$row]
                    set Widgets($var) $w
                    if {$val ne ""} {
                        $w.entry insert 0 $val
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
                list-single {
                    ttk::label $win.l$row -text "$label:"
                    set values {}
                    if {[dict exists $field options]} {
                        foreach opt [dict get $field options] {
                            lappend values [dict get $opt value]
                        }
                    }
                    set w [ttk::combobox $win.f$row -values $values -state readonly]
                    set Widgets($var) $w
                    if {$val ne ""} {
                        $w set $val
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
                default {
                    ttk::label $win.l$row -text "$label:"
                    set w [ttk::entry $win.f$row]
                    set Widgets($var) $w
                    if {$val ne ""} {
                        $w insert 0 $val
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
            }

            if {[dict exists $field media]} {
                incr row
                ttk::label $win.media_$row -text "(loading media...)"
                set Widgets(media,$var) $win.media_$row
                grid $win.media_$row -row $row -columnspan 2
            }

            incr row
        }
        grid columnconfigure $win 1 -weight 1
    }

    destructor {
        foreach {key img} [array get MediaImages] {
            catch {image delete $img}
        }
    }

    method setMedia {var data} {
        set img [image create photo $win.img_[clock microseconds] -data $data]
        set MediaImages($var) $img
        if {[info exists Widgets(media,$var)]} {
            $Widgets(media,$var) configure -image $img -text ""
        }
    }

    method values {} {
        set result {}
        foreach field [dict get $FormDict fields] {
            set var [dict get $field var]
            set type [dict get $field type]
            if {$type in {hidden fixed}} continue
            if {![info exists Widgets($var)]} continue
            set w $Widgets($var)
            if {$type eq "text-private"} {
                lappend result $var [$w.entry get]
            } else {
                lappend result $var [$w get]
            }
        }
        return $result
    }
}

snit::widget signup {
    hulltype ttk::frame
    component pages
    variable formwidget ""
    variable step 1
    variable lastValues {}
    option -onsuccess -default ""
    option -back -readonly yes

    constructor args {
        $self configurelist $args

        set token $win

        install pages using pages $win.pages

        # Step 1 — server address
        set s1 [ttk::frame $pages.step1]
        set s1inner [ttk::frame $s1.inner -padding 16]
        ttk::label $s1.label -text "Enter server address"
        ttk::entry $s1.server
        connectionfields $s1.connection
        ttk::button $s1.proceed -text "Proceed" \
            -command [mymethod FetchForm]
        ttk::progressbar $s1.progressbar
        ttk::label $s1.statuslabel
        pack $s1.label -in $s1inner -fill x -pady 4
        pack $s1.server -in $s1inner -fill x -pady 4
        pack $s1.connection -in $s1inner -fill x -pady 4
        pack $s1.proceed -in $s1inner -pady 8
        pack $s1.statuslabel -in $s1inner -fill x -pady 4
        pack $s1.progressbar -in $s1inner -fill x -pady 4
        if {$options(-back) ne ""} {
            ttk::button $s1.back -text "Back" -command $options(-back)
            pack $s1.back -in $s1inner -pady 4
        }
        pack $s1inner -expand yes

        # Step 2 — form fill (regform widget added dynamically)
        set s2 [ttk::frame $pages.step2 -padding 16]
        ttk::button $s2.submit -text "Submit" \
            -command [mymethod OnSubmit]
        ttk::button $s2.back -text "Back" \
            -command [mymethod BackToServer]
        ttk::progressbar $s2.progressbar
        ttk::label $s2.statuslabel
        # regform widget will be packed first in OnForm

        $pages add $s1
        $pages add $s2
        $pages raise $s1
        pack $pages -expand yes -fill both
    }

    destructor {
        tacky unlisten $win
        catch { tacky register cancel -token $win }
    }

    method FetchForm {} {
        set server [$pages.step1.server get]
        if {$server eq ""} {
            $pages.step1.statuslabel configure -text "Please enter a server address"
            return
        }
        $pages.step1.statuslabel configure -text ""
        $pages.step1.progressbar configure -mode indeterminate
        $pages.step1.progressbar start
        $pages.step1.proceed configure -text "Cancel" \
            -command [mymethod CancelFetch]
        set step 1
        tacky listen -tag $win register <Form> -token $win \
            [mymethod OnForm]
        tacky listen -tag $win register <MediaReady> -token $win \
            [mymethod OnMediaReady]
        tacky listen -tag $win register <Success> -token $win \
            [mymethod OnSuccess]
        tacky listen -tag $win register <Error> -token $win \
            [mymethod OnError]
        tacky register connect -domain $server -token $win \
            {*}[$pages.step1.connection args] \
            -tag $win -onerror [mymethod OnConnectError]
    }

    method OnConnectError {msg} {
        tacky unlisten $win
        $self Idle 1
        $pages.step1.statuslabel configure -text $msg
    }

    # A step's request is over, whatever the outcome: stop its spinner and put
    # its action button back.
    method Idle {step} {
        if {$step == 1} {
            set frame $pages.step1
            set button proceed
            set label "Proceed"
            set command [mymethod FetchForm]
        } else {
            set frame $pages.step2
            set button submit
            set label "Submit"
            set command [mymethod OnSubmit]
        }
        $frame.progressbar stop
        $frame.progressbar configure -mode determinate -value 0
        $frame.$button configure -text $label -command $command
    }

    method CancelFetch {} {
        tacky register cancel -token $win
        tacky unlisten $win
        $self Idle 1
        $pages.step1.statuslabel configure -text ""
    }

    method OnForm {ev} {
        $self Idle 1
        tacky register form -token $win -tag $win -command [mymethod OnFormData]
    }

    method OnFormData {formdata} {
        # Destroy previous form widget if any
        if {$formwidget ne "" && [winfo exists $formwidget]} {
            destroy $formwidget
        }
        set scrollable [scrollable $pages.step2.formscroll]
        set form [regform $scrollable.form -formdata $formdata]
        $scrollable setwidget $form
        set formwidget $scrollable

        # Pack step2 children in order
        pack $formwidget -expand yes -fill both -pady 4
        pack $pages.step2.statuslabel -fill x -pady 4
        pack $pages.step2.progressbar -fill x -pady 4
        pack $pages.step2.submit -pady 8
        pack $pages.step2.back -pady 4

        set step 2
        $pages raise $pages.step2
    }

    method OnMediaReady {ev} {
        set var [dict get $ev -var]
        tacky register media -token $win -var $var \
            -tag $win -command [mymethod OnMediaData $var]
    }

    method OnMediaData {var data} {
        if {$data ne "" && $formwidget ne "" && [winfo exists $formwidget]} {
            $formwidget.form setMedia $var $data
        }
    }

    method OnSubmit {} {
        set lastValues [$formwidget.form values]
        $pages.step2.statuslabel configure -text ""
        $pages.step2.progressbar configure -mode indeterminate
        $pages.step2.progressbar start
        $pages.step2.submit configure -text "Cancel" \
            -command [mymethod CancelSubmit]
        tacky register submit -token $win -values $lastValues
    }

    method CancelSubmit {} {
        tacky register cancel -token $win
        tacky unlisten $win
        $self Idle 2
        $pages.step2.statuslabel configure -text ""
    }

    method BackToServer {} {
        tacky register cancel -token $win
        tacky unlisten $win
        $pages.step2.statuslabel configure -text ""
        set step 1
        $pages raise $pages.step1
    }

    method OnSuccess {ev} {
        $self Idle 2

        # Extract username/password from submitted form values
        set server [$pages.step1.server get]
        set username ""
        set pw ""
        foreach {var val} $lastValues {
            if {$var eq "username"} { set username $val }
            if {$var eq "password"} { set pw $val }
        }
        if {$username ne "" && $server ne ""} {
            tacky account add -acc $username@$server -password $pw \
                {*}[$pages.step1.connection args]
        }

        tacky unlisten $win
        if {$options(-onsuccess) ne ""} {
            {*}$options(-onsuccess) $username@$server
        }
    }

    method OnError {ev} {
        set msg "Registration failed"
        if {[dict exists $ev -message]} {
            set msg [dict get $ev -message]
        }
        $self Idle $step
        $pages.step$step.statuslabel configure -text $msg
    }
}

snit::widget initialsetupchoice {
    hulltype ttk::frame
    component signup
    component signin

    constructor args {
        set inner [ttk::frame $win.inner -padding 16]
        install signup using ttk::button $win.signup \
            -text "Create an account"
        install signin using ttk::button $win.signin \
            -text "I already have an account"
        pack $signup -in $inner -pady 4
        pack $signin -in $inner -pady 4
        pack $inner -expand yes
    }
}

snit::widget initialsetup {
    hulltype ttk::frame
    component pages
    component choice
    component signin
    component signup
    option -onsuccess -default ""

    constructor args {
        $self configurelist $args
        install pages using pages $win.pages
        install choice using initialsetupchoice $pages.choice
        install signin using signin $pages.signin \
            -onsuccess $options(-onsuccess) \
            -back [list $pages raise $choice]
        install signup using signup $pages.signup \
            -onsuccess $options(-onsuccess) \
            -back [list $pages raise $choice]

        $choice.signin configure -command [list $pages raise $signin]
        $choice.signup configure -command [list $pages raise $signup]

        # Draw widgets
        $pages add $signin
        $pages add $choice
        $pages add $signup
        $pages raise $choice
        pack $pages -expand yes -fill both
    }
}
