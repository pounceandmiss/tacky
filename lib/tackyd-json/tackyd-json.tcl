package provide tackyd-json 0.1
package require json
package require json::write
package require snit

json::write indented false

# -- jsonify: Tcl-to-JSON converter with schema-based type hints --------
#
# Type expressions:
#   string         -> JSON string (default for unlisted fields)
#   int            -> JSON number
#   double         -> JSON number (floating point)
#   bool           -> JSON true/false
#   list           -> JSON array of strings
#   {list T}       -> JSON array of T
#   {dict S}       -> JSON object, S is {field type ...}, unlisted fields -> string
#   {map T}        -> JSON object with arbitrary keys, every value coerced to T
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
            double {
                if {$value eq ""} { return "null" }
                return [expr {double($value)}]
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
            map {
                set vhint [lindex $hint 1]
                if {$vhint eq ""} { set vhint string }
                set pairs {}
                dict for {k v} $value {
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

    # `default` is the hint used when schema_key is unregistered. Events pass a
    # dict (the built-in default); the result path passes `string`, so a scalar
    # return serializes as a JSON string instead of being parsed as a dict.
    method convert {schema_key value {default {dict {}}}} {
        if {[dict exists $schemas $schema_key]} {
            set hint [dict get $schemas $schema_key]
        } else {
            set hint $default
        }
        return [$self to_json $value $hint]
    }
}

jsonify_type jsonify \
    -types {
        message     {timestamp int newtimestamp int is_outgoing bool edited bool edited_ts int retracted bool formatting {tuples {type string offset int length int}} attachments {list {dict {url string type string name string size int mime string}}} caption string reactions {map {dict {reactors list mine bool}}}}
        occupant    {caps {dict {kick bool ban bool make_moderator bool grant_voice bool revoke_voice bool grant_membership bool revoke_membership bool}}}
        roster_item {approved bool groups list}
        bookmark    {autojoin bool}
        chat_entry  {groupchat bool autojoin bool last_activity int approved bool groups list}
        avatar_meta {bytes int width int height int}
        presence    {priority int}
        omemo_trust {device int active bool}
        audio_device {default bool}
        goto_result {messages {list message} anchor int bounded_before bool bounded_after bool}
        form        {fields {list form_field}}
        form_field  {required bool value list options {list {dict {label string value string}}} media {dict {cid string type string}}}
    } \
    -schemas {
        message/local_search    {list int}
        message/history         {list message}
        message/goto            goto_result
        message/gotoReply       goto_result
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
        muc/configGet           form
        muc/registerGet         form
        roster/get              {list roster_item}
        roster/subscription     string
        bookmarks/get           {list bookmark}
        bookmarks/autojoin      bool
        bookmarks/defaultNick   string
        account/list            list
        account/exists          bool
        account/get             {dict {enabled bool}}
        chats/latest            list
        presence/get            presence
        presence/isOnline       bool
        presence/resources      {map presence}
        audio/getVolume         double
        audio/getPreferredDevice string
        audio/enumerateDevices  {dict {capture {list audio_device} playback {list audio_device}}}
        calls/start             string
        author/get              {dict {}}
        register/media          base64
        register/form           form
        avatar/metadata         avatar_meta
        avatar/data             base64
        nick/get                string
        vcard/nick              string
        setting/list            list
        debugtap/on             int
        message/rawxml          string
        mam/query               {dict {messages list complete bool}}
        mam/metadata            {dict {start_timestamp int end_timestamp int error bool}}
        mam/formfields          list
        omemo/trustList         {list omemo_trust}
        omemo/devicelist        {list int}
        omemo/own_fingerprint   string
        omemo/device_id         int
        omemo/account_jid       string
        omemo/blindTrust        bool
        omemo/setBlindTrust     bool
        omemo/setEnabled        bool
        chatlist/get            {list chat_entry}

        message/<New>           {dict {message message}}
        message/<Patch>         {dict {messages {list message}}}
        message/<CatchupDone>   {dict {count int}}
        message/<Tail>          {dict {timestamp int}}
        file/<Update>           {dict {id int direction string state string loaded int total int url string localpath string thumbpath string error string}}
        muc/<Presence>          {dict {occupant occupant}}
        muc/<Unavailable>       {dict {codes {list int} occupant occupant}}
        muc/<NickChanged>       {dict {self bool}}
        muc/<ConfigChanged>     {dict {codes {list int}}}
        muc/<VoiceRequest>      {dict {form form}}
        chatlist/<Item>         {dict {item chat_entry}}

        omemo/<TrustList>          {dict {trustList {list omemo_trust}}}
        omemo/<BlindTrust>         {dict {value bool}}
        omemo/<Enabled>            {dict {value bool}}
        omemo/<TrustChanged>       {dict {device int}}
        omemo/<FingerprintChanged> {dict {device int}}
        omemo/<DecryptFailed>      {dict {device int}}

        audio/<Volume>          {dict {volume double}}
        debugtap/<Stanza>       {dict {tap int}}
    }

# -- helpers shared with entry-point dispatch ---------------------------

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
