#!/usr/bin/env tclsh9.0
# Child process entry point that speaks JSON over lenpipe.
#
# Incoming (stdin):  ["module","method",{args}]          fire-and-forget
#                    ["module","method",{args},token]     request/response
# Outgoing (stdout): ["event","module","<Event>",{args}] broadcast
#                    ["result",token,data]                success reply
#                    ["error",token,message]              error reply

lappend auto_path [file join [file dirname [info script]] libtacky]
package require json
package require json::write
package require snit
package require taco
package require lenpipe
json::write indented false

# -- jsonify: Tcl-to-JSON converter with schema-based type hints --------
#
# Type expressions:
#   string         -> JSON string (default for unlisted fields)
#   int            -> JSON number
#   bool           -> JSON true/false
#   list           -> JSON array of strings
#   {list T}       -> JSON array of T
#   {dict S}       -> JSON object, S is {field type ...}, unlisted fields -> string
#   base64         -> binary data encoded as base64 JSON string
#   {tuples S}     -> flat list grouped by fields of S into JSON array of objects
#   <name>         -> named type lookup (always a dict schema)
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
            tuples {
                set schema [lindex $hint 1]
                set keys [dict keys $schema]
                set items {}
                foreach $keys $value {
                    set d {}
                    foreach k $keys {
                        dict set d $k [set $k]
                    }
                    lappend items [$self to_json $d [list dict $schema]]
                }
                return [json::write array {*}$items]
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
                # Unknown type -> string fallback
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
        message     {timestamp int prev int patch bool formatting {tuples {type string offset int length int}}}
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
        muc/getSubject          string
        muc/myNick              string
        muc/myRole              string
        muc/myAffiliation       string
        muc/haveVoice           bool
        muc/isJoined            bool
        muc/occupant            occupant
        muc/occupants           {list occupant}
        muc/rooms               list
        roster/get              {list roster_item}
        roster/subscription     string
        bookmarks/get           {list bookmark}
        bookmarks/autojoin      bool
        bookmarks/defaultNick   string
        account/list            list
        account/exists          bool
        account/get             {dict {enabled bool}}
        chats/latest            list
        chats/maxTimestamp      int
        presence/get            presence
        presence/isOnline       bool
        avatar/metadata         avatar_meta
        avatar/thumb            base64
        avatar/data             base64
        nick/get                string
        vcard/nick              string
        setting/list            list
        debugtap/on             int
        message/rawxml          string
        mam/query               {dict {messages list complete bool}}
        mam/metadata            {dict {start_timestamp int end_timestamp int error bool}}
        mam/formfields          list
        chatlist/search         {dict {
            recent    {list roster_item}
            roster    {list roster_item}
            bookmarks {list bookmark}
        }}

        message/<Received>      {dict {message message}}
        message/<Sent>          {dict {message message}}
        message/<Patch>         {dict {message message}}
        message/<CatchupDone>   {dict {count int}}
        muc/<Presence>          {dict {occupant occupant}}
        muc/<Unavailable>       {dict {codes {list int} occupant occupant}}
        muc/<NickChanged>       {dict {self bool}}
        muc/<ConfigChanged>     {dict {codes {list int}}}
        chatlist/<RecentTop>    {dict {autojoin bool}}
    }

# -- tackyd-json backend logic -------------------------------------------

proc strip_dashes {d} {
    set out {}
    dict for {k v} $d { lappend out [string trimleft $k -] $v }
    return $out
}

proc add_dashes {d} {
    set out {}
    dict for {k v} $d { lappend out -$k $v }
    return $out
}

proc pipesend {msg} {
    set bytes [encoding convertto utf-8 $msg]
    puts stdout [string length $bytes]
    puts -nonewline stdout $bytes
    flush stdout
}

# Maps callback token -> schema key (e.g. "roster/get") so the emit
# path can serialise the result with the right schema.
variable _token_schemas [dict create]

# Define "tacky" command before creating taco_type,
# because taco constructor calls `tacky emit` for existing accounts.
namespace eval ::tacky_ns {
    namespace export emit
    namespace ensemble create -command ::tacky
    proc emit {module event args} {
        # Callback results/errors -> ["result", token, data] / ["error", token, msg]
        if {$module eq "callback" && [dict exists $args -token]} {
            set token [dict get $args -token]
            if {[dict exists $::_token_schemas $token]} {
                set schema [dict get $::_token_schemas $token]
                dict unset ::_token_schemas $token
            } else {
                set schema $module/$event
            }
            set result [dict get $args -result]
            if {$event eq "<Error>"} {
                pipesend [json::write array \
                    [json::write string error] \
                    $token \
                    [json::write string $result]]
            } else {
                pipesend [json::write array \
                    [json::write string result] \
                    $token \
                    [jsonify convert $schema $result]]
            }
            return
        }
        # Broadcast events -> ["event", module, "<Event>", {args}]
        set args [strip_dashes $args]
        set json_args [jsonify convert $module/$event $args]
        pipesend [json::write array \
            [json::write string event] \
            [json::write string $module] \
            [json::write string $event] \
            $json_args]
    }
}

# -- main: only run when executed directly, not when sourced by tests ----

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    # Configure stdout for writing
    chan configure stdout -translation binary -buffering full

    # Read JSON commands from stdin via lenpipe.
    # json2dict turns a JSON array into a Tcl list:
    #   ["chatlist","search",{"-acc":"a@b"},5] -> {chatlist search {-acc a@b} 5}
    lenpipe create _pipe stdin \
        -onmessage {apply {{msg} {
            set parts [::json::json2dict $msg]
            set module [lindex $parts 0]
            set method [lindex $parts 1]
            set args [lindex $parts 2]
            set args [add_dashes $args]
            # Optional token (4th element) -> wire up -command/-onerror internally.
            set token [lindex $parts 3]
            if {$token ne ""} {
                dict set ::_token_schemas $token $module/$method
                dict set args -command \
                    [list tacky emit callback <Result> -token $token -result]
                dict set args -onerror \
                    [list tacky emit callback <Error> -token $token -result]
            }
            taco $module $method {*}$args
        }}} \
        -oneof {apply {{} {
            taco destroy
            exit 0
        }}}

    taco_type create taco {*}$::argv
    vwait forever
}
