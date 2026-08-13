#!/usr/bin/env tclsh9.0
# Child process entry point that speaks JSON over lenpipe.
#
# Incoming (stdin):  ["module","method",{args}]          fire-and-forget
#                    ["module","method",{args},token]     request/response
# Outgoing (stdout): ["event","module","Event",{args}]     broadcast
#                    ["result",token,data]                success reply
#                    ["error",token,message]              error reply

set _proj [file normalize [file join [file dirname [info script]] ..]]
lappend auto_path [file join $_proj lib]

package require taco
package require lenpipe
package require tackyd
package require tackyd-json

# Schema conversion, token wiring and dispatch live in the tackyd-json package.
tackyd_json_install_emit pipesend

lenpipe create _pipe stdin \
    -onmessage tackyd_dispatch \
    -oneof {apply {{} {
        taco destroy
        exit 0
    }}}

tackyd_main $::argv
