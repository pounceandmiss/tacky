package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

::tcltest::testConstraint hasMagick [expr {![catch {exec magick -version}]}]

test avatar-resize-for-publish {ResizeForPublish returns valid PNG} \
    -constraints hasMagick \
    {*}[tacky_env -mock conn -account user@test -bound-jid user@test/res] \
    -body {
        # Generate a 256x256 red PNG via magick pipe (binary-safe)
        set pipe [open |[list magick -size 256x256 xc:red png:-] rb]
        set big [chan read $pipe]
        chan close $pipe

        set result [$_client.avatar ResizeForPublish $big]

        # Check PNG magic bytes (89 50 4E 47)
        binary scan $result cu4 bytes
        set bytes
    } -result {137 80 78 71}
