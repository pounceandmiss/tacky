package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

# -- level resolution ------------------------------------------------------
#
# On a private instance: these move levels around, and the singleton is what
# the rest of the suite logs through.

proc jlog_probe {} {
    jlog_type create jprobe -defaultlevel warning \
        -logproc {apply {{opts} {lappend ::jlog_seen $opts}}}
    set ::jlog_seen {}
}

set probe {
    -setup {jlog_probe}
    -cleanup {jprobe destroy; unset -nocomplain ::jlog_seen}
}

test jlog-inherit-after-child-logged {a parent level reaches a child that already logged} \
    {*}$probe -body {
        # Resolve the child before the parent moves.
        jprobe getLevel ::a.b
        jprobe setLevel ::a debug
        jprobe getLevel ::a.b
    } -result debug

test jlog-explicit-child-wins {an explicit child level survives a parent change} \
    {*}$probe -body {
        jprobe setLevel ::a.b error
        jprobe setLevel ::a debug
        jprobe getLevel ::a.b
    } -result error

test jlog-normalizes-both-ways {setLevel on a bare name reaches a bare child} \
    {*}$probe -body {
        jprobe setLevel gui verbose
        list [jprobe getLevel gui.chatarea] [jprobe getLevel ::gui.chatarea]
    } -result {verbose verbose}

test jlog-defaultlevel-applies-late {changing -defaultlevel reaches objects that already logged} \
    {*}$probe -body {
        jprobe getLevel ::a.b
        jprobe configure -defaultlevel verbose
        jprobe getLevel ::a.b
    } -result verbose

test jlog-defaultlevel-rejected-at-construction {a bad -defaultlevel never reaches an instance} \
    -body {
        jlog_type create jbad -defaultlevel dbeug
    } -cleanup {
        catch {jbad destroy}
    } -returnCodes error -match glob -result {*unknown log level "dbeug"*}

test jlog-configuredebug-rejects-unknown-level {--debug-level is not a way around the check} \
    {*}$probe -body {
        jprobe configureDebug -debug-level dbeug
    } -returnCodes error -match glob -result {unknown log level "dbeug"*}

test jlog-setlevel-rejects-unknown-for-subtree {a bad level is refused for an object too} \
    {*}$probe -body {
        jprobe setLevel ::a dbeug
    } -returnCodes error -match glob -result {unknown log level "dbeug"*}

# stdout is the daemon's wire. In a child, to tell the two channels apart.
test jlog-no-logproc-avoids-stdout {a logger with no sink writes to stderr, not stdout} \
    -constraints hasProcess -setup {
        set child [makeFile [subst -nocommands {
            lappend auto_path [file join [pwd] lib]
            package require taco
            jlog_type create t -defaultlevel debug
            t log error "sink probe" -obj ::c
        }] jlog-sink.tcl]
        set outfile [file join [temporaryDirectory] jlog-sink.out]
        set errfile [file join [temporaryDirectory] jlog-sink.err]
    } -body {
        exec [info nameofexecutable] $child > $outfile 2> $errfile
        list [string match "*sink probe*" [viewFile jlog-sink.out]] \
             [string match "*sink probe*" [viewFile jlog-sink.err]]
    } -cleanup {
        removeFile jlog-sink.tcl
        file delete -force $outfile $errfile
    } -result {0 1}

# -- write -----------------------------------------------------------------

test jlog-write-rejects-unknown-level {write rejects a level outside the vocabulary} \
    {*}$probe -body {
        jprobe write -level chatty -text hi
    } -returnCodes error -match glob -result {unknown log level "chatty"*}

test jlog-log-rejects-unknown-level {a misspelled level is refused, not dropped} \
    {*}$probe -body {
        jprobe log warnign "vanishes without this"
    } -returnCodes error -match glob -result {unknown log level "warnign"*}

test jlog-native-unknown-level-survives {an unknown native level is logged, not lost} \
    {*}$probe -body {
        jprobe setLevel ::rtcma debug
        jprobe nativeLog rtcma 0 trace "from the future"
        set rec [lindex $::jlog_seen 0]
        list [dict get $rec -level] [dict get $rec -text]
    } -result {error {[trace] from the future}}

test jlog-write-none-is-silent {write drops a record at the silence threshold} \
    {*}$probe -body {
        jprobe setLevel frontend verbose
        jprobe write -level none -text hi
        llength $::jlog_seen
    } -result 0

test jlog-write-defaults-obj {write without -obj does not guess from the calling frame} \
    {*}$probe -body {
        jprobe setLevel frontend debug
        jprobe write -level debug -text hi
        dict get [lindex $::jlog_seen 0] -obj
    } -result frontend

# -- line format -----------------------------------------------------------

test jlog-format-timestamp-and-acc {a line carries date, milliseconds and the account} \
    {*}$probe -body {
        jprobe FormatLine {-level error -text boom -obj ::c -acc user@example.com}
    } -match regexp \
      -result {^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} error\] user@example\.com ::c: boom$}

test jlog-format-omits-empty-acc {an accountless line has no stray separator} \
    {*}$probe -body {
        string match {*] ::c: boom} [jprobe FormatLine {-level error -text boom -obj ::c}]
    } -result 1

# -- choosing the sink -----------------------------------------------------

test jlog-setfile-redirects {setfile points later records at the new file} \
    {*}$probe -body {
        set path [makeFile {} jlog-setfile.log]
        jprobe setfile -path $path
        jprobe setLevel ::c debug
        jprobe log error "to the file" -obj ::c
        set fh [open $path r]
        set text [read $fh]
        close $fh
        list [string match "*::c: to the file*" $text] [jprobe getfile]
    } -cleanup {
        removeFile jlog-setfile.log
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -match glob -result {1 *jlog-setfile.log}

test jlog-setfile-empty-returns-to-stderr {an empty path drops the file sink} \
    {*}$probe -body {
        jprobe setfile -path [makeFile {} jlog-setfile.log]
        jprobe setfile -path ""
        list [jprobe getfile] [lindex [jprobe cget -logproc] end]
    } -cleanup {
        removeFile jlog-setfile.log
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result {{} stderrWriter}

test jlog-setenabled-names-the-file {enabling puts tacky.log in the given directory} \
    {*}$probe -body {
        set dir [makeDirectory jlog-cache]
        jprobe setenabled -enabled 1 -dir $dir
        string equal [jprobe getfile] [file join $dir tacky.log]
    } -cleanup {
        removeDirectory jlog-cache
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result 1

test jlog-setenabled-off-returns-to-stderr {disabling drops the file sink} \
    {*}$probe -body {
        jprobe setenabled -enabled 1 -dir [makeDirectory jlog-cache]
        jprobe setenabled -enabled 0
        list [jprobe getfile] [lindex [jprobe cget -logproc] end]
    } -cleanup {
        removeDirectory jlog-cache
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result {{} stderrWriter}

# Without a cache dir the file would land in the process's cwd.
test jlog-setenabled-needs-a-directory {enabling with no directory refuses} \
    {*}$probe -body {
        jprobe setenabled -enabled 1
    } -cleanup {
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -returnCodes error -result {cannot write a log file: no directory configured}

test jlog-setenabled-rejects-non-boolean {enabling takes only a boolean} \
    {*}$probe -body {
        jprobe setenabled -enabled maybe
    } -cleanup {
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -returnCodes error -match glob -result {invalid -enabled "maybe"*}

# An embedded host names a cache dir taco honours; the log follows it there.
test log-setenabled-uses-taco-cache-dir {the module logs into taco's cache dir} \
    -setup {set logdir [makeDirectory jlog-cache]} -body {
        taco_log create logprobe -cache-dir $logdir
        logprobe setenabled -enabled 1 -dir /should/be/overridden
        string equal [jlog getfile] [file join $logdir tacky.log]
    } -cleanup {
        jlog setfile -path ""
        logprobe destroy
        removeDirectory jlog-cache
    } -result 1

# -- native loggers --------------------------------------------------------
#
# calls.tcl hard-requires rtc and rtcma, so these drive the real commands.

set native {
    -setup {jlog_probe}
    -cleanup {
        jprobe setnativelevel -level none
        jprobe destroy
        unset -nocomplain ::jlog_seen
    }
}

test jlog-setnativelevel-round-trips {a source reads back the level it was set to} \
    {*}$native -body {
        jprobe setnativelevel -source rtcma -level debug
        list [jprobe getnativelevel -source rtcma] \
             [jprobe getnativelevel -source libdatachannel]
    } -result {debug none}

test jlog-setnativelevel-covers-every-source {omitting -source drives them all} \
    {*}$native -body {
        jprobe setnativelevel -level info
        list [jprobe getnativelevel -source rtcma] \
             [jprobe getnativelevel -source libdatachannel]
    } -result {info info}

test jlog-setnativelevel-none-turns-off {none reads back as off} \
    {*}$native -body {
        jprobe setnativelevel -source rtcma -level verbose
        jprobe setnativelevel -source rtcma -level none
        jprobe getnativelevel -source rtcma
    } -result none

test jlog-setnativelevel-stops-jlog-refiltering {the library's own filter is the only one} \
    {*}$native -body {
        jprobe setnativelevel -source rtcma -level debug
        jprobe getLevel ::rtcma
    } -result verbose

test jlog-setnativelevel-rejects-unknown-source {a bad source name is refused} \
    {*}$native -body {
        jprobe setnativelevel -source webrtc -level debug
    } -returnCodes error -match glob -result {unknown native log source "webrtc"*}

test jlog-getnativelevel-needs-a-source {there is no single native level to report} \
    {*}$native -body {
        jprobe getnativelevel
    } -returnCodes error -match glob -result {-source is required*}

# -- writer robustness -----------------------------------------------------

test jlog-file-failure-does-not-throw {an unwritable log file never throws into the caller} \
    {*}$probe -body {
        # A path under a plain file cannot be opened, on any platform.
        set blocker [makeFile {} jlog-blocker]
        jprobe fileWriter [file join $blocker nested.log] {-level error -text boom -obj ::c}
        return reached
    } -cleanup {
        removeFile jlog-blocker
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result reached

# ~46 bytes a line, so 100 of them cross a 4k cap exactly once: a second
# rotation would need roughly twice as many.
proc jlog_fill {n} {
    jprobe setLevel ::c debug
    for {set i 0} {$i < $n} {incr i} {
        jprobe log error "record $i" -obj ::c
    }
}

test jlog-rotate-moves-the-old-records {past the cap the earlier records are in .1} \
    {*}$probe -body {
        set path [file join [makeDirectory jlog-rot] app.log]
        jprobe configure -maxlogbytes 4096
        jprobe setfile -path $path
        jlog_fill 100
        list [string match "*record 0*" [viewFile app.log jlog-rot]] \
             [string match "*record 0*" [viewFile app.log.1 jlog-rot]] \
             [string match "*record 99*" [viewFile app.log jlog-rot]]
    } -cleanup {
        removeDirectory jlog-rot
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result {0 1 1}

test jlog-rotate-disabled-by-zero {a zero cap leaves the file alone} \
    {*}$probe -body {
        set path [file join [makeDirectory jlog-rot] app.log]
        jprobe configure -maxlogbytes 0
        jprobe setfile -path $path
        jlog_fill 100
        list [string match "*record 0*" [viewFile app.log jlog-rot]] \
             [file exists $path.1]
    } -cleanup {
        removeDirectory jlog-rot
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result {1 0}

test jlog-rotate-keeps-both-private {neither generation is left world-readable} \
    -constraints unix {*}$probe -body {
        set path [file join [makeDirectory jlog-rot] app.log]
        jprobe configure -maxlogbytes 4096
        jprobe setfile -path $path
        jlog_fill 100
        list [string range [file attributes $path -permissions] end-2 end] \
             [string range [file attributes $path.1 -permissions] end-2 end]
    } -cleanup {
        removeDirectory jlog-rot
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result {600 600}

test jlog-setfile-creates-private-file {a log file is readable only by its owner} \
    -constraints unix {*}$probe -body {
        jprobe setfile -path [file join [makeDirectory jlog-perm] app.log]
        string range [file attributes [jprobe getfile] -permissions] end-2 end
    } -cleanup {
        removeDirectory jlog-perm
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result 600

test jlog-file-recreated-stays-private {a log deleted underneath comes back owner-only} \
    -constraints unix {*}$probe -body {
        jprobe setfile -path [file join [makeDirectory jlog-perm] app.log]
        file delete [jprobe getfile]
        jprobe setLevel ::c debug
        jprobe log error "recreated" -obj ::c
        string range [file attributes [jprobe getfile] -permissions] end-2 end
    } -cleanup {
        removeDirectory jlog-perm
        jprobe destroy
        unset -nocomplain ::jlog_seen
    } -result 600

# -- the log module over each transport ------------------------------------

tacky_test log-getlevel-default {getlevel with no -obj reports the default level} \
    -body {
        tacky_await tacky log getlevel
    } -result warning

tacky_test log-setlevel-roundtrip {a level set for an object reads back for its children} \
    -body {
        tacky log setlevel -obj ::probe -level verbose
        list [tacky_await tacky log getlevel -obj ::probe] \
             [tacky_await tacky log getlevel -obj ::probe.child]
    } -result {verbose verbose}

tacky_test log-setlevel-rejects-unknown {a bad level reaches -onerror across the wire} \
    -body {
        tacky_await_error tacky log setlevel -obj ::probe -level chatty
    } -match glob -result {unknown log level "chatty"*}

tacky_test log-write-sugar {the level-first sugar reaches write across the wire} \
    -body {
        # Silenced first, so the record never reaches the suite's own output.
        tacky log setlevel -obj gui.testcase -level none
        tacky log warning "quiet please" -obj gui.testcase
        return reached
    } -result reached

# getlevel hands out "none" and setlevel takes it, so a caller piping a
# configured level into write will sooner or later pass it one.
tacky_test log-write-takes-a-level-from-getlevel {writing at a level the API returned does not throw} \
    -body {
        tacky log setlevel -obj gui.testcase -level none
        tacky log [tacky_await tacky log getlevel -obj gui.testcase] \
            "goes nowhere" -obj gui.testcase
        return reached
    } -result reached
