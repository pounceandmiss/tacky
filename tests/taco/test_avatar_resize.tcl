package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers
package require tclwuffs

test avatar-resize-for-publish {ResizeForPublish shrinks to a 128x128 PNG} \
    {*}[tacky_env -mock conn -account user@test -bound-jid user@test/res] \
    -body {
        # 256x256 solid red, encoded as PNG via wuffs
        set w 256; set h 256
        set px [string repeat [binary format cccc 255 0 0 255] [expr {$w * $h}]]
        set big [::tclwuffs::encode_png $w $h $px]

        set result [$_client.avatar ResizeForPublish $big]

        set d [::tclwuffs::decode $result]
        list [::tclwuffs::sniff $result] [dict get $d width] [dict get $d height]
    } -result {png 128 128}
