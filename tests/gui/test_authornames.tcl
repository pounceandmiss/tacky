# authornames resolves what to call the author of a message, and announces
# when that answer changes. A fake host records the announcements.

proc an_new {chat args} {
    catch {an destroy}
    set ::an_changed {}
    authornames an -acc user@test.example.com -chat $chat -tag an_test \
        -changed-command {apply {{jid label} {
            lappend ::an_changed [list $jid $label]
        }}} {*}$args
    return an
}

proc an_cleanup {} {
    catch {an destroy}
    unset -nocomplain ::an_changed
    mock_backend_down
}

# A server roster push naming a contact; this is what drives author <Changed>
# in a 1:1 chat.
proc an_roster_push {jid name} {
    $::_client conn feed [j iq -type set -id an-push {
        j query -ns jabber:iq:roster {
            j item -jid $jid -name $name -subscription both
        }
    }]
    wait
}

test authornames-unknown-1to1-author-is-its-jid {a contact with no name resolves to the bare JID} \
    -setup { mock_backend_up; an_new alice@example.com } \
    -cleanup { an_cleanup } \
    -body {
        an label alice@example.com
    } -result alice@example.com

test authornames-muc-author-is-the-nick {in a room the resource is the participant nick} \
    -setup { mock_backend_up; an_new room@conf.example.com?join } \
    -cleanup { an_cleanup } \
    -body {
        an label room@conf.example.com/bob
    } -result bob

test authornames-seeds-both-sides {the initial snapshot covers everyone who authors in the chat} \
    -setup { mock_backend_up; an_new alice@example.com } \
    -cleanup { an_cleanup } \
    -body {
        # Announced even though nothing is drawn yet: history may have been
        # rendered before this snapshot landed.
        lsort [lmap entry $::an_changed {lindex $entry 0}]
    } -result {alice@example.com user@test.example.com}

test authornames-uses-a-known-name {a named contact resolves to the name and announces the change} \
    -setup { mock_backend_up; an_new alice@example.com } \
    -cleanup { an_cleanup } \
    -body {
        set before [an label alice@example.com]
        set ::an_changed {}
        an_roster_push alice@example.com Alice
        list $before [an label alice@example.com] $::an_changed
    } -result {alice@example.com Alice {{alice@example.com Alice}}}

test authornames-show-jid-overrides-the-name {with the preference on, a named contact still renders as its JID} \
    -setup {
        mock_backend_up
        an_new alice@example.com -show-jid-setting 1
    } -cleanup { an_cleanup } \
    -body {
        an_roster_push alice@example.com Alice
        set named [an label alice@example.com]
        tacky setting set -key show_jid_in_1to1 -value 1
        wait
        list $named [an label alice@example.com]
    } -result {Alice alice@example.com}

test authornames-preference-flip-relabels-everyone {turning the preference on announces every known author} \
    -setup {
        mock_backend_up
        an_new alice@example.com -show-jid-setting 1
    } -cleanup { an_cleanup } \
    -body {
        an_roster_push alice@example.com Alice
        set ::an_changed {}
        tacky setting set -key show_jid_in_1to1 -value 1
        wait
        lsort [lmap entry $::an_changed {lindex $entry 1}]
    } -result {alice@example.com user@test.example.com}

test authornames-ignores-the-preference-without-it {a chat that never opted in is unaffected by the setting} \
    -setup { mock_backend_up; an_new room@conf.example.com?join } \
    -cleanup { an_cleanup } \
    -body {
        tacky setting set -key show_jid_in_1to1 -value 1
        wait
        an label room@conf.example.com/bob
    } -result bob
