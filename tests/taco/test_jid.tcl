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

test jid-equal-folds-case-but-not-the-resource {equal: localpart and domain without case, the resource exactly} -body {
    lmap {a b} {
        user@example.com         User@Example.COM
        user@example.com/Phone   USER@example.com/Phone
        user@example.com/Phone   user@example.com/phone
        room@muc.example.com/Bob Room@MUC.example.com/Bob
        user@example.com         other@example.com
        user@example.com         user@example.com/res
        ""                       ""
        user@example.com         ""
    } { jid equal $a $b }
} -result {1 1 0 1 0 0 0 0}

test jid-forme-full-jid-folds-case {forMe: our full JID in another case is still ours} -body {
    lmap to {user@example.com/res User@Example.com/res user@example.com/Res
             user@example.com/other} {
        jid forMe $to user@example.com/res
    }
} -result {1 1 0 0}
