package require control
package require snit

# authornames - what to call the author of a message in one chat.
#
# Owns the name cache and its subscription, so anything rendering that chat
# asks the same object rather than keeping its own copy. Resolution is a
# fallback chain: the cached display name, else the resource of the JID (a MUC
# nick), else the JID itself, which is what a 1:1 leaves after normalisation.
#
# `-show-jid-setting` opts a 1:1 chat into the global show_jid_in_1to1
# preference, which renders bare JIDs in place of resolved names. A MUC never
# does this, so it leaves the option off and never subscribes.
snit::type authornames {
    option -acc  -readonly yes
    option -chat -readonly yes
    option -tag  -readonly yes
    option -show-jid-setting -default 0 -readonly yes

    # Fires when a JID's label changed, as {*}$cmd $jid $label. A host repaints
    # whatever it already drew for that author.
    option -changed-command -default control::no-op

    variable Names
    variable ShowJid 0

    constructor args {
        $self configurelist $args
        set Names [dict create]
        ::tacky listen -tag $options(-tag) author <Changed> \
            -acc $options(-acc) -chat $options(-chat) [mymethod OnChanged]
        ::tacky author get -acc $options(-acc) -chat $options(-chat) \
            -command [mymethod OnSeed]
        if {$options(-show-jid-setting)} {
            ::tacky observe -tag $options(-tag) setting <Changed> \
                -key show_jid_in_1to1 [mymethod OnShowJidSetting]
        }
    }

    destructor {
        catch {::tacky unlisten $options(-tag)}
    }

    # What to call this author.
    method label {jid} {
        if {$ShowJid} { return $jid }
        if {[dict exists $Names $jid]} { return [dict get $Names $jid] }
        set resource [jid resource $jid]
        return [expr {$resource eq "" ? $jid : $resource}]
    }

    # The initial snapshot may land after history has already been rendered, so
    # announce every name rather than assuming nothing is drawn yet.
    method OnSeed {names} {
        set Names $names
        $self AnnounceAll
    }

    method OnChanged {ev} {
        set jid [dict get $ev -from]
        dict set Names $jid [dict get $ev -name]
        {*}$options(-changed-command) $jid [$self label $jid]
    }

    # Flipping the preference re-labels every author at once.
    method OnShowJidSetting {ev} {
        set val [dict get $ev -value]
        if {$val eq ""} { set val 0 }
        set val [expr {!!$val}]
        if {$val == $ShowJid} return
        set ShowJid $val
        $self AnnounceAll
    }

    method AnnounceAll {} {
        dict for {jid name} $Names {
            {*}$options(-changed-command) $jid [$self label $jid]
        }
    }
}
