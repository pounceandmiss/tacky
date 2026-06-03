if 0 {
    Recent chats ordering by last message.

    Provides a "latest" method that returns chat JIDs ordered by last
    message timestamp, and emits chats <Updated> when a genuinely new
    message arrives (not backfill/catchup).

    Backfill stability:
        The constructor loads MAX(timestamp) per chat_jid from
        chat_message.  The trigger fires on every INSERT, but only
        emits when the timestamp exceeds the known max — so catchup
        messages (older timestamps) are silently skipped.

    Debouncing:
        New JIDs are collected in PendingEmits.  An `after idle`
        flush emits one chats <Updated> per JID, collapsing batch
        INSERTs into a single event.
}

snit::type taco_chats {
    option -client -readonly yes

    variable client
    variable db
    # chat_jid (raw, may have ?join) → max timestamp (usec)
    variable MaxTimestamps {} 
    # JID (stripped of ?join) → 1, flushed on idle
    variable PendingEmits {}
    variable AfterToken ""

    constructor args {
        $self configurelist $args
        set client $options(-client)
        set db [$client cget -db]
        # Load existing max timestamps. Holes sit one microsecond past
        # the newest message to mark an unfetched gap; they are not messages,
        # so exclude them or a tail hole would masquerade as the latest.
        $db eval {
            SELECT chat_jid, MAX(timestamp) AS max_ts
            FROM chat_message
            WHERE kind='message'
            GROUP BY chat_jid
        } row {
            dict set MaxTimestamps $row(chat_jid) $row(max_ts)
        }

        # Trigger calls into Tcl on every new message. Gate on kind so a
        # hole insert neither poisons the cached max nor churns the
        # chat-list ordering with a spurious <Updated>.
        $db function _chats_on_message [mymethod OnMessage]
        $db eval {
            CREATE TRIGGER IF NOT EXISTS trg_chats_on_message
            AFTER INSERT ON chat_message
            WHEN NEW.kind='message'
            BEGIN
                SELECT _chats_on_message(NEW.chat_jid, NEW.timestamp);
            END;
        }
    }

    destructor {
        catch {after cancel $AfterToken}
    }

    method OnMessage {chat_jid timestamp} {
        # Skip backfill: only emit for genuinely new messages
        if {[dict exists $MaxTimestamps $chat_jid] &&
            $timestamp <= [dict get $MaxTimestamps $chat_jid]} {
            return ""
        }
        dict set MaxTimestamps $chat_jid $timestamp

        set bareJid [regsub {\?join$} $chat_jid {}]
        dict set PendingEmits $bareJid 1
        after cancel $AfterToken
        set AfterToken [after idle [mymethod FlushEmits]]
        return ""
    }

    method FlushEmits {} {
        set AfterToken ""
        set pending $PendingEmits
        set PendingEmits [dict create]
        dict for {jid _} $pending {
            $client emit chats <Updated> -jid $jid
        }
    }

    # Not the MaxTimestamps cache: its AFTER INSERT trigger counts hole
    # rows and misses the timestamp UPDATE on MUC-echo confirmation.
    tackymethod maxTimestamp {args} {
        array set opts $args
        set jid $opts(-chat)
        set ts [$db onecolumn {
            SELECT MAX(timestamp) FROM chat_message
            WHERE chat_jid=$jid AND kind='message'
        }]
        return [expr {$ts eq "" ? "" : $ts}]
    }

    # latest — returns ordered list of bare JIDs, most recent message first.
    tackymethod latest {args} {
        set seen [dict create]
        set result {}
        $db eval {
            SELECT chat_jid FROM chat_message
            WHERE kind='message'
            GROUP BY chat_jid
            ORDER BY MAX(timestamp) DESC
        } row {
            set bareJid [regsub {\?join$} $row(chat_jid) {}]
            if {![dict exists $seen $bareJid]} {
                dict set seen $bareJid 1
                lappend result $bareJid
            }
        }
        return $result
    }
}
