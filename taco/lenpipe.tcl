# lenpipe — length-prefixed message framing over a non-blocking channel.
#
# Protocol (both directions):
#   <byte_length>\n<payload>     (repeating, no separator after payload)
#
# Usage:
#   lenpipe create name $fd -onmessage $cmd -oneof $cmd
#   $name send $msg
#   $name destroy
#
# The channel is configured non-blocking with binary encoding so that
# lengths and read counts refer to bytes, not characters.  Payloads are
# UTF-8 on the wire; conversion happens at the message boundary.
# Partial reads are handled via a two-state machine (len / data).

oo::class create lenpipe {
    variable Fd        ;# channel handle
    variable OnMessage ;# callback script invoked with each complete message
    variable OnEof     ;# callback script invoked on EOF
    variable State     ;# "len" = reading length line, "data" = reading payload
    variable Buf       ;# accumulated payload bytes for current message
    variable Expected  ;# byte count expected for current payload

    constructor {fd args} {
        set Fd $fd
        set OnMessage {}
        set OnEof {}
        foreach {opt val} $args {
            switch $opt {
                -onmessage { set OnMessage $val }
                -oneof     { set OnEof $val }
            }
        }
        set State len
        set Buf ""
        set Expected 0
        chan configure $Fd -translation binary -buffering full -blocking 0
        chan event $Fd readable [namespace code {my _onReadable}]
    }

    destructor {
        catch {close $Fd}
    }

    method send {msg} {
        set bytes [encoding convertto utf-8 $msg]
        puts $Fd [string length $bytes]
        puts -nonewline $Fd $bytes
        flush $Fd
    }

    method _onReadable {} {
        while 1 {
            if {$State eq "len"} {
                if {[gets $Fd line] < 0} {
                    if {[eof $Fd]} { my _eof }
                    return
                }
                set Expected $line
                set Buf ""
                set State data
            }
            if {$State eq "data"} {
                set need [expr {$Expected - [string length $Buf]}]
                if {$need > 0} {
                    append Buf [read $Fd $need]
                    if {[string length $Buf] < $Expected} {
                        if {[eof $Fd]} { my _eof }
                        return
                    }
                }
                set msg [encoding convertfrom utf-8 $Buf]
                set State len
                set Buf ""
                set Expected 0
                if {$OnMessage ne {}} {
                    {*}$OnMessage $msg
                }
            }
        }
    }

    method _eof {} {
        chan event $Fd readable {}
        if {$OnEof ne {}} {
            {*}$OnEof
        }
    }
}
