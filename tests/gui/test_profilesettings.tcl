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
