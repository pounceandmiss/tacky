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

test ms-compound {overlapping bold+italic stay separate single-type spans} -body {
    messagestyling::parse "*_bold italic_*"
} -result {display_body {bold italic} entities {italic 0 11 bold 0 11}}

test ms-nested {italic nested in bold is a separate contained span} -body {
    messagestyling::parse "*bold _ital_ x*"
} -result {display_body {bold ital x} entities {italic 5 4 bold 0 11}}

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

test ms-link-bare {a body that is only a link, past parse's fast path} -body {
    set result [messagestyling::enrich [dict create body "https://example.com/a"]]
    list [dict get $result body] [dict get $result formatting]
} -result {https://example.com/a {link 0 21}}

test ms-link-in-quote {a link inside a quote, set off by angle brackets} -body {
    dict get [messagestyling::enrich \
        [dict create body "> Новости дня < https://example.com/news/1 >"]] \
        formatting
} -result {quote 0 44 link 16 26}

test ms-link-trailing-punctuation {sentence punctuation stays out} -body {
    messagestyling::links "see https://example.com/a. Or https://example.com/b, ok?" {}
} -result {link 4 21 link 30 21}

test ms-link-parens {a paren the link opened stays, one it did not goes} -body {
    list [messagestyling::links "(see https://example.com/a)" {}] \
         [messagestyling::links "https://example.com/a_(b)" {}]
} -result {{link 5 21} {link 0 25}}

test ms-link-in-code {links quoted as code are not links} -body {
    list [dict get [messagestyling::enrich \
              [dict create body "`https://example.com/a`"]] formatting] \
         [dict get [messagestyling::enrich \
              [dict create body "```\ncurl https://example.com/a\n```"]] formatting]
} -result {{monospace 0 21} {preformatted 0 26}}

test ms-link-schemes {mailto and geo link, other schemes stay text} -body {
    messagestyling::links \
        "mailto:a@example.com geo:1,2 javascript:x xmpp:a@example.com ftp://x" {}
} -result {link 0 20 link 21 7}

test ms-link-scheme-only {a scheme with nothing after it is no link} -body {
    messagestyling::links "https:// and mailto:." {}
} -result {}

test ms-link-mid-word {a scheme glued to a word is not a link start} -body {
    messagestyling::links "xhttps://example.com" {}
} -result {}

test ms-link-code-points {offsets count code points past an emoji} -body {
    messagestyling::links "\U1F600 https://example.com" {}
} -result {link 2 19}

test ms-link-styled {a link in bold keeps both spans} -body {
    dict get [messagestyling::enrich \
        [dict create body "*https://example.com*"]] formatting
} -result {bold 0 19 link 0 19}

test ms-enrich-empty-body {enrich skips empty body} -body {
    set msg [dict create body "" from_jid foo@bar timestamp 1]
    set result [messagestyling::enrich $msg]
    list [dict get $result body] [dict exists $result formatting]
} -result {{} 0}
