# Unit tests for profilesettings - the per-account profile form.
package require tcltest
namespace import ::tcltest::*

proc ps_png {} {
    set img [image create photo -width 8 -height 8]
    $img put red -to 0 0 8 8
    set png [::tkwuffs::encode_png_from_photo $img]
    image delete $img
    return $png
}

proc ps_inject {data} {
    tacky avatar inject -acc user@test.example.com -jid user@test.example.com \
        -data $data -type image/png -width 8 -height 8
}

# The Remove entry's state as the menu would show it.
proc ps_remove_state {} {
    .ps AvatarMenu 0 0
    set state [.ps.avatarmenu entrycget "Remove avatar" -state]
    .ps.avatarmenu unpost
    return $state
}

test profilesettings-avatar-is-large {the avatar is shown at the dialog's edge, not the 32px default} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    image width [.ps.avatar.img cget -image]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result 96

test profilesettings-menu-entries {the avatar menu offers Change and Remove} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    list [.ps.avatarmenu entrycget 0 -label] [.ps.avatarmenu entrycget 1 -label]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result [list "Change avatar…" "Remove avatar"]

test profilesettings-remove-disabled-without-avatar {Remove is greyed out when there is nothing to remove} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    ps_remove_state
} -cleanup {
    destroy .ps
    mock_backend_down
} -result disabled

test profilesettings-remove-enabled-with-avatar {Remove is offered once the account has an avatar} -setup {
    mock_backend_up
} -body {
    ps_inject [ps_png]
    profilesettings .ps -acc user@test.example.com
    wait
    ps_remove_state
} -cleanup {
    destroy .ps
    mock_backend_down
} -result normal

test profilesettings-remove-follows-updates {an avatar arriving or going while open flips Remove} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    set before [ps_remove_state]
    ps_inject [ps_png]
    wait
    set during [ps_remove_state]
    ps_inject ""
    wait
    list $before $during [ps_remove_state]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {disabled normal disabled}

# How many nick publishes the account has written since the last clear.
proc ps_nick_publishes {} {
    set n 0
    foreach s [$::_client.conn get_written] {
        if {[xsearch $s pubsub publish -get @node] eq "http://jabber.org/protocol/nick"} {
            incr n
        }
    }
    return $n
}

# Under Xvfb there is no WM to focus the window, and an unfocused window drops
# generated key events.
proc ps_key {key} {
    focus -force .ps.nameentry
    update
    event generate .ps.nameentry $key
}

# Packed, so the entry can take focus for key events.
proc ps_open {} {
    profilesettings .ps -acc user@test.example.com
    pack .ps
    wait
}

proc ps_type_name {name} {
    .ps.nameentry delete 0 end
    .ps.nameentry insert 0 $name
}

test profilesettings-name-saves-on-return {Return publishes an edited name} -setup {
    mock_backend_up
} -body {
    ps_open
    $::_client.conn clear
    ps_type_name Romeo
    ps_key <Return>
    wait
    ps_nick_publishes
} -cleanup {
    destroy .ps
    mock_backend_down
} -result 1

test profilesettings-name-saves-on-focusout {leaving the field publishes an edited name, once} -setup {
    mock_backend_up
} -body {
    ps_open
    $::_client.conn clear
    ps_type_name Romeo
    event generate .ps.nameentry <FocusOut>
    event generate .ps.nameentry <FocusOut>
    wait
    ps_nick_publishes
} -cleanup {
    destroy .ps
    mock_backend_down
} -result 1

test profilesettings-name-unchanged-not-saved {leaving the field untouched publishes nothing} -setup {
    mock_backend_up
} -body {
    ps_open
    $::_client.conn clear
    event generate .ps.nameentry <FocusOut>
    wait
    ps_nick_publishes
} -cleanup {
    destroy .ps
    mock_backend_down
} -result 0

test profilesettings-name-escape-reverts {Escape puts the saved name back and publishes nothing} -setup {
    mock_backend_up
} -body {
    ps_open
    ps_type_name Romeo
    ps_key <Return>
    wait
    $::_client.conn clear
    ps_type_name Tybalt
    ps_key <Escape>
    event generate .ps.nameentry <FocusOut>
    wait
    list [.ps.nameentry get] [ps_nick_publishes]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {Romeo 0}

proc ps_pass_key {key} {
    focus -force .ps.passentry.entry
    update
    event generate .ps.passentry.entry $key
}

proc ps_type_pass {pass} {
    .ps.passentry delete 0 end
    .ps.passentry insert 0 $pass
}

proc ps_stored_pass {} {
    tacky account get -acc user@test.example.com -field password
}

test profilesettings-pass-loads-stored {the field shows the password Tacky logs in with} -setup {
    mock_backend_up
    tacky account set -acc user@test.example.com -password stored
} -body {
    ps_open
    .ps.passentry get
} -cleanup {
    destroy .ps
    mock_backend_down
} -result stored

test profilesettings-pass-saves-locally {Return stores the password and hands it to the client, sending nothing} -setup {
    mock_backend_up
} -body {
    ps_open
    $::_client.conn clear
    ps_type_pass fresh
    ps_pass_key <Return>
    wait
    list [ps_stored_pass] [$::_client cget -password] \
        [llength [$::_client.conn get_written]]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {fresh fresh 0}

test profilesettings-pass-escape-reverts {Escape puts the stored password back} -setup {
    mock_backend_up
    tacky account set -acc user@test.example.com -password stored
} -body {
    ps_open
    ps_type_pass typo
    ps_pass_key <Escape>
    event generate .ps.passentry.entry <FocusOut>
    wait
    list [.ps.passentry get] [ps_stored_pass]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {stored stored}

test profilesettings-pass-follows-server-change {a server change shows up in the field} -setup {
    mock_backend_up
} -body {
    ps_open
    .ps ChangePassword
    set top .chpass_[path_safe user@test.example.com]
    $top.d.new insert 0 changed
    $top.d.btns.change invoke
    wait
    $::_client.conn feed [j iq -from test.example.com -type result \
        -id [xsearch [lindex [$::_client.conn get_written] end] -get @id]]
    wait
    list [.ps.passentry get] [.ps.status cget -text]
} -cleanup {
    destroy .ps
    catch {destroy .chpass_[path_safe user@test.example.com]}
    mock_backend_down
} -result {changed {Password changed on server.}}

test profilesettings-connection-loads {the account's connection settings fill the fields} -setup {
    mock_backend_up
    tacky account set -acc user@test.example.com -host xmpp.example.com \
        -port 5223 -tls direct
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    set c .ps.connection
    list [set [$c info vars host]] [set [$c info vars port]] \
        [set [$c info vars mode]]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {xmpp.example.com 5223 {Direct TLS}}

test profilesettings-connection-saves {Save stores the fields and says so} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    set c .ps.connection
    set [$c info vars host] 192.0.2.7
    set [$c info vars port] ""
    .ps SaveConnection
    wait
    list [tacky account get -acc user@test.example.com -field host] \
        [tacky account get -acc user@test.example.com -field port] \
        [.ps.status cget -text]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {192.0.2.7 0 {Server connection saved.}}

test profilesettings-connection-refused {a refused value is reported, not saved} -setup {
    mock_backend_up
} -body {
    profilesettings .ps -acc user@test.example.com
    wait
    set [.ps.connection info vars host] "not a host"
    .ps SaveConnection
    wait
    list [tacky account get -acc user@test.example.com -field host] \
        [.ps.status cget -text]
} -cleanup {
    destroy .ps
    mock_backend_down
} -result {{} {Server connection error: Invalid host: not a host}}
