# taco_chat - which chats the frontend shows, and how far down.
#
#   chat open  -chat J
#   chat close -chat J
#   chat view  -chat J -id I           I: last message on screen
#   chat setClientData -chat J -data S
#   chat clientData    -chat J          -> S
#
# A chat is looked at while open and the app is active. Only then does a view
# move the read watermark, and notify skips it. Open is membership, not a
# count. Memory-only, except client data: an opaque per-chat string, stored.

snit::type taco_chat {
    option -client -readonly yes

    variable client
    # chat_jid -> the last message in view while the app was inactive, ""
    # for none
    variable Open

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Open [dict create]
    }

    tackymethod open {args} {
        array set opts $args
        if {[dict exists $Open $opts(-chat)]} return
        dict set Open $opts(-chat) ""
    }

    tackymethod close {args} {
        array set opts $args
        dict unset Open $opts(-chat)
    }

    tackymethod view {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set id $opts(-id)
        if {![dict exists $Open $chatJid]} return
        if {![$self isLooking -chat $chatJid]} {
            if {[$self Below [dict get $Open $chatJid] $id $chatJid]} {
                dict set Open $chatJid $id
            }
            return
        }
        $self Read $chatJid $id
    }

    tackymethod setClientData {args} {
        array set opts $args
        $client message messagestore setClientData $opts(-chat) $opts(-data)
    }

    tackymethod clientData {args} {
        array set opts $args
        $client message messagestore clientData $opts(-chat)
    }

    tackymethod isOpen {args} {
        array set opts $args
        dict exists $Open $opts(-chat)
    }

    tackymethod isLooking {args} {
        array set opts $args
        expr {[dict exists $Open $opts(-chat)] && [$self AppActive]}
    }

    # app setActive calls this when the app becomes active.
    method ApplyHeld {} {
        dict for {chatJid id} $Open {
            if {$id eq ""} continue
            dict set Open $chatJid ""
            $self Read $chatJid $id
        }
    }

    # Whether row $a ("" for none) sits before row $b in $chatJid.
    method Below {a b chatJid} {
        if {$a eq ""} { return 1 }
        set pa [$client message messagestore PosOf $chatJid $a]
        set pb [$client message messagestore PosOf $chatJid $b]
        expr {$pb ne "" && ($pa eq "" || [string compare $pa $pb] < 0)}
    }

    # Only a forward move, and only for what lies past the old watermark, so
    # each displayed marker goes out once.
    method Read {chatJid id} {
        set read [dict get [$client message messagestore ownRead $chatJid] id]
        if {![$self Below $read $id $chatJid]} return
        $client message markOwnRead -chat $chatJid -id $id
        $client message markDisplayed -chat $chatJid -id $id -after $read
    }

    # A standalone client (tests) has no taco.
    method AppActive {} {
        if {[catch {$client AppActive} active]} { return 1 }
        return $active
    }
}
