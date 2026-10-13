package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers::integration
package require libtacky
package require taco

# XEP-0363 against the test server's upload service: a file goes up and
# comes back down byte for byte, natively over Tcl's http and in a browser
# over XMLHttpRequest.

namespace eval ::test::upload {
    variable HOST "example.local"
    variable ACC "romeo@example.local"
    variable TIMEOUT 30000

    proc setup {} {
        variable HOST
        variable ACC
        tacky_init
        tacky account add {*}$::tacky_test_account_args -acc $ACC \
            -password romeopass -domain $HOST -username romeo
        tacky account enable -acc $ACC
        wait_events [list [list conn <State> -acc $ACC -state connected]] 20000
    }

    proc cleanup {} {
        catch {tacky destroy}
    }

    # Run $script and return the first file <Update> in $direction that is no
    # longer active, as a dict.
    proc finished {direction script} {
        variable ACC
        variable TIMEOUT
        set var [namespace current]::_done
        set $var ""
        set tag [tacky listen file <Update> -acc $ACC -direction $direction \
            [list apply {{var argsL} {
                if {[dict get $argsL -state] ne "active" && [set $var] eq ""} {
                    set $var $argsL
                }
            }} $var]]
        uplevel 1 $script
        try {
            wait_var $var $TIMEOUT
        } finally {
            tacky unlisten $tag
        }
        return [set $var]
    }

    proc readBytes {path} {
        set f [open $path rb]
        set data [read $f]
        close $f
        return $data
    }
}

# Not on MongooseIM: its mod_http_upload stores files in S3 only, which the
# test server has none of.
test upload-int-round-trip {a file goes up to the server and comes back down unchanged} \
    -constraints {withServer && notMongoose} \
    -setup ::test::upload::setup -cleanup ::test::upload::cleanup -body {
        set acc $::test::upload::ACC
        set data "upload round trip [clock milliseconds]\n[string repeat x 5000]\nend\n"
        set path [file join [temporaryDirectory] upload-int.txt]
        set f [open $path wb]
        puts -nonewline $f $data
        close $f

        set up [::test::upload::finished upload {
            tacky file upload -acc $acc -path $path
        }]
        set url [dict get $up -url]
        set down [::test::upload::finished download {
            tacky file download -acc $acc -url $url
        }]
        file delete $path
        set local [dict get $down -localpath]
        list [dict get $up -state] [dict get $up -error] \
            [regexp {^https?://[^/]+/.} $url] \
            [dict get $down -state] [dict get $down -error] \
            [expr {$local ne "" && [::test::upload::readBytes $local] eq $data}]
    } -result {done {} 1 done {} 1}

# The account going mid-upload takes the upload with it: it fails, saying
# why, rather than finishing on a client that is gone. Disabled from an
# idle callback, as a frontend's request would come, not from inside the
# file module's own progress report.
test upload-int-disable-fails-upload {disabling the account mid-upload fails the upload} \
    -constraints {withServer && notMongoose} \
    -setup ::test::upload::setup -cleanup ::test::upload::cleanup -body {
        set acc $::test::upload::ACC
        set path [file join [temporaryDirectory] going-upload.bin]
        set f [open $path wb]
        puts -nonewline $f [string repeat x 9000000]
        close $f
        set tag [tacky listen file <Update> -acc $acc -direction upload \
            [list apply {{acc argsL} {
                if {[dict get $argsL -state] eq "active"
                        && [dict get $argsL -loaded] > 0
                        && ![info exists ::_upGoing]} {
                    set ::_upGoing 1
                    after 0 [list tacky account disable -acc $acc]
                }
            }} $acc]]
        try {
            set end [::test::upload::finished upload {
                tacky file upload -acc $acc -path $path
            }]
        } finally {
            tacky unlisten $tag
            unset -nocomplain ::_upGoing
            file delete $path
        }
        list [dict get $end -state] [dict get $end -error]
    } -result {failed {account disabled}}

