package require control
package require emojipicker
package require snit

# messageactions - what the user can do to a single message: the right-click
# menu, the emoji picker behind "Add Reaction", and the reaction chips.
#
# Anything it can carry out itself (reacting, fetching raw XML) it does. The
# rest lands in a composer this doesn't own, so it goes out as a virtual event
# on -widget:
#
#   <<ReplyTo>>         -data {key author snippet}
#   <<EditMessage>>     -data {key text}
#   <<RetractMessage>>  -data key
#   <<ModerateMessage>> -data key
#   <<FindInChat>>      no data
snit::type messageactions {
    option -acc  -readonly yes
    option -chat -readonly yes
    option -tag  -readonly yes
    option -groupchat -default 0 -readonly yes

    # The widget the menu and popups hang off, and the one the events above
    # are generated on.
    option -widget -readonly yes

    # {*}$cmd $key returns the store dict of a drawn message, or "".
    option -message-command -default ""
    # {*}$cmd $jid returns what to call that author.
    option -label-command -default ""

    # MUC only: the bare room JID, and our role in it. The role is cached from
    # muc <Presence> because a live `muc myRole` query only resolves inline in
    # the direct transport, and the menu has to gate on it synchronously.
    variable Room ""
    variable MyRole ""

    constructor args {
        $self configurelist $args
        if {!$options(-groupchat)} return
        regsub {\?join$} $options(-chat) {} Room
        set Room [jid norm [jid bare $Room]]
        ::tacky listen -tag $options(-tag) muc <Presence> \
            -acc $options(-acc) -jid $Room [mymethod RefreshMyRole]
        $self RefreshMyRole
    }

    destructor {
        catch {::tacky unlisten $options(-tag)}
        catch {destroy [$self Menu]}
    }

    method rightclick {key rootX rootY} {
        set m [$self Menu]
        if {![winfo exists $m]} { menu $m -tearoff 0 }
        $m delete 0 end
        set sd [$self Message $key]
        set isOutgoing [expr {[dict exists $sd is_outgoing]
            && [dict get $sd is_outgoing]}]
        set retracted [expr {[dict exists $sd retracted]
            && [dict get $sd retracted]}]

        $m add command -label "Reply" -command [mymethod reply $key]
        $m add command -label "Add Reaction" \
            -command [mymethod pick $key $rootX $rootY]
        # Edit our own, non-retracted message (XEP-0308).
        if {$isOutgoing && !$retracted} {
            $m add command -label "Edit" -command [mymethod edit $key]
        }
        # Deletion: MUC is moderation (moderators only, XEP-0425); 1:1 is a
        # self-retraction of our own message (XEP-0424).
        if {!$retracted} {
            if {$options(-groupchat)} {
                if {$MyRole eq "moderator"} {
                    $m add command -label "Delete for everyone" \
                        -command [mymethod Announce <<ModerateMessage>> $key]
                }
            } elseif {$isOutgoing} {
                $m add command -label "Delete" \
                    -command [mymethod Announce <<RetractMessage>> $key]
            }
        }
        $m add command -label "View XML" -command [mymethod viewxml $key]
        $m add command -label "Find in Chat" \
            -command [mymethod Announce <<FindInChat>>]
        tk_popup $m $rootX $rootY
    }

    method reply {key} {
        set sd [$self Message $key]
        set author [{*}$options(-label-command) [dict get $sd from_jid]]
        set snippet [lindex [split [message_text $sd] \n] 0]
        if {[string length $snippet] > 80} {
            set snippet "[string range $snippet 0 79]…"
        }
        $self Announce <<ReplyTo>> [list $key $author $snippet]
    }

    method edit {key} {
        $self Announce <<EditMessage>> \
            [list $key [message_text [$self Message $key]]]
    }

    method viewxml {key} {
        ::tacky message rawxml -acc $options(-acc) \
            -chat $options(-chat) -timestamp $key \
            -command {apply {{xml} {
                xmlstanza showxml $xml
            }}}
    }

    # Chip click: toggle our reaction (add if absent, retract if present).
    # The backend recomputes and sends the full set either way.
    method toggle {data} {
        lassign $data key emoji
        $self React $key $emoji
    }

    # Open an emoji picker at the click point; the chosen glyph toggles our
    # reaction on the message. Override-redirect + global grab so a click
    # anywhere else dismisses it (mirrors messageentry's emoji popup).
    method pick {key rootX rootY} {
        # Unique name per open: a pending idle-destroy of a prior popup must
        # never land on a freshly reopened one at the same path.
        set pop $options(-widget).__reactpop[clock microseconds]
        toplevel $pop -borderwidth 1 -relief solid
        wm withdraw $pop
        wm overrideredirect $pop 1
        if {[tk windowingsystem] eq "x11"} {
            catch {wm attributes $pop -type popup_menu}
        }
        emojipicker $pop.p -command [mymethod OnPicked $key $pop]
        pack $pop.p -expand yes -fill both
        bind $pop <Escape> [list destroy $pop]
        bind $pop <ButtonPress> [mymethod OnPickerClick $pop %X %Y]
        wm transient $pop [winfo toplevel $options(-widget)]
        wm geometry $pop +$rootX+$rootY
        wm deiconify $pop
        raise $pop
        if {[catch {ttk::globalGrab $pop}]} { catch {grab $pop} }
        $pop.p focusSearch
    }

    method OnPicked {key pop glyph} {
        # Hide immediately for instant feedback, but defer destroy: emojipicker's
        # Click still generates <<EmojiSelected>> on $pop.p after this -command
        # returns, so the window must outlive this callback.
        catch {ttk::releaseGrab $pop}
        catch {wm withdraw $pop}
        $self React $key $glyph
        after idle [list destroy $pop]
    }

    method OnPickerClick {pop X Y} {
        if {![winfo exists $pop]} return
        set x0 [winfo rootx $pop]
        set y0 [winfo rooty $pop]
        if {$X < $x0 || $X >= $x0 + [winfo width $pop]
         || $Y < $y0 || $Y >= $y0 + [winfo height $pop]} {
            catch {ttk::releaseGrab $pop}
            destroy $pop
        }
    }

    method React {key emoji} {
        ::tacky message react -acc $options(-acc) -chat $options(-chat) \
            -timestamp $key -emoji $emoji
    }

    # Re-read our role; seeded at construction and re-run on each of our own
    # presence updates, since role changes arrive as presence.
    method RefreshMyRole {args} {
        ::tacky muc myRole -acc $options(-acc) -jid $Room \
            -tag $options(-tag) -command [mymethod SetMyRole]
    }

    method SetMyRole {role} { set MyRole $role }

    method Menu {} { return $options(-widget).__ctxmenu }

    method Message {key} { {*}$options(-message-command) $key }

    method Announce {event {data ""}} {
        event generate $options(-widget) $event -data $data
    }
}
