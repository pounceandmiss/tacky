# showinfm - show a file in the desktop's file manager with the file itself
# selected, not just its folder opened.
#
# There is no xdg-open equivalent for selecting, so on Linux this goes through
# the XDG FileManager1 D-Bus interface; if no file manager answers we fall back
# to plainly opening the containing folder.

namespace eval showinfm {
    namespace export show
}

proc showinfm::show {path} {
    set path [file normalize $path]
    if {$::tcl_platform(os) eq "Darwin"} {
        if {![catch {exec open -R $path &}]} return
    } elseif {$::tcl_platform(platform) eq "windows"} {
        if {![catch {exec explorer /select,[file nativename $path] &}]} return
    } elseif {[showinfm::ShowItems $path]} {
        return
    }
    attachment_os_open [file dirname $path]
}

# The call is only answered once the file manager is up, so it runs detached
# and the folder fallback waits on its exit status.
proc showinfm::ShowItems {path} {
    set uri file://[showinfm::UriPath $path]
    if {[catch {open [list |gdbus call --session \
        --dest org.freedesktop.FileManager1 \
        --object-path /org/freedesktop/FileManager1 \
        --method org.freedesktop.FileManager1.ShowItems \
        "\['$uri'\]" "" 2>@1] r} ch]} {
        return 0
    }
    fconfigure $ch -blocking 0
    fileevent $ch readable [list showinfm::Reply $ch [file dirname $path]]
    return 1
}

proc showinfm::Reply {ch dir} {
    read $ch
    if {![eof $ch]} return
    fileevent $ch readable {}
    fconfigure $ch -blocking 1
    if {[catch {close $ch}]} { attachment_os_open $dir }
}

proc showinfm::UriPath {path} {
    set out ""
    foreach ch [split [encoding convertto utf-8 $path] ""] {
        if {[string match {[-A-Za-z0-9_.~/]} $ch]} {
            append out $ch
        } else {
            append out [format %%%02X [scan $ch %c]]
        }
    }
    return $out
}
