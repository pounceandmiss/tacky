package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

test app-active-probes-on-return {becoming active again probes each client, once} \
    {*}[tacky_env -mock conn -account user@test.example.com] \
    -body {
        set counts {}
        tacky app setActive -active 1
        lappend counts [$::_client conn probe_count]
        tacky app setActive -active 0
        lappend counts [$::_client conn probe_count] [tacky app isActive]
        tacky app setActive -active true
        tacky app setActive -active 1
        lappend counts [$::_client conn probe_count] [tacky app isActive]
    } -result {0 0 0 1 1}

test app-conn-probe-setting-reaches-conn {the conn_probe setting is what decides whether a client probes} \
    {*}[tacky_env -mock conn -account user@test.example.com] \
    -body {
        set allowed [$::_client conn cget -probe-allowed-command]
        set before [{*}$allowed]
        tacky setting set -key conn_probe -value 0
        list $before [{*}$allowed]
    } -result {1 0}
