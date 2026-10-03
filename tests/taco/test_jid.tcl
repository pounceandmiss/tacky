# Tests for the jid helpers.
package require tcltest
namespace import ::tcltest::*
package require jid

test jid-fromme-bare-only {fromMe: absent or our bare JID, not a full JID of ours} -body {
    lmap from {"" user@example.com User@Example.com user@example.com/other
               example.com other@example.com} {
        jid fromMe $from user@example.com/res
    }
} -result {1 1 1 0 0 0}
