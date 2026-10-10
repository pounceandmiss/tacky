# A second OMEMO party for unit tests: a picomemo store and its sessions,
# without a taco client or server. It decrypts what the client under test
# sends it and encrypts replies.
#
#   omemopeer::create P -device D        a fresh identity
#   omemopeer::bundle P                  its bundle, as BuildSessionFromBundle takes it
#   omemopeer::bundleReply P IQ          the server's answer to IQ, a fetch of it
#   omemopeer::learn P JID DEV BUNDLE    start a session with JID/DEV from its bundle
#   omemopeer::open P JID ENC            ENC's payload, as text (from JID, the
#                                        header's sid); a session is made on a
#                                        prekey message
#   omemopeer::encrypt P JID DEV TEXT    an <encrypted> node for JID/DEV alone
#   omemopeer::fingerprint P             its identity, as trustList shows it
#   omemopeer::destroy P
package require tacky::testhelpers
package provide tacky::omemopeer 0.1

namespace eval omemopeer {
    variable NS eu.siacs.conversations.axolotl
    # P -> {store S device D sessions {JID|DEV handle ...}}
    variable Peers [dict create]
    variable Counter 0
}

proc omemopeer::create {p args} {
    variable Peers
    array set opts $args
    set store ::omemopeer::store_$p
    omemo::store create $store -device $opts(-device)
    $store setup
    dict set Peers $p [dict create store $store device $opts(-device) sessions {}]
    return $p
}

proc omemopeer::bundle {p} {
    variable Peers
    [dict get $Peers $p store] bundle
}

# The server's result for $iq, a fetch of P's bundle.
proc omemopeer::bundleReply {p iq} {
    set b [bundle $p]
    set djb [list apply {{k} { base64::encode -wrapchar "" "\x05$k" }}]
    j iq -type result -id [xsearch $iq -get @id] -from [xsearch $iq -get @to] {
        j pubsub -ns http://jabber.org/protocol/pubsub {
            j items -node [xsearch $iq pubsub items -get @node] {
                j item -id current {
                    j bundle -ns $::omemopeer::NS {
                        j signedPreKeyPublic -signedPreKeyId [dict get $b spk_id] \
                            -body [{*}$djb [dict get $b spk]]
                        j signedPreKeySignature \
                            -body [base64::encode -wrapchar "" [dict get $b spks]]
                        j identityKey -body [{*}$djb [dict get $b ik]]
                        j prekeys {
                            foreach pk [dict get $b prekeys] {
                                j preKeyPublic -preKeyId [dict get $pk id] \
                                    -body [{*}$djb [dict get $pk pk]]
                            }
                        }
                    }
                }
            }
        }
    }
}

proc omemopeer::fingerprint {p} {
    variable Peers
    omemo::fingerprint [[dict get $Peers $p store] identity_pub]
}

proc omemopeer::Session {p jid dev} {
    variable Peers
    variable Counter
    set key $jid|$dev
    set sessions [dict get $Peers $p sessions]
    if {[dict exists $sessions $key]} { return [dict get $sessions $key] }
    set sess ::omemopeer::sess_[incr Counter]
    omemo::session create $sess -jid $jid -device $dev
    dict set Peers $p sessions $key $sess
    return $sess
}

proc omemopeer::learn {p jid dev bundle} {
    variable Peers
    set pk [lindex [dict get $bundle prekeys] 0]
    [Session $p $jid $dev] initiate [dict get $Peers $p store] \
        -ik [dict get $bundle ik] -spk [dict get $bundle spk] \
        -spks [dict get $bundle spks] -pk [dict get $pk pk] \
        -spk-id [dict get $bundle spk_id] -pk-id [dict get $pk id]
}

proc omemopeer::open {p jid enc} {
    variable Peers
    set me [dict get $Peers $p device]
    set dev [xsearch $enc header -get @sid]
    set key ""
    xsearch $enc header key -script kn {
        if {[xsearch $kn -get @rid] == $me} {
            set key [base64::decode [dict get $kn body]]
            set prekey [expr {[xsearch $kn -get @prekey] in {true 1}}]
        }
    }
    if {$key eq ""} { error "not encrypted for device $me" }
    set mk [[Session $p $jid $dev] decrypt_key [dict get $Peers $p store] \
        $key -prekey $prekey]
    encoding convertfrom utf-8 [omemo::decrypt_message $mk \
        [base64::decode [xsearch $enc header iv -get body]] \
        [base64::decode [xsearch $enc payload -get body]]]
}

proc omemopeer::encrypt {p jid dev text} {
    variable Peers
    variable NS
    set enc [omemo::encrypt_message [encoding convertto utf-8 $text]]
    set wrap [[Session $p $jid $dev] encrypt_key [dict get $enc key]]
    set k [base64::encode -wrapchar "" [dict get $wrap p]]
    set prekey [dict get $wrap isprekey]
    j encrypted -ns $NS {
        j header -sid [dict get $Peers $p device] {
            if {$prekey} { j key -rid $dev -prekey true -body $k } \
            else { j key -rid $dev -body $k }
            j iv -body [base64::encode -wrapchar "" [dict get $enc iv]]
        }
        j payload -body [base64::encode -wrapchar "" [dict get $enc ct]]
    }
}

proc omemopeer::destroy {p} {
    variable Peers
    if {![dict exists $Peers $p]} return
    dict for {_ sess} [dict get $Peers $p sessions] { catch {$sess destroy} }
    catch {[dict get $Peers $p store] destroy}
    dict unset Peers $p
}
