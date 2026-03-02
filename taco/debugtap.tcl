snit::type taco_debugtap {
    option -taco -default ""

    variable TapId 0
    variable Taps -array {}       ;# id -> {command, connKey, conn}
    variable ConnTaps -array {}   ;# connKey -> list of tap IDs

    tackymethod on {args} {
        set cmd [dict get $args -onstanza]
        set id [incr TapId]

        if {[dict exists $args -acc]} {
            set jid [dict get $args -acc]
            set connKey acc:$jid
            set connCmd [list [$options(-taco) client $jid] conn]
        } elseif {[dict exists $args -token]} {
            set tok [dict get $args -token]
            set connKey reg:$tok
            set session [$options(-taco) register session -token $tok]
            set connCmd [list $session conn]
        }

        set Taps($id) [dict create command $cmd connKey $connKey conn $connCmd]
        lappend ConnTaps($connKey) $id
        if {[llength $ConnTaps($connKey)] == 1} {
            {*}$connCmd configure -ondebugstanza \
                [mymethod OnDebugStanza $connKey]
        }
        return $id
    }

    method off {args} {
        set tapId [dict get $args -tap]
        if {![info exists Taps($tapId)]} return
        set connKey [dict get $Taps($tapId) connKey]
        set connCmd [dict get $Taps($tapId) conn]

        set idx [lsearch -exact $ConnTaps($connKey) $tapId]
        if {$idx >= 0} {
            set ConnTaps($connKey) [lreplace $ConnTaps($connKey) $idx $idx]
        }

        if {[llength $ConnTaps($connKey)] == 0} {
            catch { {*}$connCmd configure -ondebugstanza "" }
            unset ConnTaps($connKey)
        }
        unset Taps($tapId)
    }

    method write {args} {
        set tapId [dict get $args -tap]
        set stanza [dict get $args -stanza]
        {*}[dict get $Taps($tapId) conn] writeStanza $stanza
    }

    method OnDebugStanza {connKey dir stanza} {
        if {![info exists ConnTaps($connKey)]} return
        foreach id $ConnTaps($connKey) {
            {*}[dict get $Taps($id) command] -dir $dir -stanza $stanza
        }
    }
}
