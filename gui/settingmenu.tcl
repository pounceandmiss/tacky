# Menu items, and check buttons, backed by the tacky setting store.
# The default lives in the caller's `variable foo <default>`: when the setting is
# unset, Apply leaves it untouched; a stored value arrives via observe's pull.
namespace eval settingmenu {}

# settingmenu::checkbutton MENU LABEL -var FQVAR -key KEY ?-acc ACC? ?-onchange CMD? ?-confirm CMD? ?-tag T? ?-tacky T?
#   -var       fully-qualified var name  (pass [myvar foo] from inside a type)
#   -acc       the account whose own setting it is; "" (default) for a global one
#   -tag       observe/cleanup tag       (pass $win so `unlisten $win` frees it)
#   -onchange  optional command prefix run after the value updates
#   -confirm   optional command prefix run with the new value on a click only,
#              before it is stored; false puts the box back and stores nothing
#   -tacky     tacky instance            (pass $options(-tacky) where injectable)
proc settingmenu::checkbutton {menu label args} {
    array set opt [settingmenu::Opts $args]
    $menu add checkbutton -label $label -variable $opt(-var) \
        -command [settingmenu::ToggleCmd opt]
    settingmenu::Observe opt Apply
}

# settingmenu::check PATH LABEL ...
# The same as a ttk::checkbutton at PATH, for a dialog rather than a menu.
proc settingmenu::check {path label args} {
    array set opt [settingmenu::Opts $args]
    ttk::checkbutton $path -text $label -variable $opt(-var) \
        -command [settingmenu::ToggleCmd opt]
    settingmenu::Observe opt Apply
    return $path
}

# settingmenu::radiogroup MENU -entries {LABEL VALUE ...} -var FQVAR -key KEY \
#       ?-acc ACC? ?-onchange CMD? ?-tag T? ?-tacky T?
# Same contract as checkbutton, for settings with more than two values: the
# stored string is the radiobutton value, and one observer covers the group.
proc settingmenu::radiogroup {menu args} {
    array set opt [settingmenu::Opts $args]
    set opt(-confirm) ""
    foreach {label value} $opt(-entries) {
        $menu add radiobutton -label $label -variable $opt(-var) -value $value \
            -command [settingmenu::ToggleCmd opt]
    }
    settingmenu::Observe opt ApplyValue
}

proc settingmenu::Opts {argList} {
    array set opt {-acc "" -onchange "" -confirm "" -tag "" -tacky ::tacky}
    array set opt $argList
    if {$opt(-tag) eq ""} { set opt(-tag) $opt(-var) }
    array get opt
}

proc settingmenu::ToggleCmd {optVar} {
    upvar 1 $optVar opt
    list settingmenu::Toggle $opt(-tacky) $opt(-acc) $opt(-key) $opt(-var) \
        $opt(-onchange) $opt(-confirm)
}

proc settingmenu::Observe {optVar apply} {
    upvar 1 $optVar opt
    $opt(-tacky) observe -tag $opt(-tag) setting <Changed> \
        {*}[settingmenu::AccArgs $opt(-acc)] -key $opt(-key) \
        [list settingmenu::$apply $opt(-var) $opt(-onchange)]
}

proc settingmenu::AccArgs {acc} {
    expr {$acc eq "" ? {} : [list -acc $acc]}
}

proc settingmenu::Toggle {t acc key var onchange {confirm ""}} {
    if {$confirm ne "" && ![uplevel #0 [linsert $confirm end [set $var]]]} {
        set $var [expr {![set $var]}]
        return
    }
    $t setting set {*}[settingmenu::AccArgs $acc] -key $key -value [set $var]
    if {$onchange ne ""} { uplevel #0 $onchange }
}

proc settingmenu::Apply {var onchange ev} {
    set val [dict get $ev -value]
    if {$val eq ""} return
    set $var [expr {!!$val}]
    if {$onchange ne ""} { uplevel #0 $onchange }
}

proc settingmenu::ApplyValue {var onchange ev} {
    set val [dict get $ev -value]
    if {$val eq ""} return
    set $var $val
    if {$onchange ne ""} { uplevel #0 $onchange }
}
