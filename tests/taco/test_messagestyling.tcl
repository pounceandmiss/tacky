# Unit tests for messagestyling (XEP-0393)
package require tcltest
namespace import ::tcltest::*
package require taco

test ms-plain {plain text passthrough} -body {
    messagestyling::parse "hello world"
} -result {display_body {hello world} entities {}}

test ms-bold {bold span} -body {
    messagestyling::parse "*bold*"
} -result {display_body bold entities {bold 0 4}}

test ms-italic {italic span} -body {
    messagestyling::parse "_italic_"
} -result {display_body italic entities {italic 0 6}}

test ms-overstrike {overstrike span} -body {
    messagestyling::parse "~struck~"
} -result {display_body struck entities {overstrike 0 6}}

test ms-monospace {monospace span} -body {
    messagestyling::parse "`code`"
} -result {display_body code entities {monospace 0 4}}

test ms-bold-in-text {bold span in surrounding text} -body {
    messagestyling::parse "hello *bold* world"
} -result {display_body {hello bold world} entities {bold 6 4}}

test ms-compound {compound bold+italic} -body {
    messagestyling::parse "*_bold italic_*"
} -result {display_body {bold italic} entities {bold.italic 0 11}}

test ms-preformatted {preformatted block} -body {
    messagestyling::parse "```\ncode here\n```"
} -result {display_body {code here} entities {preformatted 0 9}}

test ms-quote {block quote} -body {
    set result [messagestyling::parse "> quoted text"]
    list [dict get $result display_body] \
         [lrange [dict get $result entities] 0 2]
} -result {{> quoted text} {quote 0 13}}

test ms-unclosed-bold {unclosed bold is literal} -body {
    messagestyling::parse "*not closed"
} -result {display_body {*not closed} entities {}}

test ms-empty-span {empty span is literal} -body {
    messagestyling::parse "**"
} -result {display_body ** entities {}}

test ms-enrich-with-body {enrich adds formatting to message dict} -body {
    set msg [dict create body "*hello*" from_jid foo@bar timestamp 1]
    set result [messagestyling::enrich $msg]
    list [dict get $result body] [dict get $result formatting]
} -result {hello {bold 0 5}}

test ms-enrich-plain {enrich with plain text has no formatting key} -body {
    set msg [dict create body "hello" from_jid foo@bar timestamp 1]
    set result [messagestyling::enrich $msg]
    list [dict get $result body] [dict exists $result formatting]
} -result {hello 0}

test ms-enrich-no-body {enrich skips dict without body} -body {
    set msg [dict create patch 1 timestamp 1]
    messagestyling::enrich $msg
} -result {patch 1 timestamp 1}

test ms-enrich-empty-body {enrich skips empty body} -body {
    set msg [dict create body "" from_jid foo@bar timestamp 1]
    set result [messagestyling::enrich $msg]
    list [dict get $result body] [dict exists $result formatting]
} -result {{} 0}
