# OMEMO in group chats (XEP-0384 §5.7) under a real taco_client.
#
# Juliet is the client under test. The room's other members are bare
# picomemo stores -- what another client would hold -- one per device: they
# hand Juliet their bundles, read what she sends and write what she reads.
# The room is played by hand: its presences, disco#info, affiliation lists
# and archive are fed at the connection, so the client's own dispatch
# decides where they go.

package require tcltest
namespace import ::tcltest::*
package require tacky::testhelpers

namespace eval ::t {
    variable JFULL  juliet@capulet.lit/balcony
    variable JBARE  juliet@capulet.lit
    variable ROOM   lab@chat.capulet.lit
    variable CHAT   lab@chat.capulet.lit?join
    variable ROMEO  romeo@montague.lit
    variable MERC   mercutio@verona.lit
    variable MAL    mallory@evil.lit
    variable PRIVATE {http://jabber.org/protocol/muc muc_membersonly
        muc_nonanonymous urn:xmpp:occupant-id:0 urn:xmpp:sid:0}
    variable NS_AX  eu.siacs.conversations.axolotl
    variable NS_OCC urn:xmpp:occupant-id:0
    variable seq 0
    # jid,dev -> picomemo store of that device; jid,dev -> its session
    # with Juliet's device
    variable Store
    array set Store {}
    variable Sess
    array set Sess {}
}

# --- the room -------------------------------------------------------------

proc ::t::presence {nick args} {
    set o [dict merge {jid "" affiliation member role participant occ ""
        self 0 type "" codes {}} $args]
    j presence -from $::t::ROOM/$nick {*}[expr {[dict get $o type] ne ""
            ? [list -type [dict get $o type]] : {}}] {
        if {[dict get $o occ] ne ""} {
            j occupant-id -ns $::t::NS_OCC -id [dict get $o occ]
        }
        j x -ns http://jabber.org/protocol/muc#user {
            set attrs [list -role [dict get $o role] \
                -affiliation [dict get $o affiliation]]
            if {[dict get $o jid] ne ""} { lappend attrs -jid [dict get $o jid] }
            j item {*}$attrs
            if {[dict get $o self]} { j status -code 110 }
            foreach c [dict get $o codes] { j status -code $c }
        }
    }
}

# The last request written that matches $script (a lambda on the stanza).
proc ::t::written {pred} {
    foreach w [lreverse [c.conn get_written]] {
        if {[apply [list w $pred] $w]} { return $w }
    }
    return ""
}

proc ::t::reply {req payload} {
    c.conn feed [j iq -type result -id [xsearch $req -get @id] \
        -from [xsearch $req -get @to] {
            if {$payload ne ""} { j #as-is $payload }
        }]
}

proc ::t::refuse {req} {
    c.conn feed [j iq -type error -id [xsearch $req -get @id] \
        -from [xsearch $req -get @to] {
            j error -type auth { j forbidden -ns urn:ietf:params:xml:ns:xmpp-stanzas }
        }]
}

proc ::t::answerInfo {features} {
    set req [written {expr {[xsearch $w query -ns http://jabber.org/protocol/disco#info -get tag] ne ""
        && [xsearch $w -get @to] eq $::t::ROOM}}]
    reply $req [j query -ns http://jabber.org/protocol/disco#info {
        j identity -category conference -type text
        foreach f $features { j feature -var $f }
    }]
}

# The muc#admin request for $affil, the last one asked.
proc ::t::adminRequest {affil} {
    set ::t::wantAffil $affil
    written {expr {[xsearch $w query -ns http://jabber.org/protocol/muc#admin \
        item -get @affiliation] eq $::t::wantAffil}}
}

# Answer the three affiliation lists; $members is {jid affiliation ...}.
# `refuse` in place of a list refuses that one.
proc ::t::answerLists {members {refused {}}} {
    foreach affil {owner admin member} {
        set req [adminRequest $affil]
        if {$affil in $refused} { refuse $req; continue }
        reply $req [j query -ns http://jabber.org/protocol/muc#admin {
            foreach {jid a} $members {
                if {$a eq $affil} { j item -jid $jid -affiliation $a }
            }
        }]
    }
}

# Join $ROOM: $occupants is a list of {nick jid occ affiliation} already
# in it; the room then answers disco#info with $features and, if private,
# the three lists with $members.
proc ::t::join {occupants args} {
    set o [dict merge [list features $::t::PRIVATE members {} myOcc occ-juliet \
        lists 1] $args]
    c muc join -jid $::t::ROOM -nick juliet
    foreach occ $occupants {
        lassign $occ nick jid oid affil
        if {$affil eq ""} { set affil member }
        c.conn feed [presence $nick jid $jid/res occ $oid affiliation $affil]
    }
    c.conn feed [presence juliet jid $::t::JFULL occ [dict get $o myOcc] self 1]
    answerInfo [dict get $o features]
    if {[dict get $o lists] && "muc_membersonly" in [dict get $o features]
            && "muc_nonanonymous" in [dict get $o features]} {
        answerLists [dict get $o members]
    }
}

# --- the members' devices ---------------------------------------------------

proc ::t::injectDevicelist {jid devices} {
    c omemo OnDevicelist [j message -from $jid {
        j event -ns http://jabber.org/protocol/pubsub#event {
            j items -node eu.siacs.conversations.axolotl.devicelist {
                j item {
                    j list -ns $::t::NS_AX {
                        foreach d $devices { j device -id $d }
                    }
                }
            }
        }
    }]
}

# A device of $jid: its own store, and (unless -nosession) a session Juliet
# built from its bundle, the way a fetched bundle would.
proc ::t::device {jid dev args} {
    set name ::t::store_[incr ::t::seq]
    omemo::store create $name -device $dev
    $name setup
    set ::t::Store($jid,$dev) $name
    if {"-nosession" ni $args} {
        lassign [c omemo BuildSessionFromBundle $jid $dev [$name bundle]] s err
        if {$s eq ""} { error "no session for $jid/$dev: $err" }
    }
    return $dev
}

# Juliet's current bundle, as a fetch would give it.
proc ::t::julietBundle {} {
    set before [llength [c.conn get_written]]
    c omemo DoPublishBundle
    foreach w [lrange [c.conn get_written] $before end] {
        set bn [lindex [xsearch $w pubsub publish item bundle -ns $::t::NS_AX] 0]
        if {$bn eq ""} continue
        return [c omemo ParseBundle [j iq {
            j pubsub -ns http://jabber.org/protocol/pubsub {
                j items { j item { j #as-is $bn } }
            }
        }]]
    }
    error "no bundle published"
}

# The session $jid/$dev keeps with Juliet's device, started from her
# bundle when the device has not heard from her.
proc ::t::session {jid dev} {
    if {[info exists ::t::Sess($jid,$dev)]} { return $::t::Sess($jid,$dev) }
    set s ::t::sess_[incr ::t::seq]
    omemo::session create $s -jid $::t::JBARE -device [c omemo device_id]
    set ::t::Sess($jid,$dev) $s
    set b [julietBundle]
    set pk [lindex [dict get $b prekeys] 0]
    $s initiate $::t::Store($jid,$dev) -ik [dict get $b ik] \
        -spk [dict get $b spk] -spks [dict get $b spks] \
        -pk [dict get $pk pk] -spk-id [dict get $b spk_id] -pk-id [dict get $pk id]
    return $s
}

# What device $jid/$dev reads in an <encrypted/> Juliet sent, or an error.
proc ::t::read {jid dev enc} {
    set mine ""
    xsearch $enc header key -script kn {
        if {[xsearch $kn -get @rid] == $dev} { set mine $kn }
    }
    if {$mine eq ""} { error "not keyed for $jid/$dev" }
    if {![info exists ::t::Sess($jid,$dev)]} {
        set s ::t::sess_[incr ::t::seq]
        omemo::session create $s -jid $::t::JBARE -device [c omemo device_id]
        set ::t::Sess($jid,$dev) $s
    }
    set key [$::t::Sess($jid,$dev) decrypt_key $::t::Store($jid,$dev) \
        [base64::decode [dict get $mine body]] \
        -prekey [expr {[xsearch $mine -get @prekey] in {true 1}}]]
    encoding convertfrom utf-8 [omemo::decrypt_message $key \
        [base64::decode [xsearch $enc header iv -get body]] \
        [base64::decode [xsearch $enc payload -get body]]]
}

# An <encrypted/> that $jid/$dev writes to Juliet's device.
proc ::t::encryptedFrom {jid dev text} {
    set s [session $jid $dev]
    set e [omemo::encrypt_message [encoding convertto utf-8 $text]]
    set w [$s encrypt_key [dict get $e key]]
    set rid [c omemo device_id]
    j encrypted -ns $::t::NS_AX {
        j header -sid $dev {
            if {[dict get $w isprekey]} {
                j key -rid $rid -prekey true -body [base64::encode -wrapchar "" [dict get $w p]]
            } else {
                j key -rid $rid -body [base64::encode -wrapchar "" [dict get $w p]]
            }
            j iv -body [base64::encode -wrapchar "" [dict get $e iv]]
        }
        j payload -body [base64::encode -wrapchar "" [dict get $e ct]]
    }
}

# A room message from $nick carrying $enc, as the room relays it.
proc ::t::roomMessage {nick enc args} {
    set o [dict merge {occ "" id "" extra ""} $args]
    set id [dict get $o id]
    if {$id eq ""} { set id m[incr ::t::seq] }
    j message -from $::t::ROOM/$nick -to $::t::JFULL -type groupchat -id $id {
        if {[dict get $o occ] ne ""} {
            j occupant-id -ns $::t::NS_OCC -id [dict get $o occ]
        }
        j #as-is $enc
        j encryption -ns urn:xmpp:eme:0 -namespace $::t::NS_AX -name OMEMO
        j body -body "I sent you an OMEMO encrypted message but your client doesn't support OMEMO."
        if {[dict get $o extra] ne ""} { j #as-is [dict get $o extra] }
        j stanza-id -ns urn:xmpp:sid:0 -by $::t::ROOM -id sid-$id
    }
}

# --- reading the client -----------------------------------------------------

proc ::t::rows {} {
    c db eval {
        SELECT body, encryption, from_jid, server_status FROM chat_message
        WHERE chat_jid=$::t::CHAT AND kind='message' ORDER BY timestamp
    }
}

proc ::t::emitted {module tag} {
    set out [list]
    foreach e $::_emitted {
        if {[lindex $e 0] eq $module && [lindex $e 1] eq $tag} {
            lappend out [lrange $e 2 end]
        }
    }
    return $out
}

# The last groupchat message Juliet wrote, "" when none.
proc ::t::sent {} {
    written {expr {[xsearch $w -get tag] eq "message"
        && [xsearch $w -get @type] eq "groupchat"}}
}

proc ::t::sentEncrypted {} {
    set m [sent]
    if {$m eq ""} { return "" }
    lindex [xsearch $m encrypted -ns $::t::NS_AX] 0
}

proc ::t::rids {enc} {
    set out {}
    xsearch $enc header key -script kn { lappend out [xsearch $kn -get @rid] }
    lsort -integer $out
}

# Test bodies run at global scope: drop what they set there, so no later
# test file finds a variable of ours (a scalar `row` breaks a later
# `db eval ... row {...}`). The env's own (::_*) are its to unset.
proc ::t::cleanup {} {
    foreach v [info globals] {
        if {$v in $::t::globals || [string match _* $v]} continue
        unset -nocomplain ::$v
    }
    foreach k [array names ::t::Sess] { catch {$::t::Sess($k) destroy} }
    foreach k [array names ::t::Store] { catch {$::t::Store($k) destroy} }
    array unset ::t::Sess *
    array unset ::t::Store *
}

# A client with OMEMO up: our own device list holds this device alone.
set mucenv [tacky_env -capture-emit 1 -mock conn \
    -taco-client {-db-path :memory: -username juliet -domain capulet.lit -resource balcony} \
    -bound-jid $::t::JFULL -extra-setup {
        ::t::injectDevicelist $::t::JBARE [list [c omemo device_id]]
        set ::_emitted {}
        set ::t::globals [info globals]
    } -extra-cleanup { ::t::cleanup }]

# =====================================================================
# Which rooms qualify, and the switch
# =====================================================================

test omemo-muc-private-room-eligible-off {a members-only, non-anonymous room can use OMEMO, and is off until turned on} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        set st [c omemo roomStatus -jid $::t::CHAT]
        c message send -chat $::t::CHAT -body hello
        list [dict get $st eligible] [dict get $st enabled] \
            [c omemo isEnabled -jid $::t::CHAT] \
            [xsearch [::t::sent] body -get body] \
            [expr {[::t::sentEncrypted] eq ""}]
    } -result {1 0 0 hello 1}

test omemo-muc-public-room-refused {a room anyone may join cannot be switched on} \
    {*}$mucenv -body {
        ::t::join {} features {http://jabber.org/protocol/muc muc_open muc_nonanonymous}
        set code [catch {c omemo setEnabled -jid $::t::CHAT -value 1} msg opts]
        list $code [dict get $opts -errorcode] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] reasons] \
            [c omemo isEnabled -jid $::t::CHAT]
    } -result {1 {OMEMO ROOM_NOT_ELIGIBLE} not_members_only 0}

test omemo-muc-anonymous-room-refused {a room that hides real JIDs cannot be switched on} \
    {*}$mucenv -body {
        ::t::join {} features {http://jabber.org/protocol/muc muc_membersonly muc_semianonymous}
        list [catch {c omemo setEnabled -jid $::t::CHAT -value 1}] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] reasons] \
            [llength [::t::adminRequest member]]
    } -result {1 anonymous 0}

test omemo-muc-unknown-room-refused {a room that has never said what it is cannot be switched on} \
    {*}$mucenv -body {
        list [catch {c omemo setEnabled -jid $::t::CHAT -value 1}] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] reasons]
    } -result {1 unknown}

test omemo-muc-switched-on-and-off {a private room is switched on and off, each told as <Enabled>} \
    {*}$mucenv -body {
        ::t::join {}
        c omemo setEnabled -jid $::t::CHAT -value 1
        set on [c omemo isEnabled -jid $::t::CHAT]
        c omemo setEnabled -jid $::t::CHAT -value 0
        list $on [c omemo isEnabled -jid $::t::CHAT] \
            [lmap e [::t::emitted omemo <Enabled>] {dict get $e -value}]
    } -result {1 0 {1 0}}

test omemo-muc-remembers-a-private-room {a room seen private is known as one after leaving it} \
    {*}$mucenv -body {
        ::t::join {}
        c.conn feed [::t::presence juliet jid $::t::JFULL self 1 type unavailable \
            affiliation member role none]
        list [c muc isJoined -jid $::t::ROOM] [c muc roomPrivacy -jid $::t::ROOM] \
            [catch {c omemo setEnabled -jid $::t::CHAT -value 1}]
    } -result {0 {} 0}

test omemo-muc-room-pm-stays-off {a room's private message (room/nick) is not a room chat and stays off by default} \
    {*}$mucenv -body {
        list [c omemo isEnabled -jid $::t::ROOM/romeo] \
            [catch {c omemo roomStatus -jid $::t::ROOM/romeo}]
    } -result {0 1}

# =====================================================================
# Membership (muc)
# =====================================================================

test omemo-muc-members-from-the-lists {the owner, admin and member lists together are the members} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO owner $::t::MERC admin $::t::MAL member]
        set m [c muc members -jid $::t::ROOM]
        list [dict get $m list] [lsort -stride 2 [dict get $m members]]
    } -result [list complete [list $::t::JBARE member $::t::MAL member $::t::MERC admin $::t::ROMEO owner]]

test omemo-muc-members-pending-until-all-three {the member list is pending until the last list answers} \
    {*}$mucenv -body {
        ::t::join {} lists 0
        set before [dict get [c muc members -jid $::t::ROOM] list]
        ::t::reply [::t::adminRequest owner] [j query -ns http://jabber.org/protocol/muc#admin {
            j item -jid $::t::ROMEO -affiliation owner
        }]
        ::t::reply [::t::adminRequest admin] [j query -ns http://jabber.org/protocol/muc#admin]
        set mid [dict get [c muc members -jid $::t::ROOM] list]
        ::t::reply [::t::adminRequest member] [j query -ns http://jabber.org/protocol/muc#admin]
        list $before $mid [dict get [c muc members -jid $::t::ROOM]]
    } -result [list pending pending [list list complete members [list $::t::JBARE member $::t::ROMEO owner]]]

test omemo-muc-members-partial-when-one-refused {a list the room refuses leaves the others standing} \
    {*}$mucenv -body {
        ::t::join {} lists 0
        ::t::answerLists [list $::t::ROMEO member] {owner}
        c muc members -jid $::t::ROOM
    } -result [list list partial members [list $::t::JBARE member $::t::ROMEO member]]

test omemo-muc-members-refused-uses-presence {all three refused: the members are those the room shows} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r member]] lists 0
        ::t::answerLists {} {owner admin member}
        set m [c muc members -jid $::t::ROOM]
        list [dict get $m list] [dict keys [dict get $m members]]
    } -result [list presence [list $::t::ROMEO $::t::JBARE]]

test omemo-muc-members-public-room-not-asked {a room that is not private is not asked its lists} \
    {*}$mucenv -body {
        ::t::join {} features {http://jabber.org/protocol/muc muc_open muc_nonanonymous}
        list [::t::adminRequest member] [dict get [c muc members -jid $::t::ROOM] list]
    } -result {{} none}

test omemo-muc-members-presence-adds {an occupant the room makes a member is a member} \
    {*}$mucenv -body {
        ::t::join {}
        c.conn feed [::t::presence mercutio jid $::t::MERC/x affiliation member]
        dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::MERC
    } -result 1

test omemo-muc-members-leaving-keeps {a member leaving the room is still a member} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r]] members [list $::t::ROMEO member]
        c.conn feed [::t::presence romeo jid $::t::ROMEO/res type unavailable \
            affiliation member role none]
        dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::ROMEO
    } -result 1

test omemo-muc-members-321-removes {an occupant whose affiliation is taken away is no member} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r]] members [list $::t::ROMEO member]
        c.conn feed [::t::presence romeo jid $::t::ROMEO/res type unavailable \
            affiliation none role none codes 321]
        dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::ROMEO
    } -result 0

test omemo-muc-members-notice-removes-absent {the room's notice that an absent member lost the affiliation drops them} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member $::t::MERC member]
        # With 101 (a normal message), and without it (groupchat).
        c.conn feed [j message -from $::t::ROOM {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -jid $::t::ROMEO -affiliation none
                j status -code 101
            }
        }]
        c.conn feed [j message -from $::t::ROOM -type groupchat {
            j x -ns http://jabber.org/protocol/muc#user {
                j item -jid $::t::MERC -affiliation outcast
            }
        }]
        list [dict keys [dict get [c muc members -jid $::t::ROOM] members]] \
            [llength [::t::emitted muc <AffiliationChanged>]]
    } -result [list $::t::JBARE 2]

test omemo-muc-members-notice-from-occupant-ignored {an occupant cannot announce affiliations} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        c.conn feed [j message -from $::t::ROOM/mallory -type groupchat {
            j body -body hi
            j x -ns http://jabber.org/protocol/muc#user {
                j item -jid $::t::ROMEO -affiliation none
            }
        }]
        dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::ROMEO
    } -result 1

test omemo-muc-members-own-affiliation-change {an affiliation change of ours the room accepts updates the members at once} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        c muc affiliation -jid $::t::ROOM -target $::t::MERC -affiliation member
        set grant [::t::written {expr {[xsearch $w query -ns http://jabber.org/protocol/muc#admin item -get @jid] eq $::t::MERC}}]
        set before [dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::MERC]
        ::t::reply $grant ""
        set granted [dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::MERC]
        c muc affiliation -jid $::t::ROOM -target $::t::ROMEO -affiliation none
        set revoke [::t::written {expr {[xsearch $w query -ns http://jabber.org/protocol/muc#admin item -get @jid] eq $::t::ROMEO}}]
        ::t::refuse $revoke
        list $before $granted \
            [dict exists [dict get [c muc members -jid $::t::ROOM] members] $::t::ROMEO]
    } -result {0 1 1}

test omemo-muc-members-stale-reply-ignored {a list answered for an earlier join does not land in the next} \
    {*}$mucenv -body {
        ::t::join {} lists 0
        set old [::t::adminRequest member]
        set oldOwner [::t::adminRequest owner]
        set oldAdmin [::t::adminRequest admin]
        c.conn feed [::t::presence juliet jid $::t::JFULL self 1 type unavailable \
            affiliation member role none]
        ::t::join {} lists 0
        foreach req [list $oldOwner $oldAdmin] { ::t::reply $req [j query -ns http://jabber.org/protocol/muc#admin] }
        ::t::reply $old [j query -ns http://jabber.org/protocol/muc#admin {
            j item -jid $::t::MAL -affiliation member
        }]
        c muc members -jid $::t::ROOM
    } -result [list list pending members [list $::t::JBARE member]]

test omemo-muc-occupant-id-learned-when-vouched {an occupant-id is mapped to its real JID only where the room vouches for them} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        set vouched [c muc occupantJid $::t::ROOM occ-r]
        c.conn feed [::t::presence juliet jid $::t::JFULL self 1 type unavailable \
            affiliation member role none]
        ::t::join [list [list merc $::t::MERC occ-m]] \
            features {http://jabber.org/protocol/muc muc_membersonly muc_nonanonymous}
        list $vouched [c muc occupantJid $::t::ROOM occ-m]
    } -result [list $::t::ROMEO {}]

test omemo-muc-occupant-id-first-jid-stays {another JID under a known occupant-id does not replace it} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        c.conn feed [::t::presence other jid $::t::MAL/x occ occ-r]
        c muc occupantJid $::t::ROOM occ-r
    } -result $::t::ROMEO

# =====================================================================
# Sending
# =====================================================================

test omemo-muc-send-keys-every-member {a message is keyed for every device of every member and our other devices, and each reads it} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::device $::t::ROMEO 102
        ::t::device $::t::MERC 201
        ::t::device $::t::JBARE 301
        ::t::injectDevicelist $::t::ROMEO {101 102}
        ::t::injectDevicelist $::t::MERC {201}
        ::t::injectDevicelist $::t::JBARE [list [c omemo device_id] 301]
        ::t::join {} members [list $::t::ROMEO owner $::t::MERC member $::t::JBARE member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "wherefore"
        set enc [::t::sentEncrypted]
        list [::t::rids $enc] \
            [::t::read $::t::ROMEO 101 $enc] [::t::read $::t::ROMEO 102 $enc] \
            [::t::read $::t::MERC 201 $enc] [::t::read $::t::JBARE 301 $enc] \
            [string match "*OMEMO*" [xsearch [::t::sent] body -get body]] \
            [::t::rows]
    } -result [list {101 102 201 301} wherefore wherefore wherefore wherefore 1 \
        [list wherefore omemo $::t::ROOM/juliet pending]]

test omemo-muc-own-echo-confirms-silently {the room's echo of our message confirms it, keeps its text and says nothing failed} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} members [list $::t::ROMEO member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "soft"
        set echo [::t::sent]
        dict set echo attrs from $::t::ROOM/juliet
        dict set echo attrs to $::t::JFULL
        dict unset echo attrs to
        dict lappend echo children [j occupant-id -ns $::t::NS_OCC -id occ-juliet] \
            [j stanza-id -ns urn:xmpp:sid:0 -by $::t::ROOM -id s1]
        set ::_emitted {}
        c.conn feed $echo
        list [::t::rows] [::t::emitted omemo <DecryptFailed>]
    } -result [list [list soft omemo $::t::ROOM/juliet {}] {}]

test omemo-muc-send-waits-for-member-list {a send before the member list is in waits for it, then goes out} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} lists 0
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "early"
        set before [list [::t::sent] [lindex [::t::rows] 3]]
        ::t::answerLists [list $::t::ROMEO member]
        list $before [::t::read $::t::ROMEO 101 [::t::sentEncrypted]]
    } -result {{{} pending} early}

test omemo-muc-member-without-devices-fails-closed {a member with no OMEMO device stops the send, and is named} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::injectDevicelist $::t::MERC {}
        ::t::join {} members [list $::t::ROMEO member $::t::MERC member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "secret"
        set ev [lindex [::t::emitted omemo <MembersUnreachable>] 0]
        list [::t::sent] [lindex [::t::rows] 3] \
            [dict get $ev -jid] [dict get $ev -members] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] unreachable]
    } -result [list {} failed $::t::CHAT \
        [list [list jid $::t::MERC reason no_devices]] \
        [list [list jid $::t::MERC reason no_devices]]]

test omemo-muc-untrusted-member-fails-closed {a member whose every device is untrusted is not reached, and the send fails} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} members [list $::t::ROMEO member]
        c db eval {INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
            identity_pk, trust, active, last_activation)
            VALUES($::t::JBARE, $::t::ROMEO, 101, 'x', 'untrusted', 1, 0)}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "secret"
        list [::t::sent] [lindex [::t::rows] 3] \
            [dict get [lindex [::t::emitted omemo <MembersUnreachable>] 0] -members]
    } -result [list {} failed [list [list jid $::t::ROMEO reason no_usable_device]]]

test omemo-muc-untrusted-device-left-out {an untrusted device is left out while its member's other device is keyed} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::device $::t::ROMEO 102
        ::t::injectDevicelist $::t::ROMEO {101 102}
        ::t::join {} members [list $::t::ROMEO member]
        c db eval {INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
            identity_pk, trust, active, last_activation)
            VALUES($::t::JBARE, $::t::ROMEO, 102, 'x', 'untrusted', 1, 0)}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "hi"
        ::t::rids [::t::sentEncrypted]
    } -result 101

test omemo-muc-warming-member-holds-then-fails {a member whose only bundle is still on its way holds the send; given up on, it fails it} \
    {*}$mucenv -body {
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} members [list $::t::ROMEO member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "wait"
        set held [list [::t::sent] [lindex [::t::rows] 3]]
        c omemo OnBundleFetchTimeout $::t::ROMEO 101
        list $held [::t::sent] [lindex [::t::rows] 3]
    } -result {{{} pending} {} failed}

test omemo-muc-unfetched-devicelist-holds {a member whose devicelist is not in yet holds the send and has it fetched} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "wait"
        set fetch [::t::written {expr {[xsearch $w -get @to] eq $::t::ROMEO
            && [xsearch $w pubsub items -get @node] eq "eu.siacs.conversations.axolotl.devicelist"}}]
        list [::t::sent] [lindex [::t::rows] 3] [expr {$fetch ne ""}]
    } -result {{} pending 1}

test omemo-muc-room-no-longer-private-fails-closed {a room that stops qualifying with OMEMO on fails its sends instead of sending in the clear} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} members [list $::t::ROMEO member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c.conn feed [j message -from $::t::ROOM -type groupchat {
            j x -ns http://jabber.org/protocol/muc#user { j status -code 172 }
        }]
        # 172 made it ask again; now it says it is open.
        ::t::answerInfo {http://jabber.org/protocol/muc muc_open muc_nonanonymous}
        c message send -chat $::t::CHAT -body "secret"
        list [::t::sent] [lindex [::t::rows] 3] [c omemo isEnabled -jid $::t::CHAT] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] reasons]
    } -result {{} failed 1 not_members_only}

test omemo-muc-parked-send-fails-when-room-turns-public {a send waiting on the member list fails once the room says it is no longer private} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::join {} lists 0
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "secret"
        set before [lindex [::t::rows] 3]
        c.conn feed [j message -from $::t::ROOM -type groupchat {
            j x -ns http://jabber.org/protocol/muc#user { j status -code 104 }
        }]
        ::t::answerInfo {http://jabber.org/protocol/muc muc_open muc_nonanonymous}
        list $before [lindex [::t::rows] 3] [::t::sent]
    } -result {pending failed {}}

test omemo-muc-removed-member-not-keyed {a member removed from the room is not keyed for again} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::device $::t::MERC 201
        ::t::injectDevicelist $::t::ROMEO {101}
        ::t::injectDevicelist $::t::MERC {201}
        ::t::join [list [list merc $::t::MERC occ-m]] \
            members [list $::t::ROMEO member $::t::MERC member]
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body one
        set first [::t::rids [::t::sentEncrypted]]
        c.conn feed [::t::presence merc jid $::t::MERC/res type unavailable \
            affiliation none role none codes 321]
        c message send -chat $::t::CHAT -body two
        list $first [::t::rids [::t::sentEncrypted]]
    } -result {{101 201} 101}

test omemo-muc-room-without-others-keys-own-devices {a room with no other member is keyed for our own other devices} \
    {*}$mucenv -body {
        ::t::device $::t::JBARE 301
        ::t::injectDevicelist $::t::JBARE [list [c omemo device_id] 301]
        ::t::join {}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "note"
        ::t::read $::t::JBARE 301 [::t::sentEncrypted]
    } -result note

# =====================================================================
# Receiving
# =====================================================================

test omemo-muc-live-message-read-as-its-sender {a member's message is read with that member's session} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]] members [list $::t::ROMEO member]
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "but soft"] occ occ-r]
        set fp [c db onecolumn {SELECT sender_fp FROM chat_message WHERE chat_jid=$::t::CHAT}]
        list [::t::rows] [expr {$fp ne ""}] \
            [c db eval {SELECT peer_jid FROM omemo_trust WHERE peer_device=101}]
    } -result [list [list "but soft" omemo $::t::ROOM/romeo {}] 1 $::t::ROMEO]

test omemo-muc-crossed-sessions-adopt-theirs {a prekey message from a member we had started a session with ourselves opens on a fresh one} \
    {*}$mucenv -body {
        # Juliet built a session from Romeo's bundle (warming ahead), and
        # Romeo built his from hers: his first message is a prekey message
        # the session she holds cannot open.
        ::t::device $::t::ROMEO 101
        ::t::join [list [list romeo $::t::ROMEO occ-r]] members [list $::t::ROMEO member]
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "crossed"] occ occ-r]
        # And what Juliet sends next reads on Romeo's side.
        ::t::injectDevicelist $::t::ROMEO {101}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body "back"
        list [lindex [::t::rows] 0] [::t::emitted omemo <DecryptFailed>] \
            [::t::read $::t::ROMEO 101 [::t::sentEncrypted]]
    } -result {crossed {} back}

test omemo-muc-crossed-sessions-1to1 {the same holds in a 1:1 chat} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        c.conn feed [j message -from $::t::ROMEO/res -to $::t::JFULL -type chat -id x1 {
            j #as-is [::t::encryptedFrom $::t::ROMEO 101 "crossed 1:1"]
            j body -body fallback
        }]
        c db eval {SELECT body FROM chat_message WHERE chat_jid=$::t::ROMEO}
    } -result {{crossed 1:1}}

test omemo-muc-second-message-reads-on-the-session {a member's next message reads on the session the first one made} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 one] occ occ-r]
        # Juliet answered nothing, so Romeo's next is a prekey message
        # still; a third party's message is read as such too.
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 two] occ occ-r]
        lmap {b e f s} [::t::rows] {set b}
    } -result {one two}

test omemo-muc-spoofed-sender-is-read-as-the-occupant {an occupant claiming another's JID in its message is read as itself} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::device $::t::MAL 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r] [list mallory $::t::MAL occ-x]]
        # Mallory writes as her device 101 -- Romeo's id too -- and
        # claims Romeo's JID beside the ciphertext.
        set claim [j x -ns http://jabber.org/protocol/muc#user {
            j item -jid $::t::ROMEO/res
        }]
        c.conn feed [::t::roomMessage mallory \
            [::t::encryptedFrom $::t::MAL 101 "it is i"] occ occ-x extra $claim]
        list [lindex [::t::rows] 0] \
            [c db eval {SELECT peer_jid FROM omemo_trust WHERE peer_device=101}] \
            [c db eval {SELECT peer_jid FROM omemo_sessions WHERE peer_device=101}]
    } -result [list "it is i" $::t::MAL $::t::MAL]

test omemo-muc-unknown-sender-is-a-placeholder {a message from an occupant whose real JID the room never gave, that no session opens, is a placeholder and a <DecryptFailed>} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join {}
        c.conn feed [::t::roomMessage ghost \
            [::t::encryptedFrom $::t::ROMEO 101 "boo"] occ occ-g]
        set f [lindex [::t::emitted omemo <DecryptFailed>] 0]
        list [string match "*did not say who sent it*" [lindex [::t::rows] 0]] \
            [dict get $f -jid] [dict get $f -room] \
            [c db eval {SELECT count(*) FROM omemo_sessions WHERE peer_device=101}]
    } -result [list 1 $::t::ROOM/ghost $::t::CHAT 0]

test omemo-muc-occupant-id-mismatch-is-not-read-as-the-nick {a message under a nick whose presence carried another occupant-id is not read as that occupant} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::device $::t::MERC 201 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        # Someone else, now under the nick romeo, by the room's id occ-z.
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::MERC 201 "not romeo"] occ occ-z]
        list [string match "*did not say who sent it*" [lindex [::t::rows] 0]] \
            [c db eval {SELECT peer_jid FROM omemo_trust}]
    } -result {1 {}}

test omemo-muc-our-other-device-is-read {a message our other device wrote to the room is read as ours} \
    {*}$mucenv -body {
        ::t::device $::t::JBARE 301 -nosession
        ::t::join {}
        c.conn feed [::t::roomMessage juliet \
            [::t::encryptedFrom $::t::JBARE 301 "from my phone"] occ occ-juliet]
        lrange [::t::rows] 0 1
    } -result {{from my phone} omemo}

test omemo-muc-untrusted-sender-dropped {a message from a device we refuse is dropped, with nothing shown} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        c db eval {INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
            identity_pk, trust, active, last_activation)
            VALUES($::t::JBARE, $::t::ROMEO, 101, 'x', 'untrusted', 1, 0)}
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "hidden"] occ occ-r]
        list [::t::rows] [::t::emitted omemo <DecryptFailed>]
    } -result {{} {}}

test omemo-muc-not-keyed-for-us {a room message keyed for none of our devices is a placeholder} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        set enc [j encrypted -ns $::t::NS_AX {
            j header -sid 101 {
                j key -rid 999 -body [base64::encode AAAA]
                j iv -body [base64::encode [string repeat x 12]]
            }
            j payload -body [base64::encode ciphertext]
        }]
        c.conn feed [::t::roomMessage romeo $enc occ occ-r]
        string match "*not encrypted for this device*" [lindex [::t::rows] 0]
    } -result 1

# =====================================================================
# The archive
# =====================================================================

test omemo-muc-archive-read-by-occupant-id {an archived message is read as the member its occupant-id names, after they left} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        c.conn feed [::t::presence romeo jid $::t::ROMEO/res type unavailable \
            affiliation member role none occ occ-r]
        set out [c omemo decryptForwarded [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "archived"] occ occ-r]]
        list [xsearch $out body -get body] [dict get $out decrypted]
    } -result {archived 1}

test omemo-muc-archive-map-outlives-the-join {the occupant-id map is kept: history reads after a rejoin the member is not in} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        c.conn feed [::t::presence juliet jid $::t::JFULL self 1 type unavailable \
            affiliation member role none]
        ::t::join {}
        set out [c omemo decryptForwarded [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "still romeo"] occ occ-r]]
        list [xsearch $out body -get body] \
            [c db eval {SELECT real_jid FROM muc_occupant WHERE occupant_id='occ-r'}]
    } -result [list "still romeo" $::t::ROMEO]

test omemo-muc-archive-nick-alone-not-trusted {an archived message is not read by its nick, which may have changed hands} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO ""]] \
            features {http://jabber.org/protocol/muc muc_membersonly muc_nonanonymous}
        set out [c omemo decryptForwarded [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 "who"]]]
        string match "*did not say who sent it*" [xsearch $out body -get body]
    } -result 1

test omemo-muc-archive-fallback-by-session {an archived message no occupant-id names is read by the one session that opens it} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join [list [list romeo $::t::ROMEO occ-r]]
        # A live message makes the session, and Juliet answers it so
        # Romeo's next is an ordinary (not prekey) message.
        c.conn feed [::t::roomMessage romeo \
            [::t::encryptedFrom $::t::ROMEO 101 first] occ occ-r]
        ::t::injectDevicelist $::t::ROMEO {101}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body reply
        ::t::read $::t::ROMEO 101 [::t::sentEncrypted]
        set enc [::t::encryptedFrom $::t::ROMEO 101 "from the archive"]
        set prekey [xsearch $enc header key -get @prekey]
        set out [c omemo decryptForwarded [::t::roomMessage romeo $enc occ occ-new]]
        list $prekey [xsearch $out body -get body] [c muc occupantJid $::t::ROOM occ-new]
    } -result [list {} "from the archive" $::t::ROMEO]

test omemo-muc-archive-fallback-prekey-by-identity {an archived prekey message no occupant-id names is read when its identity key is one we hold} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join {}
        set ik [$::t::Store($::t::ROMEO,101) identity_pub]
        c db eval {INSERT INTO omemo_trust(account_jid, peer_jid, peer_device,
            identity_pk, trust, active, last_activation)
            VALUES($::t::JBARE, $::t::ROMEO, 101, $ik, 'undecided', 1, 0)}
        set out [c omemo decryptForwarded [::t::roomMessage nobody \
            [::t::encryptedFrom $::t::ROMEO 101 "known key"]]]
        xsearch $out body -get body
    } -result {known key}

test omemo-muc-archive-fallback-unknown-identity {an archived prekey message under an identity key we do not hold is a placeholder} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101 -nosession
        ::t::join {}
        set out [c omemo decryptForwarded [::t::roomMessage nobody \
            [::t::encryptedFrom $::t::ROMEO 101 "unknown key"]]]
        list [string match "*did not say who sent it*" [xsearch $out body -get body]] \
            [c db eval {SELECT count(*) FROM omemo_sessions}]
    } -result {1 0}

test omemo-muc-archive-own-message-blank {our own message in the room's archive is left to the row we stored} \
    {*}$mucenv -body {
        ::t::join {}
        set enc [j encrypted -ns $::t::NS_AX {
            j header -sid [c omemo device_id] {
                j key -rid 101 -body [base64::encode AAAA]
                j iv -body [base64::encode [string repeat x 12]]
            }
            j payload -body [base64::encode ciphertext]
        }]
        set out [c omemo decryptForwarded [::t::roomMessage juliet $enc occ occ-juliet]]
        list [xsearch $out body -get body] [::t::emitted omemo <DecryptFailed>]
    } -result {{} {}}

# =====================================================================
# Status and the trust list
# =====================================================================

test omemo-muc-trust-list-of-a-room {the trust list of a room lists every member's devices, each naming its member} \
    {*}$mucenv -body {
        ::t::device $::t::ROMEO 101
        ::t::device $::t::MERC 201
        foreach {jid dev} [list $::t::ROMEO 101 $::t::MERC 201] {
            c omemo EnsureTrustRow $jid $dev [$::t::Store($jid,$dev) identity_pub]
        }
        ::t::join {} members [list $::t::ROMEO member $::t::MERC member]
        lmap trow [c omemo trustList -jid $::t::CHAT] {
            list [dict get $trow jid] [dict get $trow device] [dict get $trow trust]
        }
    } -result [list [list $::t::MERC 201 undecided] [list $::t::ROMEO 101 undecided]]

test omemo-muc-room-status {roomStatus says whether the room qualifies, whether it is on and who it is keyed for} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member $::t::JBARE owner]
        c omemo setEnabled -jid $::t::CHAT -value 1
        set st [c omemo roomStatus -jid $::t::CHAT]
        list [dict get $st jid] [dict get $st eligible] [dict get $st enabled] \
            [dict get $st offered] [dict get $st member_list] \
            [lmap m [dict get $st members] {dict get $m jid}] \
            [expr {[llength [::t::emitted omemo <RoomStatus>]] > 0}]
    } -result [list $::t::CHAT 1 1 1 complete [list $::t::ROMEO] 1]

test omemo-muc-enabling-fetches-member-devicelists {switching a room on fetches its members' devicelists} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        set before [::t::written {expr {[xsearch $w -get @to] eq $::t::ROMEO}}]
        c omemo setEnabled -jid $::t::CHAT -value 1
        set after [::t::written {expr {[xsearch $w -get @to] eq $::t::ROMEO}}]
        list [expr {$before eq ""}] [xsearch $after pubsub items -get @node]
    } -result {1 eu.siacs.conversations.axolotl.devicelist}

test omemo-muc-pull-room-status {<RoomStatus> can be pulled} \
    {*}$mucenv -body {
        ::t::join {}
        set ::_emitted {}
        c omemo pull -event <RoomStatus> -jid $::t::CHAT
        dict get [lindex [::t::emitted omemo <RoomStatus>] 0] -jid
    } -result $::t::CHAT

# =====================================================================
# Each member's keys, and the room's people
# =====================================================================

# A key of $jid's on file, undecided, as the first message or bundle from
# that device would leave it.
proc ::t::key {jid dev} {
    c omemo EnsureTrustRow $jid $dev ik-$jid-$dev
}

# {jid keys trusted undecided attention reason} of each member, in order.
proc ::t::memberKeys {} {
    lmap m [dict get [c omemo roomStatus -jid $::t::CHAT] members] {
        list [dict get $m jid] [dict get $m keys] [dict get $m trusted] \
            [dict get $m undecided] [dict get $m attention] [dict get $m reason]
    }
}

test omemo-muc-member-keys {each member's keys are counted, those needing attention first} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member $::t::MERC member]
        ::t::injectDevicelist $::t::ROMEO {11 12}
        ::t::key $::t::ROMEO 11
        ::t::key $::t::ROMEO 12
        set blind [::t::memberKeys]
        # Verifying one ends blind trust for the other, which then holds a
        # send up.
        c omemo trust -jid $::t::ROMEO -device 11 -state trusted
        set verified [::t::memberKeys]
        c omemo trust -jid $::t::ROMEO -device 12 -state trusted
        list $blind $verified [::t::memberKeys] \
            [dict get [c omemo roomStatus -jid $::t::CHAT] attention]
    } -result [list \
        [list [list $::t::MERC 0 0 0 1 {}] [list $::t::ROMEO 2 0 2 0 {}]] \
        [list [list $::t::MERC 0 0 0 1 {}] [list $::t::ROMEO 2 1 1 1 {}]] \
        [list [list $::t::MERC 0 0 0 1 {}] [list $::t::ROMEO 2 2 0 0 {}]] 1]

test omemo-muc-member-keys-follow-trust {a trust change re-tells the room's status} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        ::t::injectDevicelist $::t::ROMEO {11}
        ::t::key $::t::ROMEO 11
        set ::_emitted {}
        c omemo trust -jid $::t::ROMEO -device 11 -state untrusted
        set st [dict get [lindex [::t::emitted omemo <RoomStatus>] end] -status]
        dict get [lindex [dict get $st members] 0] attention
    } -result 1

test omemo-muc-member-keys-follow-blind-trust {turning blind trust off re-tells which new keys hold a send up} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        ::t::injectDevicelist $::t::ROMEO {11}
        ::t::key $::t::ROMEO 11
        set before [::t::memberKeys]
        set ::_emitted {}
        c omemo setBlindTrust -value 0
        list $before [llength [::t::emitted omemo <RoomStatus>]] [::t::memberKeys]
    } -result [list [list [list $::t::ROMEO 1 0 1 0 {}]] 1 [list [list $::t::ROMEO 1 0 1 1 {}]]]

test omemo-muc-member-keys-name-who-stopped-a-send {a member who stopped the last send says why} \
    {*}$mucenv -body {
        ::t::join {} members [list $::t::ROMEO member]
        ::t::injectDevicelist $::t::ROMEO {}
        c omemo setEnabled -jid $::t::CHAT -value 1
        c message send -chat $::t::CHAT -body hello
        ::t::memberKeys
    } -result [list [list $::t::ROMEO 0 0 0 1 no_devices]]

# {key nick jid present group affiliation} of each person, in order.
proc ::t::people {} {
    lmap p [dict get [c muc people -jid $::t::ROOM] people] {
        list [dict get $p key] [dict get $p nick] [dict get $p jid] \
            [dict get $p present] [dict get $p group] [dict get $p affiliation]
    }
}

test omemo-muc-people {people are those in the room, then the members who are not} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r member]] \
            members [list $::t::ROMEO member $::t::MERC admin]
        set p [c muc people -jid $::t::ROOM]
        list [::t::people] [dict get $p list] [dict get $p groups] \
            [dict get [lindex [dict get $p people] 0] self] \
            [dict get [lindex [dict get $p people] 1] occupant]
    } -result [list [list \
            [list $::t::JBARE juliet $::t::JBARE 1 participant member] \
            [list $::t::ROMEO romeo $::t::ROMEO 1 participant member] \
            [list $::t::MERC {} $::t::MERC 0 absent admin]] \
        complete {participant 2 absent 1} 1 $::t::ROOM/romeo]

test omemo-muc-people-keys {a member's keys ride on their person; ours and an open room's do not} \
    {*}$mucenv -body {
        ::t::join [list [list romeo $::t::ROMEO occ-r member]] \
            members [list $::t::ROMEO member]
        ::t::injectDevicelist $::t::ROMEO {11}
        ::t::key $::t::ROMEO 11
        lmap p [dict get [c muc people -jid $::t::ROOM] people] {
            expr {[dict get $p keys] eq "" ? "" : [dict get $p keys keys]}
        }
    } -result {{} 1}

test omemo-muc-people-anonymous {an occupant the room shows no JID for is listed by nick} \
    {*}$mucenv -body {
        ::t::join [list [list romeo "" occ-r none]] \
            features {http://jabber.org/protocol/muc muc_open muc_semianonymous}
        ::t::people
    } -result [list [list $::t::JBARE juliet $::t::JBARE 1 participant member] \
        [list nick:romeo romeo {} 1 participant none]]

test omemo-muc-people-changed-once-per-burst {a burst of presences is one <PeopleChanged>} \
    {*}$mucenv -body {
        ::t::join {}
        update idletasks
        set ::_emitted {}
        foreach n {a b c} {
            c.conn feed [::t::presence $n jid $n@x.lit/r affiliation none]
        }
        set before [llength [::t::emitted muc <PeopleChanged>]]
        update idletasks
        list $before [::t::emitted muc <PeopleChanged>]
    } -result [list 0 [list [list -acc $::t::JBARE -jid $::t::ROOM]]]

test omemo-muc-people-room-caps {what we may do about the room itself} \
    {*}$mucenv -body {
        ::t::join {}
        set as [dict get [c muc people -jid $::t::ROOM] me]
        c.conn feed [::t::presence juliet jid $::t::JFULL self 1 \
            affiliation owner role visitor]
        list $as [dict get [c muc people -jid $::t::ROOM] me]
    } -result {{request_voice 0 destroy 0} {request_voice 1 destroy 1}}

test omemo-muc-people-not-joined {a room we are not in has no people} \
    {*}$mucenv -body {
        c muc people -jid $::t::ROOM
    } -result {list none groups {} me {request_voice 0 destroy 0} people {}}

cleanupTests
