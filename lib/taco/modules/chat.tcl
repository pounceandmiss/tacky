# taco_chat - which chats the frontend shows, and how far down.
#
#   chat open  -chat J
#   chat close -chat J
#   chat view  -chat J -timestamp T    T: newest message on screen
#
# A chat is looked at while open and the app is active. Only then does a view
# move the read watermark, and notify skips it. Open is membership, not a
# count. Memory-only.

snit::type taco_chat {
    option -client -readonly yes

    variable client
    # chat_jid -> newest view held while the app was inactive, 0 for none
    variable Open

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set Open [dict create]
    }

    tackymethod open {args} {
        array set opts $args
        if {[dict exists $Open $opts(-chat)]} return
        dict set Open $opts(-chat) 0
    }

    tackymethod close {args} {
        array set opts $args
        dict unset Open $opts(-chat)
    }

    tackymethod view {args} {
        array set opts $args
        set chatJid $opts(-chat)
        set ts $opts(-timestamp)
        if {![dict exists $Open $chatJid]} return
        if {![$self isLooking -chat $chatJid]} {
            if {$ts > [dict get $Open $chatJid]} { dict set Open $chatJid $ts }
            return
        }
        $self Read $chatJid $ts
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
        dict for {chatJid ts} $Open {
            if {$ts <= 0} continue
            dict set Open $chatJid 0
            $self Read $chatJid $ts
        }
    }

    # Only a forward move, so the displayed marker goes out once.
    method Read {chatJid ts} {
        set readTs [dict get [$client message messagestore ownRead $chatJid] read_ts]
        if {$ts <= $readTs} return
        $client message markOwnRead -chat $chatJid -timestamp $ts
        $client message markDisplayed -chat $chatJid -timestamp $ts
    }

    # A standalone client (tests) has no taco.
    method AppActive {} {
        if {[catch {$client AppActive} active]} { return 1 }
        return $active
    }
}
