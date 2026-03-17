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
        grid $jidLabel $jidEntry -sticky ew
        grid $passwordLabel $passwordEntry -sticky ew
        grid columnconfigure $win $passwordEntry -weight 1
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

        set inner [ttk::frame $win.inner]
        raise $win.proceed

        install accountdetails using jidpassword \
            $win.accountdetails \
            -array $options(-array)

        install progressbar using ttk::progressbar $win.progressbar

        install statuslabel using \
            ttk::label $win.statuslabel

        pack $accountdetails -in $inner -fill x
        pack $statuslabel -in $inner -fill x
        pack $progressbar -in $inner -fill x
        pack $proceed -in $inner
        if {$options(-back) ne ""} {
            install backbutton using ttk::button $win.back -command $options(-back) -text "Back"
            pack $backbutton -in $inner
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
        tacky listen -tag $win conn <Ready> -acc $jid [mymethod OnReady]
        tacky listen -tag $win conn <AuthError> -acc $jid [mymethod OnAuthError]
        tacky listen -tag $win conn <Disconnected> -acc $jid [mymethod OnDisconnected]
        tacky account add -acc $jid -password $pw
        tacky account enable -acc $jid
    }

    method Cancel {} {
        tacky unlisten $win
        catch { tacky account remove -acc $jid }
        $win.progressbar stop
        $win.progressbar configure -mode determinate -value 0
        $win.proceed configure -text "Proceed" -command [mymethod Proceed]
        $win.statuslabel configure -text ""
    }

    method OnBack {} {
        $self Cancel
        {*}$options(-back)
    }

    method OnReady {ev} {
        set succeeded 1
        tacky unlisten $win
        $win.progressbar stop
        $win.progressbar configure -mode determinate -value 0
        $win.proceed configure -text "Proceed" -command [mymethod Proceed]
        if {$options(-onsuccess) ne ""} {
            {*}$options(-onsuccess) $jid
        }
    }

    method OnAuthError {ev} {
        tacky unlisten $win
        set msg "Authentication failed"
        if {[dict exists $ev -message]} {
            set msg [dict get $ev -message]
        }
        $win.progressbar stop
        $win.progressbar configure -mode determinate -value 0
        $win.proceed configure -text "Proceed" -command [mymethod Proceed]
        $win.statuslabel configure -text $msg
    }

    method OnDisconnected {ev} {
        tacky unlisten $win
        set msg "Connection failed"
        if {[dict exists $ev -message]} {
            set msg [dict get $ev -message]
        }
        $win.progressbar stop
        $win.progressbar configure -mode determinate -value 0
        $win.proceed configure -text "Proceed" -command [mymethod Proceed]
        $win.statuslabel configure -text $msg
    }
}

snit::widget regform {
    hulltype ttk::frame
    option -formdata -default {} -readonly yes
    variable FormData -array {}
    variable Widgets -array {}
    variable MediaImages -array {}

    constructor args {
        $self configurelist $args
        array set FormData $options(-formdata)

        set row 0
        if {[info exists FormData(instructions)] && $FormData(instructions) ne ""} {
            ttk::label $win.instructions -text $FormData(instructions) \
                -wraplength 400
            grid $win.instructions -row $row -columnspan 2 -sticky ew -pady {0 5}
            incr row
        }

        foreach var $FormData(fields) {
            set type $FormData(field,$var,type)
            set label $FormData(field,$var,label)

            switch -- $type {
                hidden {
                    continue
                }
                fixed {
                    set val ""
                    if {[info exists FormData(field,$var,value)]} {
                        set val $FormData(field,$var,value)
                    }
                    ttk::label $win.f$row -text $val
                    grid $win.f$row -row $row -columnspan 2 -sticky ew
                }
                text-private {
                    ttk::label $win.l$row -text "$label:"
                    set w [showableentry $win.f$row]
                    set Widgets($var) $w
                    if {[info exists FormData(field,$var,value)]} {
                        $w.entry insert 0 $FormData(field,$var,value)
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
                list-single {
                    ttk::label $win.l$row -text "$label:"
                    set values {}
                    if {[info exists FormData(field,$var,options)]} {
                        foreach opt $FormData(field,$var,options) {
                            lappend values [dict get $opt value]
                        }
                    }
                    set w [ttk::combobox $win.f$row -values $values -state readonly]
                    set Widgets($var) $w
                    if {[info exists FormData(field,$var,value)]} {
                        $w set $FormData(field,$var,value)
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
                default {
                    ttk::label $win.l$row -text "$label:"
                    set w [ttk::entry $win.f$row]
                    set Widgets($var) $w
                    if {[info exists FormData(field,$var,value)]} {
                        $w insert 0 $FormData(field,$var,value)
                    }
                    grid $win.l$row -row $row -column 0 -sticky w
                    grid $w -row $row -column 1 -sticky ew
                }
            }

            if {[info exists FormData(field,$var,media)]} {
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
        foreach var $FormData(fields) {
            set type $FormData(field,$var,type)
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
        set s1inner [ttk::frame $s1.inner]
        ttk::label $s1.label -text "Enter server address"
        ttk::entry $s1.server
        ttk::button $s1.proceed -text "Proceed" \
            -command [mymethod FetchForm]
        ttk::progressbar $s1.progressbar
        ttk::label $s1.statuslabel
        pack $s1.label -in $s1inner -fill x
        pack $s1.server -in $s1inner -fill x
        pack $s1.proceed -in $s1inner
        pack $s1.statuslabel -in $s1inner -fill x
        pack $s1.progressbar -in $s1inner -fill x
        if {$options(-back) ne ""} {
            ttk::button $s1.back -text "Back" -command $options(-back)
            pack $s1.back -in $s1inner
        }
        pack $s1inner -expand yes

        # Step 2 — form fill (regform widget added dynamically)
        set s2 [ttk::frame $pages.step2]
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
        tacky register connect -host $server -token $win
    }

    method CancelFetch {} {
        tacky register cancel -token $win
        tacky unlisten $win
        $pages.step1.progressbar stop
        $pages.step1.progressbar configure -mode determinate -value 0
        $pages.step1.proceed configure -text "Proceed" \
            -command [mymethod FetchForm]
        $pages.step1.statuslabel configure -text ""
    }

    method OnForm {ev} {
        $pages.step1.progressbar stop
        $pages.step1.progressbar configure -mode determinate -value 0
        $pages.step1.proceed configure -text "Proceed" \
            -command [mymethod FetchForm]

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
        pack $formwidget -expand yes -fill both
        pack $pages.step2.statuslabel -fill x
        pack $pages.step2.progressbar -fill x
        pack $pages.step2.submit
        pack $pages.step2.back

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
        $pages.step2.progressbar stop
        $pages.step2.progressbar configure -mode determinate -value 0
        $pages.step2.submit configure -text "Submit" \
            -command [mymethod OnSubmit]
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
        $pages.step2.progressbar stop
        $pages.step2.progressbar configure -mode determinate -value 0
        $pages.step2.submit configure -text "Submit" \
            -command [mymethod OnSubmit]

        # Extract username/password from submitted form values
        set server [$pages.step1.server get]
        set username ""
        set pw ""
        foreach {var val} $lastValues {
            if {$var eq "username"} { set username $val }
            if {$var eq "password"} { set pw $val }
        }
        if {$username ne "" && $server ne ""} {
            tacky account add -acc $username@$server -password $pw
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
        if {$step == 1} {
            $pages.step1.progressbar stop
            $pages.step1.progressbar configure -mode determinate -value 0
            $pages.step1.proceed configure -text "Proceed" \
                -command [mymethod FetchForm]
            $pages.step1.statuslabel configure -text $msg
        } else {
            $pages.step2.progressbar stop
            $pages.step2.progressbar configure -mode determinate -value 0
            $pages.step2.submit configure -text "Submit" \
                -command [mymethod OnSubmit]
            $pages.step2.statuslabel configure -text $msg
        }
    }
}

snit::widget initialsetupchoice {
    hulltype ttk::frame
    component signup
    component signin

    constructor args {
        set inner [ttk::frame $win.inner]
        install signup using ttk::button $win.signup \
            -text "Create an account"
        install signin using ttk::button $win.signin \
            -text "I already have an account"
        pack $signup -in $inner
        pack $signin -in $inner
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
