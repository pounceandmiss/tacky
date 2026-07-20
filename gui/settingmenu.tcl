# Menu items backed by the tacky setting store.
# The default lives in the caller's `variable foo <default>`: when the setting is
# unset, Apply leaves it untouched; a stored value arrives via observe's pull.
namespace eval settingmenu {}

# settingmenu::checkbutton MENU LABEL -var FQVAR -key KEY ?-onchange CMD? ?-tag T? ?-tacky T?
#   -var       fully-qualified var name  (pass [myvar foo] from inside a type)
#   -tag       observe/cleanup tag       (pass $win so `unlisten $win` frees it)
#   -onchange  optional command prefix run after the value updates
#   -tacky     tacky instance            (pass $options(-tacky) where injectable)
proc settingmenu::checkbutton {menu label args} {
    array set opt {-onchange "" -tag "" -tacky ::tacky}
    array set opt $args
    set var $opt(-var)
    set key $opt(-key)
    if {$opt(-tag) eq ""} { set opt(-tag) $var }
    $menu add checkbutton -label $label -variable $var \
        -command [list settingmenu::Toggle $opt(-tacky) $key $var $opt(-onchange)]
    $opt(-tacky) observe -tag $opt(-tag) setting <Changed> -key $key \
        [list settingmenu::Apply $var $opt(-onchange)]
}

proc settingmenu::Toggle {t key var onchange} {
    $t setting set -key $key -value [set $var]
    if {$onchange ne ""} { uplevel #0 $onchange }
}

proc settingmenu::Apply {var onchange ev} {
    set val [dict get $ev -value]
    if {$val eq ""} return
    set $var [expr {!!$val}]
    if {$onchange ne ""} { uplevel #0 $onchange }
}
