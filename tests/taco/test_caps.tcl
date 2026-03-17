# Unit tests for capsmod (XEP-0115)

set caps_common {
    -setup {
        tacky_type create tacky
        oo::objdefine tacky method emit {module event args} {}
        rename conn _real_conn
        rename mock_conn conn
        taco_client c \
            -host test.example.com -port 5222 \
            -username user -password pass -resource res
    }
    -cleanup {
        catch {c destroy}
        rename conn mock_conn
        rename _real_conn conn
        tacky destroy
    }
}

test caps-verstr-1 {XEP-0115 example verification string} {*}$caps_common -body {
    # Build the XEP example disco#info query node using j
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {http://psi-im.org#q07IKJEyjvHSyhy//CH0CxmKi8w=} {
        j identity -xml:lang en -category client -name {Psi 0.11} -type pc
        j identity -xml:lang el -category client -name "\u03A8 0.11" -type pc
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/disco#items
        j feature -var http://jabber.org/protocol/muc
        j x -ns jabber:x:data -type result {
            j field -var FORM_TYPE -type hidden {
                j value #body urn:xmpp:dataforms:softwareinfo
            }
            j field -var ip_version -type text-multi {
                j value #body ipv4
                j value #body ipv6
            }
            j field -var os {
                j value #body Mac
            }
            j field -var os_version {
                j value #body 10.5.1
            }
            j field -var software {
                j value #body Psi
            }
            j field -var software_version {
                j value #body 0.11
            }
        }
    }]

    c.caps VerificationString $queryNode
} -result "client/pc/el/\u03A8 0.11<client/pc/en/Psi 0.11<http://jabber.org/protocol/caps<http://jabber.org/protocol/disco#info<http://jabber.org/protocol/disco#items<http://jabber.org/protocol/muc<urn:xmpp:dataforms:softwareinfo<ip_version<ipv4<ipv6<os<Mac<os_version<10.5.1<software<Psi<software_version<0.11<"

test caps-hash-1 {XEP-0115 example hash} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {http://psi-im.org#q07IKJEyjvHSyhy//CH0CxmKi8w=} {
        j identity -xml:lang en -category client -name {Psi 0.11} -type pc
        j identity -xml:lang el -category client -name "\u03A8 0.11" -type pc
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/disco#items
        j feature -var http://jabber.org/protocol/muc
        j x -ns jabber:x:data -type result {
            j field -var FORM_TYPE -type hidden {
                j value #body urn:xmpp:dataforms:softwareinfo
            }
            j field -var ip_version -type text-multi {
                j value #body ipv4
                j value #body ipv6
            }
            j field -var os {
                j value #body Mac
            }
            j field -var os_version {
                j value #body 10.5.1
            }
            j field -var software {
                j value #body Psi
            }
            j field -var software_version {
                j value #body 0.11
            }
        }
    }]

    c.caps HashDiscoQuery $queryNode
} -result {q07IKJEyjvHSyhy//CH0CxmKi8w=}

test caps-hash-2 {Cheogram real-world verification hash} {*}$caps_common -body {
    set queryNode [j query -ns http://jabber.org/protocol/disco#info \
        -node {https://cheogram.com#hAx0qhppW5/ZjrpXmbXW0F2SJVM=} {
        j identity -type phone -name Cheogram -category client
        j feature -var eu.siacs.conversations.axolotl.devicelist+notify
        j feature -var http://jabber.org/protocol/caps
        j feature -var http://jabber.org/protocol/chatstates
        j feature -var http://jabber.org/protocol/disco#info
        j feature -var http://jabber.org/protocol/muc
        j feature -var http://jabber.org/protocol/nick+notify
        j feature -var http://jabber.org/protocol/xhtml-im
        j feature -var jabber:iq:version
        j feature -var jabber:x:conference
        j feature -var jabber:x:oob
        j feature -var urn:xmpp:avatar:metadata+notify
        j feature -var urn:xmpp:bob
        j feature -var urn:xmpp:bookmarks:1+notify
        j feature -var urn:xmpp:chat-markers:0
        j feature -var urn:xmpp:idle:1
        j feature -var urn:xmpp:jingle-message:0
        j feature -var urn:xmpp:jingle:1
        j feature -var urn:xmpp:jingle:apps:dtls:0
        j feature -var urn:xmpp:jingle:apps:file-transfer:5
        j feature -var urn:xmpp:jingle:apps:rtp:1
        j feature -var urn:xmpp:jingle:apps:rtp:audio
        j feature -var urn:xmpp:jingle:apps:rtp:video
        j feature -var urn:xmpp:jingle:jet-omemo:0
        j feature -var urn:xmpp:jingle:jet:0
        j feature -var urn:xmpp:jingle:transports:ibb:1
        j feature -var urn:xmpp:jingle:transports:ice-udp:1
        j feature -var urn:xmpp:jingle:transports:s5b:1
        j feature -var urn:xmpp:jingle:transports:webrtc-datachannel:1
        j feature -var urn:xmpp:mds:displayed:0+notify
        j feature -var urn:xmpp:message-correct:0
        j feature -var urn:xmpp:ping
        j feature -var urn:xmpp:receipts
        j feature -var urn:xmpp:time
    }]

    c.caps HashDiscoQuery $queryNode
} -result {hAx0qhppW5/ZjrpXmbXW0F2SJVM=}
