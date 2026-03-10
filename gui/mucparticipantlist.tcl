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
	    -command [mymethod OnOccupantsList]
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

	set targetData $OccupantData($nick)

	# Get our own data
	::tacky muc myNick -acc $options(-acc) -jid $options(-jid) \
	    -command [mymethod OnMyNickForMenu $nick $targetData $X $Y]
    }

    method OnMyNickForMenu {nick targetData X Y myNick} {
	if {![winfo exists $win]} return
	if {$myNick eq "" || $myNick eq $nick} return
	if {![info exists OccupantData($myNick)]} return
	set myData $OccupantData($myNick)

	set myRole [dict get $myData role]
	set myAffil [dict get $myData affiliation]
	set targetRole [dict get $targetData role]
	set targetAffil [dict get $targetData affiliation]
	set targetJid [dict get $targetData jid]

	set m $win.__ctxmenu
	if {![winfo exists $m]} {
	    menu $m -tearoff 0
	}
	$m delete 0 end

	set hasItems 0

	# Kick: our role=moderator, target affiliation < admin
	if {$myRole eq "moderator" && $targetAffil ni {admin owner}} {
	    $m add command -label "Kick..." \
		-command [mymethod DoKick $nick]
	    set hasItems 1
	}

	# Ban: our affiliation >= admin, target affiliation < ours, jid known
	if {[$self AffilLevel $myAffil] >= [$self AffilLevel admin]
	    && [$self AffilLevel $targetAffil] < [$self AffilLevel $myAffil]
	    && $targetJid ne ""} {
	    $m add command -label "Ban..." \
		-command [mymethod DoBan $nick $targetJid]
	    set hasItems 1
	}

	# Role changes
	if {$hasItems} {
	    $m add separator
	}
	set roleItems 0

	# Make Moderator: our affiliation >= admin, target not already moderator
	if {[$self AffilLevel $myAffil] >= [$self AffilLevel admin]
	    && $targetRole ne "moderator"} {
	    $m add command -label "Make Moderator" \
		-command [mymethod DoRole $nick moderator]
	    set roleItems 1
	}

	# Grant Voice: our role=moderator, target role=visitor
	if {$myRole eq "moderator" && $targetRole eq "visitor"} {
	    $m add command -label "Grant Voice" \
		-command [mymethod DoRole $nick participant]
	    set roleItems 1
	}

	# Revoke Voice: our role=moderator, target role=participant
	if {$myRole eq "moderator" && $targetRole eq "participant"} {
	    $m add command -label "Revoke Voice" \
		-command [mymethod DoRole $nick visitor]
	    set roleItems 1
	}

	set hasItems [expr {$hasItems || $roleItems}]

	# Affiliation changes
	if {[$self AffilLevel $myAffil] >= [$self AffilLevel admin]} {
	    if {$roleItems} {
		$m add separator
	    }
	    # Grant Membership: target affiliation=none
	    if {$targetAffil eq "none" && $targetJid ne ""} {
		$m add command -label "Grant Membership" \
		    -command [mymethod DoAffiliation $targetJid member]
		set hasItems 1
	    }
	    # Revoke Membership: target affiliation=member
	    if {$targetAffil eq "member" && $targetJid ne ""} {
		$m add command -label "Revoke Membership" \
		    -command [mymethod DoAffiliation $targetJid none]
		set hasItems 1
	    }
	}

	if {$hasItems} {
	    tk_popup $m $X $Y
	}
    }

    method NickFromItem {item} {
	foreach {nick itemId} [array get NickIds] {
	    if {$itemId eq $item} {
		return $nick
	    }
	}
	return ""
    }

    # Numeric affiliation level for comparison
    method AffilLevel {affiliation} {
	switch -- $affiliation {
	    owner  { return 4 }
	    admin  { return 3 }
	    member { return 2 }
	    none   { return 1 }
	    outcast { return 0 }
	    default { return 1 }
	}
    }

    method DoKick {nick} {
	set reason [InputDialog .muc_kick_dlg \
	    -title "Kick $nick" \
	    -prompt "Reason (optional):"]
	set args [list -acc $options(-acc) -jid $options(-jid) -nick $nick]
	if {$reason ne ""} {
	    lappend args -reason $reason
	}
	lappend args -command [mymethod OnActionError "Kick"]
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
	lappend args -command [mymethod OnActionError "Ban"]
	::tacky muc affiliation {*}$args
    }

    method DoRole {nick role} {
	::tacky muc role -acc $options(-acc) -jid $options(-jid) \
	    -nick $nick -role $role \
	    -command [mymethod OnActionError "Role change"]
    }

    method DoAffiliation {jid affiliation} {
	::tacky muc affiliation -acc $options(-acc) -jid $options(-jid) \
	    -target $jid -affiliation $affiliation \
	    -command [mymethod OnActionError "Affiliation change"]
    }

    method OnActionError {action stanza} {
	set type_ [xsearch $stanza -get @type]
	if {$type_ eq "error"} {
	    set errorType [xsearch $stanza error * -get tag]
	    tk_messageBox -icon error -title "$action Failed" \
		-message "$action failed: $errorType"
	}
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
