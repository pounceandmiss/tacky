# mucparticipantlist - treeview widget showing MUC room occupants.
#
# Groups occupants by role (Moderators, Participants, Visitors) with
# affiliation prefixes and presence-colored tags.
#
# Right-click on an occupant shows a context menu with moderation
# actions (kick, ban, role/affiliation changes) filtered by our
# permissions in the room.
#
# Usage:
#   mucparticipantlist .plist -acc $acc -jid room@conf.local
#   pack .plist

snit::widget mucparticipantlist {
    hulltype ttk::frame

    option -acc -default ""
    option -jid -default ""

    variable tree
    variable legendBtn
    # Maps role name -> treeview item id for group headers
    variable GroupIds -array {}
    # Maps nick -> treeview item id for occupants
    variable NickIds -array {}
    # Maps nick -> occupant dict (role, affiliation, jid, etc.)
    variable OccupantData -array {}

    constructor args {
        $self configurelist $args

        set tree [ttk::treeview $win.tree -show tree -selectmode browse]
        ttk::scrollbar $win.sb -orient vertical -command [list $tree yview]
        $tree configure -yscrollcommand [list $win.sb set]

        set legendBtn [ttk::button $win.legend -text "? Legend" -style Toolbutton \
            -command [list participantlegend show]]

        grid $tree $win.sb -sticky nsew
        grid $legendBtn - -sticky w -padx 4 -pady {2 2}
        grid columnconfigure $win 0 -weight 1
        grid rowconfigure $win 0 -weight 1

        # Presence color tags
        $tree tag configure available -foreground green4
        $tree tag configure away -foreground goldenrod3
        $tree tag configure xa -foreground darkorange3
        $tree tag configure dnd -foreground red3
        $tree tag configure offline -foreground gray50

        # Create group headers
        foreach {role label} {moderator Moderators participant Participants visitor Visitors} {
            set GroupIds($role) [$tree insert {} end -text "$label (0)" -open true]
        }

        # Listen to MUC events
        ::tacky listen -tag $win muc <Presence> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnPresence]
        ::tacky listen -tag $win muc <Unavailable> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnUnavailable]
        ::tacky listen -tag $win muc <NickChanged> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnOccupantNickChanged]
        ::tacky listen -tag $win muc <Left> \
            -acc $options(-acc) -jid $options(-jid) [mymethod OnRoomLeft]

        # Context menu
        bind $tree <Button-3> [mymethod OnRightClick %x %y %X %Y]

        $self LoadOccupants
    }

    destructor {
        catch {::tacky unlisten $win}
    }

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    method LoadOccupants {} {
        ::tacky muc occupants -acc $options(-acc) -jid $options(-jid) \
            -tag $win -command [mymethod OnOccupantsList]
    }

    method OnOccupantsList {occupants} {
        foreach occ $occupants {
            $self UpsertOccupant $occ
        }
        $self UpdateGroupLabels
    }

    method UpsertOccupant {occDict} {
        set nick [dict get $occDict nick]
        set role [dict get $occDict role]
        set affiliation [dict get $occDict affiliation]
        set show [dict get $occDict show]

        # Store full occupant data
        set OccupantData($nick) $occDict

        # Affiliation prefix
        set prefix ""
        switch -- $affiliation {
            owner  { set prefix "* " }
            admin  { set prefix "& " }
            member { set prefix "+ " }
        }

        # Presence tag
        set tag available
        if {$show ne ""} {
            switch -- $show {
                away { set tag away }
                xa   { set tag xa }
                dnd  { set tag dnd }
                chat { set tag available }
            }
        }

        set displayText "${prefix}${nick}"

        # Determine parent group
        set parent {}
        if {[info exists GroupIds($role)]} {
            set parent $GroupIds($role)
        } else {
            set parent $GroupIds(participant)
        }

        if {[info exists NickIds($nick)]} {
            # Update existing item — may have moved groups
            set itemId $NickIds($nick)
            set curParent [$tree parent $itemId]
            if {$curParent ne $parent} {
                $tree move $itemId $parent end
            }
            $tree item $itemId -text $displayText -tags [list $tag]
        } else {
            # Insert new, sorted alphabetically within group
            set idx [$self FindInsertIndex $parent $nick]
            set itemId [$tree insert $parent $idx -text $displayText -tags [list $tag]]
            set NickIds($nick) $itemId
        }
    }

    method RemoveOccupant {nick} {
        if {![info exists NickIds($nick)]} return
        $tree delete $NickIds($nick)
        unset NickIds($nick)
        unset -nocomplain OccupantData($nick)
    }

    method UpdateGroupLabels {} {
        foreach {role label} {moderator Moderators participant Participants visitor Visitors} {
            if {![info exists GroupIds($role)]} continue
            set count [llength [$tree children $GroupIds($role)]]
            $tree item $GroupIds($role) -text "$label ($count)"
        }
    }

    method FindInsertIndex {parent nick} {
        set children [$tree children $parent]
        set nickLower [string tolower $nick]
        set idx 0
        foreach child $children {
            set childText [$tree item $child -text]
            # Strip prefix for comparison
            set childNick [string trimleft $childText "* &+ "]
            if {[string tolower $childNick] > $nickLower} {
                return $idx
            }
            incr idx
        }
        return $idx
    }

    # ------------------------------------------------------------------
    # Context menu
    # ------------------------------------------------------------------

    method OnRightClick {x y X Y} {
        if {$options(-acc) eq "" || $options(-jid) eq ""} return

        set item [$tree identify item $x $y]
        if {$item eq ""} return

        # Don't show menu for group headers
        set groupItems {}
        foreach {_ gid} [array get GroupIds] { lappend groupItems $gid }
        if {$item in $groupItems} return

        $tree selection set $item

        # Find nick from item
        set nick [$self NickFromItem $item]
        if {$nick eq ""} return
        if {![info exists OccupantData($nick)]} return

        $self ShowMenu $nick $X $Y
    }

    method ShowMenu {nick X Y} {
        set caps [dict merge [$self ZeroCaps] \
            [dict getdef $OccupantData($nick) caps {}]]
        set targetJid [dict get $OccupantData($nick) jid]

        set m $win.__ctxmenu
        if {![winfo exists $m]} {
            menu $m -tearoff 0
        }
        $m delete 0 end

        set n 0
        if {[dict get $caps kick]} {
            $m add command -label "Kick..." -command [mymethod DoKick $nick]
            incr n
        }
        if {[dict get $caps ban]} {
            $m add command -label "Ban..." -command [mymethod DoBan $nick $targetJid]
            incr n
        }

        if {[dict get $caps make_moderator] || [dict get $caps grant_voice]
            || [dict get $caps revoke_voice]} {
            if {$n} { $m add separator }
        }
        if {[dict get $caps make_moderator]} {
            $m add command -label "Make Moderator" \
                -command [mymethod DoRole $nick moderator]
            incr n
        }
        if {[dict get $caps grant_voice]} {
            $m add command -label "Grant Voice" \
                -command [mymethod DoRole $nick participant]
            incr n
        }
        if {[dict get $caps revoke_voice]} {
            $m add command -label "Revoke Voice" \
                -command [mymethod DoRole $nick visitor]
            incr n
        }

        if {[dict get $caps grant_membership] || [dict get $caps revoke_membership]} {
            if {$n} { $m add separator }
        }
        if {[dict get $caps grant_membership]} {
            $m add command -label "Grant Membership" \
                -command [mymethod DoAffiliation $targetJid member]
            incr n
        }
        if {[dict get $caps revoke_membership]} {
            $m add command -label "Revoke Membership" \
                -command [mymethod DoAffiliation $targetJid none]
            incr n
        }

        if {$n} {
            tk_popup $m $X $Y
        }
    }

    method ZeroCaps {} {
        return {kick 0 ban 0 make_moderator 0 grant_voice 0 \
            revoke_voice 0 grant_membership 0 revoke_membership 0}
    }

    method NickFromItem {item} {
        foreach {nick itemId} [array get NickIds] {
            if {$itemId eq $item} {
                return $nick
            }
        }
        return ""
    }

    method DoKick {nick} {
        set reason [InputDialog .muc_kick_dlg \
            -title "Kick $nick" \
            -prompt "Reason (optional):"]
        set args [list -acc $options(-acc) -jid $options(-jid) -nick $nick]
        if {$reason ne ""} {
            lappend args -reason $reason
        }
        lappend args -tag $win -onerror [mymethod ShowActionError "Kick"]
        ::tacky muc kick {*}$args
    }

    method DoBan {nick jid} {
        set reason [InputDialog .muc_ban_dlg \
            -title "Ban $nick" \
            -prompt "Reason (optional):"]
        set args [list -acc $options(-acc) -jid $options(-jid) \
            -target $jid -affiliation outcast]
        if {$reason ne ""} {
            lappend args -reason $reason
        }
        lappend args -tag $win -onerror [mymethod ShowActionError "Ban"]
        ::tacky muc affiliation {*}$args
    }

    method DoRole {nick role} {
        ::tacky muc role -acc $options(-acc) -jid $options(-jid) \
            -nick $nick -role $role \
            -tag $win -onerror [mymethod ShowActionError "Role change"]
    }

    method DoAffiliation {jid affiliation} {
        ::tacky muc affiliation -acc $options(-acc) -jid $options(-jid) \
            -target $jid -affiliation $affiliation \
            -tag $win -onerror [mymethod ShowActionError "Affiliation change"]
    }

    method ShowActionError {action message} {
        if {![winfo exists $win]} return
        tk_messageBox -icon error -title "$action Failed" \
            -parent [winfo toplevel $win] \
            -message $message
    }

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    method OnPresence {ev} {
        $self UpsertOccupant [dict get $ev -occupant]
        $self UpdateGroupLabels
    }

    method OnUnavailable {ev} {
        $self RemoveOccupant [dict get $ev -nick]
        $self UpdateGroupLabels
    }

    method OnOccupantNickChanged {ev} {
        set oldNick [dict get $ev -oldNick]
        $self RemoveOccupant $oldNick
        # The new nick's presence event will trigger UpsertOccupant
    }

    method OnRoomLeft {ev} {
        array unset NickIds
        array unset OccupantData
        foreach {role id} [array get GroupIds] {
            foreach child [$tree children $id] {
                $tree delete $child
            }
        }
        $self UpdateGroupLabels
    }
}
