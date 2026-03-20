package require snit
package require json::write
json::write indented false

# Tcl-to-JSON converter with schema-based type hints.
#
# Type expressions:
#   string         → JSON string (default for unlisted fields)
#   int            → JSON number
#   bool           → JSON true/false
#   list           → JSON array of strings
#   {list T}       → JSON array of T
#   {dict S}       → JSON object, S is {field type ...}, unlisted fields → string
#   base64         → binary data encoded as base64 JSON string
#   <name>         → named type lookup (always a dict schema)
#
# Usage:
#   jsonify to_json $value $type
#   jsonify convert $schema_key $value

snit::type jsonify_type {
    variable types {}
    variable schemas {}

    constructor {args} {
        array set opts {-types {} -schemas {}}
        array set opts $args
        set types $opts(-types)
        set schemas $opts(-schemas)
    }

    method to_json {value hint} {
        set base [lindex $hint 0]
        switch $base {
            string {
                return [json::write string $value]
            }
            int {
                if {$value eq ""} { return "null" }
                return [expr {entier($value)}]
            }
            bool {
                if {$value eq ""} { return "false" }
                return [expr {$value ? "true" : "false"}]
            }
            base64 {
                return [json::write string [binary encode base64 $value]]
            }
            list {
                set subhint [lindex $hint 1]
                if {$subhint eq ""} { set subhint string }
                return [json::write array {*}[lmap v $value {
                    $self to_json $v $subhint
                }]]
            }
            dict {
                set schema [lindex $hint 1]
                set pairs {}
                dict for {k v} $value {
                    set vhint string
                    if {[dict exists $schema $k]} {
                        set vhint [dict get $schema $k]
                    }
                    lappend pairs $k [$self to_json $v $vhint]
                }
                return [json::write object {*}$pairs]
            }
            default {
                # Named type lookup
                if {[dict exists $types $base]} {
                    return [$self to_json $value [list dict [dict get $types $base]]]
                }
                # Unknown type → string fallback
                return [json::write string $value]
            }
        }
    }

    method convert {schema_key value} {
        if {[dict exists $schemas $schema_key]} {
            set hint [dict get $schemas $schema_key]
        } else {
            set hint {dict {}}
        }
        return [$self to_json $value $hint]
    }
}

jsonify_type jsonify \
    -types {
        message     {timestamp int prev int hollow bool}
        occupant    {}
        roster_item {approved bool groups list}
        bookmark    {autojoin bool}
        avatar_meta {bytes int width int height int}
        presence    {priority int}
    } \
    -schemas {
        message/local_search    {list int}
        message/history         {list message}
        message/goto            {list message}
        message/search          {dict {messages {list message} complete bool}}
        muc/getList             {list {dict {}}}
        muc/discoverRooms       {list {dict {}}}
        muc/reservedNick        string
        roster/get              {list roster_item}
        bookmarks/get           {list bookmark}
        bookmarks/autojoin      bool
        account/list            list
        account/exists          bool
        account/get             {dict {enabled bool}}
        chats/latest            list
        presence/get            presence
        presence/isOnline       bool
        avatar/metadata         avatar_meta
        avatar/thumb            base64
        avatar/data             base64
        mam/query               {dict {messages list complete bool}}
        mam/metadata            {dict {start_timestamp int end_timestamp int error bool}}
        mam/formfields          list
        chatlist/search         {dict {
            recent    {list roster_item}
            roster    {list roster_item}
            bookmarks {list bookmark}
        }}

        message/<Received>      {dict {message message timestamp int}}
        message/<Sent>          {dict {message message}}
        message/<Confirmed>     {dict {timestamp int}}
        message/<CatchupDone>   {dict {count int}}
        muc/<Presence>          {dict {occupant occupant}}
        muc/<Unavailable>       {dict {codes {list int} occupant occupant}}
        muc/<NickChanged>       {dict {self bool}}
        muc/<ConfigChanged>     {dict {codes {list int}}}
        chatlist/<RecentTop>    {dict {autojoin bool}}
    }
