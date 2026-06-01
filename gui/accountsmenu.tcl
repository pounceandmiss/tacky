snit::type accountsmenu {
    option -menubar -readonly yes
    option -tacky -default ::tacky -readonly yes
    option -parent -default "" -readonly yes
    option -open-here-command -default ""
    option -open-window-command -default ""
    option -add-account-command -default ""
    option -join-room-command -default ""

    variable accounts {}

    constructor args {
        $self configurelist $args

        set m $options(-menubar).accounts
        menu $m -tearoff 0 -postcommand [mymethod Rebuild]
        $options(-menubar) add cascade -label "Accounts" -menu $m

        set t $options(-tacky)
        $t listen -tag $self account <Added>    [mymethod OnAdded]
        $t listen -tag $self account <Enabled>  [mymethod OnEnabled]
        $t listen -tag $self account <Disabled> [mymethod OnDisabled]
        $t listen -tag $self account <Removed>  [mymethod OnRemoved]

        # Seed initial state from two async queries.
        # OnSeedAll uses dict-exists guard so order doesn't matter.
        $t account list -tag $self -command [mymethod OnSeedAll]
        $t account list -enabled 1 -tag $self -command [mymethod OnSeedEnabled]
    }

    destructor {
        catch {$options(-tacky) unlisten $self}
        catch {destroy $options(-menubar).accounts}
    }

    # --- Seeding ---

    method OnSeedAll {result} {
        foreach jid $result {
            if {![dict exists $accounts $jid]} {
                dict set accounts $jid 0
            }
        }
    }

    method OnSeedEnabled {result} {
        foreach jid $result {
            dict set accounts $jid 1
        }
    }

    # --- Event handlers ---

    method OnAdded {ev}    { dict set accounts [dict get $ev -acc] 0 }
    method OnEnabled {ev}  { dict set accounts [dict get $ev -acc] 1 }
    method OnDisabled {ev} { dict set accounts [dict get $ev -acc] 0 }
    method OnRemoved {ev}  { dict unset accounts [dict get $ev -acc] }

    # --- Menu rebuild (called by -postcommand each time menu opens) ---

    method Rebuild {} {
        set m $options(-menubar).accounts
        $m delete 0 end
        foreach child [winfo children $m] {
            destroy $child
        }

        dict for {jid enabled} $accounts {
            set safe [string map {@ _ . _} $jid]
            set sub $m.mng_$safe
            menu $sub -tearoff 0

            if {$enabled} {
                $sub add command -label "Open in This Window" \
                    -command [list {*}$options(-open-here-command) $jid]
                $sub add command -label "Open in New Window" \
                    -command [list {*}$options(-open-window-command) $jid]
                $sub add separator
            }

            $sub add command -label "Settings..." \
                -command [list profilesettings open $jid]

            if {$enabled} {
                $sub add command -label "Disable" \
                    -command [list $options(-tacky) account disable -acc $jid]
            } else {
                $sub add command -label "Enable" \
                    -command [list $options(-tacky) account enable -acc $jid]
            }

            $sub add command -label "Remove..." \
                -command [mymethod RemoveAccount $jid]

            set label $jid
            if {!$enabled} { append label " (disabled)" }
            $m add cascade -label $label -menu $sub
        }

        $m add separator

        $m add command -label "Add Account..." \
            -command $options(-add-account-command)
        $m add command -label "Join Room..." \
            -command $options(-join-room-command)
        $m add command -label "Create Room..." \
            -command $options(-join-room-command)
    }

    # --- Actions ---

    method RemoveAccount {jid} {
        set args [list -type yesno -icon warning \
            -title "Remove Account" \
            -message "Remove account $jid?\nThis cannot be undone."]
        if {$options(-parent) ne "" && [winfo exists $options(-parent)]} {
            lappend args -parent $options(-parent)
        }
        if {[tk_messageBox {*}$args] eq "yes"} {
            $options(-tacky) account remove -acc $jid
        }
    }
}
