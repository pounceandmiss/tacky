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
